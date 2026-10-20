package main

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:os"
import sdl "vendor:sdl3"

// Builds a minimal App with one Editor pane and a matching split tree.
// The font is zero-valued, which editor_init accepts (char advance becomes 0).
make_test_app :: proc() -> App {
    app: App
    app.panes = make([dynamic]^Pane)
    app.next_pane_id = 1
    app.current_theme_id = DEFAULT_THEME
    app.theme = theme_get(DEFAULT_THEME)
    p := pane_create(&app, .Editor)
    app.root_split = split_create_leaf(p)
    app.active_pane = p
    return app
}

destroy_test_app :: proc(app: ^App) {
    for len(app.panes) > 0 {
        pane_destroy(app, app.panes[0])
    }
    split_destroy_tree(app.root_split)
    app.root_split = nil
    lsp_manager_stop_all(&app.lsp_manager)
    delete(app.panes)
    app_reset_command_completion(&app.cmd_prompt)
    delete(app.cmd_prompt.buffer)
    delete(app.cmd_prompt.matches)
    if app.working_dir != "" do delete(app.working_dir)
    if app.root_dir != "" do delete(app.root_dir)
    if app.last_compile_cmd != "" do delete(app.last_compile_cmd)
    if app.last_search != "" do delete(app.last_search)
}

@(test)
test_split_tree_geometry_and_lookup :: proc(t: ^testing.T) {
    p1, p2, p3: Pane
    n1 := SplitNode{is_leaf = true, pane = &p1}
    n2 := SplitNode{is_leaf = true, pane = &p2}
    n3 := SplitNode{is_leaf = true, pane = &p3}
    vertical := SplitNode{
        is_leaf = false,
        dir     = .Vertical,
        ratio   = 0.5,
        first   = &n1,
        second  = &n2,
    }
    root := SplitNode{
        is_leaf = false,
        dir     = .Horizontal,
        ratio   = 0.25,
        first   = &vertical,
        second  = &n3,
    }

    split_compute_rects(&root, sdl.FRect{0, 0, 101, 101})

    // Horizontal split at 25%: top row is 25px, bottom row 75px
    testing.expect_value(t, p1.rect.x, 0.0)
    testing.expect_value(t, p1.rect.y, 0.0)
    testing.expect_value(t, p1.rect.w, 50.0)
    testing.expect_value(t, p1.rect.h, 25.0)
    testing.expect_value(t, p2.rect.x, 51.0)
    testing.expect_value(t, p2.rect.y, 0.0)
    testing.expect_value(t, p2.rect.w, 50.0)
    testing.expect_value(t, p2.rect.h, 25.0)
    testing.expect_value(t, p3.rect.x, 0.0)
    testing.expect_value(t, p3.rect.y, 26.0)
    testing.expect_value(t, p3.rect.w, 101.0)
    testing.expect_value(t, p3.rect.h, 75.0)

    // Tree lookups
    testing.expect_value(t, split_find_node_with_pane(&root, &p1), &n1)
    testing.expect_value(t, split_find_node_with_pane(&root, &p2), &n2)
    testing.expect_value(t, split_find_node_with_pane(&root, &p3), &n3)
    testing.expect_value(t, split_find_node_with_pane(&root, nil), nil)
    testing.expect_value(t, split_find_parent(&root, &n2), &vertical)
    testing.expect_value(t, split_find_parent(&root, &vertical), &root)
    testing.expect_value(t, split_find_parent(&root, &n1), &vertical)
    testing.expect_value(t, split_get_first_leaf(&root), &n1)
    testing.expect_value(t, split_get_first_leaf(nil), nil)

    split_compute_rects(nil, sdl.FRect{0, 0, 10, 10}) // must not crash
    fmt.println("  ✓ [Split] rect computation, leaf lookup and parent lookup")
}

@(test)
test_split_pane_lifecycle :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    testing.expect_value(t, len(app.panes), 1)
    orig := app.active_pane
    testing.expect_value(t, orig.kind, PaneKind.Editor)

    // Content and cursor are copied into the new pane
    pt_insert(&orig.editor.buffer.table, 0, "hello")
    orig.editor.cursor.row = 0
    orig.editor.cursor.col = 2
    orig.editor.buffer.dirty = true

    app_split_pane(&app, orig, .Vertical)
    testing.expect_value(t, len(app.panes), 2)
    new_pane := app.active_pane
    testing.expect(t, new_pane != orig)
    copied := pt_full_text(&new_pane.editor.buffer.table)
    defer delete(copied)
    testing.expect_value(t, copied, "hello")
    testing.expect_value(t, new_pane.editor.cursor.col, 2)
    // Split views share the document and its dirty state.
    testing.expect_value(t, new_pane.editor.buffer.dirty, true)
    testing.expect_value(t, new_pane.editor.buffer, orig.editor.buffer)
    pt_insert(&new_pane.editor.buffer.table, 5, " world")
    shared := pt_full_text(&orig.editor.buffer.table)
    defer delete(shared)
    testing.expect_value(t, shared, "hello world")
    testing.expect_value(t, app.root_split.is_leaf, false)
    testing.expect_value(t, app.root_split.dir, SplitDir.Vertical)

    split_compute_rects(app.root_split, sdl.FRect{0, 0, 101, 50})
    testing.expect_value(t, orig.rect.w, 50.0)
    testing.expect_value(t, new_pane.rect.x, 51.0)
    testing.expect_value(t, new_pane.rect.w, 50.0)

    // Directional focus and cycling
    app_focus_dir(&app, .Left)
    testing.expect_value(t, app.active_pane, orig)
    app_focus_dir(&app, .Right)
    testing.expect_value(t, app.active_pane, new_pane)
    app_cycle_pane(&app)
    testing.expect_value(t, app.active_pane, orig)
    app_cycle_pane(&app)
    testing.expect_value(t, app.active_pane, new_pane)

    // Closing the focused pane collapses the tree and refocuses the sibling
    testing.expect_value(t, app_close_pane(&app, new_pane), true)
    testing.expect_value(t, len(app.panes), 1)
    testing.expect_value(t, app.active_pane, orig)
    testing.expect_value(t, app.root_split.is_leaf, true)
    testing.expect_value(t, app.root_split.pane, orig)
    // The surviving view keeps the shared document after its sibling closes.
    surviving := pt_full_text(&orig.editor.buffer.table)
    defer delete(surviving)
    testing.expect_value(t, surviving, "hello world")
    testing.expect_value(t, orig.editor.buffer.dirty, true)

    // Closing the only pane asks the app to quit but keeps the pane alive
    app.running = true
    testing.expect_value(t, app_close_pane(&app, orig), true)
    testing.expect_value(t, app.running, false)
    testing.expect_value(t, len(app.panes), 1)

    // Nil targets are ignored
    app_split_pane(&app, nil, .Horizontal)
    testing.expect_value(t, len(app.panes), 1)
    testing.expect_value(t, app_close_pane(&app, nil), false)
    fmt.println("  ✓ [Split] split/copy/close lifecycle and focus movement verified")
}

@(test)
test_split_focus_and_cycle_geometry :: proc(t: ^testing.T) {
    app: App
    app.panes = make([dynamic]^Pane)
    defer {
        for p in app.panes do free(p)
        delete(app.panes)
    }

    center := new(Pane)
    center.rect = sdl.FRect{0, 0, 100, 100}
    right := new(Pane)
    right.rect = sdl.FRect{200, 0, 100, 100}
    below := new(Pane)
    below.rect = sdl.FRect{0, 200, 100, 100}

    append(&app.panes, center, right, below)
    app.active_pane = center

    app_focus_dir(&app, .Right)
    testing.expect_value(t, app.active_pane, right)
    app_focus_dir(&app, .Down)
    testing.expect_value(t, app.active_pane, below)
    app_focus_dir(&app, .Up)
    testing.expect_value(t, app.active_pane, center)

    // No pane to the left of center: focus does not move
    app_focus_dir(&app, .Left)
    testing.expect_value(t, app.active_pane, center)

    // Cycling wraps around the pane list
    app_cycle_pane(&app)
    testing.expect_value(t, app.active_pane, right)
    app_cycle_pane(&app)
    testing.expect_value(t, app.active_pane, below)
    app_cycle_pane(&app)
    testing.expect_value(t, app.active_pane, center)
    fmt.println("  ✓ [Split] directional focus and pane cycling wrap verified")
}

@(test)
test_split_preserves_read_only :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    orig := app.active_pane
    orig.editor.read_only = true
    app_split_pane(&app, orig, .Horizontal)
    copy := app.active_pane
    testing.expect(t, copy != orig)
    testing.expect_value(t, copy.editor.read_only, true)
    fmt.println("  ✓ [Split] read-only buffers stay read-only across splits")
}

@(test)
test_split_compilation_does_not_start_build :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    comp := app.active_pane
    comp.kind = .Compilation
    comp.compilation.command = strings.clone("printf 'copy-only\\n'")

    app_split_pane(&app, comp, .Horizontal)
    copy := app.active_pane
    testing.expect(t, copy != comp)
    testing.expect_value(t, copy.compilation.command, "printf 'copy-only\\n'")
    testing.expect_value(t, copy.compilation.job, nil)
    fmt.println("  ✓ [Split] splitting a compilation pane does not start another build")
}

@(test)
test_split_same_file_shares_buffer :: proc(t: ^testing.T) {
    path := "/tmp/odin_editor_tests/shared_buffer.txt"
    _ = os.remove(path)
    testing.expect(t, os.write_entire_file_from_string(path, "abc") == nil)
    defer os.remove(path)

    app := make_test_app()
    defer destroy_test_app(&app)

    orig := app.active_pane
    testing.expect_value(t, app_pane_open_file(&app, orig, path), true)
    app_split_pane(&app, orig, .Horizontal)
    other := app.active_pane
    testing.expect(t, orig.editor.buffer == other.editor.buffer)

    // Type in one view; the shared table and dirty flag change everywhere.
    other.editor.mode = .Insert
    other.editor.cursor.row = 0
    other.editor.cursor.col = 3
    simulate_typing(&other.editor, "d")

    text_orig := pt_full_text(&orig.editor.buffer.table)
    defer delete(text_orig)
    text_other := pt_full_text(&other.editor.buffer.table)
    defer delete(text_other)
    testing.expect_value(t, text_orig, "abcd")
    testing.expect_value(t, text_other, "abcd")
    testing.expect_value(t, orig.editor.buffer.dirty, true)
    testing.expect_value(t, other.editor.buffer.dirty, true)

    // Undo is shared too.
    testing.expect_value(t, pt_undo(&orig.editor.buffer.table), true)
    undone := pt_full_text(&other.editor.buffer.table)
    defer delete(undone)
    testing.expect_value(t, undone, "abc")

    // Saving from one view clears the shared dirty flag.
    testing.expect_value(t, editor_save_file(&other.editor, &app), true)
    testing.expect_value(t, orig.editor.buffer.dirty, false)

    // Re-opening the same file attaches the existing buffer.
    testing.expect_value(t, app_pane_open_file(&app, orig, path), true)
    testing.expect(t, orig.editor.buffer == other.editor.buffer)

    // A forced reload replaces the document under every view, not just one.
    testing.expect(t, os.write_entire_file_from_string(path, "reloaded\nline") == nil)
    testing.expect_value(t, app_pane_open_file(&app, orig, path, force = true), true)
    testing.expect(t, orig.editor.buffer == other.editor.buffer)
    reloaded := pt_full_text(&other.editor.buffer.table)
    defer delete(reloaded)
    testing.expect_value(t, reloaded, "reloaded\nline")
    testing.expect_value(t, orig.editor.buffer.dirty, false)

    // A view whose cursor predates another view's edit is clamped before use.
    orig.editor.cursor.row = 1
    orig.editor.cursor.col = 4
    editor_replace_buffer_text(&other.editor, "x")
    editor_sync_view(&orig.editor)
    testing.expect_value(t, orig.editor.cursor.row, 0)
    testing.expect_value(t, orig.editor.cursor.col, 1)
    fmt.println("  ✓ [Split] same-file views share content, undo, dirty, and reload state")
}
