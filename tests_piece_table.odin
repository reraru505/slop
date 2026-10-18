package main

import "core:testing"
import "core:strings"
import "core:fmt"

@(test)
test_pt_init_empty :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "")
    defer pt_destroy(&pt)

    testing.expect_value(t, pt_get_length(&pt), 0)
    testing.expect_value(t, pt_get_line_count(&pt), 0)

    full := pt_full_text(&pt)
    defer delete(full)
    testing.expect_value(t, full, "")
    fmt.println("  ✓ [PieceTable] Empty buffer invariants verified")
}

@(test)
test_pt_init_content :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "Hello, world!\nLine 2\nLine 3")
    defer pt_destroy(&pt)

    testing.expect_value(t, pt_get_length(&pt), 27)
    testing.expect_value(t, pt_get_line_count(&pt), 2)

    full := pt_full_text(&pt)
    defer delete(full)
    testing.expect_value(t, full, "Hello, world!\nLine 2\nLine 3")
    fmt.println("  ✓ [PieceTable] Initial content & line indexing verified")
}

@(test)
test_pt_insertions :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "world")
    defer pt_destroy(&pt)

    // Insert at beginning
    pt_insert(&pt, 0, "Hello ")
    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "Hello world")

    // Insert at end
    pt_insert(&pt, pt_get_length(&pt), "!")
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "Hello world!")

    // Insert in middle
    pt_insert(&pt, 5, ", beautiful")
    text3 := pt_full_text(&pt)
    defer delete(text3)
    testing.expect_value(t, text3, "Hello, beautiful world!")
    fmt.println("  ✓ [PieceTable] Start/middle/end insertions verified")
}

@(test)
test_pt_deletions :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "Hello, beautiful world!")
    defer pt_destroy(&pt)

    // Delete middle ", beautiful"
    pt_delete_range(&pt, 5, 11)
    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "Hello world!")

    // Delete beginning "Hello "
    pt_delete_range(&pt, 0, 6)
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "world!")

    // Delete end "!"
    pt_delete_range(&pt, 5, 1)
    text3 := pt_full_text(&pt)
    defer delete(text3)
    testing.expect_value(t, text3, "world")
    fmt.println("  ✓ [PieceTable] Start/middle/end deletions verified")
}

@(test)
test_pt_line_indexing :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "alpha\nbeta\ngamma\ndelta")
    defer pt_destroy(&pt)

    testing.expect_value(t, pt_get_line_count(&pt), 3)

    line0, ok0 := pt_line_text(&pt, 0)
    defer if ok0 do delete(line0)
    testing.expect_value(t, ok0, true)
    testing.expect_value(t, line0, "alpha")

    line1, ok1 := pt_line_text(&pt, 1)
    defer if ok1 do delete(line1)
    testing.expect_value(t, ok1, true)
    testing.expect_value(t, line1, "beta")

    line2, ok2 := pt_line_text(&pt, 2)
    defer if ok2 do delete(line2)
    testing.expect_value(t, ok2, true)
    testing.expect_value(t, line2, "gamma")

    line3, ok3 := pt_line_text(&pt, 3)
    defer if ok3 do delete(line3)
    testing.expect_value(t, ok3, true)
    testing.expect_value(t, line3, "delta")

    // Out of range line
    _, ok4 := pt_line_text(&pt, 4)
    testing.expect_value(t, ok4, false)
    fmt.println("  ✓ [PieceTable] Multi-line row/col lookup verified")
}

@(test)
test_pt_undo_redo :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "start")
    defer pt_destroy(&pt)

    pt_insert(&pt, 5, " middle")
    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "start middle")

    pt_insert(&pt, 12, " end")
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "start middle end")

    // Undo second insertion
    undo1 := pt_undo(&pt)
    testing.expect_value(t, undo1, true)
    text_u1 := pt_full_text(&pt)
    defer delete(text_u1)
    testing.expect_value(t, text_u1, "start middle")

    // Undo first insertion
    undo2 := pt_undo(&pt)
    testing.expect_value(t, undo2, true)
    text_u2 := pt_full_text(&pt)
    defer delete(text_u2)
    testing.expect_value(t, text_u2, "start")

    // Redo first insertion
    redo1 := pt_redo(&pt)
    testing.expect_value(t, redo1, true)
    text_r1 := pt_full_text(&pt)
    defer delete(text_r1)
    testing.expect_value(t, text_r1, "start middle")

    // Redo second insertion
    redo2 := pt_redo(&pt)
    testing.expect_value(t, redo2, true)
    text_r2 := pt_full_text(&pt)
    defer delete(text_r2)
    testing.expect_value(t, text_r2, "start middle end")
    fmt.println("  ✓ [PieceTable] Full undo/redo cycle verified")
}

@(test)
test_pt_replace :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "Hello, world!")
    defer pt_destroy(&pt)

    // Replace "world" with "there"
    pt_replace(&pt, 7, 5, "there")
    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "Hello, there!")
    testing.expect_value(t, pt_get_length(&pt), 13)

    // A replace is a single undo step
    testing.expect_value(t, pt_undo(&pt), true)
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "Hello, world!")

    testing.expect_value(t, pt_redo(&pt), true)
    text3 := pt_full_text(&pt)
    defer delete(text3)
    testing.expect_value(t, text3, "Hello, there!")
    fmt.println("  ✓ [PieceTable] replace() is atomic for undo and redo")
}

@(test)
test_pt_replace_edge_cases :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "abc")
    defer pt_destroy(&pt)

    // length 0 with text behaves as an insert
    pt_replace(&pt, 1, 0, "X")
    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "aXbc")

    // Offset at EOF with a positive length appends
    pt_replace(&pt, pt_get_length(&pt), 5, "!")
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "aXbc!")

    // Offset beyond EOF clamps and appends
    pt_replace(&pt, 999, 3, "?")
    text3 := pt_full_text(&pt)
    defer delete(text3)
    testing.expect_value(t, text3, "aXbc!?")

    // Deleting beyond the end clamps
    pt_replace(&pt, 2, 999, "Z")
    text4 := pt_full_text(&pt)
    defer delete(text4)
    testing.expect_value(t, text4, "aXZ")

    // No-op replace
    pt_replace(&pt, 0, 0, "")
    text5 := pt_full_text(&pt)
    defer delete(text5)
    testing.expect_value(t, text5, "aXZ")
    fmt.println("  ✓ [PieceTable] replace() clamping and empty-edit cases")
}

@(test)
test_pt_text_bounds :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "abcdef")
    defer pt_destroy(&pt)

    s, ok := pt_text(&pt, 1, 3)
    defer if ok do delete(s)
    testing.expect_value(t, ok, true)
    testing.expect_value(t, s, "bcd")

    empty, empty_ok := pt_text(&pt, 6, 0)
    defer if empty_ok do delete(empty)
    testing.expect_value(t, empty_ok, true)
    testing.expect_value(t, empty, "")

    _, neg_off := pt_text(&pt, -1, 1)
    testing.expect_value(t, neg_off, false)

    _, neg_len := pt_text(&pt, 0, -1)
    testing.expect_value(t, neg_len, false)

    _, past_end := pt_text(&pt, 5, 2)
    testing.expect_value(t, past_end, false)

    // write_text mirrors text() but rejects out-of-bounds ranges
    b := strings.builder_make(context.temp_allocator)
    defer strings.builder_destroy(&b)
    testing.expect_value(t, write_text(&pt, 2, 2, &b), true)
    testing.expect_value(t, strings.to_string(b), "cd")
    testing.expect_value(t, write_text(&pt, 2, 99, &b), false)
    fmt.println("  ✓ [PieceTable] text()/write_text() bounds verified")
}

@(test)
test_pt_byte_at_bounds :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "abc")
    defer pt_destroy(&pt)

    testing.expect_value(t, pt_byte_at(&pt, 0), 'a')
    testing.expect_value(t, pt_byte_at(&pt, 2), 'c')
    testing.expect_value(t, pt_byte_at(&pt, 3), 0)
    testing.expect_value(t, pt_byte_at(&pt, -1), 0)
    fmt.println("  ✓ [PieceTable] byte_at() out-of-range returns zero")
}

@(test)
test_pt_line_offset_roundtrip :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "alpha\nbeta\ngamma\ndelta")
    defer pt_destroy(&pt)

    expected_starts := []int{0, 6, 11, 17}
    for start, line in expected_starts {
        testing.expect_value(t, pt_line_to_offset(&pt, line), start)
        testing.expect_value(t, pt_offset_to_line(&pt, start), line)
    }

    // Negative line clamps to 0; lines past the last newline clamp to EOF
    testing.expect_value(t, pt_line_to_offset(&pt, -3), 0)
    testing.expect_value(t, pt_line_to_offset(&pt, 4), 22)
    testing.expect_value(t, pt_line_to_offset(&pt, 999), 22)

    // Newline bytes belong to the line they terminate
    testing.expect_value(t, pt_offset_to_line(&pt, 5), 0)
    testing.expect_value(t, pt_offset_to_line(&pt, 6), 1)
    testing.expect_value(t, pt_offset_to_line(&pt, 10), 1)
    testing.expect_value(t, pt_offset_to_line(&pt, 16), 2)
    testing.expect_value(t, pt_offset_to_line(&pt, 22), 3)
    fmt.println("  ✓ [PieceTable] line_to_offset/offset_to_line roundtrip")
}

@(test)
test_pt_line_mapping_empty_and_trailing :: proc(t: ^testing.T) {
    // Empty buffer: one logical empty line
    empty: PieceTable
    pt_init(&empty, "")
    defer pt_destroy(&empty)
    testing.expect_value(t, pt_get_line_count(&empty), 0)
    line0, ok0 := pt_line_text(&empty, 0)
    defer if ok0 do delete(line0)
    testing.expect_value(t, ok0, true)
    testing.expect_value(t, line0, "")
    _, missing := pt_line_text(&empty, 1)
    testing.expect_value(t, missing, false)

    // Trailing newline creates an empty final logical line
    trailing: PieceTable
    pt_init(&trailing, "a\n")
    defer pt_destroy(&trailing)
    testing.expect_value(t, pt_get_line_count(&trailing), 1)
    testing.expect_value(t, pt_line_to_offset(&trailing, 1), 2)
    testing.expect_value(t, pt_offset_to_line(&trailing, 2), 1)
    last, last_ok := pt_line_text(&trailing, 1)
    defer if last_ok do delete(last)
    testing.expect_value(t, last_ok, true)
    testing.expect_value(t, last, "")
    fmt.println("  ✓ [PieceTable] empty buffer and trailing-newline mapping")
}

@(test)
test_pt_line_mapping_crlf :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "one\r\ntwo\r\n")
    defer pt_destroy(&pt)

    testing.expect_value(t, pt_get_line_count(&pt), 2)
    testing.expect_value(t, pt_line_to_offset(&pt, 1), 5)
    testing.expect_value(t, pt_line_to_offset(&pt, 2), 10)

    l0, ok0 := pt_line_text(&pt, 0)
    defer if ok0 do delete(l0)
    testing.expect_value(t, ok0, true)
    testing.expect_value(t, l0, "one")

    l1, ok1 := pt_line_text(&pt, 1)
    defer if ok1 do delete(l1)
    testing.expect_value(t, ok1, true)
    testing.expect_value(t, l1, "two")

    l2, ok2 := pt_line_text(&pt, 2)
    defer if ok2 do delete(l2)
    testing.expect_value(t, ok2, true)
    testing.expect_value(t, l2, "")
    fmt.println("  ✓ [PieceTable] CRLF line endings index and strip correctly")
}

@(test)
test_pt_interleaved_edits_line_index :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "one\ntwo\nthree")
    defer pt_destroy(&pt)

    pt_insert(&pt, 0, "zero\n")
    pt_delete_range(&pt, 4, 4) // remove "one\n"
    pt_insert(&pt, 5, "TWO-")

    text := pt_full_text(&pt)
    defer delete(text)
    testing.expect_value(t, text, "zero\nTWO-two\nthree")
    testing.expect_value(t, pt_get_line_count(&pt), 2)

    expected := []string{"zero", "TWO-two", "three"}
    for want, row in expected {
        got, ok := pt_line_text(&pt, row)
        defer if ok do delete(got)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, got, want)
        testing.expect_value(t, pt_offset_to_line(&pt, pt_line_to_offset(&pt, row)), row)
    }
    fmt.println("  ✓ [PieceTable] line index stays consistent across mixed edits")
}

@(test)
test_pt_undo_redo_deletions_and_replacements :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "abcdef")
    defer pt_destroy(&pt)

    pt_delete_range(&pt, 1, 3) // "aef"
    pt_replace(&pt, 1, 1, "XY") // "aXYf"

    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "aXYf")

    testing.expect_value(t, pt_undo(&pt), true) // undo replace
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "aef")

    testing.expect_value(t, pt_undo(&pt), true) // undo delete
    text3 := pt_full_text(&pt)
    defer delete(text3)
    testing.expect_value(t, text3, "abcdef")

    testing.expect_value(t, pt_redo(&pt), true)
    text4 := pt_full_text(&pt)
    defer delete(text4)
    testing.expect_value(t, text4, "aef")

    testing.expect_value(t, pt_redo(&pt), true)
    text5 := pt_full_text(&pt)
    defer delete(text5)
    testing.expect_value(t, text5, "aXYf")

    testing.expect_value(t, pt_undo(&pt), true)
    testing.expect_value(t, pt_undo(&pt), true)
    testing.expect_value(t, pt_undo(&pt), false) // history exhausted
    fmt.println("  ✓ [PieceTable] delete and replace undo/redo stacks verified")
}

@(test)
test_pt_new_edit_clears_redo :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "a")
    defer pt_destroy(&pt)

    pt_insert(&pt, 1, "b")
    testing.expect_value(t, pt_undo(&pt), true)
    testing.expect_value(t, pt_redo(&pt), true)
    testing.expect_value(t, pt_undo(&pt), true) // back to "a", redo available

    pt_insert(&pt, 1, "c") // a new edit must discard the redo branch
    testing.expect_value(t, pt_redo(&pt), false)

    text := pt_full_text(&pt)
    defer delete(text)
    testing.expect_value(t, text, "ac")
    fmt.println("  ✓ [PieceTable] new edits invalidate the redo stack")
}

@(test)
test_pt_undo_controls :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "a")
    defer pt_destroy(&pt)

    // Disabled recording: edits apply but cannot be undone
    set_undo_enabled(&pt, false)
    pt_insert(&pt, 1, "b")
    testing.expect_value(t, pt_undo(&pt), false)
    text1 := pt_full_text(&pt)
    defer delete(text1)
    testing.expect_value(t, text1, "ab")

    // Re-enabling starts recording again
    set_undo_enabled(&pt, true)
    pt_insert(&pt, 2, "c")
    testing.expect_value(t, pt_undo(&pt), true)
    text2 := pt_full_text(&pt)
    defer delete(text2)
    testing.expect_value(t, text2, "ab")

    // clear_undo drops history, clear_redo drops the undone branch
    pt_insert(&pt, 2, "d")
    clear_undo(&pt)
    testing.expect_value(t, pt_undo(&pt), false)
    pt_insert(&pt, 3, "e")
    testing.expect_value(t, pt_undo(&pt), true)
    clear_redo(&pt)
    testing.expect_value(t, pt_redo(&pt), false)
    fmt.println("  ✓ [PieceTable] undo enabled/clear_undo/clear_redo controls")
}

@(test)
test_pt_piece_coalescing :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "")
    defer pt_destroy(&pt)

    // Sequential typing at EOF must fold into a single add piece
    for ch in "hello" {
        pt_insert(&pt, pt_get_length(&pt), string([]u8{u8(ch)}))
    }
    text := pt_full_text(&pt)
    defer delete(text)
    testing.expect_value(t, text, "hello")
    testing.expect_value(t, piece_count(&pt), 1)

    // Appending to a buffer with original content is one original + one add piece
    pt2: PieceTable
    pt_init(&pt2, "x")
    defer pt_destroy(&pt2)
    pt_insert(&pt2, 1, "ab")
    pt_insert(&pt2, 3, "cd")
    text2 := pt_full_text(&pt2)
    defer delete(text2)
    testing.expect_value(t, text2, "xabcd")
    testing.expect_value(t, piece_count(&pt2), 2)
    fmt.println("  ✓ [PieceTable] adjacent insertions coalesce into one piece")
}

// Small deterministic PRNG so the fuzz test is identical on every run.
pt_test_rand :: proc(rng: ^u64) -> u64 {
    rng^ = rng^ * 6364136223846793005 + 1442695040888963407
    return rng^ >> 33
}

pt_test_line_count :: proc(s: []u8) -> int {
    n := 0
    for b in s do if b == '\n' do n += 1
    return n
}

pt_test_line_to_offset :: proc(s: []u8, line: int) -> int {
    if line <= 0 do return 0
    seen := 0
    for b, i in s {
        if b == '\n' {
            seen += 1
            if seen == line do return i + 1
        }
    }
    return len(s)
}

pt_test_offset_to_line :: proc(s: []u8, offset: int) -> int {
    end := clamp(offset, 0, len(s))
    line := 0
    for i in 0 ..< end do if s[i] == '\n' do line += 1
    return line
}

@(test)
test_pt_random_edits_against_reference :: proc(t: ^testing.T) {
    initial := "seed\ntext\n"
    pt: PieceTable
    pt_init(&pt, initial)
    defer pt_destroy(&pt)

    ref: [dynamic]u8
    defer delete(ref)
    append(&ref, ..transmute([]u8)initial)

    alphabet := []u8{'a', 'b', 'c', 'd', ' ', '\n'}
    rng: u64 = 0x5EED_1234_ABCD_0001

    for _ in 0 ..< 400 {
        op := pt_test_rand(&rng) % 3
        switch op {
        case 0: // insert
            off := int(pt_test_rand(&rng) % u64(len(ref) + 1))
            n := int(pt_test_rand(&rng) % 4) + 1
            tmp: [4]u8
            for i in 0 ..< n do tmp[i] = alphabet[pt_test_rand(&rng) % u64(len(alphabet))]
            pt_insert(&pt, off, string(tmp[:n]))
            inject_at(&ref, off, ..tmp[:n])
        case 1: // delete
            if len(ref) == 0 do continue
            off := int(pt_test_rand(&rng) % u64(len(ref)))
            max_del := min(4, len(ref) - off)
            n := int(pt_test_rand(&rng) % u64(max_del)) + 1
            pt_delete_range(&pt, off, n)
            remove_range(&ref, off, off + n)
        case 2: // replace
            off := int(pt_test_rand(&rng) % u64(len(ref) + 1))
            max_del := min(4, len(ref) - off)
            n := int(pt_test_rand(&rng) % u64(max_del + 1))
            m := int(pt_test_rand(&rng) % 3) + 1
            tmp: [3]u8
            for i in 0 ..< m do tmp[i] = alphabet[pt_test_rand(&rng) % u64(len(alphabet))]
            pt_replace(&pt, off, n, string(tmp[:m]))
            if n > 0 do remove_range(&ref, off, off + n)
            inject_at(&ref, off, ..tmp[:m])
        }

        full := pt_full_text(&pt)
        testing.expect_value(t, full, string(ref[:]))
        delete(full)
        testing.expect_value(t, pt_get_length(&pt), len(ref))
        testing.expect_value(t, pt_get_line_count(&pt), pt_test_line_count(ref[:]))

        // Check line/offset mapping against a straightforward reference scan
        for line in 0 ..= pt_get_line_count(&pt) + 1 {
            testing.expect_value(t, pt_line_to_offset(&pt, line), pt_test_line_to_offset(ref[:], line))
        }
        if len(ref) > 0 {
            off := int(pt_test_rand(&rng) % u64(len(ref)))
            testing.expect_value(t, pt_offset_to_line(&pt, off), pt_test_offset_to_line(ref[:], off))
            testing.expect_value(t, pt_byte_at(&pt, off), ref[off])
        }
    }

    final_ref := make([]u8, len(ref), context.temp_allocator)
    copy(final_ref, ref[:])

    // Undoing every edit must return exactly to the initial text
    undo_count := 0
    for pt_undo(&pt) do undo_count += 1
    testing.expect_value(t, undo_count > 0, true)
    restored := pt_full_text(&pt)
    defer delete(restored)
    testing.expect_value(t, restored, initial)

    // Redoing every edit must reproduce the final text
    redo_count := 0
    for pt_redo(&pt) do redo_count += 1
    testing.expect_value(t, redo_count, undo_count)
    final_text := pt_full_text(&pt)
    defer delete(final_text)
    testing.expect_value(t, final_text, string(final_ref))
    fmt.println("  ✓ [PieceTable] 400 randomized edits match a reference buffer")
}

@(test)
test_pt_edge_cases :: proc(t: ^testing.T) {
    pt: PieceTable
    pt_init(&pt, "sample")
    defer pt_destroy(&pt)

    // Zero-length operations
    pt_insert(&pt, 0, "")
    pt_insert(&pt, 3, "")
    pt_delete_range(&pt, 2, 0)
    text := pt_full_text(&pt)
    defer delete(text)
    testing.expect_value(t, text, "sample")

    // Clamped deletions
    pt_delete_range(&pt, 4, 100) // delete beyond end
    text_clamped := pt_full_text(&pt)
    defer delete(text_clamped)
    testing.expect_value(t, text_clamped, "samp")
    fmt.println("  ✓ [PieceTable] Out-of-bounds & zero-length operations verified")
}
