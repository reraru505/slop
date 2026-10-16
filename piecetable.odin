// Package piecetable implements an efficient text buffer backed by a piece
// table. It is designed for text editors: insertions and deletions do not
// move the document's contents; instead the document is represented as a
// balanced sequence of immutable "pieces" that reference spans of two
// append-only buffers (the original text and the added text).
//
// Performance characteristics (P = number of pieces, N = newlines in a buffer)
//   - insert / delete / replace: O(log P) to locate and splice, plus O(edited
//     bytes) to copy inserted text into the add buffer. Adjacent pieces that
//     are contiguous in the same buffer are coalesced, so sequential typing
//     keeps P at 1 and costs O(edited bytes).
//   - reading the full text: O(document length).
//   - line <-> offset mapping: O(log P + log N + one index block) rather than
//     a scan of the document.
//   - undo / redo: O(edited bytes) per step; history is stored as deltas, not
//     as copies of the piece list.
//
// The piece sequence is an implicit treap whose nodes cache subtree byte and
// newline totals, so both byte offsets and line numbers can be resolved by
// descent. Each buffer keeps a cumulative newline index sampled at fixed byte
// boundaries, which bounds intra-piece newline counting to a single block.
//
// All allocations use the current context.allocator, following Odin idiom.
package main

import "core:strings"

// Byte block size for a buffer's newline index. `cum[j]` holds the number of
// newlines in data[0 : j*NEWLINE_BLOCK], so counting newlines before an offset
// is O(1) plus a scan of at most one block, in either direction.
NEWLINE_BLOCK :: 256

// BufferKind identifies which underlying buffer a piece refers to.
BufferKind :: enum u8 {
	Original, // the immutable text the table was initialized with
	Add,      // the append-only buffer holding all inserted text
}

// Piece is a contiguous span of bytes in one of the two buffers.
Piece :: struct {
	kind:   BufferKind,
	start:  int, // byte offset into the buffer
	length: int, // number of bytes
	lines:  int, // number of '\n' bytes in this span (line-count cache)
}

// Buf is an append-only byte buffer plus a cumulative newline index sampled at
// fixed byte boundaries.
Buf :: struct {
	data:     [dynamic]u8,
	cum:      [dynamic]u32, // cum[j] = newlines in data[0 : j*NEWLINE_BLOCK]
	newlines: int, // total '\n' count
}

// Node is a node of the implicit treap over pieces. The in-order walk of the
// treap is the document. Subtree aggregates (size, bytes, lines) let both byte
// offsets and line numbers be resolved by descent.
Node :: struct {
	left, right: ^Node,
	prio:        u32,
	piece:       Piece,
	size:        int, // nodes in subtree
	bytes:       int, // bytes in subtree (including this piece)
	lines:       int, // newlines in subtree
}

// Edit is one undoable operation, stored as a delta rather than a full copy of
// the piece list: `removed` are the spans that were deleted at `offset` (in
// order) and `added` is the span that was inserted at `offset`.
Edit :: struct {
	offset:  int,
	added:   Piece,            // length == 0 when nothing was inserted
	removed: [dynamic]Piece,   // empty when nothing was deleted
}

// PieceTable is the main type. Zero value is not usable; call init first.
PieceTable :: struct {
	original: Buf,
	add:      Buf,
	root:     ^Node,
	length:     int,
	line_count: int,

	// node pool: chunks are never reallocated, so node pointers stay valid
	chunks:     [dynamic][]Node,
	chunk:      []Node,
	chunk_used: int,
	free:       ^Node,

	record_undo: bool,
	undo_stack:  [dynamic]Edit,
	redo_stack:  [dynamic]Edit,

	rng: u64,

	// lazily materialized flat view of the piece list (for inspection)
	pieces:       [dynamic]Piece,
	pieces_valid: bool,
}

// init initializes a zero-value PieceTable, optionally with initial text.
// The original text is copied into the original buffer.
init :: proc(pt: ^PieceTable, initial: string = "") {
	buf_init(&pt.original)
	buf_init(&pt.add)
	pt.record_undo = true
	pt.rng = 0x9E3779B97F4A7C15
	pt.pieces_valid = true
	if len(initial) == 0 {
		return
	}
	buf_append(&pt.original, transmute([]u8) initial)
	p := Piece {
		kind   = .Original,
		start  = 0,
		length = len(initial),
		lines  = pt.original.newlines,
	}
	pt.root = node_new(pt, p)
	pt.length = len(initial)
	pt.line_count = p.lines
}

// new_piece_table allocates and returns a ready-to-use table with optional
// initial text.
new_piece_table :: proc(initial: string = "") -> PieceTable {
	pt: PieceTable
	init(&pt, initial)
	return pt
}

// destroy releases all memory held by the table, including undo history.
destroy :: proc(pt: ^PieceTable) {
	for c in pt.chunks {
		delete(c)
	}
	delete(pt.chunks)
	delete(pt.original.data)
	delete(pt.original.cum)
	delete(pt.add.data)
	delete(pt.add.cum)
	for e in pt.undo_stack {
		delete(e.removed)
	}
	for e in pt.redo_stack {
		delete(e.removed)
	}
	delete(pt.undo_stack)
	delete(pt.redo_stack)
	delete(pt.pieces)
	pt^ = {}
}

// --- Accessors -------------------------------------------------------------

// get_length returns the document size in bytes.
get_length :: proc(pt: ^PieceTable) -> int {
	return pt.length
}

// get_line_count returns the number of newline characters in the document.
// The number of logical lines is therefore get_line_count(pt) + 1.
get_line_count :: proc(pt: ^PieceTable) -> int {
	return pt.line_count
}

// piece_count returns how many pieces currently make up the document.
piece_count :: proc(pt: ^PieceTable) -> int {
	return sub_size(pt.root)
}

// pieces_slice returns the current piece list in document order. The result is
// owned by the table and is invalidated by the next edit.
pieces_slice :: proc(pt: ^PieceTable) -> []Piece {
	if !pt.pieces_valid {
		clear(&pt.pieces)
		collect_inorder(pt.root, &pt.pieces)
		pt.pieces_valid = true
	}
	return pt.pieces[:]
}

// is_empty reports whether the document has zero bytes.
is_empty :: proc(pt: ^PieceTable) -> bool {
	return pt.length == 0
}

// --- Editing ---------------------------------------------------------------

// insert places text at the given byte offset. The offset is clamped to
// [0, length]. The operation is recorded for undo.
insert :: proc(pt: ^PieceTable, offset: int, text: string) {
	if len(text) == 0 {
		return
	}
	o := clamp(offset, 0, pt.length)
	added := insert_impl(pt, o, text)
	if pt.record_undo {
		push_edit(pt, Edit{offset = o, added = added})
	}
}

// delete_range removes length bytes starting at offset. The range is clamped
// to the document. The operation is recorded for undo.
delete_range :: proc(pt: ^PieceTable, offset, length: int) {
	if length <= 0 || pt.length == 0 {
		return
	}
	o := clamp(offset, 0, pt.length)
	l := min(length, pt.length - o)
	if l == 0 {
		return
	}
	removed: [dynamic]Piece
	if pt.record_undo {
		delete_impl(pt, o, l, &removed)
		push_edit(pt, Edit{offset = o, removed = removed})
	} else {
		delete_impl(pt, o, l, nil)
	}
}

// replace overwrites the byte range [offset, offset+length) with text, in a
// single undo step.
replace :: proc(pt: ^PieceTable, offset, length: int, text: string) {
	if length <= 0 && len(text) == 0 {
		return
	}
	o := clamp(offset, 0, pt.length)
	removed: [dynamic]Piece
	l := 0
	if length > 0 {
		l = min(length, pt.length - o)
	}
	if l > 0 {
		if pt.record_undo {
			delete_impl(pt, o, l, &removed)
		} else {
			delete_impl(pt, o, l, nil)
		}
	}
	added: Piece
	if len(text) > 0 {
		added = insert_impl(pt, o, text)
	}
	if l == 0 && added.length == 0 {
		return
	}
	if pt.record_undo {
		push_edit(pt, Edit{offset = o, added = added, removed = removed})
	}
}

// --- Reading ---------------------------------------------------------------

// write_text appends the byte range [offset, offset+length) to a
// strings.Builder. Returns false if the range is out of bounds.
write_text :: proc(pt: ^PieceTable, offset, length: int, b: ^strings.Builder) -> bool {
	if offset < 0 || length < 0 || offset + length > pt.length {
		return false
	}
	if length == 0 {
		return true
	}
	write_range(pt, pt.root, 0, offset, offset + length, b)
	return true
}

// text returns the byte range [offset, offset+length) as an allocated string.
text :: proc(pt: ^PieceTable, offset, length: int, allocator := context.allocator) -> (string, bool) {
	if offset < 0 || length < 0 || offset + length > pt.length {
		return "", false
	}
	b := strings.builder_make_len_cap(0, length, allocator)
	write_text(pt, offset, length, &b)
	return strings.to_string(b), true
}

// full_text returns the entire document as an allocated string.
full_text :: proc(pt: ^PieceTable, allocator := context.allocator) -> string {
	s, _ := text(pt, 0, pt.length, allocator)
	return s
}

// byte_at returns the byte at offset, or 0 if offset is out of range.
byte_at :: proc(pt: ^PieceTable, offset: int) -> byte {
	if offset < 0 || offset >= pt.length {
		return 0
	}
	rem := offset
	for n := pt.root; n != nil; {
		lb := sub_bytes(n.left)
		if rem < lb {
			n = n.left
			continue
		}
		rem -= lb
		if rem < n.piece.length {
			return piece_data(pt, n.piece)[rem]
		}
		rem -= n.piece.length
		n = n.right
	}
	return 0
}

// --- Line mapping ----------------------------------------------------------

// line_to_offset returns the byte offset of the start of the 0-based line.
// Lines beyond the document clamp to pt.length.
line_to_offset :: proc(pt: ^PieceTable, line: int) -> int {
	if line <= 0 {
		return 0
	}
	if line > pt.line_count {
		return pt.length
	}
	rem := line // newlines still to cross
	off := 0
	for n := pt.root; n != nil; {
		ll := sub_lines(n.left)
		if rem <= ll {
			n = n.left
			continue
		}
		rem -= ll
		off += sub_bytes(n.left)
		if rem <= n.piece.lines {
			buf := buf_of(pt, n.piece.kind)
			base := nl_before(buf, n.piece.start)
			ord := base + rem - 1
			abs := nth_newline_offset(buf, ord)
			return off + (abs - n.piece.start) + 1
		}
		rem -= n.piece.lines
		off += n.piece.length
		n = n.right
	}
	return pt.length
}

// offset_to_line returns the 0-based line number containing the given byte
// offset. The offset is clamped to the document.
offset_to_line :: proc(pt: ^PieceTable, offset: int) -> int {
	rem := clamp(offset, 0, pt.length)
	line := 0
	for n := pt.root; n != nil; {
		lb := sub_bytes(n.left)
		if rem < lb {
			n = n.left
			continue
		}
		rem -= lb
		line += sub_lines(n.left)
		if rem < n.piece.length {
			if n.piece.lines > 0 {
				line += count_newlines(pt, n.piece, rem)
			}
			return line
		}
		rem -= n.piece.length
		line += n.piece.lines
		n = n.right
	}
	return line
}

// line_text returns the text of the 0-based line without its trailing
// newline (and optional carriage return). ok is false when line is out of
// range.
line_text :: proc(pt: ^PieceTable, line: int, allocator := context.allocator) -> (string, bool) {
	if line < 0 || line > pt.line_count {
		return "", false
	}
	start := line_to_offset(pt, line)
	end := line_to_offset(pt, line + 1)
	if end > start && byte_at(pt, end - 1) == '\n' {
		end -= 1
		if end > start && byte_at(pt, end - 1) == '\r' {
			end -= 1
		}
	}
	return text(pt, start, end - start, allocator)
}

// --- Undo / redo -----------------------------------------------------------

// set_undo_enabled toggles whether edits are recorded in the undo history.
// Disabling it drops nothing already recorded; use clear_undo for that.
set_undo_enabled :: proc(pt: ^PieceTable, enabled: bool) {
	pt.record_undo = enabled
}

// undo reverts the most recent recorded edit. Returns false if there is
// nothing to undo.
undo :: proc(pt: ^PieceTable) -> bool {
	if len(pt.undo_stack) == 0 {
		return false
	}
	e := pop(&pt.undo_stack)
	if e.added.length > 0 {
		delete_impl(pt, e.offset, e.added.length, nil)
	}
	if len(e.removed) > 0 {
		insert_spans_impl(pt, e.offset, e.removed[:])
	}
	append(&pt.redo_stack, e)
	return true
}

// redo reapplies the most recently undone edit. Returns false if there is
// nothing to redo.
redo :: proc(pt: ^PieceTable) -> bool {
	if len(pt.redo_stack) == 0 {
		return false
	}
	e := pop(&pt.redo_stack)
	if len(e.removed) > 0 {
		total := 0
		for p in e.removed {
			total += p.length
		}
		delete_impl(pt, e.offset, total, nil)
	}
	if e.added.length > 0 {
		insert_spans_impl(pt, e.offset, []Piece{e.added})
	}
	append(&pt.undo_stack, e)
	return true
}

// clear_undo drops all undo history.
clear_undo :: proc(pt: ^PieceTable) {
	for e in pt.undo_stack {
		delete(e.removed)
	}
	clear(&pt.undo_stack)
}

// clear_redo drops all redo history.
clear_redo :: proc(pt: ^PieceTable) {
	for e in pt.redo_stack {
		delete(e.removed)
	}
	clear(&pt.redo_stack)
}

// --- Editing internals -----------------------------------------------------

// insert_impl performs an insert without recording undo and returns the span
// of add-buffer bytes that was inserted. If the piece just before the insertion
// point is an add piece ending exactly where the new bytes begin, the bytes are
// folded into it instead of creating a new piece.
insert_impl :: proc(pt: ^PieceTable, offset: int, text: string) -> Piece {
	add_start := len(pt.add.data)
	buf_append(&pt.add, transmute([]u8) text)
	p := Piece {
		kind   = .Add,
		start  = add_start,
		length = len(text),
		lines  = count_newlines_bytes(transmute([]u8) text),
	}

	a, b := split_bytes(pt, pt.root, offset)
	if a != nil {
		m := tree_max(a)
		if m.piece.kind == .Add && m.piece.start + m.piece.length == add_start {
			// fold the new bytes into the piece that ends where they begin
			mm, rest := pop_max(a)
			mm.piece.length += p.length
			mm.piece.lines += p.lines
			node_update(mm)
			pt.root = merge(merge(rest, mm), b)
			pt.length += p.length
			pt.line_count += p.lines
			pt.pieces_valid = false
			return p
		}
	}

	mid := node_new(pt, p)
	pt.root = merge(merge(a, mid), b)
	pt.length += p.length
	pt.line_count += p.lines
	pt.pieces_valid = false
	return p
}

// delete_impl removes the byte range [offset, offset+length) without recording
// undo. When out is non-nil it receives the removed spans in document order.
delete_impl :: proc(pt: ^PieceTable, offset, length: int, out: ^[dynamic]Piece) {
	a, b := split_bytes(pt, pt.root, offset)
	mid, c := split_bytes(pt, b, length)

	removed_bytes := sub_bytes(mid)
	removed_lines := sub_lines(mid)
	if out != nil {
		collect_inorder(mid, out)
	}
	free_tree(pt, mid)

	pt.length -= removed_bytes
	pt.line_count -= removed_lines
	pt.root = join(pt, a, c)
	pt.pieces_valid = false
}

// insert_spans_impl inserts already-existing buffer spans (used by undo/redo)
// at offset, without copying any bytes.
insert_spans_impl :: proc(pt: ^PieceTable, offset: int, spans: []Piece) {
	if len(spans) == 0 {
		return
	}
	total_bytes := 0
	total_lines := 0
	mid: ^Node
	for p in spans {
		total_bytes += p.length
		total_lines += p.lines
		mid = merge(mid, node_new(pt, p))
	}
	a, b := split_bytes(pt, pt.root, offset)
	pt.root = join(pt, join(pt, a, mid), b)
	pt.length += total_bytes
	pt.line_count += total_lines
	pt.pieces_valid = false
}

// push_edit records an edit for undo and clears the redo stack.
push_edit :: proc(pt: ^PieceTable, e: Edit) {
	clear_redo(pt)
	append(&pt.undo_stack, e)
}

// --- Treap -----------------------------------------------------------------

sub_size :: proc(n: ^Node) -> int {
	return n == nil ? 0 : n.size
}

sub_bytes :: proc(n: ^Node) -> int {
	return n == nil ? 0 : n.bytes
}

sub_lines :: proc(n: ^Node) -> int {
	return n == nil ? 0 : n.lines
}

node_update :: proc(n: ^Node) {
	if n == nil {
		return
	}
	n.size = 1 + sub_size(n.left) + sub_size(n.right)
	n.bytes = n.piece.length + sub_bytes(n.left) + sub_bytes(n.right)
	n.lines = n.piece.lines + sub_lines(n.left) + sub_lines(n.right)
}

node_new :: proc(pt: ^PieceTable, p: Piece) -> ^Node {
	n := pool_alloc(pt)
	n.piece = p
	n.prio = rand_prio(pt)
	node_update(n)
	return n
}

// merge joins two treaps whose key ranges are ordered (all of a before all of b).
merge :: proc(a, b: ^Node) -> ^Node {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	if a.prio > b.prio {
		a.right = merge(a.right, b)
		node_update(a)
		return a
	}
	b.left = merge(a, b.left)
	node_update(b)
	return b
}

// join merges two ordered treaps, coalescing the pieces that meet at the seam
// when they are contiguous in the same buffer.
join :: proc(pt: ^PieceTable, a, b: ^Node) -> ^Node {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	am := tree_max(a)
	bm := tree_min(b)
	if !pieces_contiguous(am.piece, bm.piece) {
		return merge(a, b)
	}
	amx, arest := pop_max(a)
	bmn, brest := pop_min(b)
	amx.piece.length += bmn.piece.length
	amx.piece.lines += bmn.piece.lines
	node_update(amx)
	pool_free(pt, bmn)
	return merge(merge(arest, amx), brest)
}

// pieces_contiguous reports whether span q starts exactly where p ends in the
// same buffer, i.e. whether the two can be represented as one piece.
pieces_contiguous :: proc(p, q: Piece) -> bool {
	return p.kind == q.kind && p.start + p.length == q.start
}

// tree_max returns the rightmost node without modifying the tree.
tree_max :: proc(n: ^Node) -> ^Node {
	m := n
	for m.right != nil {
		m = m.right
	}
	return m
}

// tree_min returns the leftmost node without modifying the tree.
tree_min :: proc(n: ^Node) -> ^Node {
	m := n
	for m.left != nil {
		m = m.left
	}
	return m
}

// pop_max removes and returns the maximum (rightmost) node, detached, plus the
// remaining tree.
pop_max :: proc(n: ^Node) -> (m: ^Node, rest: ^Node) {
	if n.right == nil {
		l := n.left
		n.left = nil
		node_update(n)
		return n, l
	}
	m2, r2 := pop_max(n.right)
	n.right = r2
	node_update(n)
	return m2, n
}

// pop_min removes and returns the minimum (leftmost) node, detached, plus the
// remaining tree.
pop_min :: proc(n: ^Node) -> (m: ^Node, rest: ^Node) {
	if n.left == nil {
		r := n.right
		n.right = nil
		node_update(n)
		return n, r
	}
	m2, r2 := pop_min(n.left)
	n.left = r2
	node_update(n)
	return m2, n
}

// split_bytes splits the treap so that the left result covers exactly the first
// k bytes of the document, splitting the boundary piece if necessary.
split_bytes :: proc(pt: ^PieceTable, n: ^Node, k: int) -> (l: ^Node, r: ^Node) {
	if n == nil {
		return nil, nil
	}
	lb := sub_bytes(n.left)
	if k < lb {
		l2, r2 := split_bytes(pt, n.left, k)
		n.left = r2
		node_update(n)
		return l2, n
	}
	if k > lb + n.piece.length {
		l2, r2 := split_bytes(pt, n.right, k - lb - n.piece.length)
		n.right = l2
		node_update(n)
		return n, r2
	}
	rel := k - lb
	if rel == 0 {
		l2 := n.left
		n.left = nil
		node_update(n)
		return l2, n
	}
	if rel == n.piece.length {
		r2 := n.right
		n.right = nil
		node_update(n)
		return n, r2
	}
	left_piece := n.piece
	left_piece.length = rel
	left_piece.lines = count_newlines(pt, n.piece, rel)
	right_piece := n.piece
	right_piece.start += rel
	right_piece.length -= rel
	right_piece.lines = n.piece.lines - left_piece.lines

	rn := node_new(pt, right_piece)
	rn.right = n.right
	node_update(rn)
	n.piece = left_piece
	n.right = nil
	node_update(n)
	return n, rn
}

collect_inorder :: proc(n: ^Node, out: ^[dynamic]Piece) {
	if n == nil {
		return
	}
	collect_inorder(n.left, out)
	append(out, n.piece)
	collect_inorder(n.right, out)
}

free_tree :: proc(pt: ^PieceTable, n: ^Node) {
	if n == nil {
		return
	}
	free_tree(pt, n.left)
	free_tree(pt, n.right)
	pool_free(pt, n)
}

write_range :: proc(pt: ^PieceTable, n: ^Node, base, from, to: int, b: ^strings.Builder) {
	if n == nil {
		return
	}
	if base >= to {
		return
	}
	if base + sub_bytes(n) <= from {
		return
	}
	write_range(pt, n.left, base, from, to, b)
	node_start := base + sub_bytes(n.left)
	if node_start < to && node_start + n.piece.length > from {
		s := max(node_start, from) - node_start
		e := min(node_start + n.piece.length, to) - node_start
		data := piece_data(pt, n.piece)
		strings.write_bytes(b, data[s:e])
	}
	write_range(pt, n.right, node_start + n.piece.length, from, to, b)
}

// --- Node pool -------------------------------------------------------------

NODE_CHUNK :: 4096

pool_alloc :: proc(pt: ^PieceTable) -> ^Node {
	if pt.free != nil {
		n := pt.free
		pt.free = n.left
		n^ = {}
		return n
	}
	if pt.chunk == nil || pt.chunk_used >= len(pt.chunk) {
		c := make([]Node, NODE_CHUNK)
		append(&pt.chunks, c)
		pt.chunk = c
		pt.chunk_used = 0
	}
	n := &pt.chunk[pt.chunk_used]
	pt.chunk_used += 1
	n^ = {}
	return n
}

pool_free :: proc(pt: ^PieceTable, n: ^Node) {
	n.left = pt.free
	pt.free = n
}

rand_prio :: proc(pt: ^PieceTable) -> u32 {
	x := pt.rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	pt.rng = x
	return u32(x >> 32)
}

// --- Buffers and newline index ---------------------------------------------

buf_of :: proc(pt: ^PieceTable, kind: BufferKind) -> ^Buf {
	switch kind {
	case .Original:
		return &pt.original
	case .Add:
		return &pt.add
	}
	return nil
}

piece_data :: proc(pt: ^PieceTable, p: Piece) -> []u8 {
	switch p.kind {
	case .Original:
		return pt.original.data[p.start:p.start + p.length]
	case .Add:
		return pt.add.data[p.start:p.start + p.length]
	}
	return nil
}

// buf_init prepares an empty buffer and its newline index.
buf_init :: proc(b: ^Buf) {
	append(&b.cum, 0) // boundary 0 has zero preceding newlines
}

// buf_append appends bytes to a buffer and extends its cumulative newline index.
buf_append :: proc(b: ^Buf, data: []u8) {
	if len(data) == 0 {
		return
	}
	base := len(b.data)
	append(&b.data, ..data)
	for i in 0 ..< len(data) {
		if data[i] == '\n' {
			b.newlines += 1
		}
		if (base + i + 1) % NEWLINE_BLOCK == 0 {
			append(&b.cum, u32(b.newlines))
		}
	}
}

// nl_before returns the number of '\n' bytes in data[0:off].
nl_before :: proc(b: ^Buf, off: int) -> int {
	if off <= 0 || b.newlines == 0 {
		return 0
	}
	j := off / NEWLINE_BLOCK
	total := int(b.cum[j])
	for i := j * NEWLINE_BLOCK; i < off; i += 1 {
		if b.data[i] == '\n' {
			total += 1
		}
	}
	return total
}

// nth_newline_offset returns the absolute offset of the k-th newline (0-based).
nth_newline_offset :: proc(b: ^Buf, k: int) -> int {
	target := k + 1 // 1-based ordinal
	// largest j with cum[j] < target; cum[0] == 0 < target, so j >= 0
	lo, hi := 0, len(b.cum)
	for lo < hi {
		mid := (lo + hi) / 2
		if int(b.cum[mid]) < target {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	j := lo - 1
	rem := target - int(b.cum[j])
	p := j * NEWLINE_BLOCK
	for {
		if b.data[p] == '\n' {
			rem -= 1
			if rem == 0 {
				return p
			}
		}
		p += 1
	}
}

// count_newlines returns the number of newlines in the first rel bytes of p.
count_newlines :: proc(pt: ^PieceTable, p: Piece, rel: int) -> int {
	if rel <= 0 || p.lines == 0 {
		return 0
	}
	b := buf_of(pt, p.kind)
	return nl_before(b, p.start + rel) - nl_before(b, p.start)
}

count_newlines_bytes :: proc(data: []u8) -> (n: int) {
	for b in data {
		if b == '\n' {
			n += 1
		}
	}
	return
}

pt_init            :: init
pt_destroy         :: destroy
pt_get_length      :: get_length
pt_get_line_count  :: get_line_count
pt_insert          :: insert
pt_delete_range    :: delete_range
pt_replace         :: replace
pt_line_to_offset  :: line_to_offset
pt_offset_to_line  :: offset_to_line
pt_line_text       :: line_text
pt_full_text       :: full_text
pt_byte_at         :: byte_at
pt_undo            :: undo
pt_redo            :: redo
