package main

import "core:fmt"
import "core:testing"
import "core:strings"
import sdl "vendor:sdl3"

ml_send_text :: proc(e: ^Editor, text: string) -> bool {
    ev: sdl.Event
    ev.type = .TEXT_INPUT
    ev.text.text = strings.clone_to_cstring(text, context.temp_allocator)
    return editor_handle_event(e, &ev, nil, nil)
}

@(test)
test_multicursor_place_insert_and_undo :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo foo foo")

    app.last_search = strings.clone("foo")
    app.search_highlight = true
    app.search_scoped = false

    // Shift+C with a highlighted search routes to multi-cursor placement.
    editor_handle_normal_key(e, KEY_MULTI_CURSOR, sdl.KMOD_SHIFT, nil, &app)
    testing.expect_value(t, len(e.extra_cursors), 2)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, e.extra_cursors[0].col, 4)
    testing.expect_value(t, e.extra_cursors[1].col, 8)
    testing.expect_value(t, app.cmd_prompt.message, "3 cursors")

    // `i` enters Insert without collapsing the extra cursors.
    editor_handle_normal_key(e, KEY_INSERT_BEFORE, {}, nil, &app)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, len(e.extra_cursors), 2)
    testing.expect_value(t, ml_send_text(e, "X"), true)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "Xfoo Xfoo Xfoo")
    testing.expect_value(t, e.cursor.col, 1)
    testing.expect_value(t, e.extra_cursors[0].col, 6)
    testing.expect_value(t, e.extra_cursors[1].col, 11)

    // One undo step reverts every cursor's insertion.
    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    undone := pt_full_text(&e.buffer.table)
    defer delete(undone)
    testing.expect_value(t, undone, "foo foo foo")

    // Esc leaves Insert and collapses the extra cursors.
    send_key_event(e, sdl.K_ESCAPE)
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, len(e.extra_cursors), 0)

    fmt.println("  ✓ [MultiCursor] Shift+C placement, multi-insert, undo, and Esc collapse")
}

@(test)
test_multicursor_backspace_all :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo foo foo")

    app.last_search = strings.clone("foo")
    app.search_highlight = true
    app.search_scoped = false
    testing.expect_value(t, editor_place_multi_cursors(e, &app), true)
    editor_set_mode(e, .Insert, nil)

    ml_send_text(e, "X")
    send_key_event(e, sdl.K_BACKSPACE)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "foo foo foo")
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, e.extra_cursors[0].col, 4)
    testing.expect_value(t, e.extra_cursors[1].col, 8)

    fmt.println("  ✓ [MultiCursor] Backspace deletes at every cursor")
}

@(test)
test_block_selection_text_and_delete :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "abcd\nefgh\nijkl")

    ev: sdl.Event
    ev.type = .KEY_DOWN
    ev.key.key = KEY_BLOCK_VISUAL
    ev.key.mod = sdl.KMOD_CTRL
    editor_handle_event(e, &ev, nil, &app)
    testing.expect_value(t, e.mode, EditorMode.Visual)
    testing.expect_value(t, e.block_selection, true)

    ev.key.mod = {}
    ev.key.key = KEY_MOVE_DOWN
    editor_handle_event(e, &ev, nil, &app)
    editor_handle_event(e, &ev, nil, &app)
    ev.key.key = KEY_MOVE_RIGHT
    editor_handle_event(e, &ev, nil, &app)
    editor_handle_event(e, &ev, nil, &app)
    testing.expect_value(t, e.cursor.row, 2)
    testing.expect_value(t, e.cursor.col, 2)

    block := editor_block_text(e, context.allocator)
    defer delete(block)
    // Rectangle selection includes the character under the cursor.
    testing.expect_value(t, block, "abc\nefg\nijk\n")

    // Visual D deletes the rectangle, then undo restores it.
    ev.key.key = KEY_DELETE_SELECTION
    editor_handle_event(e, &ev, nil, &app)
    after := pt_full_text(&e.buffer.table)
    defer delete(after)
    testing.expect_value(t, after, "d\nh\nl")
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 0)

    testing.expect_value(t, pt_undo(&e.buffer.table), true)
    restored := pt_full_text(&e.buffer.table)
    defer delete(restored)
    testing.expect_value(t, restored, "abcd\nefgh\nijkl")

    fmt.println("  ✓ [Block] Ctrl+V rectangle, j/k extension, text extraction, delete")
}

@(test)
test_shift_c_falls_back_to_block_selection :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "abcd\nefgh")

    ev: sdl.Event
    ev.type = .KEY_DOWN
    ev.key.key = KEY_MULTI_CURSOR
    ev.key.mod = sdl.KMOD_SHIFT
    editor_handle_event(e, &ev, nil, &app)
    testing.expect_value(t, e.mode, EditorMode.Visual)
    testing.expect_value(t, e.block_selection, true)

    fmt.println("  ✓ [Block] Shift+C starts rectangle selection without a search")
}

@(test)
test_scoped_search_inside_visual_selection :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo\nbar foo\nfoo baz")

    // Select only "bar foo" on the second line.
    editor_set_mode(e, .Visual, nil)
    e.selection_anchor = Cursor{row = 1, col = 0}
    e.cursor = Cursor{row = 1, col = 6}

    key_ev: sdl.Event
    key_ev.type = .KEY_DOWN
    key_ev.key.key = KEY_SEARCH
    editor_handle_event(e, &key_ev, app.window, &app)
    testing.expect_value(t, app.cmd_prompt.scoped, true)
    for b in transmute([]u8)string("foo") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)

    // The previous line's match is outside the selection and must be skipped.
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)
    testing.expect_value(t, app.search_scoped, true)
    testing.expect_value(t, app.search_scope_pane, app.active_pane)

    // Only one match is in scope; n wraps back to it.
    app_search_repeat(&app, false)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "wrapped to top"))

    // Multi-cursor placement also respects the scope.
    testing.expect_value(t, editor_place_multi_cursors(e, &app), true)
    testing.expect_value(t, len(e.extra_cursors), 0)

    // Leaving Visual and searching again restores whole-buffer scope.
    editor_set_mode(e, .Normal, nil)
    app_open_search_prompt(&app)
    testing.expect_value(t, app.cmd_prompt.scoped, false)
    for b in transmute([]u8)string("foo") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)
    testing.expect_value(t, app.search_scoped, false)
    // The inclusive new search lands on the match under the cursor; n then
    // proceeds past the old selection boundary.
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)
    app_search_repeat(&app, false)
    testing.expect_value(t, e.cursor.row, 2)
    testing.expect_value(t, e.cursor.col, 0)

    fmt.println("  ✓ [Search] Visual selection scopes /, n, and multi-cursor placement")
}

@(test)
test_multicursor_moves_together :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo\nfoo\nfoo\nfoo")

    app.last_search = strings.clone("foo")
    app.search_highlight = true
    app.search_scoped = false
    testing.expect_value(t, editor_place_multi_cursors(e, &app), true)
    testing.expect_value(t, len(e.extra_cursors), 3)

    // j moves the primary and every extra cursor down one row.
    editor_handle_normal_key(e, KEY_MOVE_DOWN, {}, nil, &app)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.extra_cursors[0].row, 2)
    testing.expect_value(t, e.extra_cursors[1].row, 3)
    testing.expect_value(t, e.extra_cursors[2].row, 3)

    fmt.println("  ✓ [MultiCursor] vertical motion moves every cursor")
}

@(test)
test_block_scoped_search_and_replace :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "aa foo zz\naa foo zz\naa foo zz")

    // Rectangle over the first two lines' foo occurrences.
    editor_set_mode(e, .Visual, nil)
    e.block_selection = true
    e.selection_anchor = Cursor{row = 0, col = 3}
    e.cursor = Cursor{row = 1, col = 5}

    key_ev: sdl.Event
    key_ev.type = .KEY_DOWN
    key_ev.key.key = KEY_SEARCH
    editor_handle_event(e, &key_ev, app.window, &app)
    testing.expect_value(t, app.cmd_prompt.scoped, true)
    testing.expect_value(t, app.cmd_prompt.scope_block, true)
    for b in transmute([]u8)string("foo") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)

    testing.expect_value(t, app.search_scope_block, true)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 3)
    app_search_repeat(&app, false)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 3)
    app_search_repeat(&app, false)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 3)

    // Replacing highlighted matches honors the block scope.
    app_execute_command(&app, `replace "bar"`)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "aa bar zz\naa bar zz\naa foo zz")

    fmt.println("  ✓ [Search] block selection scopes search and replacement")
}

@(test)
test_multicursor_escape_route_keeps_cursors_when_entering_insert :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo foo")

    app.last_search = strings.clone("foo")
    app.search_highlight = true
    e.cursor.row = 0
    e.cursor.col = 0
    testing.expect_value(t, editor_place_multi_cursors(e, &app), true)
    testing.expect_value(t, len(e.extra_cursors), 1)

    // Normal-mode Esc toggles into Insert in this editor and must keep the
    // extra cursors so the user can start editing them.
    send_key_event(e, sdl.K_ESCAPE)
    testing.expect_value(t, e.mode, EditorMode.Insert)
    testing.expect_value(t, len(e.extra_cursors), 1)

    // Leaving Insert collapses them.
    send_key_event(e, sdl.K_ESCAPE)
    testing.expect_value(t, e.mode, EditorMode.Normal)
    testing.expect_value(t, len(e.extra_cursors), 0)

    fmt.println("  ✓ [MultiCursor] Esc keeps cursors entering Insert and collapses on exit")
}

@(test)
test_multicursor_normal_delete_char :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    e := &app.active_pane.editor
    set_editor_text(e, "foo foo foo")

    app.last_search = strings.clone("foo")
    app.search_highlight = true
    testing.expect_value(t, editor_place_multi_cursors(e, &app), true)

    editor_handle_normal_key(e, KEY_DELETE_CHAR, {}, nil, &app)
    text := pt_full_text(&e.buffer.table)
    defer delete(text)
    testing.expect_value(t, text, "oo oo oo")
    testing.expect_value(t, len(e.extra_cursors), 2)

    fmt.println("  ✓ [MultiCursor] normal-mode delete applies at every cursor")
}
