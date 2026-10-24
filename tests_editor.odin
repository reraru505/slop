package main

import "core:testing"
import "core:strings"
import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

@(test)
test_editor_mode_transitions :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "Line 1\nLine 2\nLine 3")
    defer editor_destroy(&e)

    testing.expect_value(t, e.mode, EditorMode.Normal)

    editor_set_mode(&e, .Insert, nil)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.shape, CursorShape.Bar)

    editor_set_mode(&e, .Visual, nil)
    testing.expect_value(t, e.mode, EditorMode.Visual)

    editor_set_mode(&e, .Command, nil)
    testing.expect_value(t, e.mode, EditorMode.Command)

    editor_set_mode(&e, .Normal, nil)
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, e.cursor.shape, CursorShape.Block)
    fmt.println("  ✓ [Editor] Normal/Insert/Visual/CommandLine state transitions verified")
}

@(test)
test_editor_cursor_navigation :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "first line\nsecond line\nthird line")
    defer editor_destroy(&e)

    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 0)

    // Move right via 'l'
    editor_handle_normal_key(&e, KEY_MOVE_RIGHT, {}, nil, nil)
    testing.expect_value(t, e.cursor.col, 1)

    // Move down via 'j'
    editor_handle_normal_key(&e, KEY_MOVE_DOWN, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 1)

    // Move left via 'h'
    editor_handle_normal_key(&e, KEY_MOVE_LEFT, {}, nil, nil)
    testing.expect_value(t, e.cursor.col, 0)

    // Move up via 'k'
    editor_handle_normal_key(&e, KEY_MOVE_UP, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 0)

    // Row clamping
    e.cursor.row = 999
    editor_clamp_cursor(&e)
    testing.expect_value(t, e.cursor.row, 2)

    // Offset clamps column to line length
    e.cursor.col = 999
    off := editor_get_cursor_offset(&e)
    line2_start := pt_line_to_offset(&e.buffer.table, 2)
    line2_len := editor_get_line_len(&e, 2)
    testing.expect_value(t, off, line2_start + line2_len)
    fmt.println("  ✓ [Editor] Navigation bounds & line clamping verified")
}

@(test)
test_editor_word_motions :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "apple banana cherry")
    defer editor_destroy(&e)

    // w -> start of banana
    editor_motion_word_forward(&e)
    testing.expect_value(t, e.cursor.col, 6)

    // w -> start of cherry
    editor_motion_word_forward(&e)
    testing.expect_value(t, e.cursor.col, 13)

    // b -> back to banana
    editor_motion_word_backward(&e)
    testing.expect_value(t, e.cursor.col, 6)

    // b -> back to apple
    editor_motion_word_backward(&e)
    testing.expect_value(t, e.cursor.col, 0)
    fmt.println("  ✓ [Editor] 'w' and 'b' word boundary navigation verified")
}

@(test)
test_editor_delete_line :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "line 1\nline 2\nline 3")
    defer editor_destroy(&e)

    // Delete middle line
    e.cursor.row = 1
    editor_delete_current_line(&e)

    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "line 1\nline 3")
    fmt.println("  ✓ [Editor] 'dd' whole-line deletion verified")
}

@(test)
test_editor_completion_filtering :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "std.")
    defer editor_destroy(&e)

    // Add candidate completions
    candidates := []string{
        "Alignment",
        "Allocator",
        "std",
        "stdin",
        "stdout",
        "string",
        "struct",
    }

    for cand in candidates {
        append(&e.completion.all_items, LspCompletionItem{
            label       = strings.clone(cand),
            detail      = strings.clone("detail"),
            insert_text = strings.clone(cand),
        })
    }

    e.cursor.row = 0
    e.cursor.col = 4
    e.completion.trigger_row = 0
    e.completion.trigger_col = 4

    // 1. With empty prefix (immediately after trigger), all items are available
    editor_filter_completions(&e)
    testing.expect_value(t, e.completion.active, true)
    testing.expect_value(t, len(e.completion.items), len(candidates))

    // 2. Type prefix "st"
    pt_insert(&e.buffer.table, 4, "st")
    e.cursor.col = 6
    editor_filter_completions(&e)
    testing.expect_value(t, e.completion.active, true)
    // Matches "std", "stdin", "stdout", "string", "struct"
    testing.expect_value(t, len(e.completion.items), 5)

    // 3. Type prefix "std"
    pt_insert(&e.buffer.table, 6, "d")
    e.cursor.col = 7
    editor_filter_completions(&e)
    testing.expect_value(t, e.completion.active, true)
    // Matches "std", "stdin", "stdout"
    testing.expect_value(t, len(e.completion.items), 3)

    // 4. Case-insensitive test: type "al"
    pt_delete_range(&e.buffer.table, 4, 3)
    pt_insert(&e.buffer.table, 4, "al")
    e.cursor.col = 6
    editor_filter_completions(&e)
    testing.expect_value(t, e.completion.active, true)
    // Matches "Alignment", "Allocator"
    testing.expect_value(t, len(e.completion.items), 2)
    fmt.println("  ✓ [Editor] Case-insensitive prefix filtering & sorting verified")
}

@(test)
test_editor_space_insertion_no_double_jump :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "hello")
    defer editor_destroy(&e)

    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 5

    // In insert mode, KEY_DOWN with K_SPACE must NOT insert into the piece table.
    // It returns false so that SDL's TEXT_INPUT event performs the single insertion.
    handled := editor_handle_insert_key(&e, sdl.K_SPACE, {}, nil, nil)
    testing.expect_value(t, handled, false)
    testing.expect_value(t, pt_get_length(&e.buffer.table), 5)

    // Simulate SDL TEXT_INPUT event inserting a single space
    space_str: cstring = " "
    text_ev: sdl.Event
    text_ev.type = .TEXT_INPUT
    text_ev.text.text = space_str
    editor_handle_event(&e, &text_ev, nil, nil)

    // Total length must be 6 (exactly one space added, not two)
    testing.expect_value(t, pt_get_length(&e.buffer.table), 6)
    full := pt_full_text(&e.buffer.table)
    defer delete(full)
    testing.expect_value(t, full, "hello ")
    testing.expect_value(t, e.cursor.col, 6)

    fmt.println("  ✓ [Editor] Space key inserts exactly one space (no double jump)")
}

@(test)
test_command_prompt_completion :: proc(t: ^testing.T) {
    app: App
    app.cmd_prompt.buffer = make([dynamic]u8, context.allocator)
    app.cmd_prompt.matches = make([dynamic]string, context.allocator)
    defer {
        app_reset_command_completion(&app.cmd_prompt)
        delete(app.cmd_prompt.matches)
        delete(app.cmd_prompt.buffer)
    }

    // Test 1: Complete "w" -> matches "w", "wa", "wq", "wqa"
    clear(&app.cmd_prompt.buffer)
    append(&app.cmd_prompt.buffer, 'w')
    app_command_prompt_tab(&app, reverse = false)

    testing.expect_value(t, app.cmd_prompt.in_completion, true)
    testing.expect_value(t, len(app.cmd_prompt.matches), 4)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "w")

    // Tab cycles through the write commands and wraps back to "w"
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "wa")
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "wq")
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "wqa")
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "w")

    // Shift-Tab -> cycles backwards to "wqa"
    app_command_prompt_tab(&app, reverse = true)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "wqa")

    // Test 2: Reset completion
    app_reset_command_completion(&app.cmd_prompt)
    testing.expect_value(t, app.cmd_prompt.in_completion, false)
    testing.expect_value(t, len(app.cmd_prompt.matches), 0)

    // Test 3: Subcommand completion: ":theme nay" -> ":theme naysayer"
    clear(&app.cmd_prompt.buffer)
    for b in transmute([]u8)string("theme nay") {
        append(&app.cmd_prompt.buffer, b)
    }
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, app.cmd_prompt.in_completion, true)
    testing.expect_value(t, len(app.cmd_prompt.matches), 1)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "theme naysayer")

    // Test 4: Subcommand completion: ":sort r" -> matches "sort rev", "sort reverse"
    app_reset_command_completion(&app.cmd_prompt)
    clear(&app.cmd_prompt.buffer)
    for b in transmute([]u8)string("sort r") {
        append(&app.cmd_prompt.buffer, b)
    }
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, app.cmd_prompt.in_completion, true)
    testing.expect_value(t, len(app.cmd_prompt.matches), 2)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "sort rev")
    app_command_prompt_tab(&app, reverse = false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "sort reverse")

    fmt.println("  ✓ [CommandPrompt] Tab / Shift-Tab autocompletion & cycling verified")
}

simulate_typing :: proc(e: ^Editor, s: string) {
    ev: sdl.Event
    ev.type = .TEXT_INPUT
    ev.text.text = strings.clone_to_cstring(s, context.temp_allocator)
    editor_handle_event(e, &ev, nil, nil)
}

@(test)
test_editor_autopairs_brackets_and_quotes :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)

    // 1. Typing '(' autopairs to '()'
    simulate_typing(&e, "(")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 2)
    testing.expect_value(t, e.cursor.col, 1)

    // 2. Inside '()', typing '[' autopairs to '[]' -> '([])'
    simulate_typing(&e, "[")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 4)
    testing.expect_value(t, e.cursor.col, 2)

    // 3. Inside '([])', typing '{' autopairs to '{}' -> '([{}])'
    simulate_typing(&e, "{")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 6)
    testing.expect_value(t, e.cursor.col, 3)

    // 4. Inside '([{}])', typing '"' autopairs to '""' -> '([{" "}])'
    simulate_typing(&e, "\"")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 8)
    testing.expect_value(t, e.cursor.col, 4)

    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "([{\"\"}])")

    // 5. Test step-over (overtyping closing characters)
    // Step over '"'
    simulate_typing(&e, "\"")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 8)
    testing.expect_value(t, e.cursor.col, 5)

    // Step over '}'
    simulate_typing(&e, "}")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 8)
    testing.expect_value(t, e.cursor.col, 6)

    // Step over ']'
    simulate_typing(&e, "]")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 8)
    testing.expect_value(t, e.cursor.col, 7)

    // Step over ')'
    simulate_typing(&e, ")")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 8)
    testing.expect_value(t, e.cursor.col, 8)

    fmt.println("  ✓ [Editor] Autopairs '()', '[]', '{}', '\"\"' and closing step-over verified")
}

@(test)
test_editor_autopairs_smart_backspace :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)

    // Test parenthesis pair backspace
    simulate_typing(&e, "(")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 2)
    editor_handle_insert_key(&e, sdl.K_BACKSPACE, {}, nil, nil)
    testing.expect_value(t, pt_get_length(&e.buffer.table), 0)
    testing.expect_value(t, e.cursor.col, 0)

    // Test double-quote pair backspace
    simulate_typing(&e, "\"")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 2)
    editor_handle_insert_key(&e, sdl.K_BACKSPACE, {}, nil, nil)
    testing.expect_value(t, pt_get_length(&e.buffer.table), 0)
    testing.expect_value(t, e.cursor.col, 0)

    // Test single-quote pair backspace
    simulate_typing(&e, "'")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 2)
    editor_handle_insert_key(&e, sdl.K_BACKSPACE, {}, nil, nil)
    testing.expect_value(t, pt_get_length(&e.buffer.table), 0)
    testing.expect_value(t, e.cursor.col, 0)

    fmt.println("  ✓ [Editor] Smart backspace deletion of empty autopairs verified")
}

@(test)
test_editor_autopairs_no_pair_before_alnum_and_ident :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "word")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 0

    // Typing '(' before an alphanumeric character should NOT autopair
    simulate_typing(&e, "(")
    t1 := pt_full_text(&e.buffer.table)
    defer delete(t1)
    testing.expect_value(t, t1, "(word")

    // Typing '\'' after an identifier character should NOT autopair (e.g. don't)
    e2: Editor
    editor_init(&e2, nil, "don")
    defer editor_destroy(&e2)
    editor_set_mode(&e2, .Insert, nil)
    e2.cursor.col = 3

    simulate_typing(&e2, "'")
    t2 := pt_full_text(&e2.buffer.table)
    defer delete(t2)
    testing.expect_value(t, t2, "don'")

    fmt.println("  ✓ [Editor] Autopairs guard against unwanted pairs before alnum & inside words")
}

set_editor_text :: proc(e: ^Editor, text: string) {
    pt_delete_range(&e.buffer.table, 0, pt_get_length(&e.buffer.table))
    pt_insert(&e.buffer.table, 0, text)
    e.cursor.row = 0
    e.cursor.col = 0
    e.selection_anchor = e.cursor
    e.desired_col = 0
    e.buffer.dirty = false
}

send_key_event :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod = {}) {
    ev: sdl.Event
    ev.type = .KEY_DOWN
    ev.key.key = key
    ev.key.mod = mod
    editor_handle_event(e, &ev, nil, nil)
}

@(test)
test_editor_line_number_format :: proc(t: ^testing.T) {
    testing.expect_value(t, format_line_number(1, 1), "1 ")
    testing.expect_value(t, format_line_number(1, 3), "  1 ")
    testing.expect_value(t, format_line_number(9, 3), "  9 ")
    testing.expect_value(t, format_line_number(10, 3), " 10 ")
    testing.expect_value(t, format_line_number(100, 3), "100 ")
    fmt.println("  ✓ [Editor] gutter line numbers are space-padded, not zero-padded")
}

@(test)
test_editor_line_brace_delta :: proc(t: ^testing.T) {
    cases := []struct {
        line: string,
        want: int,
    }{
        {"", 0},
        {"{", 1},
        {"}", -1},
        {"{}", 0},
        {"if (x) {", 1},
        {"} else {", 0},
        {`s := "{{"`, 0},
        {"s := `}`", 0},
        {"// { not a brace", 0},
        {"{ // trailing }", 1},
    }
    for tc in cases {
        testing.expect_value(t, editor_line_brace_delta(tc.line), tc.want)
    }
    fmt.println("  ✓ [Editor] brace-depth counting ignores strings and comments")
}

@(test)
test_editor_line_indent :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "    foo\n\tbar\n\n   \n  x")
    defer editor_destroy(&e)

    indent, first, blank := editor_get_line_indent(&e, 0)
    testing.expect_value(t, indent, 4)
    testing.expect_value(t, first, 4)
    testing.expect_value(t, blank, false)

    indent, first, blank = editor_get_line_indent(&e, 1)
    testing.expect_value(t, indent, 4) // tab counts as 4
    testing.expect_value(t, first, 1)
    testing.expect_value(t, blank, false)

    indent, first, blank = editor_get_line_indent(&e, 2)
    testing.expect_value(t, indent, 0)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, blank, true)

    indent, first, blank = editor_get_line_indent(&e, 3)
    testing.expect_value(t, indent, 3)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, blank, true)

    indent, first, blank = editor_get_line_indent(&e, 4)
    testing.expect_value(t, indent, 2)
    testing.expect_value(t, first, 2)
    testing.expect_value(t, blank, false)

    indent, first, blank = editor_get_line_indent(&e, 99)
    testing.expect_value(t, indent, 0)
    testing.expect_value(t, first, 0)
    testing.expect_value(t, blank, true)
    fmt.println("  ✓ [Editor] line indentation (spaces/tabs/blank) verified")
}

@(test)
test_editor_line_len_and_virtual_space :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "ab\ncd")
    defer editor_destroy(&e)

    testing.expect_value(t, editor_get_line_len(&e, 0), 2)
    testing.expect_value(t, editor_get_line_len(&e, 1), 2)
    testing.expect_value(t, editor_get_line_len(&e, 2), 0)
    testing.expect_value(t, editor_get_line_len(&e, -1), 0)

    // Cursor columns past EOL clamp when converting to a byte offset
    e.cursor.row = 0
    e.cursor.col = 10
    testing.expect_value(t, editor_get_cursor_offset(&e), 2)

    // ...and become real spaces when an edit needs an offset
    editor_realize_virtual_spaces(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "ab        \ncd")
    testing.expect_value(t, editor_get_cursor_offset(&e), 10)
    testing.expect_value(t, e.buffer.dirty, true)
    fmt.println("  ✓ [Editor] virtual spaces are realized on demand")
}

@(test)
test_editor_visual_columns_with_tabs :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "\tab\nx\ty")
    defer editor_destroy(&e)

    testing.expect_value(t, editor_visual_col(&e, 0, 0), 0)
    testing.expect_value(t, editor_visual_col(&e, 0, 1), TAB_WIDTH)
    testing.expect_value(t, editor_visual_col(&e, 0, 2), TAB_WIDTH + 1)
    testing.expect_value(t, editor_visual_col(&e, 0, 3), TAB_WIDTH + 2)

    // A position inside the expanded tab snaps back to the tab's byte.
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 1), 0)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 3), 0)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 4), 1)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 5), 2)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 6), 3)
    // Past EOL the column is virtual.
    testing.expect_value(t, editor_visual_col(&e, 0, 9), 12)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 9), 6)

    // desired_col is measured in visual cells, so vertical motion preserves the
    // screen column across lines where tabs expand differently.
    e.cursor.row = 0
    e.cursor.col = 2
    e.desired_col = editor_visual_col(&e, 0, e.cursor.col) // visual 5
    editor_handle_normal_key(&e, KEY_MOVE_DOWN, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, editor_visual_col(&e, 1, e.cursor.col), 5)
    testing.expect_value(t, e.cursor.col, 2)
    editor_handle_normal_key(&e, KEY_MOVE_UP, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 2)
    fmt.println("  ✓ [Editor] byte<->visual columns map tabs and preserve desired column")
}

@(test)
test_editor_line_len_crlf :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc\r\ndef\r\n")
    defer editor_destroy(&e)

    testing.expect_value(t, editor_get_line_len(&e, 0), 3)
    testing.expect_value(t, editor_get_line_len(&e, 1), 3)
    testing.expect_value(t, editor_get_line_len(&e, 2), 0)
    fmt.println("  ✓ [Editor] CRLF is excluded from line lengths")
}

@(test)
test_editor_selection_range :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc\ndef")
    defer editor_destroy(&e)

    e.selection_anchor = Cursor{row = 0, col = 2}
    e.cursor = Cursor{row = 1, col = 1}
    start, end := editor_get_selection_range(&e)
    testing.expect_value(t, start.row, 0)
    testing.expect_value(t, start.col, 2)
    testing.expect_value(t, end.row, 1)
    testing.expect_value(t, end.col, 1)

    // Reversed selection normalizes to anchor-first
    e.selection_anchor = Cursor{row = 1, col = 1}
    e.cursor = Cursor{row = 0, col = 2}
    start, end = editor_get_selection_range(&e)
    testing.expect_value(t, start.row, 0)
    testing.expect_value(t, start.col, 2)
    testing.expect_value(t, end.row, 1)
    testing.expect_value(t, end.col, 1)
    fmt.println("  ✓ [Editor] selection range normalizes backwards selections")
}

@(test)
test_editor_delete_selection :: proc(t: ^testing.T) {
    // Partial single-line selection is inclusive of the cursor character
    e: Editor
    editor_init(&e, nil, "hello world")
    defer editor_destroy(&e)
    e.mode = .Visual
    e.selection_anchor = Cursor{row = 0, col = 0}
    e.cursor = Cursor{row = 0, col = 4}
    editor_delete_selection(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, " world")
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, e.buffer.dirty, true)

    // Whole-line selection removes the trailing newline as well
    e2: Editor
    editor_init(&e2, nil, "aaa\nbbb\nccc")
    defer editor_destroy(&e2)
    e2.mode = .Visual
    e2.selection_anchor = Cursor{row = 0, col = 0}
    e2.cursor = Cursor{row = 1, col = 3}
    editor_delete_selection(&e2)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "ccc")
    testing.expect_value(t, e2.cursor.row, 0)
    fmt.println("  ✓ [Editor] visual selection deletion (partial & whole lines)")
}

@(test)
test_editor_visual_line_select_and_delete :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "aaa\nbbb\nccc")
    defer editor_destroy(&e)

    e.cursor.row = 1
    e.cursor.col = 1
    testing.expect_value(t, editor_handle_normal_key(&e, KEY_SELECT_LINE, {}, nil, nil), true)
    testing.expect_value(t, e.mode, EditorMode.Visual)
    testing.expect_value(t, e.selection_anchor.row, 1)
    testing.expect_value(t, e.selection_anchor.col, 0)
    testing.expect_value(t, e.cursor.col, 3)

    testing.expect_value(t, editor_handle_normal_key(&e, KEY_DELETE_SELECTION, {}, nil, nil), true)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "aaa\nccc")
    testing.expect_value(t, e.mode, EditorMode.Normal)

    // X extends line selection and D removes the final line
    e.cursor.row = 1
    e.cursor.col = 0
    editor_handle_normal_key(&e, KEY_SELECT_LINE, {}, nil, nil)
    editor_handle_normal_key(&e, KEY_DELETE_SELECTION, {}, nil, nil)
    text2 := pt_full_text(&e.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "aaa")
    fmt.println("  ✓ [Editor] X line-selection + D deletion verified")
}

@(test)
test_editor_delete_char_forward :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "ab\ncd")
    defer editor_destroy(&e)

    // Mid-line d deletes the character under the cursor
    testing.expect_value(t, editor_handle_normal_key(&e, KEY_DELETE_CHAR, {}, nil, nil), true)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "b\ncd")

    // At EOL d joins the next line
    e.cursor.col = 1
    editor_handle_normal_key(&e, KEY_DELETE_CHAR, {}, nil, nil)
    text2 := pt_full_text(&e.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "bcd")
    fmt.println("  ✓ [Editor] d deletes a char and joins at EOL")
}

@(test)
test_editor_move_lines :: proc(t: ^testing.T) {
    // Move current line down
    e: Editor
    editor_init(&e, nil, "aaa\nbbb\nccc")
    defer editor_destroy(&e)
    editor_move_lines(&e, 1)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "bbb\naaa\nccc\n")
    testing.expect_value(t, e.cursor.row, 1)

    // Move current line up (on a fresh editor)
    e2: Editor
    editor_init(&e2, nil, "aaa\nbbb\nccc")
    defer editor_destroy(&e2)
    e2.cursor.row = 1
    editor_move_lines(&e2, -1)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "bbb\naaa\nccc\n")
    testing.expect_value(t, e2.cursor.row, 0)

    // Boundary moves are no-ops and do not append a trailing newline
    e3: Editor
    editor_init(&e3, nil, "aaa\nbbb")
    defer editor_destroy(&e3)
    editor_move_lines(&e3, -1)
    text3 := pt_full_text(&e3.buffer.table)
    defer delete(text3)
    testing.expect_value(t, text3, "aaa\nbbb")
    e3.cursor.row = 1
    editor_move_lines(&e3, 1)
    text4 := pt_full_text(&e3.buffer.table)
    defer delete(text4)
    testing.expect_value(t, text4, "aaa\nbbb")

    // Moving a visual block down keeps block order
    e4: Editor
    editor_init(&e4, nil, "a\nb\nc")
    defer editor_destroy(&e4)
    e4.mode = .Visual
    e4.selection_anchor = Cursor{row = 0, col = 0}
    e4.cursor = Cursor{row = 1, col = 0}
    editor_move_lines(&e4, 1)
    text5 := pt_full_text(&e4.buffer.table)
    defer delete(text5)
    testing.expect_value(t, text5, "c\na\nb\n")
    testing.expect_value(t, e4.cursor.row, 2)
    testing.expect_value(t, e4.selection_anchor.row, 1)

    // Moving a visual block up
    e5: Editor
    editor_init(&e5, nil, "a\nb\nc")
    defer editor_destroy(&e5)
    e5.mode = .Visual
    e5.selection_anchor = Cursor{row = 1, col = 0}
    e5.cursor = Cursor{row = 2, col = 0}
    editor_move_lines(&e5, -1)
    text6 := pt_full_text(&e5.buffer.table)
    defer delete(text6)
    testing.expect_value(t, text6, "b\nc\na\n")
    testing.expect_value(t, e5.cursor.row, 1)
    testing.expect_value(t, e5.selection_anchor.row, 0)
    fmt.println("  ✓ [Editor] Alt+j / Alt+k line and block moves verified")
}

@(test)
test_editor_delete_current_line_variants :: proc(t: ^testing.T) {
    cases := []struct {
        input: string,
        row: int,
        want: string,
    }{
        {"a\nb\nc", 0, "b\nc"},
        {"a\nb\nc", 2, "a\nb"},
        {"abc", 0, ""},
        {"", 0, ""},
    }
    for tc in cases {
        e: Editor
        editor_init(&e, nil, tc.input)
        defer editor_destroy(&e)
        e.cursor.row = tc.row
        editor_delete_current_line(&e)
        text := pt_full_text(&e.buffer.table)
        testing.expect_value(t, text, tc.want)
        delete(text)
    }
    fmt.println("  ✓ [Editor] dd on first/last/only/empty buffer verified")
}

@(test)
test_editor_normal_navigation :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "longline\nab\nlongline2")
    defer editor_destroy(&e)

    // desired_col survives travel over a shorter line
    e.cursor.col = 6
    e.desired_col = 6
    editor_handle_normal_key(&e, KEY_MOVE_DOWN, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 6)
    editor_handle_normal_key(&e, KEY_MOVE_DOWN, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 2)
    testing.expect_value(t, e.cursor.col, 6)
    editor_handle_normal_key(&e, KEY_MOVE_UP, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 6)
    editor_handle_normal_key(&e, KEY_MOVE_UP, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 0)

    // gg / G
    editor_handle_normal_key(&e, KEY_GOTO, {}, nil, nil)
    testing.expect_value(t, e.pending_cmd, 'g')
    editor_handle_normal_key(&e, KEY_GOTO, {}, nil, nil)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 0)
    editor_handle_normal_key(&e, KEY_FILE_END, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.cursor.row, 2)
    testing.expect_value(t, e.cursor.col, 0)

    // 0 / $ / H / L
    editor_handle_normal_key(&e, KEY_LINE_END_DOLLAR, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.cursor.col, 9)
    editor_handle_normal_key(&e, KEY_LINE_START_ZERO, {}, nil, nil)
    testing.expect_value(t, e.cursor.col, 0)
    editor_handle_normal_key(&e, KEY_LINE_START, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.cursor.col, 0)
    editor_handle_normal_key(&e, KEY_LINE_END, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.cursor.col, 9)
    editor_handle_normal_key(&e, KEY_MOVE_LEFT, {}, nil, nil)
    testing.expect_value(t, e.cursor.col, 8)
    editor_handle_normal_key(&e, KEY_MOVE_RIGHT, {}, nil, nil)
    testing.expect_value(t, e.cursor.col, 9)
    fmt.println("  ✓ [Editor] h/j/k/l, gg, G, 0, $, H, L navigation verified")
}

@(test)
test_editor_mode_entry_keys :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc")
    defer editor_destroy(&e)
    e.cursor.col = 1

    editor_handle_normal_key(&e, KEY_INSERT_BEFORE, {}, nil, nil)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.col, 1)

    editor_set_mode(&e, .Normal, nil)
    e.cursor.col = 1
    editor_handle_normal_key(&e, KEY_INSERT_LINE_START, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.col, 0)

    editor_set_mode(&e, .Normal, nil)
    e.cursor.col = 1
    editor_handle_normal_key(&e, KEY_APPEND, {}, nil, nil)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.col, 2)

    editor_set_mode(&e, .Normal, nil)
    e.cursor.col = 1
    editor_handle_normal_key(&e, KEY_APPEND_LINE_END, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.col, 3)
    fmt.println("  ✓ [Editor] i/a/I/A mode entry and cursor placement verified")
}

@(test)
test_editor_open_line_keys :: proc(t: ^testing.T) {
    // o opens a line below and enters insert mode
    e: Editor
    editor_init(&e, nil, "abc")
    defer editor_destroy(&e)
    e.cursor.col = 1
    editor_handle_normal_key(&e, KEY_OPEN_BELOW, {}, nil, nil)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "abc\n")
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, e.mode, EditorMode.Insert)

    // O opens a line above
    e2: Editor
    editor_init(&e2, nil, "abc")
    defer editor_destroy(&e2)
    e2.cursor.col = 1
    editor_handle_normal_key(&e2, KEY_OPEN_ABOVE, sdl.KMOD_SHIFT, nil, nil)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "\nabc")
    testing.expect_value(t, e2.cursor.row, 0)
    testing.expect_value(t, e2.cursor.col, 0)
    testing.expect_value(t, e2.mode, EditorMode.Insert)
    fmt.println("  ✓ [Editor] o / O line insertion verified")
}

@(test)
test_editor_insert_backspace_join :: proc(t: ^testing.T) {
    // LF join
    e: Editor
    editor_init(&e, nil, "ab\ncd")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.row = 1
    e.cursor.col = 0
    editor_handle_insert_key(&e, sdl.K_BACKSPACE, {}, nil, nil)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "abcd")
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 2)

    // CRLF join removes both bytes
    e2: Editor
    editor_init(&e2, nil, "ab\r\ncd")
    defer editor_destroy(&e2)
    editor_set_mode(&e2, .Insert, nil)
    e2.cursor.row = 1
    e2.cursor.col = 0
    editor_handle_insert_key(&e2, sdl.K_BACKSPACE, {}, nil, nil)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "abcd")
    testing.expect_value(t, e2.cursor.row, 0)
    testing.expect_value(t, e2.cursor.col, 2)

    // Mid-line backspace deletes one byte
    e3: Editor
    editor_init(&e3, nil, "abc")
    defer editor_destroy(&e3)
    editor_set_mode(&e3, .Insert, nil)
    e3.cursor.col = 2
    editor_handle_insert_key(&e3, sdl.K_BACKSPACE, {}, nil, nil)
    text3 := pt_full_text(&e3.buffer.table)
    defer delete(text3)
    testing.expect_value(t, text3, "ac")
    testing.expect_value(t, e3.cursor.col, 1)
    fmt.println("  ✓ [Editor] insert-mode Backspace joins lines (LF/CRLF)")
}

@(test)
test_editor_insert_delete_key :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 1
    editor_handle_insert_key(&e, sdl.K_DELETE, {}, nil, nil)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "ac")
    testing.expect_value(t, e.cursor.col, 1)

    // Delete at EOL joins the next line
    e2: Editor
    editor_init(&e2, nil, "ab\ncd")
    defer editor_destroy(&e2)
    editor_set_mode(&e2, .Insert, nil)
    e2.cursor.col = 2
    editor_handle_insert_key(&e2, sdl.K_DELETE, {}, nil, nil)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "abcd")

    // Delete at CRLF removes both bytes
    e3: Editor
    editor_init(&e3, nil, "ab\r\ncd")
    defer editor_destroy(&e3)
    editor_set_mode(&e3, .Insert, nil)
    e3.cursor.col = 2
    editor_handle_insert_key(&e3, sdl.K_DELETE, {}, nil, nil)
    text3 := pt_full_text(&e3.buffer.table)
    defer delete(text3)
    testing.expect_value(t, text3, "abcd")
    fmt.println("  ✓ [Editor] insert-mode Delete (incl. CRLF) verified")
}

@(test)
test_editor_insert_tab_and_enter_indent :: proc(t: ^testing.T) {
    // Tab inserts four spaces and realizes pending virtual spaces first
    e: Editor
    editor_init(&e, nil, "a")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 3
    editor_handle_insert_key(&e, sdl.K_TAB, {}, nil, nil)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "a      ")
    testing.expect_value(t, e.cursor.col, 7)

    // Enter preserves the current leading indentation
    e2: Editor
    editor_init(&e2, nil, "  foo")
    defer editor_destroy(&e2)
    editor_set_mode(&e2, .Insert, nil)
    e2.cursor.col = 5
    editor_handle_insert_key(&e2, sdl.K_RETURN, {}, nil, nil)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "  foo\n  ")
    testing.expect_value(t, e2.cursor.row, 1)
    testing.expect_value(t, e2.cursor.col, 2)

    // Enter between () and [] expands like {} does
    pairs := []struct {
        input, want: string,
    }{
        {"()", "(\n    \n)"},
        {"[]", "[\n    \n]"},
    }
    for pair in pairs {
        ep: Editor
        editor_init(&ep, nil, pair.input)
        defer editor_destroy(&ep)
        editor_set_mode(&ep, .Insert, nil)
        ep.cursor.col = 1
        editor_handle_insert_key(&ep, sdl.K_RETURN, {}, nil, nil)
        got := pt_full_text(&ep.buffer.table)
        testing.expect_value(t, got, pair.want)
        delete(got)
    }

    // Indentation is carried into the expanded pair
    e3: Editor
    editor_init(&e3, nil, "  {}")
    defer editor_destroy(&e3)
    editor_set_mode(&e3, .Insert, nil)
    e3.cursor.col = 3
    editor_handle_insert_key(&e3, sdl.K_RETURN, {}, nil, nil)
    text3 := pt_full_text(&e3.buffer.table)
    defer delete(text3)
    testing.expect_value(t, text3, "  {\n      \n  }")
    testing.expect_value(t, e3.cursor.col, 6)
    fmt.println("  ✓ [Editor] Tab indentation and Enter auto-indent verified")
}

@(test)
test_editor_escape_leaves_insert_with_completion :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)

    append(&e.completion.all_items, LspCompletionItem{label = strings.clone("abc")})
    e.completion.active = true

    testing.expect_value(t, editor_handle_insert_key(&e, sdl.K_ESCAPE, {}, nil, nil), true)
    testing.expect_value(t, e.completion.active, false)
    testing.expect_value(t, e.mode, EditorMode.Normal) // one Esc leaves Insert

    fmt.println("  ✓ [Editor] Esc leaves Insert and dismisses completion in one press")
}

@(test)
test_editor_undo_redo_keys :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)

    simulate_typing(&e, "hello")
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "hello")

    editor_set_mode(&e, .Normal, nil)
    send_key_event(&e, KEY_UNDO)
    undone := pt_full_text(&e.buffer.table)
    defer delete(undone)
    testing.expect_value(t, undone, "")

    send_key_event(&e, KEY_REDO, sdl.KMOD_CTRL)
    redone := pt_full_text(&e.buffer.table)
    defer delete(redone)
    testing.expect_value(t, redone, "hello")

    send_key_event(&e, KEY_UNDO_ALT, sdl.KMOD_CTRL)
    undone2 := pt_full_text(&e.buffer.table)
    defer delete(undone2)
    testing.expect_value(t, undone2, "")
    fmt.println("  ✓ [Editor] u, Ctrl+Z and Ctrl+R undo/redo verified")
}

@(test)
test_editor_completion_substring_and_apply :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "sta")
    defer editor_destroy(&e)

    labels := []string{"static", "stack", "constant"}
    for lbl in labels {
        append(&e.completion.all_items, LspCompletionItem{
            label         = strings.clone(lbl),
            detail        = strings.clone("detail"),
            documentation = strings.clone("doc"),
            insert_text   = strings.clone(lbl),
        })
    }

    e.cursor.row = 0
    e.cursor.col = 3
    e.completion.trigger_row = 0
    e.completion.trigger_col = 0

    editor_filter_completions(&e)
    testing.expect_value(t, e.completion.active, true)
    // "static" and "stack" match by prefix; "constant" matches by substring
    testing.expect_value(t, len(e.completion.items), 3)
    testing.expect_value(t, e.completion.items[0].label, "static")
    testing.expect_value(t, e.completion.items[2].label, "constant")

    // Apply replaces the typed prefix with insert_text
    e.completion.selected = 0
    editor_apply_completion(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "static")
    testing.expect_value(t, e.cursor.col, 6)
    testing.expect_value(t, e.completion.active, false)
    testing.expect_value(t, len(e.completion.items), 0)
    testing.expect_value(t, len(e.completion.all_items), 0)

    // No matches deactivates the popup
    e2: Editor
    editor_init(&e2, nil, "zzz")
    defer editor_destroy(&e2)
    append(&e2.completion.all_items, LspCompletionItem{label = strings.clone("alpha")})
    e2.cursor.col = 3
    e2.completion.trigger_row = 0
    e2.completion.trigger_col = 0
    editor_filter_completions(&e2)
    testing.expect_value(t, e2.completion.active, false)
    fmt.println("  ✓ [Editor] completion prefix filtering + apply verified")
}

@(test)
test_editor_apply_completion_fallback_insert_text :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "fo")
    defer editor_destroy(&e)
    e.cursor.col = 2
    e.completion.trigger_row = 0
    e.completion.trigger_col = 0
    append(&e.completion.all_items, LspCompletionItem{
        label         = strings.clone("foo()"),
        detail        = strings.clone(""),
        documentation = strings.clone(""),
        insert_text   = strings.clone(""),
    })
    editor_filter_completions(&e)
    testing.expect_value(t, len(e.completion.items), 1)
    // "fo" is a prefix of "foo()", so the item survives; empty insertText falls back to label
    e.completion.active = true
    editor_apply_completion(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "foo()")
    fmt.println("  ✓ [Editor] completion falls back to label when insertText is empty")
}

@(test)
test_editor_apply_lsp_edits :: proc(t: ^testing.T) {
    // Multiple non-overlapping edits are applied bottom-up
    e: Editor
    editor_init(&e, nil, "aaa\nbbb\nccc")
    defer editor_destroy(&e)
    edits := []LspTextEdit{
        {start_row = 0, start_col = 0, end_row = 0, end_col = 3, new_text = "AAA"},
        {start_row = 2, start_col = 0, end_row = 2, end_col = 3, new_text = "CCC"},
    }
    editor_apply_lsp_edits(&e, edits)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "AAA\nbbb\nCCC")
    testing.expect_value(t, e.buffer.dirty, true)
    testing.expect_value(t, e.buffer.needs_lsp_sync, true)

    // Insertion, deletion and multi-line replacement
    e2: Editor
    editor_init(&e2, nil, "a\nb\nc")
    defer editor_destroy(&e2)
    edits2 := []LspTextEdit{
        {start_row = 0, start_col = 0, end_row = 1, end_col = 1, new_text = "X"},
    }
    editor_apply_lsp_edits(&e2, edits2)
    text2 := pt_full_text(&e2.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "X\nc")

    e3: Editor
    editor_init(&e3, nil, "abcdef")
    defer editor_destroy(&e3)
    edits3 := []LspTextEdit{
        {start_row = 0, start_col = 1, end_row = 0, end_col = 4, new_text = ""},
    }
    editor_apply_lsp_edits(&e3, edits3)
    text3 := pt_full_text(&e3.buffer.table)
    defer delete(text3)
    testing.expect_value(t, text3, "aef")

    e4: Editor
    editor_init(&e4, nil, "ab")
    defer editor_destroy(&e4)
    edits4 := []LspTextEdit{
        {start_row = 0, start_col = 1, end_row = 0, end_col = 1, new_text = "\n"},
    }
    editor_apply_lsp_edits(&e4, edits4)
    text4 := pt_full_text(&e4.buffer.table)
    defer delete(text4)
    testing.expect_value(t, text4, "a\nb")

    // Out-of-range rows clamp instead of panicking; cursor is re-clamped
    e5: Editor
    editor_init(&e5, nil, "abc")
    defer editor_destroy(&e5)
    e5.cursor.row = 99
    e5.cursor.col = 99
    edits5 := []LspTextEdit{
        {start_row = 99, start_col = 0, end_row = 99, end_col = 0, new_text = "!"},
    }
    editor_apply_lsp_edits(&e5, edits5)
    text5 := pt_full_text(&e5.buffer.table)
    defer delete(text5)
    testing.expect_value(t, text5, "abc!")
    testing.expect_value(t, e5.cursor.row <= 0, true)
    fmt.println("  ✓ [Editor] LSP text edits applied bottom-up and clamped")
}

@(test)
test_editor_undo_grouping_typing_burst :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)

    // One TEXT_INPUT per character; the editor should group the burst.
    simulate_typing(&e, "h")
    simulate_typing(&e, "e")
    simulate_typing(&e, "l")
    simulate_typing(&e, "l")
    simulate_typing(&e, "o")
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "hello")

    editor_set_mode(&e, .Normal, nil)
    send_key_event(&e, KEY_UNDO)
    undone := pt_full_text(&e.buffer.table)
    defer delete(undone)
    testing.expect_value(t, undone, "")
    send_key_event(&e, KEY_LINE_START_ZERO)

    // A motion starts a new group: only the second burst is undone.
    editor_set_mode(&e, .Insert, nil)
    simulate_typing(&e, "ab")
    editor_set_mode(&e, .Normal, nil)
    send_key_event(&e, KEY_MOVE_LEFT)
    editor_set_mode(&e, .Insert, nil)
    simulate_typing(&e, "cd")
    editor_set_mode(&e, .Normal, nil)

    send_key_event(&e, KEY_UNDO)
    after_undo := pt_full_text(&e.buffer.table)
    defer delete(after_undo)
    testing.expect_value(t, after_undo, "ab")
    fmt.println("  ✓ [Editor] typing bursts group; motions break the group")
}

@(test)
test_editor_status_message_truncation :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)

    long_msg := strings.repeat("x", 300, context.temp_allocator)
    editor_set_status_message(&e, long_msg)
    testing.expect_value(t, len(e.status_message), 256)
    testing.expect_value(t, e.status_message, strings.repeat("x", 256, context.temp_allocator))
    fmt.println("  ✓ [Editor] status message is truncated at buffer size")
}

@(test)
test_editor_save_file :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/editor_save"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    path := "/tmp/odin_editor_tests/editor_save/out.txt"
    e: Editor
    editor_init(&e, nil, "hello\nworld", path)
    defer editor_destroy(&e)

    e.buffer.dirty = true
    testing.expect_value(t, editor_save_file(&e, nil), true)
    testing.expect_value(t, e.buffer.dirty, false)

    data, err := os.read_entire_file(path, context.temp_allocator)
    testing.expect(t, err == nil)
    testing.expect_value(t, string(data), "hello\nworld")

    // Saving without a file name fails cleanly
    e2: Editor
    editor_init(&e2, nil, "x", "")
    defer editor_destroy(&e2)
    testing.expect_value(t, editor_save_file(&e2, nil), false)
    fmt.println("  ✓ [Editor] save writes exact buffer bytes; unnamed buffer fails")
}

@(test)
test_editor_enter_between_braces :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "fn main() {}")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)

    // Position cursor between '{' and '}'
    e.cursor.col = 11

    // Press Enter
    editor_handle_insert_key(&e, sdl.K_RETURN, {}, nil, nil)

    t1 := pt_full_text(&e.buffer.table)
    defer delete(t1)
    testing.expect_value(t, t1, "fn main() {\n    \n}")
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)

    fmt.println("  ✓ [Editor] Enter between '{}' expands with indentation verified")
}



@(test)
test_editor_insert_text_at_cursor_multiline :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc\ndef")
    defer editor_destroy(&e)

    // Multi-line clip: the cursor ends after the last inserted character.
    e.cursor.row = 0
    e.cursor.col = 1
    editor_insert_text_at_cursor(&e, "X\nY\nZ")
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "aX\nY\nZbc\ndef")
    testing.expect_value(t, e.cursor.row, 2)
    testing.expect_value(t, e.cursor.col, 1)
    testing.expect_value(t, e.desired_col, 1)

    // A trailing newline leaves the cursor at the start of the next line.
    e.cursor.row = 2
    e.cursor.col = 1
    editor_insert_text_at_cursor(&e, "Q\n")
    text2 := pt_full_text(&e.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "aX\nY\nZQ\nbc\ndef")
    testing.expect_value(t, e.cursor.row, 3)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, e.desired_col, 0)

    // A single-line clip only advances the column.
    e.cursor.row = 0
    e.cursor.col = 0
    editor_insert_text_at_cursor(&e, "hi")
    text3 := pt_full_text(&e.buffer.table)
    defer delete(text3)
    testing.expect_value(t, text3, "hiaX\nY\nZQ\nbc\ndef")
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 2)
    testing.expect_value(t, e.desired_col, 2)

    // Empty text is a no-op.
    editor_insert_text_at_cursor(&e, "")
    testing.expect_value(t, e.cursor.col, 2)
    fmt.println("  ✓ [Editor] pasted text advances rows and leaves the cursor at its end")
}

@(test)
test_editor_read_only_save_rejected :: proc(t: ^testing.T) {
    path := "/tmp/odin_editor_tests/read_only_save.txt"
    _ = os.remove(path)

    e: Editor
    editor_init(&e, nil, "do not write", path)
    defer editor_destroy(&e)
    e.read_only = true

    testing.expect_value(t, editor_save_file(&e, nil), false)
    testing.expect_value(t, os.exists(path), false)
    testing.expect_value(t, e.status_message, "Buffer is read-only")
    fmt.println("  ✓ [Editor] read-only buffers cannot be written")
}

@(test)
test_editor_mutations_schedule_lsp_sync :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abc\ndef")
    defer editor_destroy(&e)
    e.buffer.dirty = false
    e.buffer.needs_lsp_sync = false

    // Paste/text insertion
    editor_insert_text_at_cursor(&e, "X")
    testing.expect_value(t, e.buffer.dirty, true)
    testing.expect_value(t, e.buffer.needs_lsp_sync, true)

    // Undo
    e.buffer.dirty = false
    e.buffer.needs_lsp_sync = false
    send_key_event(&e, KEY_UNDO)
    testing.expect_value(t, e.buffer.dirty, true)
    testing.expect_value(t, e.buffer.needs_lsp_sync, true)

    // Line moves
    e.buffer.dirty = false
    e.buffer.needs_lsp_sync = false
    editor_move_lines(&e, 1)
    testing.expect_value(t, e.buffer.dirty, true)
    testing.expect_value(t, e.buffer.needs_lsp_sync, true)
    fmt.println("  ✓ [Editor] paste/undo/line-move schedule LSP sync")
}

@(test)
test_editor_autopair_step_over_stays_clean :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "()")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 1
    e.buffer.dirty = false
    e.buffer.needs_lsp_sync = false

    simulate_typing(&e, ")")
    testing.expect_value(t, e.cursor.col, 2)
    testing.expect_value(t, e.buffer.dirty, false)
    testing.expect_value(t, e.buffer.needs_lsp_sync, false)
    fmt.println("  ✓ [Editor] auto-pair step-over does not dirty the buffer")
}

@(test)
test_editor_dollar_vertical_and_append_eol :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "abcdef\nabc")
    defer editor_destroy(&e)

    // `$` keeps a sticky EOL column; j lands at the shorter line's EOL.
    e.cursor.row = 0
    e.cursor.col = 6
    e.desired_col = 6
    send_key_event(&e, KEY_LINE_END_DOLLAR, sdl.KMOD_SHIFT)
    testing.expect_value(t, e.desired_col, DESIRED_EOL)
    send_key_event(&e, KEY_MOVE_DOWN)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 3)

    // `a` at EOL (as left by Esc) must not step into a virtual column.
    set_editor_text(&e, "abc")
    e.cursor.row = 0
    e.cursor.col = 3
    e.desired_col = 3
    send_key_event(&e, KEY_APPEND)
    simulate_typing(&e, "d")
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "abcd")
    fmt.println("  ✓ [Editor] sticky $ and append-at-EOL stay within the line")
}

@(test)
test_editor_undo_resnaps_cursor :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "")
    defer editor_destroy(&e)

    editor_set_mode(&e, .Insert, nil)
    simulate_typing(&e, "hello")
    editor_set_mode(&e, .Normal, nil)
    send_key_event(&e, KEY_UNDO)

    testing.expect_value(t, pt_get_length(&e.buffer.table), 0)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, e.desired_col, 0)

    editor_set_mode(&e, .Insert, nil)
    simulate_typing(&e, "x")
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "x")
    fmt.println("  ✓ [Editor] undo re-snaps the cursor instead of materializing spaces")
}

@(test)
test_editor_completion_is_single_undo_step :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "sta")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 3
    e.desired_col = 3
    e.completion.active = true
    e.completion.trigger_row = 0
    e.completion.trigger_col = 0
    append(&e.completion.items, LspCompletionItem{
        label = strings.clone("static"),
        insert_text = strings.clone("static"),
    })

    editor_apply_completion(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "static")

    // Prefix replacement is one pt_replace edit, so one undo restores "sta".
    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    text2 := pt_full_text(&e.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "sta")
    fmt.println("  ✓ [Editor] completion replacement is a single undo step")
}

@(test)
test_editor_completion_multiline_cursor :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "pri")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 3
    e.desired_col = 3
    e.completion.active = true
    e.completion.trigger_row = 0
    e.completion.trigger_col = 0
    append(&e.completion.items, LspCompletionItem{
        label = strings.clone("snippet"),
        insert_text = strings.clone("static\nfn"),
    })

    editor_apply_completion(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "static\nfn")
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 2)
    testing.expect_value(t, e.desired_col, 2)
    fmt.println("  ✓ [Editor] multi-line completion advances rows")
}

@(test)
test_editor_completion_ignores_stale_trigger_row :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "pri\nxyz")
    defer editor_destroy(&e)
    editor_set_mode(&e, .Insert, nil)
    e.cursor.row = 1
    e.cursor.col = 3
    e.desired_col = 3
    e.completion.active = true
    e.completion.trigger_row = 0
    e.completion.trigger_col = 0
    append(&e.completion.items, LspCompletionItem{
        label = strings.clone("Q"),
        insert_text = strings.clone("Q"),
    })

    editor_apply_completion(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "pri\nxyzQ")
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)
    fmt.println("  ✓ [Editor] completion does not delete across a moved trigger row")
}

@(test)
test_editor_read_only_blocks_line_moves :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "aa\nbb")
    defer editor_destroy(&e)
    e.read_only = true
    e.cursor.row = 0

    send_key_event(&e, KEY_MOVE_LINE_DOWN, sdl.KMOD_ALT)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "aa\nbb")
    testing.expect_value(t, e.status_message, "Buffer is read-only")
    fmt.println("  ✓ [Editor] Alt+J cannot mutate a read-only buffer")
}

@(test)
test_editor_crlf_join_and_line_delete :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "ab\r\ncd")
    defer editor_destroy(&e)

    // d at EOL joins the next line, removing both CR and LF.
    e.cursor.row = 0
    e.cursor.col = editor_get_line_len(&e, 0)
    send_key_event(&e, KEY_DELETE_CHAR)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "abcd")

    // Deleting the final line of a CRLF file also removes the preceding CRLF.
    set_editor_text(&e, "aaa\r\nbbb")
    e.cursor.row = 1
    e.cursor.col = 0
    send_key_event(&e, KEY_SELECT_LINE)
    send_key_event(&e, KEY_DELETE_SELECTION)
    text2 := pt_full_text(&e.buffer.table)
    defer delete(text2)
    testing.expect_value(t, text2, "aaa")
    fmt.println("  ✓ [Editor] CRLF join and final-line deletion handle both bytes")
}

@(test)
test_editor_visual_delete_clamps_virtual_start :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "ab\ncdefgh")
    defer editor_destroy(&e)

    e.mode = .Visual
    e.selection_anchor = Cursor{row = 0, col = 5}
    e.cursor = Cursor{row = 1, col = 5}
    e.desired_col = 5

    editor_delete_selection(&e)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "ab")
    fmt.println("  ✓ [Editor] visual delete clamps a virtual start column to its line")
}

@(test)
test_editor_unicode_columns_and_motions :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "héllo 日本 é")
    defer editor_destroy(&e)

    // Byte columns: é starts at 1 (2 bytes), 日 at 7, 本 at 10, e at 14.
    testing.expect_value(t, editor_visual_col(&e, 0, 0), 0)
    testing.expect_value(t, editor_visual_col(&e, 0, 1), 1)
    testing.expect_value(t, editor_visual_col(&e, 0, 3), 2) // é is one cell
    testing.expect_value(t, editor_visual_col(&e, 0, 6), 5) // "héllo"
    testing.expect_value(t, editor_visual_col(&e, 0, 7), 6) // first CJK rune
    testing.expect_value(t, editor_visual_col(&e, 0, 10), 8) // second CJK rune
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 7), 7)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 8), 10)
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 9), 10) // inside 本 snaps left
    testing.expect_value(t, editor_byte_col_for_visual(&e, 0, 10), 13)

    // Combining mark contributes no cell: 12 cells over 17 bytes.
    total := pt_get_length(&e.buffer.table)
    testing.expect_value(t, editor_visual_col(&e, 0, total), 12)

    // Right/Left move over whole runes.
    e.cursor = Cursor{row = 0, col = 6}
    send_key_event(&e, KEY_MOVE_RIGHT)
    testing.expect_value(t, e.cursor.col, 7)
    send_key_event(&e, KEY_MOVE_RIGHT)
    testing.expect_value(t, e.cursor.col, 10)
    send_key_event(&e, KEY_MOVE_LEFT)
    testing.expect_value(t, e.cursor.col, 7)
    testing.expect_value(t, e.desired_col, 6)

    // Backspace deletes the whole preceding rune.
    e.mode = .Insert
    e.cursor.col = 10
    send_key_event(&e, sdl.K_BACKSPACE)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "héllo 本 é")
    testing.expect_value(t, e.cursor.col, 7)

    fmt.println("  ✓ [Editor] UTF-8 columns, wide runes, and rune-boundary motions")
}

@(test)
test_editor_unicode_selection_and_word_motion :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "日a 世界")
    defer editor_destroy(&e)

    e.mode = .Visual
    e.selection_anchor = Cursor{row = 0, col = 0}
    e.cursor = Cursor{row = 0, col = 0}
    start_off, end_off := editor_selection_offsets(&e)
    testing.expect_value(t, start_off, 0)
    testing.expect_value(t, end_off, 3)
    e.mode = .Normal

    e.cursor = Cursor{row = 0, col = 0}
    editor_motion_word_forward(&e)
    testing.expect_value(t, e.cursor.col, 5) // 日a is one word; skip the space
    editor_motion_word_forward(&e)
    testing.expect_value(t, e.cursor.col, 11) // 世界 is the next word
    editor_motion_word_backward(&e)
    testing.expect_value(t, e.cursor.col, 5) // back over 世界
    editor_motion_word_backward(&e)
    testing.expect_value(t, e.cursor.col, 0) // 日a are one contiguous word

    fmt.println("  ✓ [Editor] UTF-8 selections and word motions stay on runes")
}

@(test)
test_editor_line_move_is_single_undo :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "one\ntwo\nthree\n")
    defer editor_destroy(&e)

    e.cursor = Cursor{row = 1, col = 0}
    editor_move_lines(&e, 1)
    moved := pt_full_text(&e.buffer.table)
    defer delete(moved)
    testing.expect_value(t, moved, "one\nthree\ntwo\n")

    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    restored := pt_full_text(&e.buffer.table)
    defer delete(restored)
    testing.expect_value(t, restored, "one\ntwo\nthree\n")
    fmt.println("  ✓ [Editor] Alt+J/K line move is one undo step")
}

@(test)
test_editor_multi_lsp_edit_is_single_undo :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "aaa\nbbb\nccc")
    defer editor_destroy(&e)

    edits := []LspTextEdit{
        {start_row = 0, start_col = 0, end_row = 0, end_col = 3, new_text = "AAA"},
        {start_row = 2, start_col = 0, end_row = 2, end_col = 3, new_text = "CCC"},
    }
    editor_apply_lsp_edits(&e, edits)
    changed := pt_full_text(&e.buffer.table)
    defer delete(changed)
    testing.expect_value(t, changed, "AAA\nbbb\nCCC")

    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    restored := pt_full_text(&e.buffer.table)
    defer delete(restored)
    testing.expect_value(t, restored, "aaa\nbbb\nccc")
    fmt.println("  ✓ [Editor] multi-edit LSP formatting is one undo step")
}

@(test)
test_editor_crlf_insertions_and_save :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "a\r\nb", "crlf.txt")
    defer editor_destroy(&e)
    testing.expect_value(t, e.buffer.line_ending, Line_Ending.CRLF)

    e.mode = .Insert
    e.cursor = Cursor{row = 0, col = 1}
    e.desired_col = 1
    send_key_event(&e, sdl.K_RETURN)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "a\r\n\r\nb")

    // o/O use the buffer's line ending too.
    e.mode = .Normal
    e.cursor = Cursor{row = 0, col = 0}
    send_key_event(&e, KEY_OPEN_BELOW)
    opened := pt_full_text(&e.buffer.table)
    defer delete(opened)
    testing.expect(t, strings.has_prefix(opened, "a\r\n\r\n"), opened)

    // Normalization never produces a bare LF in a CRLF buffer.
    normalized := editor_normalize_newlines(&e, "x\ny\r\nz")
    testing.expect_value(t, normalized, "x\r\ny\r\nz")

    // LSP edits and pasted text are normalized as well.
    edits := []LspTextEdit{{start_row = 0, start_col = 0, end_row = 0, end_col = 1, new_text = "Q\nR"}}
    editor_apply_lsp_edits(&e, edits)
    edited := pt_full_text(&e.buffer.table)
    defer delete(edited)
    testing.expect(t, strings.contains(edited, "Q\r\nR"))
    for i in 0 ..< len(edited) {
        if edited[i] == '\n' {
            testing.expect(t, i > 0 && edited[i - 1] == '\r', "bare LF in CRLF buffer")
        }
    }

    // Saving preserves the CRLF bytes.
    path := "/tmp/odin_editor_tests/crlf_save.txt"
    _ = os.remove(path)
    defer os.remove(path)
    if e.buffer.file_path != "" do delete(e.buffer.file_path)
    e.buffer.file_path = strings.clone(path, context.allocator)
    testing.expect_value(t, editor_save_file(&e), true)
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    testing.expect_value(t, read_err, nil)
    for i in 0 ..< len(data) {
        if data[i] == '\n' {
            testing.expect(t, i > 0 && data[i - 1] == '\r', "saved bare LF")
        }
    }
    fmt.println("  ✓ [Editor] CRLF buffers insert, normalize, and save CRLF only")
}

@(test)
test_insert_escape_steps_cursor_left :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "héllo\nx\n")
    defer editor_destroy(&e)

    // Insert cursor at a character boundary: Esc lands on the previous rune.
    editor_set_mode(&e, .Insert, nil)
    e.cursor.row = 0
    e.cursor.col = 3 // before the first 'l'; é occupies bytes 1..2
    send_key_event(&e, sdl.K_ESCAPE)
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, e.cursor.col, 1)

    // At end of line the cursor lands on the last rune, not past it.
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 6
    send_key_event(&e, sdl.K_ESCAPE)
    testing.expect_value(t, e.cursor.col, 5)

    // Column 0 has nowhere to step back to.
    editor_set_mode(&e, .Insert, nil)
    e.cursor.col = 0
    send_key_event(&e, sdl.K_ESCAPE)
    testing.expect_value(t, e.cursor.col, 0)

    // Esc on a single-character line lands at column 0.
    editor_set_mode(&e, .Insert, nil)
    e.cursor.row = 1
    e.cursor.col = 1
    send_key_event(&e, sdl.K_ESCAPE)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 0)

    // Entering Insert from Normal does not move; 'a' steps over one rune.
    e.cursor.row = 0
    e.cursor.col = 2
    send_key_event(&e, sdl.K_ESCAPE)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.col, 2)

    editor_set_mode(&e, .Normal, nil)
    e.cursor.col = 1
    e.desired_col = 1
    send_key_event(&e, KEY_APPEND)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, e.cursor.col, 3)

    fmt.println("  ✓ [Editor] Insert→Normal Escape steps back one rune; Normal→Insert does not")
}

@(test)
test_command_parse_replacement :: proc(t: ^testing.T) {
    text, ok := command_parse_replacement(`"hello"`)
    testing.expect_value(t, ok, true)
    testing.expect_value(t, text, "hello")

    text, ok = command_parse_replacement(`"a\nb\tc"`)
    testing.expect_value(t, ok, true)
    testing.expect_value(t, text, "a\nb\tc")

    text, ok = command_parse_replacement(`'it\'s'`)
    testing.expect_value(t, ok, true)
    testing.expect_value(t, text, "it's")

    text, ok = command_parse_replacement("plain text")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, text, "plain text")

    _, ok = command_parse_replacement(`"unterminated`)
    testing.expect_value(t, ok, false)
    _, ok = command_parse_replacement("")
    testing.expect_value(t, ok, false)

    fmt.println("  ✓ [Editor] :replace argument quoting and escapes verified")
}

@(test)
test_editor_replace_selection :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "hello world")
    defer editor_destroy(&e)

    editor_set_mode(&e, .Visual, nil)
    e.selection_anchor = Cursor{row = 0, col = 6}
    e.cursor = Cursor{row = 0, col = 10}

    testing.expect_value(t, editor_replace_selection(&e, "there"), true)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "hello there")
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 6)
    testing.expect_value(t, e.buffer.dirty, true)

    // The replacement is one undo step.
    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    undone := pt_full_text(&e.buffer.table)
    defer delete(undone)
    testing.expect_value(t, undone, "hello world")

    // Without a Visual selection the helper refuses.
    testing.expect_value(t, editor_replace_selection(&e, "x"), false)

    fmt.println("  ✓ [Editor] selection replacement is atomic and rune-safe")
}

@(test)
test_editor_replace_selection_multiline_and_crlf :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "one\r\ntwo")
    defer editor_destroy(&e)

    editor_set_mode(&e, .Visual, nil)
    e.selection_anchor = Cursor{row = 1, col = 0}
    e.cursor = Cursor{row = 1, col = 2}

    testing.expect_value(t, editor_replace_selection(&e, "a\nb"), true)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "one\r\na\r\nb")
    testing.expect_value(t, e.buffer.line_ending, Line_Ending.CRLF)

    // An empty replacement deletes the selection.
    editor_set_mode(&e, .Visual, nil)
    e.selection_anchor = Cursor{row = 2, col = 0}
    e.cursor = Cursor{row = 2, col = 0}
    testing.expect_value(t, editor_replace_selection(&e, ""), true)
    deleted := pt_full_text(&e.buffer.table)
    defer delete(deleted)
    testing.expect_value(t, deleted, "one\r\na\r\n")

    fmt.println("  ✓ [Editor] replacement normalizes newlines to the buffer EOL")
}

@(test)
test_replace_command_dispatch :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    e := &app.active_pane.editor
    set_editor_text(e, "hello world")
    editor_set_mode(e, .Visual, nil)
    e.selection_anchor = Cursor{row = 0, col = 6}
    e.cursor = Cursor{row = 0, col = 10}

    app_execute_command(&app, `replace "there"`)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "hello there")
    testing.expect_value(t, app.cmd_prompt.message, "Replaced selection")

    // Deleting with an empty quoted argument.
    editor_set_mode(e, .Visual, nil)
    e.selection_anchor = Cursor{row = 0, col = 5}
    e.cursor = Cursor{row = 0, col = 10}
    app_execute_command(&app, `replace ""`)
    trimmed := pt_full_text(&e.buffer.table)
    defer delete(trimmed)
    testing.expect_value(t, trimmed, "hello")

    // Errors leave the buffer untouched and report an E: message.
    app_execute_command(&app, `replace "oops`)
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "E:"))
    app_execute_command(&app, "replace")
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "E:"))
    unchanged := pt_full_text(&e.buffer.table)
    defer delete(unchanged)
    testing.expect_value(t, unchanged, "hello")

    e.read_only = true
    editor_set_mode(e, .Visual, nil)
    e.selection_anchor = Cursor{row = 0, col = 0}
    e.cursor = Cursor{row = 0, col = 4}
    app_execute_command(&app, `replace "x"`)
    testing.expect_value(t, app.cmd_prompt.message, "Buffer is read-only")
    testing.expect_value(t, pt_get_length(&e.buffer.table), 5)
    e.read_only = false

    fmt.println("  ✓ [Editor] :replace dispatch, deletion, and error paths verified")
}

@(test)
test_read_only_editor_allows_selection :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "hello\nworld")
    defer editor_destroy(&e)
    e.read_only = true

    send_key_event(&e, KEY_VISUAL_TOGGLE, sdl.KMOD_CTRL)
    testing.expect_value(t, e.mode, EditorMode.Visual)

    send_key_event(&e, KEY_MOVE_RIGHT)
    testing.expect_value(t, e.cursor.col, 1)

    send_key_event(&e, sdl.K_ESCAPE)
    testing.expect_value(t, e.mode, EditorMode.Normal)

    // Line selection is navigation-only and stays available when read-only.
    send_key_event(&e, KEY_SELECT_LINE)
    testing.expect_value(t, e.mode, EditorMode.Visual)

    fmt.println("  ✓ [Editor] read-only buffers allow Visual selection and movement")
}

@(test)
test_shift_h_first_nonblank :: proc(t: ^testing.T) {
    e: Editor
    editor_init(&e, nil, "    indented\n   \n")
    defer editor_destroy(&e)

    editor_set_mode(&e, .Normal, nil)
    e.cursor.row = 0
    e.cursor.col = 8
    editor_handle_normal_key(&e, KEY_LINE_START, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.cursor.col, 4)

    // `0` still goes to column zero.
    editor_handle_normal_key(&e, KEY_LINE_START_ZERO, {}, nil, nil)
    testing.expect_value(t, e.cursor.col, 0)

    // A whitespace-only line has no text start; stay at column zero.
    e.cursor.row = 1
    e.cursor.col = 3
    editor_handle_normal_key(&e, KEY_LINE_START, sdl.KMOD_SHIFT, nil, nil)
    testing.expect_value(t, e.cursor.col, 0)

    fmt.println("  ✓ [Editor] Shift+H moves to first non-blank; 0 keeps column zero")
}

@(test)
test_replace_highlighted_matches :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo bar foo\nfoo baz")

    app.last_search = strings.clone("foo")
    app.search_highlight = true

    app_execute_command(&app, `replace "X"`)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "X bar X\nX baz")
    testing.expect_value(t, app.search_highlight, false)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "3 match"))

    // One undo restores every replaced occurrence.
    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    restored := pt_full_text(&e.buffer.table)
    defer delete(restored)
    testing.expect_value(t, restored, "foo bar foo\nfoo baz")

    fmt.println("  ✓ [Editor] :replace targets highlighted matches without a selection")
}

@(test)
test_replace_only_inside_selection_matches :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo foo foo")

    app.last_search = strings.clone("foo")
    app.search_highlight = true

    // Select just the first two occurrences ("foo foo").
    editor_set_mode(e, .Visual, nil)
    e.selection_anchor = Cursor{row = 0, col = 0}
    e.cursor = Cursor{row = 0, col = 6}

    app_execute_command(&app, `replace "Z"`)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "Z Z foo")
    testing.expect_value(t, e.mode, EditorMode.Normal)

    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    restored := pt_full_text(&e.buffer.table)
    defer delete(restored)
    testing.expect_value(t, restored, "foo foo foo")

    fmt.println("  ✓ [Editor] :replace only rewrites highlighted matches inside the selection")
}
