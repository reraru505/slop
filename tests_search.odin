package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_search_find_in_text :: proc(t: ^testing.T) {
    text := "alpha beta alpha\nsecond alpha\n"

    // Forward search includes a match at the start offset.
    off, wrapped, found := search_find_in_text(text, "alpha", 0, 1, true)
    testing.expect_value(t, found, true)
    testing.expect_value(t, off, 0)
    testing.expect_value(t, wrapped, false)

    off, wrapped, found = search_find_in_text(text, "alpha", 1, 1, true)
    testing.expect_value(t, off, 11)
    testing.expect_value(t, wrapped, false)

    // Nothing left below the last match: wrap to the first one.
    off, wrapped, found = search_find_in_text(text, "alpha", 29, 1, true)
    testing.expect_value(t, off, 0)
    testing.expect_value(t, wrapped, true)

    // Backward search is exclusive of the start offset.
    off, wrapped, found = search_find_in_text(text, "alpha", 12, -1, false)
    testing.expect_value(t, off, 11)
    testing.expect_value(t, wrapped, false)

    off, wrapped, found = search_find_in_text(text, "alpha", 11, -1, false)
    testing.expect_value(t, off, 0)
    testing.expect_value(t, wrapped, false)

    // Wrapping backward lands on the last occurrence.
    off, wrapped, found = search_find_in_text(text, "alpha", 0, -1, false)
    testing.expect_value(t, off, 24)
    testing.expect_value(t, wrapped, true)

    // Overlapping occurrences are considered.
    off, wrapped, found = search_find_in_text("aaaa", "aa", 0, 1, true)
    testing.expect_value(t, off, 0)
    off, wrapped, found = search_find_in_text("aaaa", "aa", 1, 1, true)
    testing.expect_value(t, off, 1)

    // Missing patterns and empty inputs are not found.
    _, _, found = search_find_in_text(text, "missing", 0, 1, true)
    testing.expect_value(t, found, false)
    _, _, found = search_find_in_text("", "alpha", 0, 1, true)
    testing.expect_value(t, found, false)
    _, _, found = search_find_in_text(text, "", 0, 1, true)
    testing.expect_value(t, found, false)

    fmt.println("  ✓ [Search] forward/backward/wrap/overlap matching verified")
}

@(test)
test_search_prompt_navigation :: proc(t: ^testing.T) {
    path := "/tmp/odin_editor_search_test.txt"
    content := "one needle\ntwo needle\nthree\nneedle four\n"
    _ = os.remove(path)
    testing.expect(t, os.write_entire_file_from_string(path, content) == nil)
    defer os.remove(path)

    app := make_test_app()
    defer destroy_test_app(&app)

    pane := app.active_pane
    testing.expect_value(t, app_pane_open_file(&app, pane, path), true)
    e := &pane.editor

    // `/` opens a search prompt over the editor.
    key_event: sdl.Event
    key_event.type = .KEY_DOWN
    key_event.key.key = KEY_SEARCH
    editor_handle_event(e, &key_event, app.window, &app)
    testing.expect_value(t, app.cmd_prompt.active, true)
    testing.expect_value(t, app.cmd_prompt.kind, CommandPromptKind.Search)
    testing.expect_value(t, app.cmd_prompt.source_pane, pane)

    for b in transmute([]u8)string("needle") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)
    testing.expect_value(t, app.cmd_prompt.active, false)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 4)
    testing.expect_value(t, app.last_search, "needle")
    testing.expect_value(t, app.search_direction, 1)
    testing.expect_value(t, app.cmd_prompt.message, "/needle")

    // n advances through the normal-mode key handler.
    editor_handle_normal_key(e, KEY_SEARCH_NEXT, {}, nil, &app)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)
    // The second n reaches the last match; the third wraps to the first.
    app_search_repeat(&app, false)
    testing.expect_value(t, e.cursor.row, 3)
    testing.expect_value(t, e.cursor.col, 0)
    app_search_repeat(&app, false)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 4)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "wrapped to top"))

    // N reverses direction; from the first match it wraps to the last.
    app_search_repeat(&app, true)
    testing.expect_value(t, e.cursor.row, 3)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, app.search_direction, -1)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "wrapped to bottom"))

    // An empty prompt repeats the previous pattern from the current cursor.
    e.cursor.row = 2
    e.cursor.col = 0
    app_open_search_prompt(&app)
    app_submit_prompt(&app)
    testing.expect_value(t, e.cursor.row, 3)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, app.last_search, "needle")

    // Esc restores the cursor and scroll position.
    e.cursor.row = 2
    e.cursor.col = 3
    e.scroll_row = 2
    e.scroll_col = 1
    app_open_search_prompt(&app)
    for b in transmute([]u8)string("needle") do append(&app.cmd_prompt.buffer, b)
    app_cancel_search_prompt(&app)
    testing.expect_value(t, e.cursor.row, 2)
    testing.expect_value(t, e.cursor.col, 3)
    testing.expect_value(t, e.scroll_row, 2)
    testing.expect_value(t, e.scroll_col, 1)
    testing.expect_value(t, app.cmd_prompt.active, false)

    fmt.println("  ✓ [Search] prompt, n/N, wrap, repeat, and Esc restore verified")
}

@(test)
test_search_missing_pattern_and_history :: proc(t: ^testing.T) {
    path := "/tmp/odin_editor_search_missing.txt"
    _ = os.remove(path)
    testing.expect(t, os.write_entire_file_from_string(path, "abc\ndef\n") == nil)
    defer os.remove(path)

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane
    testing.expect_value(t, app_pane_open_file(&app, pane, path), true)
    e := &pane.editor

    // No previous pattern: n and an empty prompt both report E35.
    app_search_repeat(&app, false)
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "E35"))
    app_open_search_prompt(&app)
    app_submit_prompt(&app)
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "E35"))

    // A pattern that does not exist leaves the cursor alone.
    e.cursor.row = 1
    e.cursor.col = 2
    app_open_search_prompt(&app)
    for b in transmute([]u8)string("zzz") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 2)
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "E486"))
    testing.expect_value(t, app.last_search, "")

    fmt.println("  ✓ [Search] E35/E486 paths leave the cursor unchanged")
}
