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

    // N searches opposite to the `/` direction; from the first match it wraps.
    app_search_repeat(&app, true)
    testing.expect_value(t, e.cursor.row, 3)
    testing.expect_value(t, e.cursor.col, 0)
    testing.expect_value(t, app.search_direction, 1)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "wrapped to bottom"))

    // p is the alternate backwards binding (Ctrl+Y remains paste). Repeated p
    // keeps walking backwards instead of toggling between two matches.
    editor_handle_normal_key(e, KEY_SEARCH_PREV_ALT, {}, nil, &app)
    testing.expect_value(t, e.cursor.row, 1)
    testing.expect_value(t, e.cursor.col, 4)
    testing.expect_value(t, app.search_direction, 1)
    editor_handle_normal_key(e, KEY_SEARCH_PREV_ALT, {}, nil, &app)
    testing.expect_value(t, e.cursor.row, 0)
    testing.expect_value(t, e.cursor.col, 4)

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

@(test)
test_search_in_dired_buffer :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/search_dired"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/alpha.txt", dir), "a") == nil)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/beta.txt", dir), "b") == nil)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/gamma.log", dir), "g") == nil)

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane
    app_pane_open_dired(&app, pane, dir)
    dired_wait_load(&pane.dired)
    testing.expect_value(t, pane.kind, PaneKind.Dired)
    testing.expect_value(t, app.active_pane, pane)

    gamma_idx := -1
    for entry, i in pane.dired.entries {
        if entry.name == "gamma.log" do gamma_idx = i
    }
    testing.expect(t, gamma_idx >= 0)

    app_open_search_prompt(&app)
    for b in transmute([]u8)string("gamma") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)
    testing.expect_value(t, pane.dired.cursor, gamma_idx)
    testing.expect_value(t, app.last_search, "gamma")

    // n wraps around when the only match is the current one.
    app_search_repeat(&app, false)
    testing.expect_value(t, pane.dired.cursor, gamma_idx)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "wrapped to top"))

    fmt.println("  ✓ [Search] dired listing search moves the entry cursor")
}

@(test)
test_search_in_compilation_buffer :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    pane := app.active_pane
    pane.kind = .Compilation
    c := &pane.compilation
    append(&c.lines, CompilationLine{text = strings.clone("first line")})
    append(&c.lines, CompilationLine{text = strings.clone("an error here")})
    append(&c.lines, CompilationLine{text = strings.clone("another error")})
    c.cursor = 0
    c.cursor_col = 0
    app.active_pane = pane

    app_open_search_prompt(&app)
    testing.expect_value(t, app.cmd_prompt.source_pane, pane)
    for b in transmute([]u8)string("error") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)
    testing.expect_value(t, c.cursor, 1)
    testing.expect_value(t, c.cursor_col, 3)
    testing.expect_value(t, app.last_search, "error")

    // An empty `/<Enter>` repeats the search from the current match.
    app_open_search_prompt(&app)
    app_submit_prompt(&app)
    testing.expect_value(t, c.cursor, 2)
    testing.expect_value(t, c.cursor_col, 8)

    // Esc restores the compilation cursor and scroll position.
    c.cursor = 0
    c.cursor_col = 2
    c.scroll = 1
    app_open_search_prompt(&app)
    for b in transmute([]u8)string("error") do append(&app.cmd_prompt.buffer, b)
    app_cancel_search_prompt(&app)
    testing.expect_value(t, c.cursor, 0)
    testing.expect_value(t, c.cursor_col, 2)
    testing.expect_value(t, c.scroll, 1)

    fmt.println("  ✓ [Search] compilation output search and restore verified")
}

@(test)
test_dired_search_cycles_three_matches :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/search_dired_cycle"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)
    for name in ([]string{"a-hit.txt", "b.txt", "c-hit.txt", "d.txt", "e-hit.txt"}) {
        testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/%s", dir, name), "x") == nil)
    }

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane
    app_pane_open_dired(&app, pane, dir)
    dired_wait_load(&pane.dired)

    hit_rows: [dynamic]int
    defer delete(hit_rows)
    for entry, i in pane.dired.entries {
        if strings.contains(entry.name, "hit") do append(&hit_rows, i)
    }
    testing.expect_value(t, len(hit_rows), 3)

    app_open_search_prompt(&app)
    for b in transmute([]u8)string("hit") do append(&app.cmd_prompt.buffer, b)
    app_submit_prompt(&app)
    testing.expect_value(t, pane.dired.cursor, hit_rows[0])

    app_search_repeat(&app, false)
    testing.expect_value(t, pane.dired.cursor, hit_rows[1])
    app_search_repeat(&app, false)
    testing.expect_value(t, pane.dired.cursor, hit_rows[2])
    app_search_repeat(&app, false)
    testing.expect_value(t, pane.dired.cursor, hit_rows[0])
    testing.expect(t, strings.contains(app.cmd_prompt.message, "wrapped to top"))

    // p cycles backwards through dired matches and keeps going.
    key_event: sdl.Event
    key_event.type = .KEY_DOWN
    key_event.key.key = KEY_SEARCH_PREV_ALT
    dired_handle_event(&pane.dired, &key_event, &app, pane)
    testing.expect_value(t, pane.dired.cursor, hit_rows[2])
    dired_handle_event(&pane.dired, &key_event, &app, pane)
    testing.expect_value(t, pane.dired.cursor, hit_rows[1])

    fmt.println("  ✓ [Search] dired cycles through all three matches")
}
