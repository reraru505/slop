package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

EditorMode :: enum {
    Normal,
    Insert,
    Visual,
    Command,
}

Line_Ending :: enum {
    LF,
    CRLF,
}

// Highlight results are cached per visible slot, keyed by row + content hash +
// file/theme. This keeps per-frame cost to a cheap hash for unchanged lines.
SYNTAX_CACHE_SLOTS :: 256

Syntax_Cache_Entry :: struct {
    valid:      bool,
    row:        int,
    hash:       u64,
    state_hash: u64,
    state_out:  Syntax_State,
    colors:     [dynamic]sdl.FColor,
}

syntax_cache_hash :: proc(line: string, seed: u64) -> u64 {
    h := seed
    for b in line {
        h = (h ~ u64(b)) * 1099511628211
    }
    return h
}

CompletionState :: struct {
    active         : bool,
    items          : [dynamic]LspCompletionItem,
    all_items      : [dynamic]LspCompletionItem,
    selected       : int,
    scroll_offset  : int,
    trigger_row    : int,
    trigger_col    : int,
    prefix         : string,
}

Editor :: struct {
    table              : PieceTable,
    cursor             : Cursor,
    selection_anchor   : Cursor,
    mode               : EditorMode,
    scroll_row         : int,
    scroll_col         : int,
    last_action        : time.Time,
    pending_cmd        : rune,
    font_scale         : FONT_SCALE,
    char_advance       : f32,
    file_path          : string,
    dirty              : bool,
    command_buffer     : [dynamic]u8,
    status_message     : string,
    status_message_buf : [256]u8,
    desired_col        : int,
    needs_lsp_sync     : bool,
    last_edit_time     : time.Time,
    completion         : CompletionState,
    read_only          : bool,
    lsp_doc_open       : bool,
    line_ending        : Line_Ending,
    syntax_cache       : [SYNTAX_CACHE_SLOTS]Syntax_Cache_Entry,
    // state after line i; len == number of lines whose outgoing state is known.
    syntax_states      : [dynamic]Syntax_State,
    syntax_scratch     : [dynamic]sdl.FColor,
}

// Odin's fmt zero-pads width-formatted numbers by default; the gutter needs
// space padding so line numbers stay right-aligned without becoming "0001".
format_line_number :: proc(line_number, digits: int) -> string {
    return fmt.tprintf("% *d ", digits, line_number)
}

editor_set_status_message :: proc(e: ^Editor, msg: string) {
    if e == nil do return
    n := copy(e.status_message_buf[:], msg)
    e.status_message = string(e.status_message_buf[:n])
}

editor_init :: proc(e: ^Editor, font: ^Font, initial_text := "", file_path := "") {
    e.line_ending = .CRLF if strings.contains(initial_text, "\r\n") else .LF
    pt_init(&e.table, initial_text)
    set_undo_grouping(&e.table, true)
    e.char_advance = font_cell_width(font)
    e.font_scale = .HALF
    e.mode = .Normal
    e.cursor = Cursor{
        col   = 0,
        row   = 0,
        shape = .Block,
        color = sdl.FColor{0.92, 0.92, 0.92, 1.0},
    }
    e.selection_anchor = e.cursor
    e.desired_col = 0
    e.scroll_row = 0
    e.scroll_col = 0
    e.last_action = time.now()
    e.pending_cmd = 0
    e.file_path = strings.clone(file_path)
    e.syntax_cache = {}
    e.syntax_states = make([dynamic]Syntax_State, 0, 64)
    e.syntax_scratch = make([dynamic]sdl.FColor, 0, 256)
    e.dirty = false
    e.command_buffer = make([dynamic]u8, context.allocator)
    editor_set_status_message(e, "")
    e.needs_lsp_sync = false
    e.last_edit_time = time.now()
    e.read_only = false
    e.lsp_doc_open = false
    e.completion.active = false
    e.completion.items = make([dynamic]LspCompletionItem, 0, 32)
    e.completion.all_items = make([dynamic]LspCompletionItem, 0, 64)
    e.completion.prefix = ""
}

editor_destroy :: proc(e: ^Editor) {
    for entry in e.syntax_cache {
        delete(entry.colors)
    }
    e.syntax_cache = {}
    delete(e.syntax_states)
    delete(e.syntax_scratch)
    pt_destroy(&e.table)
    delete(e.command_buffer)
    for c in e.completion.items {
        delete(c.label)
        delete(c.detail)
        delete(c.documentation)
        delete(c.insert_text)
    }
    delete(e.completion.items)
    for c in e.completion.all_items {
        delete(c.label)
        delete(c.detail)
        delete(c.documentation)
        delete(c.insert_text)
    }
    delete(e.completion.all_items)
    if e.completion.prefix != "" do delete(e.completion.prefix)
    if e.file_path != "" {
        delete(e.file_path)
        e.file_path = ""
    }
}

editor_eol :: proc(e: ^Editor) -> string {
    return "\r\n" if e.line_ending == .CRLF else "\n"
}

// Normalize inserted text (paste, completion, LSP edits) to the buffer's line
// ending so a CRLF file never gains bare LF bytes.
editor_normalize_newlines :: proc(
    e: ^Editor,
    text: string,
    allocator: runtime.Allocator = context.temp_allocator,
) -> string {
    eol := editor_eol(e)
    b: strings.Builder
    strings.builder_init(&b, 0, len(text) + 16, allocator)
    i := 0
    for i < len(text) {
        c := text[i]
        if c == '\r' {
            strings.write_string(&b, eol)
            i += 1
            if i < len(text) && text[i] == '\n' do i += 1
            continue
        }
        if c == '\n' {
            strings.write_string(&b, eol)
            i += 1
            continue
        }
        strings.write_byte(&b, c)
        i += 1
    }
    return strings.to_string(b)
}

// Every buffer mutation must mark the buffer dirty and schedule an LSP sync.
editor_mark_dirty :: proc(e: ^Editor, from_row := -1) {
    e.dirty = true
    e.needs_lsp_sync = true
    e.last_edit_time = time.now()
    row := from_row if from_row >= 0 else e.cursor.row
    editor_invalidate_syntax(e, row)
}

// Invalidate cached line-continuation states at/after `from_row`. States for
// earlier lines are unaffected because lexing only flows downward.
editor_invalidate_syntax :: proc(e: ^Editor, from_row: int) {
    row := max(0, from_row)
    if row < len(e.syntax_states) {
        resize(&e.syntax_states, row)
    }
}

// State entering `row`, computing any missing predecessor states.
editor_ensure_syntax_state :: proc(e: ^Editor, row: int, theme: ^Theme) -> Syntax_State {
    if row <= 0 do return {}
    total_lines := pt_get_line_count(&e.table) + 1
    target := min(row, total_lines)
    for len(e.syntax_states) < target {
        idx := len(e.syntax_states)
        line, ok := pt_line_text(&e.table, idx)
        if !ok do break
        resize(&e.syntax_scratch, len(line))
        state_in: Syntax_State
        if idx > 0 do state_in = e.syntax_states[idx - 1]
        state_out := syntax_highlight_line_state(e.file_path, line, theme, e.syntax_scratch[:], state_in)
        append(&e.syntax_states, state_out)
        delete(line)
    }
    if row - 1 < len(e.syntax_states) do return e.syntax_states[row - 1]
    return {}
}

editor_record_syntax_state :: proc(e: ^Editor, row: int, state: Syntax_State) {
    if row == len(e.syntax_states) {
        append(&e.syntax_states, state)
    } else if row < len(e.syntax_states) {
        e.syntax_states[row] = state
    }
}

// Compound edits (line moves, multi-edit formatting, paste-over-selection) are
// recorded as a single undo step.
editor_begin_undo_transaction :: proc(e: ^Editor) {
    pt_begin_undo_transaction(&e.table)
}

editor_end_undo_transaction :: proc(e: ^Editor) {
    pt_end_undo_transaction(&e.table)
}

editor_get_line_len :: proc(e: ^Editor, row: int) -> int {
    total_lines := pt_get_line_count(&e.table) + 1
    if row < 0 || row >= total_lines do return 0

    start_off := pt_line_to_offset(&e.table, row)
    if row + 1 < total_lines {
        next_off := pt_line_to_offset(&e.table, row + 1)
        len := next_off - start_off - 1
        if len > 0 && pt_byte_at(&e.table, start_off + len - 1) == '\r' {
            len -= 1
        }
        return max(0, len)
    } else {
        total_len := pt_get_length(&e.table)
        return max(0, total_len - start_off)
    }
}

// Move the cursor to a 1-based line, scrolling so it is comfortably visible.
editor_goto_line :: proc(e: ^Editor, line_1based: int) {
    break_undo_group(&e.table)
    total_lines := pt_get_line_count(&e.table) + 1
    e.cursor.row = clamp(line_1based - 1, 0, total_lines - 1)
    e.cursor.col = 0
    e.desired_col = 0
    e.scroll_row = max(0, e.cursor.row - 10)
    editor_clamp_cursor(e)
}

// Tabs occupy this many character cells when rendered.
TAB_WIDTH :: 4

// Convert a byte column to the visual (cell) column used for drawing.
editor_visual_col :: proc(e: ^Editor, row, byte_col: int) -> int {
    line_len := editor_get_line_len(e, row)
    col := clamp(byte_col, 0, line_len)
    visual := 0
    i := 0
    for i < col {
        r, size := editor_rune_at(e, row, i)
        if size <= 0 do break
        if r == '\t' {
            visual += TAB_WIDTH
        } else {
            visual += rune_display_width(r)
        }
        i += size
    }
    // Columns past EOL are virtual and count one cell each.
    if byte_col > line_len do visual += byte_col - line_len
    return visual
}

// Convert a visual column back to a byte column. A position inside an expanded
// tab snaps to the tab's byte.
editor_byte_col_for_visual :: proc(e: ^Editor, row, visual_col: int) -> int {
    if visual_col <= 0 do return 0
    line_len := editor_get_line_len(e, row)
    visual := 0
    i := 0
    for i < line_len {
        r, size := editor_rune_at(e, row, i)
        if size <= 0 do break
        width := TAB_WIDTH if r == '\t' else rune_display_width(r)
        // A position inside a wide glyph or expanded tab snaps to its start.
        if visual + width > visual_col do return i
        visual += width
        if visual == visual_col do return i + size
        i += size
    }
    // Preserve virtual columns past EOL.
    if visual_col > visual do return line_len + (visual_col - visual)
    return line_len
}

// Vertical moves keep the desired virtual column, but `$` uses 999999 as a
// sticky end-of-line marker and must land at the target line's EOL instead of
// materializing a million virtual spaces.
DESIRED_EOL :: 999_999

editor_col_for_vertical_move :: proc(e: ^Editor, row: int) -> int {
    if e.desired_col >= DESIRED_EOL do return editor_get_line_len(e, row)
    return editor_byte_col_for_visual(e, row, e.desired_col)
}

editor_get_cursor_offset :: proc(e: ^Editor) -> int {
    start_off := pt_line_to_offset(&e.table, e.cursor.row)
    line_len := editor_get_line_len(e, e.cursor.row)
    col := editor_clamp_col_to_rune(e, e.cursor.row, clamp(e.cursor.col, 0, line_len))
    return start_off + col
}

editor_realize_virtual_spaces :: proc(e: ^Editor) {
    line_len := editor_get_line_len(e, e.cursor.row)
    if e.cursor.col > line_len {
        spaces_needed := e.cursor.col - line_len
        spaces := make([]u8, spaces_needed, context.temp_allocator)
        for i in 0 ..< spaces_needed {
            spaces[i] = ' '
        }
        start_off := pt_line_to_offset(&e.table, e.cursor.row)
        pt_insert(&e.table, start_off + line_len, string(spaces))
        editor_mark_dirty(e)
    }
}

editor_clamp_cursor :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    e.cursor.row = clamp(e.cursor.row, 0, max(0, total_lines - 1))
    e.cursor.col = max(0, e.cursor.col)
    // Never leave the cursor inside a multi-byte rune.
    line_len := editor_get_line_len(e, e.cursor.row)
    if e.cursor.col <= line_len {
        e.cursor.col = editor_clamp_col_to_rune(e, e.cursor.row, e.cursor.col)
    }
}

// Clamp after an operation that may have shortened or removed the current
// line, and resynchronize the desired column (used by undo/redo/LSP edits).
editor_snap_cursor :: proc(e: ^Editor) {
    editor_clamp_cursor(e)
    e.cursor.col = min(e.cursor.col, editor_get_line_len(e, e.cursor.row))
    e.cursor.col = editor_clamp_col_to_rune(e, e.cursor.row, e.cursor.col)
    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
}

editor_scroll_to_cursor :: proc(e: ^Editor, visible_lines: int, visible_cols: int) {
    if visible_lines <= 0 || visible_cols <= 0 do return

    margin := 2
    if visible_lines <= 4 do margin = 0

    if e.cursor.row < e.scroll_row + margin {
        e.scroll_row = max(0, e.cursor.row - margin)
    } else if e.cursor.row >= e.scroll_row + visible_lines - margin {
        e.scroll_row = e.cursor.row - visible_lines + 1 + margin
    }

    // scroll_col is a visual (cell) column, matching cursor_vis/selection math.
    vis_col := editor_visual_col(e, e.cursor.row, e.cursor.col)
    if vis_col < e.scroll_col {
        e.scroll_col = vis_col
    } else if vis_col >= e.scroll_col + visible_cols {
        e.scroll_col = vis_col - visible_cols + 1
    }
}

editor_set_mode :: proc(e: ^Editor, new_mode: EditorMode, window: ^sdl.Window) {
    break_undo_group(&e.table)
    e.mode = new_mode
    e.last_action = time.now()
    e.pending_cmd = 0

    if new_mode == .Insert || new_mode == .Command {
        e.cursor.shape = .Bar
        if window != nil do _ = sdl.StartTextInput(window)
    } else {
        e.cursor.shape = .Block
        if window != nil do _ = sdl.StopTextInput(window)
        editor_clamp_cursor(e)
    }
}

editor_save_file :: proc(e: ^Editor, app: ^App = nil) -> bool {
    if e.read_only {
        editor_set_status_message(e, "Buffer is read-only")
        return false
    }
    if e.file_path == "" do return false
    full := pt_full_text(&e.table)
    defer delete(full)
    err := os.write_entire_file(e.file_path, transmute([]u8)full)
    if err == nil {
        e.dirty = false
        editor_set_status_message(e, "File saved successfully.")
        if e.needs_lsp_sync {
            e.needs_lsp_sync = false
            app_lsp_doc_change(app, e.file_path, full)
        }
        lsp := app_get_lsp_for_file(app, e.file_path)
        if lsp != nil && lsp_is_running(lsp) {
            lsp_did_save(lsp, e.file_path)
        }
        return true
    }
    editor_set_status_message(e, "Error: Failed to save file.")
    return false
}

// Word movement helpers (rune-aware; UTF-8 continuation bytes are never
// treated as standalone characters).
editor_skip_whitespace_forward :: proc(e: ^Editor) {
    line_len := editor_get_line_len(e, e.cursor.row)
    for e.cursor.col < line_len {
        r, size := editor_rune_at(e, e.cursor.row, e.cursor.col)
        if size <= 0 do break
        if r != ' ' && r != '\t' do break
        e.cursor.col += size
    }
}

editor_motion_word_forward :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    line_len := editor_get_line_len(e, e.cursor.row)

    if e.cursor.col >= line_len {
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = 0
            editor_skip_whitespace_forward(e)
        }
        return
    }

    cur_rune, _ := editor_rune_at(e, e.cursor.row, e.cursor.col)

    if is_word_rune(cur_rune) {
        for e.cursor.col < line_len {
            r, size := editor_rune_at(e, e.cursor.row, e.cursor.col)
            if size <= 0 || !is_word_rune(r) do break
            e.cursor.col += size
        }
    } else if cur_rune != ' ' && cur_rune != '\t' {
        for e.cursor.col < line_len {
            r, size := editor_rune_at(e, e.cursor.row, e.cursor.col)
            if size <= 0 || is_word_rune(r) || r == ' ' || r == '\t' do break
            e.cursor.col += size
        }
    }

    // Skip whitespace
    for e.cursor.col < line_len {
        r, size := editor_rune_at(e, e.cursor.row, e.cursor.col)
        if size <= 0 || (r != ' ' && r != '\t') do break
        e.cursor.col += size
    }

    if e.cursor.col >= line_len && e.cursor.row + 1 < total_lines {
        e.cursor.row += 1
        e.cursor.col = 0
        editor_skip_whitespace_forward(e)
    }

    editor_clamp_cursor(e)
}

editor_motion_word_backward :: proc(e: ^Editor) {
    if e.cursor.col == 0 {
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = editor_get_line_len(e, e.cursor.row)
        } else {
            return
        }
    }

    // Skip whitespace backward
    for e.cursor.col > 0 {
        start := editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
        r, _ := editor_rune_at(e, e.cursor.row, start)
        if r != ' ' && r != '\t' do break
        e.cursor.col = start
    }

    if e.cursor.col == 0 do return

    prev_start := editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
    prev_rune, _ := editor_rune_at(e, e.cursor.row, prev_start)
    if is_word_rune(prev_rune) {
        for e.cursor.col > 0 {
            start := editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
            r, _ := editor_rune_at(e, e.cursor.row, start)
            if !is_word_rune(r) do break
            e.cursor.col = start
        }
    } else {
        for e.cursor.col > 0 {
            start := editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
            r, _ := editor_rune_at(e, e.cursor.row, start)
            if is_word_rune(r) || r == ' ' || r == '\t' do break
            e.cursor.col = start
        }
    }

    editor_clamp_cursor(e)
}

// Scope and paragraph motions
editor_line_brace_delta :: proc(line: string) -> int {
    delta := 0
    in_string := false
    escaped := false

    for i := 0; i < len(line); i += 1 {
        c := line[i]
        if escaped {
            escaped = false
            continue
        }
        if c == '\\' && in_string {
            escaped = true
            continue
        }
        if c == '"' || c == '`' {
            in_string = !in_string
            continue
        }
        if in_string do continue

        // Check for line comment //
        if i + 1 < len(line) && c == '/' && line[i + 1] == '/' {
            break
        }

        if c == '{' {
            delta += 1
        } else if c == '}' {
            delta -= 1
        }
    }
    return delta
}

editor_get_line_indent :: proc(e: ^Editor, row: int) -> (indent: int, first_char_col: int, is_blank: bool) {
    line_str, ok := pt_line_text(&e.table, row)
    if !ok do return 0, 0, true
    defer delete(line_str)

    indent = 0
    first_char_col = 0
    is_blank = true

    for i := 0; i < len(line_str); i += 1 {
        c := line_str[i]
        if c == ' ' {
            indent += 1
        } else if c == '\t' {
            indent += 4
        } else if c == '\r' || c == '\n' {
            continue
        } else {
            is_blank = false
            first_char_col = i
            break
        }
    }

    if is_blank {
        first_char_col = 0
    }
    return indent, first_char_col, is_blank
}

editor_count_char_on_current_line_before_cursor :: proc(e: ^Editor, quote_char: u8) -> int {
    line_start := pt_line_to_offset(&e.table, e.cursor.row)
    count := 0
    for i := 0; i < e.cursor.col; i += 1 {
        off := line_start + i
        if off < pt_get_length(&e.table) && pt_byte_at(&e.table, off) == quote_char {
            back_off := off - 1
            slash_count := 0
            for back_off >= line_start && pt_byte_at(&e.table, back_off) == '\\' {
                slash_count += 1
                back_off -= 1
            }
            if slash_count % 2 == 0 {
                count += 1
            }
        }
    }
    return count
}

editor_is_line_blank :: proc(e: ^Editor, row: int) -> bool {
    line_str, ok := pt_line_text(&e.table, row)
    if !ok do return true
    defer delete(line_str)

    for i := 0; i < len(line_str); i += 1 {
        c := line_str[i]
        if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
            return false
        }
    }
    return true
}

editor_motion_scope_up :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    if total_lines <= 1 || e.cursor.row <= 0 {
        e.cursor.row = 0
        new_len := editor_get_line_len(e, 0)
        max_c := max(0, new_len - 1)
        if e.mode == .Visual do max_c = new_len
        e.cursor.col = min(max_c, editor_byte_col_for_visual(e, e.cursor.row, e.desired_col))
        editor_clamp_cursor(e)
        return
    }

    cur_row := e.cursor.row
    target_row := 0

    if editor_is_line_blank(e, cur_row) {
        // When on a blank line: skip preceding blank lines, then find the blank line above that paragraph
        r := cur_row - 1
        for r >= 0 && editor_is_line_blank(e, r) {
            r -= 1
        }
        for r >= 0 {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }
            r -= 1
        }
    } else {
        // When on text: find preceding blank line or enclosing scope header
        cur_indent, _, _ := editor_get_line_indent(e, cur_row)
        brace_depth := 0
        r := cur_row - 1
        for r >= 0 {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }

            line_str, ok := pt_line_text(&e.table, r)
            if ok {
                b_delta := editor_line_brace_delta(line_str)
                delete(line_str)
                brace_depth += b_delta
                indent, _, _ := editor_get_line_indent(e, r)
                if brace_depth > 0 || indent < cur_indent {
                    target_row = r
                    break
                }
            }
            r -= 1
        }
    }

    e.cursor.row = target_row
    new_len := editor_get_line_len(e, e.cursor.row)
    max_c := max(0, new_len - 1)
    if e.mode == .Visual do max_c = new_len
    e.cursor.col = min(max_c, editor_byte_col_for_visual(e, e.cursor.row, e.desired_col))
    editor_clamp_cursor(e)
}

editor_motion_scope_down :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    if total_lines <= 1 || e.cursor.row >= total_lines - 1 {
        e.cursor.row = max(0, total_lines - 1)
        new_len := editor_get_line_len(e, e.cursor.row)
        max_c := max(0, new_len - 1)
        if e.mode == .Visual do max_c = new_len
        e.cursor.col = min(max_c, editor_byte_col_for_visual(e, e.cursor.row, e.desired_col))
        editor_clamp_cursor(e)
        return
    }

    cur_row := e.cursor.row
    target_row := total_lines - 1

    if editor_is_line_blank(e, cur_row) {
        // When on a blank line: skip following blank lines, then find the blank line below that paragraph
        r := cur_row + 1
        for r < total_lines && editor_is_line_blank(e, r) {
            r += 1
        }
        for r < total_lines {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }
            r += 1
        }
    } else {
        // When on text: find following blank line or closing scope boundary
        cur_indent, _, _ := editor_get_line_indent(e, cur_row)
        brace_depth := 0
        r := cur_row + 1
        for r < total_lines {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }

            line_str, ok := pt_line_text(&e.table, r)
            if ok {
                b_delta := editor_line_brace_delta(line_str)
                delete(line_str)
                brace_depth += b_delta
                indent, _, _ := editor_get_line_indent(e, r)
                if brace_depth < 0 || indent < cur_indent {
                    target_row = r
                    break
                }
            }
            r += 1
        }
    }

    e.cursor.row = target_row
    new_len := editor_get_line_len(e, e.cursor.row)
    max_c := max(0, new_len - 1)
    if e.mode == .Visual do max_c = new_len
    e.cursor.col = min(max_c, editor_byte_col_for_visual(e, e.cursor.row, e.desired_col))
    editor_clamp_cursor(e)
}


// Selection helpers
editor_get_selection_range :: proc(e: ^Editor) -> (start: Cursor, end: Cursor) {
    if e.cursor.row < e.selection_anchor.row ||
       (e.cursor.row == e.selection_anchor.row && e.cursor.col < e.selection_anchor.col) {
        return e.cursor, e.selection_anchor
    }
    return e.selection_anchor, e.cursor
}

// Byte offsets for the current Visual selection. Columns past EOL are
// clamped to their line so a virtual cursor cannot delete into the next line.
editor_selection_offsets :: proc(e: ^Editor) -> (start_off, end_off: int) {
    start_sel, end_sel := editor_get_selection_range(e)
    total_len := pt_get_length(&e.table)

    start_line_len := editor_get_line_len(e, start_sel.row)
    start_off = pt_line_to_offset(&e.table, start_sel.row) + min(start_sel.col, start_line_len)

    end_line_len := editor_get_line_len(e, end_sel.row)
    is_full_line := (start_sel.col == 0 && end_sel.col >= end_line_len)
    end_col := end_line_len
    if end_sel.col < end_line_len {
        end_col = editor_next_rune_end(e, end_sel.row, end_sel.col)
    }
    end_off = pt_line_to_offset(&e.table, end_sel.row) + end_col

    if is_full_line {
        if end_off < total_len && pt_byte_at(&e.table, end_off) == '\n' {
            end_off += 1
        } else if end_off + 1 < total_len &&
                  pt_byte_at(&e.table, end_off) == '\r' &&
                  pt_byte_at(&e.table, end_off + 1) == '\n' {
            end_off += 2
        } else if start_off > 0 && pt_byte_at(&e.table, start_off - 1) == '\n' {
            if start_off >= 2 && pt_byte_at(&e.table, start_off - 2) == '\r' {
                start_off -= 2
            } else {
                start_off -= 1
            }
        }
    }

    if end_off < start_off do end_off = start_off
    return
}

editor_delete_selection :: proc(e: ^Editor) {
    break_undo_group(&e.table)
    start_sel, _ := editor_get_selection_range(e)
    start_off, end_off := editor_selection_offsets(e)

    if end_off > start_off {
        pt_delete_range(&e.table, start_off, end_off - start_off)
        editor_mark_dirty(e, start_sel.row)
    }

    e.cursor = start_sel
    e.cursor.col = min(e.cursor.col, editor_get_line_len(e, e.cursor.row))
    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
    editor_set_mode(e, .Normal, nil)
}

editor_yank_selection :: proc(e: ^Editor) {
    start_sel, _ := editor_get_selection_range(e)
    start_off, end_off := editor_selection_offsets(e)

    if end_off > start_off {
        sel_text, ok := pt_text(&e.table, start_off, end_off - start_off)
        if ok {
            defer delete(sel_text)
            c_text := strings.clone_to_cstring(sel_text)
            defer delete(c_text)
            _ = sdl.SetClipboardText(c_text)
            e.status_message = "Yanked selection."
        }
    }

    e.cursor = start_sel
    editor_set_mode(e, .Normal, nil)
}

// Insert clipboard/environment text at the cursor and leave the cursor at the
// end of the inserted text. Multi-line inserts must advance rows; adding the
// byte length to the column would send the cursor far past the line end.
// Position the cursor at the end of text inserted starting at start_row/col.
editor_advance_after_insert :: proc(e: ^Editor, start_row, start_col: int, text: string) {
    newline_count := 0
    last_newline := -1
    for ch, i in text {
        if ch == '\n' {
            newline_count += 1
            last_newline = i
        }
    }

    if last_newline >= 0 {
        e.cursor.row = start_row + newline_count
        e.cursor.col = len(text) - last_newline - 1
    } else {
        e.cursor.row = start_row
        e.cursor.col = start_col + len(text)
    }
    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
}

editor_insert_text_at_cursor :: proc(e: ^Editor, text: string) {
    if len(text) == 0 do return

    e.completion.active = false
    editor_begin_undo_transaction(e)
    defer editor_end_undo_transaction(e)

    if e.mode == .Visual {
        editor_delete_selection(e)
    }
    editor_realize_virtual_spaces(e)

    start_row := e.cursor.row
    start_col := e.cursor.col
    offset := editor_get_cursor_offset(e)
    pt_insert(&e.table, offset, text)

    editor_advance_after_insert(e, start_row, start_col, text)
    editor_mark_dirty(e, start_row)
}

editor_paste :: proc(e: ^Editor) {
    break_undo_group(&e.table)
    if !sdl.HasClipboardText() do return
    clip_raw := sdl.GetClipboardText()
    if clip_raw == nil do return
    defer sdl.free(rawptr(clip_raw))
    clip := string(cstring(clip_raw))
    if len(clip) == 0 do return

    normalized := editor_normalize_newlines(e, clip)
    editor_insert_text_at_cursor(e, normalized)
}

editor_move_lines :: proc(e: ^Editor, dir: int) {
    if e.read_only {
        editor_set_status_message(e, "Buffer is read-only")
        return
    }
    break_undo_group(&e.table)
    total_lines := pt_get_line_count(&e.table) + 1
    if total_lines <= 1 do return

    editor_begin_undo_transaction(e)
    defer editor_end_undo_transaction(e)

    r_start := e.cursor.row
    r_end := e.cursor.row
    if e.mode == .Visual {
        r_start = min(e.selection_anchor.row, e.cursor.row)
        r_end = max(e.selection_anchor.row, e.cursor.row)
    }

    if dir > 0 { // Move Down
        if r_end >= total_lines - 1 do return

        // Ensure file ends with newline before moving into bottom-most position
        total_len := pt_get_length(&e.table)
        if total_len > 0 && pt_byte_at(&e.table, total_len - 1) != '\n' {
            pt_insert(&e.table, total_len, editor_eol(e))
            total_lines = pt_get_line_count(&e.table) + 1
        }

        block_start := pt_line_to_offset(&e.table, r_start)
        block_end := pt_line_to_offset(&e.table, r_end + 1)

        target_row := r_end + 1
        target_start := block_end
        target_end := pt_line_to_offset(&e.table, target_row + 1) if target_row + 1 < total_lines else pt_get_length(&e.table)
        target_len := target_end - target_start
        if target_len <= 0 do return

        target_text, ok := pt_text(&e.table, target_start, target_len)
        if !ok do return
        defer delete(target_text)

        pt_delete_range(&e.table, target_start, target_len)
        pt_insert(&e.table, block_start, target_text)

        e.cursor.row += 1
        e.selection_anchor.row += 1
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_mark_dirty(e, r_start)

    } else if dir < 0 { // Move Up
        if r_start <= 0 do return

        // Ensure file ends with newline
        total_len := pt_get_length(&e.table)
        if total_len > 0 && pt_byte_at(&e.table, total_len - 1) != '\n' {
            pt_insert(&e.table, total_len, editor_eol(e))
            total_lines = pt_get_line_count(&e.table) + 1
        }

        target_row := r_start - 1
        target_start := pt_line_to_offset(&e.table, target_row)
        target_end := pt_line_to_offset(&e.table, r_start)
        target_len := target_end - target_start
        if target_len <= 0 do return

        target_text, ok := pt_text(&e.table, target_start, target_len)
        if !ok do return
        defer delete(target_text)

        pt_delete_range(&e.table, target_start, target_len)

        new_insert_offset := pt_line_to_offset(&e.table, r_end) if r_end < total_lines - 1 else pt_get_length(&e.table)
        pt_insert(&e.table, new_insert_offset, target_text)

        e.cursor.row -= 1
        e.selection_anchor.row -= 1
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_mark_dirty(e, max(0, r_start - 1))
    }
}

editor_filter_completions :: proc(e: ^Editor) {
    for c in e.completion.items {
        delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
    }
    clear(&e.completion.items)

    if len(e.completion.all_items) == 0 {
        e.completion.active = false
        return
    }

    // Determine current typed prefix
    line_start := pt_line_to_offset(&e.table, e.cursor.row)
    cur_off := line_start + e.cursor.col
    trig_off := line_start + e.completion.trigger_col
    cur_prefix := ""
    if cur_off > trig_off && e.cursor.row == e.completion.trigger_row {
        if s, ok := pt_text(&e.table, trig_off, cur_off - trig_off, context.temp_allocator); ok {
            cur_prefix = s
        }
    }

    if e.completion.prefix != "" do delete(e.completion.prefix)
    e.completion.prefix = strings.clone(cur_prefix, context.allocator)

    if cur_prefix == "" {
        // No prefix: show items up to 100
        count := min(100, len(e.completion.all_items))
        for i in 0 ..< count {
            c := e.completion.all_items[i]
            append(&e.completion.items, LspCompletionItem{
                label         = strings.clone(c.label),
                detail        = strings.clone(c.detail),
                documentation = strings.clone(c.documentation),
                insert_text   = strings.clone(c.insert_text),
                kind          = c.kind,
            })
        }
    } else {
        pref_lower := strings.to_lower(cur_prefix, context.temp_allocator)

        // Pass 1: exact case prefix match
        for c in e.completion.all_items {
            if strings.has_prefix(c.label, cur_prefix) {
                append(&e.completion.items, LspCompletionItem{
                    label         = strings.clone(c.label),
                    detail        = strings.clone(c.detail),
                    documentation = strings.clone(c.documentation),
                    insert_text   = strings.clone(c.insert_text),
                    kind          = c.kind,
                })
            }
        }

        // Pass 2: case-insensitive prefix match (not already added)
        for c in e.completion.all_items {
            if !strings.has_prefix(c.label, cur_prefix) {
                lbl_lower := strings.to_lower(c.label, context.temp_allocator)
                if strings.has_prefix(lbl_lower, pref_lower) {
                    append(&e.completion.items, LspCompletionItem{
                        label         = strings.clone(c.label),
                        detail        = strings.clone(c.detail),
                        documentation = strings.clone(c.documentation),
                        insert_text   = strings.clone(c.insert_text),
                        kind          = c.kind,
                    })
                }
            }
        }

        // Pass 3: substring match (not prefix)
        for c in e.completion.all_items {
            lbl_lower := strings.to_lower(c.label, context.temp_allocator)
            if !strings.has_prefix(lbl_lower, pref_lower) && strings.contains(lbl_lower, pref_lower) {
                append(&e.completion.items, LspCompletionItem{
                    label         = strings.clone(c.label),
                    detail        = strings.clone(c.detail),
                    documentation = strings.clone(c.documentation),
                    insert_text   = strings.clone(c.insert_text),
                    kind          = c.kind,
                })
            }
        }
    }

    e.completion.selected = 0
    e.completion.scroll_offset = 0
    e.completion.active = len(e.completion.items) > 0
}

editor_apply_completion :: proc(e: ^Editor) {
    break_undo_group(&e.table)
    if !e.completion.active || len(e.completion.items) == 0 do return
    if e.completion.selected < 0 || e.completion.selected >= len(e.completion.items) do return

    item := e.completion.items[e.completion.selected]
    insert_str := item.insert_text if item.insert_text != "" else item.label
    if len(insert_str) == 0 do return
    insert_str = editor_normalize_newlines(e, insert_str)

    // Only replace the typed prefix when the cursor is still on the line where
    // completion was triggered. If the buffer moved (paste, multi-line edit),
    // insert at the cursor instead of deleting unrelated bytes.
    start_row := e.cursor.row
    start_col := e.cursor.col
    if e.cursor.row == e.completion.trigger_row && e.cursor.col > e.completion.trigger_col {
        del_count := e.cursor.col - e.completion.trigger_col
        offset := pt_line_to_offset(&e.table, e.cursor.row) + e.completion.trigger_col
        pt_replace(&e.table, offset, del_count, insert_str)
        start_col = e.completion.trigger_col
    } else {
        editor_realize_virtual_spaces(e)
        start_row = e.cursor.row
        start_col = e.cursor.col
        offset := editor_get_cursor_offset(e)
        pt_insert(&e.table, offset, insert_str)
    }

    editor_advance_after_insert(e, start_row, start_col, insert_str)
    editor_mark_dirty(e)

    for c in e.completion.items {
        delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
    }
    clear(&e.completion.items)
    for c in e.completion.all_items {
        delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
    }
    clear(&e.completion.all_items)
    e.completion.active = false
}

editor_open_completion_doc :: proc(e: ^Editor, app: ^App) {
    if !e.completion.active || len(e.completion.items) == 0 do return
    if e.completion.selected < 0 || e.completion.selected >= len(e.completion.items) do return

    item := e.completion.items[e.completion.selected]
    doc_title := fmt.tprintf("*doc: %s*", item.label)

    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "// LSP Documentation Preview\n")
    strings.write_string(&b, fmt.tprintf("// Symbol: %s\n", item.label))
    if item.detail != "" {
        strings.write_string(&b, fmt.tprintf("// Detail: %s\n", item.detail))
    }
    strings.write_string(&b, "\n")
    if item.documentation != "" {
        strings.write_string(&b, item.documentation)
        strings.write_byte(&b, '\n')
    } else {
        strings.write_string(&b, "(No documentation string provided by language server)\n")
    }
    doc_text := strings.to_string(b)

    // Open in a vertical split pane
    app_split_pane(app, app.active_pane, .Vertical)
    doc_pane := app.active_pane
    if doc_pane != nil {
        doc_pane.kind = .Editor
        editor_destroy(&doc_pane.editor)
        editor_init(&doc_pane.editor, &app.font, doc_text, doc_title)
        doc_pane.editor.read_only = true
        doc_pane.editor.dirty = false
    }

    for c in e.completion.items {
        delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
    }
    clear(&e.completion.items)
    for c in e.completion.all_items {
        delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
    }
    clear(&e.completion.all_items)
    e.completion.active = false
}

// Queue the current document snapshot before an LSP request so the server
// resolves positions against the text the cursor coordinates came from.
editor_flush_lsp_change :: proc(e: ^Editor, app: ^App) {
    if app == nil || e.file_path == "" do return
    if !e.needs_lsp_sync do return

    e.needs_lsp_sync = false
    full_text := pt_full_text(&e.table)
    defer delete(full_text)
    app_lsp_doc_change(app, e.file_path, full_text)
}

editor_apply_lsp_edits :: proc(e: ^Editor, edits: []LspTextEdit) {
    break_undo_group(&e.table)
    if len(edits) == 0 do return

    editor_begin_undo_transaction(e)
    defer editor_end_undo_transaction(e)

    // Sort edits descending (bottom to top)
    sorted_edits := slice.clone(edits, context.temp_allocator)
    slice.sort_by(sorted_edits, proc(a, b: LspTextEdit) -> bool {
        if a.start_row != b.start_row do return a.start_row > b.start_row
        return a.start_col > b.start_col
    })

    total_len := pt_get_length(&e.table)
    line_count := pt_get_line_count(&e.table)
    min_row := sorted_edits[len(sorted_edits) - 1].start_row

    for ed in sorted_edits {
        s_off: int
        if ed.start_row <= 0 {
            s_off = min(ed.start_col, editor_get_line_len(e, 0))
        } else if ed.start_row > line_count {
            s_off = total_len
        } else {
            s_off = pt_line_to_offset(&e.table, ed.start_row) +
                    min(ed.start_col, editor_get_line_len(e, ed.start_row))
        }
        s_off = clamp(s_off, 0, total_len)

        e_off: int
        if ed.end_row <= 0 {
            e_off = min(ed.end_col, editor_get_line_len(e, 0))
        } else if ed.end_row > line_count {
            e_off = total_len
        } else {
            e_off = pt_line_to_offset(&e.table, ed.end_row) +
                    min(ed.end_col, editor_get_line_len(e, ed.end_row))
        }
        e_off = clamp(e_off, s_off, total_len)

        del_len := e_off - s_off
        if del_len > 0 || len(ed.new_text) > 0 {
            normalized := editor_normalize_newlines(e, ed.new_text)
            pt_replace(&e.table, s_off, del_len, normalized)
        }
        total_len = pt_get_length(&e.table)
        line_count = pt_get_line_count(&e.table)
    }

    editor_mark_dirty(e, min_row)
    editor_snap_cursor(e)
}

editor_delete_current_line :: proc(e: ^Editor) {
    break_undo_group(&e.table)
    total_lines := pt_get_line_count(&e.table) + 1
    start_off := pt_line_to_offset(&e.table, e.cursor.row)
    changed := false

    if e.cursor.row + 1 < total_lines {
        next_off := pt_line_to_offset(&e.table, e.cursor.row + 1)
        pt_delete_range(&e.table, start_off, next_off - start_off)
        changed = true
    } else if e.cursor.row > 0 {
        prev_start := pt_line_to_offset(&e.table, e.cursor.row - 1)
        prev_len := editor_get_line_len(e, e.cursor.row - 1)
        del_start := prev_start + prev_len
        total_len := pt_get_length(&e.table)
        pt_delete_range(&e.table, del_start, total_len - del_start)
        e.cursor.row -= 1
        changed = true
    } else {
        total_len := pt_get_length(&e.table)
        if total_len > 0 {
            pt_delete_range(&e.table, 0, total_len)
            changed = true
        }
        e.cursor.col = 0
    }
    if changed do editor_mark_dirty(e)
    editor_snap_cursor(e)
}

editor_handle_insert_key :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod, window: ^sdl.Window, app: ^App) -> bool {
    is_shift := (mod & sdl.KMOD_SHIFT) != {}
    is_ctrl  := (mod & sdl.KMOD_CTRL) != {}

    // Ctrl+Space: explicit autocomplete trigger
    if is_ctrl && key == KEY_COMPLETION_TRIGGER {
        trigger_col := e.cursor.col
        for trigger_col > 0 {
            start := editor_prev_rune_start(e, e.cursor.row, trigger_col)
            r, _ := editor_rune_at(e, e.cursor.row, start)
            if is_word_rune(r) {
                trigger_col = start
            } else {
                break
            }
        }
        e.completion.trigger_row = e.cursor.row
        e.completion.trigger_col = trigger_col
        lsp := app_get_lsp_for_file(app, e.file_path)
        if lsp != nil && lsp_is_running(lsp) && e.file_path != "" {
            editor_flush_lsp_change(e, app)
            lsp_request_completion(lsp, e.file_path, e.cursor.row, e.cursor.col)
        }
        return true
    }

    switch key {
    case sdl.K_ESCAPE:
        if e.completion.active {
            e.completion.active = false
            return true
        }
        editor_set_mode(e, .Normal, window)
        return true

    case sdl.K_RETURN, sdl.K_KP_ENTER:
        if e.completion.active && len(e.completion.items) > 0 {
            if is_shift {
                // Shift+Enter: open documentation / definition in a vertical split!
                editor_open_completion_doc(e, app)
                return true
            } else {
                // Enter: complete selected symbol
                editor_apply_completion(e)
                return true
            }
        }
        e.completion.active = false
        insert_row := e.cursor.row
        editor_begin_undo_transaction(e)
        defer editor_end_undo_transaction(e)
        editor_realize_virtual_spaces(e)
        offset := editor_get_cursor_offset(e)

        // Check if cursor is between matching braces {} or brackets [] or ()
        is_between_pair := false
        if offset > 0 && offset < pt_get_length(&e.table) {
            prev := pt_byte_at(&e.table, offset - 1)
            next := pt_byte_at(&e.table, offset)
            if (prev == '{' && next == '}') ||
               (prev == '(' && next == ')') ||
               (prev == '[' && next == ']') {
                is_between_pair = true
            }
        }

        // Get leading whitespace of current line up to cursor
        cur_line_text, line_ok := pt_line_text(&e.table, e.cursor.row)
        defer if line_ok do delete(cur_line_text)
        indent_len := 0
        if line_ok {
            for i := 0; i < min(len(cur_line_text), e.cursor.col); i += 1 {
                if cur_line_text[i] == ' ' || cur_line_text[i] == '\t' {
                    indent_len += 1
                } else {
                    break
                }
            }
        }
        base_indent := cur_line_text[:indent_len] if indent_len > 0 else ""

        eol := editor_eol(e)
        if is_between_pair {
            // Expand with new line + extra indent + new line + base indent
            to_insert := fmt.tprintf("%s%s    %s%s", eol, base_indent, eol, base_indent)
            pt_insert(&e.table, offset, to_insert)
            e.cursor.row += 1
            e.cursor.col = len(base_indent) + 4
            e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        } else {
            // Normal enter: preserve current line's leading indentation
            to_insert := fmt.tprintf("%s%s", eol, base_indent)
            pt_insert(&e.table, offset, to_insert)
            e.cursor.row += 1
            e.cursor.col = len(base_indent)
            e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        }

        editor_mark_dirty(e, insert_row)
        return true

    case sdl.K_TAB:
        if e.completion.active && len(e.completion.items) > 0 {
            if is_shift {
                e.completion.selected = (e.completion.selected - 1 + len(e.completion.items)) % len(e.completion.items)
            } else {
                e.completion.selected = (e.completion.selected + 1) % len(e.completion.items)
            }
            return true
        }
        editor_begin_undo_transaction(e)
        defer editor_end_undo_transaction(e)
        editor_realize_virtual_spaces(e)
        offset := editor_get_cursor_offset(e)
        pt_insert(&e.table, offset, "    ")
        e.cursor.col += 4
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_mark_dirty(e)
        return true

    case sdl.K_SPACE:
        e.completion.active = false
        return false

    case sdl.K_BACKSPACE:
        line_len := editor_get_line_len(e, e.cursor.row)
        if e.cursor.col > line_len {
            e.cursor.col -= 1
            e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        } else if e.cursor.col > 0 {
            offset := editor_get_cursor_offset(e)
            prev_start := editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
            del_len := e.cursor.col - prev_start
            new_col := prev_start
            if offset > 0 && offset < pt_get_length(&e.table) {
                prev := pt_byte_at(&e.table, offset - 1)
                next := pt_byte_at(&e.table, offset)
                if (prev == '(' && next == ')') ||
                   (prev == '[' && next == ']') ||
                   (prev == '{' && next == '}') ||
                   (prev == '"' && next == '"') ||
                   (prev == '\'' && next == '\'') ||
                   (prev == '`' && next == '`') {
                    del_len = 2
                    new_col = max(0, prev_start)
                }
            }
            pt_delete_range(&e.table, offset - del_len, del_len)
            e.cursor.col = new_col
            e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
            editor_mark_dirty(e)
        } else if e.cursor.row > 0 {
            prev_len := editor_get_line_len(e, e.cursor.row - 1)
            offset := pt_line_to_offset(&e.table, e.cursor.row)
            del_len := 1
            del_pos := offset - 1
            if del_pos > 0 && pt_byte_at(&e.table, del_pos - 1) == '\r' {
                del_pos -= 1
                del_len = 2
            }
            pt_delete_range(&e.table, del_pos, del_len)
            e.cursor.row -= 1
            e.cursor.col = prev_len
            e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
            editor_mark_dirty(e)
        }
        if e.completion.active {
            if e.cursor.col < e.completion.trigger_col || e.cursor.row != e.completion.trigger_row {
                e.completion.active = false
            } else if len(e.completion.all_items) > 0 {
                editor_filter_completions(e)
            }
        }
        return true

    case sdl.K_DELETE:
        offset := editor_get_cursor_offset(e)
        if offset < pt_get_length(&e.table) {
            del_len := 1
            line_len := editor_get_line_len(e, e.cursor.row)
            if e.cursor.col < line_len {
                _, size := editor_rune_at(e, e.cursor.row, e.cursor.col)
                if size > 0 do del_len = size
            } else if pt_byte_at(&e.table, offset) == '\r' &&
               offset + 1 < pt_get_length(&e.table) &&
               pt_byte_at(&e.table, offset + 1) == '\n' {
                del_len = 2
            }
            pt_delete_range(&e.table, offset, del_len)
            editor_mark_dirty(e)
        }
        return true

    case sdl.K_LEFT:
        break_undo_group(&e.table)
        line_len := editor_get_line_len(e, e.cursor.row)
        if e.cursor.col > line_len {
            e.cursor.col -= 1
        } else {
            e.cursor.col = editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        if e.completion.active && e.cursor.col < e.completion.trigger_col {
            e.completion.active = false
        }
        return true

    case sdl.K_RIGHT:
        break_undo_group(&e.table)
        line_len := editor_get_line_len(e, e.cursor.row)
        if e.cursor.col < line_len {
            e.cursor.col = editor_next_rune_end(e, e.cursor.row, e.cursor.col)
        } else {
            e.cursor.col += 1
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true

    case sdl.K_UP:
        break_undo_group(&e.table)
        if e.completion.active && len(e.completion.items) > 0 {
            e.completion.selected = (e.completion.selected - 1 + len(e.completion.items)) % len(e.completion.items)
            return true
        }
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = editor_col_for_vertical_move(e, e.cursor.row)
            e.completion.active = false
        }
        return true

    case sdl.K_DOWN:
        break_undo_group(&e.table)
        if e.completion.active && len(e.completion.items) > 0 {
            e.completion.selected = (e.completion.selected + 1) % len(e.completion.items)
            return true
        }
        total_lines := pt_get_line_count(&e.table) + 1
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = editor_col_for_vertical_move(e, e.cursor.row)
            e.completion.active = false
        }
        return true
    }
    return false
}

editor_handle_command_key :: proc(e: ^Editor, key: sdl.Keycode, window: ^sdl.Window, app: ^App) -> bool {
    switch key {
    case sdl.K_ESCAPE:
        editor_set_mode(e, .Normal, window)
        clear(&e.command_buffer)
        return true

    case sdl.K_BACKSPACE:
        if len(e.command_buffer) > 0 {
            pop(&e.command_buffer)
        } else {
            editor_set_mode(e, .Normal, window)
        }
        return true

    case sdl.K_RETURN, sdl.K_KP_ENTER:
        cmd := strings.trim_space(string(e.command_buffer[:]))
        editor_set_mode(e, .Normal, window)
        clear(&e.command_buffer)

        // Use the global command dispatcher so :wq/:x, wdired, relative
        // paths, and error reporting behave identically in every mode.
        if app != nil {
            app_execute_command(app, cmd)
        } else if cmd == "w" {
            editor_save_file(e, nil)
        } else if cmd != "" {
            e.status_message = fmt.tprintf("Unknown command: :%s", cmd)
        }
        return true

    case:
        if !sdl.TextInputActive(window) && key >= 32 && key <= 126 {
            append(&e.command_buffer, u8(key))
            return true
        }
    }
    return false
}

editor_handle_normal_key :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod, window: ^sdl.Window, app: ^App) -> bool {
    break_undo_group(&e.table)
    total_lines := pt_get_line_count(&e.table) + 1
    line_len := editor_get_line_len(e, e.cursor.row)
    is_shift := (mod & sdl.KMOD_SHIFT) != {}
    is_ctrl  := (mod & sdl.KMOD_CTRL) != {}

    // Multi-key commands
    if e.pending_cmd == 'g' {
        e.pending_cmd = 0
        if key == KEY_GOTO {
            e.cursor.row = 0
            e.cursor.col = 0
            e.desired_col = 0
            return true
        }
        if key == KEY_GOTO_DEFINITION {
            // gd: Go to definition
            lsp := app_get_lsp_for_file(app, e.file_path)
            if lsp != nil && lsp_is_running(lsp) && e.file_path != "" {
                editor_flush_lsp_change(e, app)
                lsp_request_definition(lsp, e.file_path, e.cursor.row, e.cursor.col)
                app_set_message(app, "LSP: Requesting definition...")
            }
            return true
        }
    }

    if e.pending_cmd == '=' {
        e.pending_cmd = 0
        if key == KEY_FORMAT_LINE {
            // ==: Format current line
            lsp := app_get_lsp_for_file(app, e.file_path)
            if lsp != nil && lsp_is_running(lsp) && e.file_path != "" {
                editor_flush_lsp_change(e, app)
                lsp_request_range_formatting(lsp, e.file_path, e.cursor.row, e.cursor.row)
                app_set_message(app, fmt.tprintf("LSP: Formatting line %d...", e.cursor.row + 1))
            }
            return true
        }
    }

    // Ctrl+l: word forward
    if is_ctrl && key == KEY_WORD_FORWARD {
        editor_motion_word_forward(e)
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true
    }

    // Ctrl+h: word backward
    if is_ctrl && key == KEY_WORD_BACKWARD {
        editor_motion_word_backward(e)
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true
    }

    // Ctrl+j: scope / paragraph jump down
    if is_ctrl && key == KEY_SCOPE_DOWN {
        editor_motion_scope_down(e)
        return true
    }

    // Ctrl+k: scope / paragraph jump up
    if is_ctrl && key == KEY_SCOPE_UP {
        editor_motion_scope_up(e)
        return true
    }

    // Ctrl+x: toggle visual mode selection
    if is_ctrl && key == KEY_VISUAL_TOGGLE {
        if e.mode == .Visual {
            editor_set_mode(e, .Normal, window)
        } else {
            e.mode = .Visual
            e.selection_anchor = e.cursor
            e.cursor.shape = .Block
        }
        return true
    }

    // Colon ':' opens global command prompt
    if key == KEY_CMD_PROMPT || (key == KEY_CMD_PROMPT_ALT && is_shift) {
        app_open_command_prompt(app)
        return true
    }

    // ESC = Insert / Normal toggle
    if key == sdl.K_ESCAPE {
        if e.mode == .Visual {
            editor_set_mode(e, .Normal, window)
        } else {
            editor_set_mode(e, .Insert, window)
        }
        return true
    }

    // Shift+H: start of line; h: left
    if is_shift && key == KEY_LINE_START {
        e.cursor.col = 0
        e.desired_col = 0
        return true
    }
    if key == KEY_MOVE_LEFT {
        if e.cursor.col > line_len {
            e.cursor.col -= 1
        } else {
            e.cursor.col = editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true
    }

    // Shift+L: end of line; l: right (virtual edit)
    if is_shift && key == KEY_LINE_END {
        e.cursor.col = line_len
        e.desired_col = editor_visual_col(e, e.cursor.row, line_len)
        return true
    }
    if key == KEY_MOVE_RIGHT {
        if e.cursor.col < line_len {
            e.cursor.col = editor_next_rune_end(e, e.cursor.row, e.cursor.col)
        } else {
            e.cursor.col += 1
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true
    }

    // Navigation: j, down
    if key == KEY_MOVE_DOWN || key == sdl.K_DOWN {
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = editor_col_for_vertical_move(e, e.cursor.row)
        }
        return true
    }

    // Shift+K: hover; k, up: move up
    if is_shift && key == KEY_HOVER {
        lsp := app_get_lsp_for_file(app, e.file_path)
        if lsp != nil && lsp_is_running(lsp) && e.file_path != "" {
            editor_flush_lsp_change(e, app)
            lsp_request_hover(lsp, e.file_path, e.cursor.row, e.cursor.col)
            app_set_message(app, "LSP: Requesting hover...")
        }
        return true
    }
    if key == KEY_MOVE_UP || key == sdl.K_UP {
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = editor_col_for_vertical_move(e, e.cursor.row)
        }
        return true
    }

    // =: format selection in Visual, arm == in Normal
    if e.mode == .Visual && key == KEY_FORMAT_SELECTION {
        start_row := min(e.cursor.row, e.selection_anchor.row)
        end_row := max(e.cursor.row, e.selection_anchor.row)
        lsp := app_get_lsp_for_file(app, e.file_path)
        if lsp != nil && lsp_is_running(lsp) && e.file_path != "" {
            editor_flush_lsp_change(e, app)
            lsp_request_range_formatting(lsp, e.file_path, start_row, end_row)
            app_set_message(app, fmt.tprintf("LSP: Formatting lines %d-%d...", start_row + 1, end_row + 1))
        }
        editor_set_mode(e, .Normal, window)
        return true
    }
    if e.mode != .Visual && key == KEY_FORMAT_LINE {
        e.pending_cmd = '='
        return true
    }

    if key == sdl.K_LEFT {
        if e.cursor.col > line_len {
            e.cursor.col -= 1
        } else {
            e.cursor.col = editor_prev_rune_start(e, e.cursor.row, e.cursor.col)
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true
    }

    if key == sdl.K_RIGHT {
        if e.cursor.col < line_len {
            e.cursor.col = editor_next_rune_end(e, e.cursor.row, e.cursor.col)
        } else {
            e.cursor.col += 1
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        return true
    }

    // Line start / end
    if key == KEY_LINE_START_ZERO {
        e.cursor.col = 0
        e.desired_col = 0
        return true
    }

    if is_shift && key == KEY_LINE_END_DOLLAR {
        e.cursor.col = line_len
        e.desired_col = 999999
        return true
    }

    // Top / bottom
    if is_shift && key == KEY_FILE_END {
        e.cursor.row = max(0, total_lines - 1)
        e.cursor.col = 0
        e.desired_col = 0
        return true
    }
    if key == KEY_GOTO {
        e.pending_cmd = 'g'
        return true
    }

    if key == KEY_DIRED_EDIT_CANCEL {
        if app.active_pane != nil && app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
            app.active_pane.dired.is_editing = false
            _ = sdl.StopTextInput(window)
            app_set_message(app, "Dired: edit cancelled")
            return true
        }
    }

    // Dash '-' opens parent directory in Dired
    if key == KEY_OPEN_PARENT_DIR {
        dir := filepath.dir(e.file_path)
        if dir == "" do dir = "."
        app_open_dired(app, dir)
        return true
    }

    // Enter Insert Mode
    if e.mode != .Visual && is_shift && key == KEY_INSERT_LINE_START {
        e.cursor.col = 0
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_set_mode(e, .Insert, window)
        return true
    }
    if e.mode != .Visual && key == KEY_INSERT_BEFORE {
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_set_mode(e, .Insert, window)
        return true
    }

    if e.mode != .Visual && is_shift && key == KEY_APPEND_LINE_END {
        e.cursor.col = line_len
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_set_mode(e, .Insert, window)
        return true
    }
    if e.mode != .Visual && key == KEY_APPEND {
        // Step over one full rune, but do not go past EOL.
        if e.cursor.col < line_len {
            e.cursor.col = editor_next_rune_end(e, e.cursor.row, e.cursor.col)
        } else {
            e.cursor.col = line_len
        }
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        editor_set_mode(e, .Insert, window)
        return true
    }

    // New lines (O above, o / Enter below)
    if e.mode != .Visual && is_shift && key == KEY_OPEN_ABOVE {
        start_off := pt_line_to_offset(&e.table, e.cursor.row)
        pt_insert(&e.table, start_off, editor_eol(e))
        e.cursor.col = 0
        e.desired_col = 0
        editor_mark_dirty(e)
        editor_set_mode(e, .Insert, window)
        return true
    }
    if e.mode != .Visual && (key == KEY_OPEN_BELOW || key == sdl.K_RETURN || key == sdl.K_KP_ENTER) {
        open_row := e.cursor.row
        start_off := pt_line_to_offset(&e.table, e.cursor.row)
        insert_pos := start_off + line_len
        pt_insert(&e.table, insert_pos, editor_eol(e))
        e.cursor.row += 1
        e.cursor.col = 0
        e.desired_col = 0
        editor_mark_dirty(e, open_row)
        editor_set_mode(e, .Insert, window)
        return true
    }

    // Line selection with X (Kakoune / Helix style)
    if key == KEY_SELECT_LINE {
        if e.mode != .Visual {
            e.mode = .Visual
            e.cursor.shape = .Block
            e.selection_anchor = Cursor{row = e.cursor.row, col = 0}
            e.cursor.col = max(0, line_len)
            e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        } else {
            if e.cursor.row + 1 < total_lines {
                e.cursor.row += 1
                e.cursor.col = max(0, editor_get_line_len(e, e.cursor.row))
                e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
            }
        }
        return true
    }

    // Deletion with D (single char in Normal, selection in Visual)
    if e.mode == .Visual && key == KEY_DELETE_SELECTION {
        editor_delete_selection(e)
        return true
    }
    if e.mode != .Visual && key == KEY_DELETE_CHAR {
        if line_len > 0 && e.cursor.col < line_len {
            offset := pt_line_to_offset(&e.table, e.cursor.row) + e.cursor.col
            _, size := editor_rune_at(e, e.cursor.row, e.cursor.col)
            if size <= 0 do size = 1
            pt_delete_range(&e.table, offset, size)
            editor_mark_dirty(e)
        } else if e.cursor.row + 1 < total_lines {
            offset := pt_line_to_offset(&e.table, e.cursor.row) + line_len
            total_len := pt_get_length(&e.table)
            del_len := 1
            if offset + 1 < total_len &&
               pt_byte_at(&e.table, offset) == '\r' &&
               pt_byte_at(&e.table, offset + 1) == '\n' {
                del_len = 2
            }
            pt_delete_range(&e.table, offset, del_len)
            editor_mark_dirty(e)
        }
        return true
    }

    if key == KEY_PASTE_NORMAL {
        editor_paste(e)
        return true
    }

    if e.mode == .Visual && key == KEY_YANK_SELECTION {
        editor_yank_selection(e)
        return true
    }

    if e.mode == .Visual && key == KEY_CHANGE_SELECTION {
        editor_delete_selection(e)
        editor_set_mode(e, .Insert, window)
        return true
    }

    // Undo / Redo
    if key == KEY_UNDO {
        if pt_undo(&e.table) {
            editor_invalidate_syntax(e, 0)
            editor_mark_dirty(e)
            editor_snap_cursor(e)
        }
        return true
    }

    return false
}

editor_handle_event :: proc(e: ^Editor, event: ^sdl.Event, window: ^sdl.Window, app: ^App) -> bool {
    #partial switch event.type {
    case .TEXT_INPUT:
        if e.read_only {
            editor_set_status_message(e, "Buffer is read-only")
            return true
        }
        if e.mode == .Insert {
            text_str := string(event.text.text)
            if len(text_str) == 1 {
                ch := text_str[0]
                offset := editor_get_cursor_offset(e)
                total_len := pt_get_length(&e.table)

                next_ch: u8 = 0
                if offset < total_len {
                    next_ch = pt_byte_at(&e.table, offset)
                }
                prev_ch: u8 = 0
                if offset > 0 {
                    prev_ch = pt_byte_at(&e.table, offset - 1)
                }

                // 1. Step-over (overtype closing bracket or quote)
                if (ch == ')' && next_ch == ')') ||
                   (ch == ']' && next_ch == ']') ||
                   (ch == '}' && next_ch == '}') ||
                   (ch == '"' && next_ch == '"') ||
                   (ch == '\'' && next_ch == '\'') ||
                   (ch == '`' && next_ch == '`') {
                    e.cursor.col += 1
                    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
                    e.last_action = time.now()
                    e.completion.active = false
                    return true
                }

                // 2. Auto-pair brackets and quotes
                is_next_alnum := (next_ch >= 'a' && next_ch <= 'z') ||
                                 (next_ch >= 'A' && next_ch <= 'Z') ||
                                 (next_ch >= '0' && next_ch <= '9')

                paired_str := ""
                if !is_next_alnum {
                    switch ch {
                    case '(':
                        paired_str = "()"
                    case '[':
                        paired_str = "[]"
                    case '{':
                        paired_str = "{}"
                    case '"':
                        if prev_ch != '\\' {
                            cnt := editor_count_char_on_current_line_before_cursor(e, '"')
                            if cnt % 2 == 0 {
                                paired_str = "\"\""
                            }
                        }
                    case '\'':
                        is_prev_ident := (prev_ch >= 'a' && prev_ch <= 'z') ||
                                         (prev_ch >= 'A' && prev_ch <= 'Z') ||
                                         (prev_ch >= '0' && prev_ch <= '9') ||
                                         prev_ch == '_' || prev_ch == '\\'
                        if !is_prev_ident {
                            cnt := editor_count_char_on_current_line_before_cursor(e, '\'')
                            if cnt % 2 == 0 {
                                paired_str = "''"
                            }
                        }
                    case '`':
                        if prev_ch != '\\' {
                            cnt := editor_count_char_on_current_line_before_cursor(e, '`')
                            if cnt % 2 == 0 {
                                paired_str = "``"
                            }
                        }
                    }
                }

                if paired_str != "" {
                    editor_begin_undo_transaction(e)
                    defer editor_end_undo_transaction(e)
                    editor_realize_virtual_spaces(e)
                    offset = editor_get_cursor_offset(e)
                    pt_insert(&e.table, offset, paired_str)
                    e.cursor.col += 1
                    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
                    editor_mark_dirty(e)
                    e.last_action = time.now()
                    e.completion.active = false
                    return true
                }
            }

            if len(text_str) > 0 {
                typed_row := e.cursor.row
                editor_realize_virtual_spaces(e)
                offset := editor_get_cursor_offset(e)
                pt_insert(&e.table, offset, text_str)
                e.cursor.col += len(text_str)
                e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
                editor_mark_dirty(e, typed_row)
                e.last_action = time.now()

                // Trigger or update completion when typing identifier or dot
                lsp := app_get_lsp_for_file(app, e.file_path)
                if lsp != nil && lsp_is_running(lsp) && e.file_path != "" {
                    typed_rune: rune
                    for r in text_str do typed_rune = r
                    if is_word_rune(typed_rune) || typed_rune == '.' {
                        if typed_rune == '.' || !e.completion.active || e.cursor.row != e.completion.trigger_row {
                            trigger_col := e.cursor.col
                            if typed_rune == '.' {
                                trigger_col = e.cursor.col
                            } else {
                                for trigger_col > 0 {
                                    start := editor_prev_rune_start(e, e.cursor.row, trigger_col)
                                    r, _ := editor_rune_at(e, e.cursor.row, start)
                                    if is_word_rune(r) {
                                        trigger_col = start
                                    } else {
                                        break
                                    }
                                }
                            }
                            e.completion.trigger_row = e.cursor.row
                            e.completion.trigger_col = trigger_col
                        }

                        // Immediate didChange sync so server has exact current buffer
                        editor_flush_lsp_change(e, app)

                        // Immediate local filter on existing all_items for zero-latency keystrokes
                        if len(e.completion.all_items) > 0 {
                            editor_filter_completions(e)
                        }

                        lsp_request_completion(lsp, e.file_path, e.cursor.row, e.cursor.col)
                    } else {
                        e.completion.active = false
                    }
                }
            }
            return true
        } else if e.mode == .Command {
            text_str := string(event.text.text)
            for b in transmute([]u8)text_str {
                append(&e.command_buffer, b)
            }
            return true
        }

    case .KEY_DOWN:
        e.last_action = time.now()
        e.status_message = ""
        key := event.key.key
        mod := event.key.mod
        is_ctrl := (mod & sdl.KMOD_CTRL) != {}
        is_alt  := (mod & sdl.KMOD_ALT) != {}

        // Read-only buffers still support navigation, command mode and the
        // mouse wheel, but reject any key that could modify the buffer.
        if e.read_only {
            if key == sdl.K_ESCAPE {
                editor_set_mode(e, .Normal, window)
                return true
            }
            allowed :=
                key == sdl.K_LEFT || key == sdl.K_RIGHT || key == sdl.K_UP || key == sdl.K_DOWN ||
                key == KEY_MOVE_LEFT || key == KEY_MOVE_DOWN || key == KEY_MOVE_UP || key == KEY_MOVE_RIGHT ||
                key == KEY_LINE_START || key == KEY_LINE_END ||
                key == KEY_LINE_START_ZERO || key == KEY_LINE_END_DOLLAR ||
                key == KEY_GOTO || key == KEY_FILE_END || key == KEY_HOVER ||
                key == KEY_WORD_FORWARD || key == KEY_WORD_BACKWARD ||
                key == KEY_SCOPE_DOWN || key == KEY_SCOPE_UP ||
                key == KEY_CMD_PROMPT || key == KEY_CMD_PROMPT_ALT
            if !allowed {
                e.pending_cmd = 0
                editor_set_status_message(e, "Buffer is read-only")
                return true
            }
        }

        // A-j: Move line or selection down
        if is_alt && key == KEY_MOVE_LINE_DOWN {
            editor_move_lines(e, 1)
            return true
        }

        // A-k: Move line or selection up
        if is_alt && key == KEY_MOVE_LINE_UP {
            editor_move_lines(e, -1)
            return true
        }

        // A-w: Copy selection (yank)
        if is_alt && key == KEY_YANK_ALT {
            if e.mode == .Visual {
                editor_yank_selection(e)
                return true
            }
        }

        // C-y: Paste clipboard
        if is_ctrl && key == KEY_PASTE_CLIPBOARD {
            editor_paste(e)
            return true
        }

        if is_ctrl && key == KEY_SAVE {
            editor_save_file(e, app)
            return true
        }

        if is_ctrl && key == KEY_UNDO_ALT {
            if pt_undo(&e.table) {
                editor_invalidate_syntax(e, 0)
                editor_mark_dirty(e)
                editor_snap_cursor(e)
            }
            return true
        }

        if is_ctrl && key == KEY_REDO {
            if pt_redo(&e.table) {
                editor_invalidate_syntax(e, 0)
                editor_mark_dirty(e)
                editor_snap_cursor(e)
            }
            return true
        }

        if e.mode == .Insert {
            return editor_handle_insert_key(e, key, mod, window, app)
        } else if e.mode == .Command {
            return editor_handle_command_key(e, key, window, app)
        } else {
            return editor_handle_normal_key(e, key, mod, window, app)
        }

    case .MOUSE_WHEEL:
        if event.wheel.y > 0 {
            e.scroll_row = max(0, e.scroll_row - 3)
        } else if event.wheel.y < 0 {
            total_lines := pt_get_line_count(&e.table) + 1
            e.scroll_row = min(max(0, total_lines - 1), e.scroll_row + 3)
        }
        return true
    }

    return false
}

editor_render :: proc(e: ^Editor, renderer: ^sdl.Renderer, font: ^Font, rect: sdl.FRect, is_focused: bool, theme: ^Theme, lsp: ^LspClient = nil) {
    if rect.w < 50 || rect.h < 50 do return

    scale := get_font_scale_multiplier(e.font_scale)
    line_h := get_line_height(e.font_scale)
    char_w := e.char_advance * scale

    total_lines := pt_get_line_count(&e.table) + 1

    status_bar_h := line_h + 8.0
    editor_h := rect.h - status_bar_h

    digits := 1
    tmp := total_lines
    for tmp >= 10 {
        tmp /= 10
        digits += 1
    }
    digits = max(3, digits)
    gutter_w := f32(digits + 2) * char_w

    visible_lines := int(editor_h / line_h)
    visible_cols := int((rect.w - gutter_w) / char_w)
    if visible_lines <= 0 do visible_lines = 1
    if visible_cols <= 0 do visible_cols = 1

    editor_scroll_to_cursor(e, visible_lines, visible_cols)

    // Clip rendering to this pane's rectangle
    clip := sdl.Rect{i32(rect.x), i32(rect.y), i32(rect.w), i32(rect.h)}
    sdl.SetRenderClipRect(renderer, &clip)
    defer sdl.SetRenderClipRect(renderer, nil)

    // 1. Background
    bg_color := theme.bg
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    bg_rect := rect
    sdl.RenderFillRect(renderer, &bg_rect)

    // 2. Gutter background
    gutter_rect := sdl.FRect{
        x = rect.x,
        y = rect.y,
        w = gutter_w,
        h = editor_h,
    }
    sdl.SetRenderDrawColorFloat(renderer, theme.gutter_bg.r, theme.gutter_bg.g, theme.gutter_bg.b, theme.gutter_bg.a)
    sdl.RenderFillRect(renderer, &gutter_rect)

    // 3. Gutter separator line
    sep_rect := sdl.FRect{
        x = rect.x + gutter_w - 1.0,
        y = rect.y,
        w = 1.0,
        h = editor_h,
    }
    sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
    sdl.RenderFillRect(renderer, &sep_rect)

    // 4. Current line highlight
    if is_focused && e.cursor.row >= e.scroll_row && e.cursor.row < e.scroll_row + visible_lines {
        hl_y := rect.y + f32(e.cursor.row - e.scroll_row) * line_h
        hl_rect := sdl.FRect{
            x = rect.x + gutter_w,
            y = hl_y,
            w = rect.w - gutter_w,
            h = line_h,
        }
        sdl.SetRenderDrawColorFloat(renderer, theme.cursor_line_bg.r, theme.cursor_line_bg.g, theme.cursor_line_bg.b, theme.cursor_line_bg.a)
        sdl.RenderFillRect(renderer, &hl_rect)
    }

    // 5. Visual Mode selection highlight rectangles
    if e.mode == .Visual {
        start_sel, end_sel := editor_get_selection_range(e)
        for i in 0 ..< visible_lines {
            line_idx := e.scroll_row + i
            if line_idx >= total_lines do break
            if line_idx < start_sel.row || line_idx > end_sel.row do continue

            y_pos := rect.y + f32(i) * line_h
            line_len := editor_get_line_len(e, line_idx)

            c0 := 0
            c1 := line_len

            end_sel_len := editor_get_line_len(e, end_sel.row)
            end_rune := end_sel.col
            if end_sel.col < end_sel_len {
                end_rune = editor_next_rune_end(e, end_sel.row, end_sel.col)
            }
            if line_idx == start_sel.row && line_idx == end_sel.row {
                c0 = start_sel.col
                c1 = end_rune
            } else if line_idx == start_sel.row {
                c0 = start_sel.col
                c1 = max(line_len + 1, start_sel.col + 1)
            } else if line_idx == end_sel.row {
                c0 = 0
                c1 = end_rune
            } else {
                c0 = 0
                c1 = line_len + 1
            }

            c0_vis := editor_visual_col(e, line_idx, min(c0, line_len))
            c1_vis := editor_visual_col(e, line_idx, min(c1, line_len))
            if c1 > line_len do c1_vis += 1
            scroll_vis := e.scroll_col

            if c1_vis > c0_vis {
                sel_x := rect.x + gutter_w + 4.0 + f32(c0_vis - scroll_vis) * char_w
                sel_w := f32(c1_vis - c0_vis) * char_w
                sel_rect := sdl.FRect{
                    x = sel_x,
                    y = y_pos,
                    w = sel_w,
                    h = line_h,
                }
                sdl.SetRenderDrawColorFloat(renderer, theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, theme.selection_bg.a)
                sdl.RenderFillRect(renderer, &sel_rect)
            }
        }
    }

    // Diagnostic underlines on visible lines
    if lsp != nil && e.file_path != "" {
        norm_path, _ := filepath.abs(e.file_path, context.temp_allocator)
        if diags, has_diags := lsp.diagnostics[norm_path]; has_diags {
            for d in diags {
                for i in 0 ..< visible_lines {
                    line_idx := e.scroll_row + i
                    if line_idx >= total_lines do break
                    if d.start_row <= line_idx && d.end_row >= line_idx {
                        c_st := d.start_col if d.start_row == line_idx else 0
                        c_en := d.end_col if d.end_row == line_idx else editor_get_line_len(e, line_idx)
                        if c_en <= c_st do c_en = c_st + 1

                        scroll_vis := e.scroll_col
                        vis_st := max(0, editor_visual_col(e, line_idx, c_st) - scroll_vis)
                        vis_en := max(vis_st + 1, editor_visual_col(e, line_idx, c_en) - scroll_vis)
                        if vis_st < visible_cols {
                            vis_en = min(visible_cols, vis_en)
                            dx := rect.x + gutter_w + 4.0 + f32(vis_st) * char_w
                            dw := f32(vis_en - vis_st) * char_w
                            dy := rect.y + f32(i) * line_h + line_h - 2.0
                            under_rect := sdl.FRect{dx, dy, dw, 2.0}
                            d_col := sdl.FColor{0.95, 0.25, 0.25, 0.9} if d.severity == .Error else sdl.FColor{0.95, 0.75, 0.2, 0.9}
                            sdl.SetRenderDrawColorFloat(renderer, d_col.r, d_col.g, d_col.b, d_col.a)
                            sdl.RenderFillRect(renderer, &under_rect)
                        }
                    }
                }
            }
        }
    }

    // 6. Block Cursor (rendered behind text)
    cursor_vis := editor_visual_col(e, e.cursor.row, e.cursor.col)
    scroll_vis := e.scroll_col
    cx := rect.x + gutter_w + 4.0 + f32(cursor_vis - scroll_vis) * char_w
    cy := rect.y + f32(e.cursor.row - e.scroll_row) * line_h
    cursor_visible := is_focused && cursor_is_visible(&e.cursor, e.last_action)
    e.cursor.color = theme.cursor

    if is_focused && e.cursor.shape == .Block {
        render_cursor(&e.cursor, renderer, cx, cy, char_w, line_h, e.last_action)
    }

    // 7. Push visible lines into font batcher
    inverted_cursor_char_color := theme.bg
    active_line_num_color := theme.gutter_active_fg
    normal_line_num_color := theme.gutter_fg
    cache_seed := syntax_cache_hash(e.file_path, u64(theme.id) + 1)

    for i in 0 ..< visible_lines {
        line_idx := e.scroll_row + i
        if line_idx >= total_lines do break

        y_pos := rect.y + f32(i) * line_h

        // Line number in gutter
        line_num_str := format_line_number(line_idx + 1, digits)
        ln_color := normal_line_num_color
        if is_focused && line_idx == e.cursor.row {
            ln_color = active_line_num_color
        }
        push_line(font, line_num_str, Vec2{rect.x + char_w * 0.5, y_pos}, ln_color, e.font_scale)

        // Line text
        state_in := editor_ensure_syntax_state(e, line_idx, theme)
        line_str, ok := pt_line_text(&e.table, line_idx)
        if ok {
            defer delete(line_str)
            byte_start := editor_byte_col_for_visual(e, line_idx, e.scroll_col)
            if byte_start < len(line_str) {
                visible_str := line_str[byte_start:]
                vis_start := editor_visual_col(e, line_idx, byte_start)

                hl_col := -1
                if is_focused && (e.mode == .Normal || e.mode == .Visual) && cursor_visible && line_idx == e.cursor.row {
                    hl_col = e.cursor.col - byte_start
                }

                line_hash := syntax_cache_hash(line_str, cache_seed)
                state_hash := syntax_state_hash(state_in)
                cache := &e.syntax_cache[line_idx % SYNTAX_CACHE_SLOTS]
                if !cache.valid || cache.row != line_idx || cache.hash != line_hash ||
                   cache.state_hash != state_hash || len(cache.colors) != len(line_str) {
                    resize(&cache.colors, len(line_str))
                    cache.state_out = syntax_highlight_line_state(e.file_path, line_str, theme, cache.colors[:], state_in)
                    cache.valid = true
                    cache.row = line_idx
                    cache.hash = line_hash
                    cache.state_hash = state_hash
                }
                editor_record_syntax_state(e, line_idx, cache.state_out)
                visible_colors := cache.colors[byte_start:]

                push_editor_line(
                    font,
                    visible_str,
                    Vec2{rect.x + gutter_w + 4.0 - f32(e.scroll_col - vis_start) * char_w, y_pos},
                    theme.fg,
                    e.font_scale,
                    hl_col,
                    inverted_cursor_char_color,
                    visible_colors,
                )
            }
        }
    }

    // 8. Status Bar
    status_bar_rect := sdl.FRect{
        x = rect.x,
        y = rect.y + editor_h,
        w = rect.w,
        h = status_bar_h,
    }
    sb_bg := theme.status_bg if is_focused else theme.status_inactive_bg
    sdl.SetRenderDrawColorFloat(renderer, sb_bg.r, sb_bg.g, sb_bg.b, sb_bg.a)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    mode_text := "-- NORMAL --"
    status_color := theme.keyword
    switch e.mode {
    case .Normal:
        mode_text = "-- NORMAL --"
        status_color = theme.keyword
    case .Insert:
        mode_text = "-- INSERT --"
        status_color = theme.string_lit
    case .Visual:
        mode_text = "-- VISUAL --"
        status_color = theme.fn_name
    case .Command:
        mode_text = "-- COMMAND --"
        status_color = theme.number_lit
    }

    if !is_focused {
        status_color = theme.status_inactive_fg
    }

    dirty_indicator := " [+]" if e.dirty else ""
    file_display := e.file_path if e.file_path != "" else "[No Name]"
    focus_badge := "[ACTIVE] " if is_focused else ""
    status_info := fmt.tprintf("%s%s   %s%s   Line %d/%d, Col %d", focus_badge, mode_text, file_display, dirty_indicator, e.cursor.row + 1, total_lines, e.cursor.col + 1)

    // Diagnostic message on cursor line
    current_diag_msg := ""
    if lsp != nil && e.file_path != "" {
        norm_path, _ := filepath.abs(e.file_path, context.temp_allocator)
        if diags, has_diags := lsp.diagnostics[norm_path]; has_diags {
            for d in diags {
                if d.start_row <= e.cursor.row && d.end_row >= e.cursor.row {
                    current_diag_msg = d.message
                    break
                }
            }
        }
    }
    if current_diag_msg != "" {
        first_nl := strings.index(current_diag_msg, "\n")
        short_msg := current_diag_msg if first_nl < 0 else current_diag_msg[:first_nl]
        status_info = fmt.tprintf("%s   | [LSP: %s]", status_info, short_msg)
    } else if e.status_message != "" {
        status_info = fmt.tprintf("%s   | %s", status_info, e.status_message)
    }

    push_line(font, status_info, Vec2{rect.x + 10.0, rect.y + editor_h + 4.0}, status_color, e.font_scale)

    // Flush text
    flush_text(font, renderer)

    // 9. Bar Cursor (in Insert Mode)
    if is_focused && e.cursor.shape == .Bar {
        render_cursor(&e.cursor, renderer, cx, cy, char_w, line_h, e.last_action)
    }

    // 10. Autocomplete Popup
    if is_focused && e.mode == .Insert && e.completion.active && len(e.completion.items) > 0 {
        pop_w := min(460.0 * global_ui_scale, rect.w - 20.0)
        item_h := line_h + 2.0
        visible_items := min(7, len(e.completion.items))
        items_h := f32(visible_items) * item_h

        sel_idx := clamp(e.completion.selected, 0, len(e.completion.items) - 1)
        sel_item := e.completion.items[sel_idx]
        has_doc := (sel_item.documentation != "" || sel_item.detail != "")
        doc_preview_h : f32 = 0
        if has_doc {
            doc_preview_h = line_h * 2 + 8.0
        }
        footer_h := line_h + 6.0
        pop_h := items_h + doc_preview_h + footer_h + 4.0

        pop_x := cx
        if pop_x + pop_w > rect.x + rect.w - 8.0 {
            pop_x = rect.x + rect.w - pop_w - 8.0
        }
        pop_x = max(rect.x + 8.0, pop_x)

        pop_y := cy + line_h + 2.0
        if pop_y + pop_h > rect.y + editor_h {
            pop_y = cy - pop_h - 2.0
        }
        pop_y = max(rect.y + 2.0, pop_y)

        // Dropdown background
        pop_rect := sdl.FRect{pop_x, pop_y, pop_w, pop_h}
        sdl.SetRenderDrawColorFloat(renderer, theme.bg.r * 0.85, theme.bg.g * 0.85, theme.bg.b * 0.85, 0.98)
        sdl.RenderFillRect(renderer, &pop_rect)
        sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, 1.0)
        sdl.RenderRect(renderer, &pop_rect)

        // Keep scroll offset aligned
        if e.completion.selected < e.completion.scroll_offset {
            e.completion.scroll_offset = e.completion.selected
        } else if e.completion.selected >= e.completion.scroll_offset + visible_items {
            e.completion.scroll_offset = e.completion.selected - visible_items + 1
        }

        // Render visible items
        for vi in 0 ..< visible_items {
            idx := e.completion.scroll_offset + vi
            if idx >= len(e.completion.items) do break
            it := e.completion.items[idx]
            row_y := pop_y + 2.0 + f32(vi) * item_h

            if idx == e.completion.selected {
                row_sel_rect := sdl.FRect{pop_x + 2.0, row_y, pop_w - 4.0, item_h}
                sdl.SetRenderDrawColorFloat(renderer, theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 0.9)
                sdl.RenderFillRect(renderer, &row_sel_rect)
            }

            lbl_color := theme.keyword if idx == e.completion.selected else theme.fg
            push_line(font, it.label, Vec2{pop_x + 8.0, row_y + 1.0}, lbl_color, e.font_scale)

            if it.detail != "" {
                det_x := pop_x + pop_w * 0.45
                det_str := it.detail
                if len(det_str) > 28 do det_str = det_str[:28]
                push_line(font, det_str, Vec2{det_x, row_y + 1.0}, theme.comment, e.font_scale)
            }
        }

        // Render Doc preview if selected item has it
        curr_y := pop_y + 2.0 + items_h
        if has_doc {
            div_rect := sdl.FRect{pop_x + 2.0, curr_y, pop_w - 4.0, 1.0}
            sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, 0.7)
            sdl.RenderFillRect(renderer, &div_rect)

            doc_text := sel_item.documentation if sel_item.documentation != "" else sel_item.detail
            lines := strings.split(doc_text, "\n", context.temp_allocator)
            doc_line1 := strings.trim_space(lines[0])
            doc_line2 := ""
            if len(lines) > 1 do doc_line2 = strings.trim_space(lines[1])

            push_line(font, doc_line1, Vec2{pop_x + 8.0, curr_y + 3.0}, theme.string_lit, e.font_scale)
            if doc_line2 != "" {
                push_line(font, doc_line2, Vec2{pop_x + 8.0, curr_y + 3.0 + line_h}, theme.comment, e.font_scale)
            }
            curr_y += doc_preview_h
        }

        // Render footer bar
        foot_div := sdl.FRect{pop_x + 2.0, curr_y, pop_w - 4.0, 1.0}
        sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, 0.7)
        sdl.RenderFillRect(renderer, &foot_div)

        footer_text := "[Enter: Complete | Shift+Enter: Doc Split | Tab: Cycle]"
        push_line(font, footer_text, Vec2{pop_x + 8.0, curr_y + 3.0}, theme.gutter_fg, e.font_scale)

        flush_text(font, renderer)
    }
}
