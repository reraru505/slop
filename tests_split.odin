package main

import "core:fmt"
import "core:testing"
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
    delete(app.panes)
    app_reset_command_completion(&app.cmd_prompt)
    delete(app.cmd_prompt.buffer)
    delete(app.cmd_prompt.matches)
    if app.working_dir != "" do delete(app.working_dir)
    if app.last_compile_cmd != "" do delete(app.last_compile_cmd)
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
    pt_insert(&orig.editor.table, 0, "hello")
    orig.editor.cursor.row = 0
    orig.editor.cursor.col = 2
    orig.editor.dirty = true

    app_split_pane(&app, orig, .Vertical)
    testing.expect_value(t, len(app.panes), 2)
    new_pane := app.active_pane
    testing.expect(t, new_pane != orig)
    copied := pt_full_text(&new_pane.editor.table)
    defer delete(copied)
    testing.expect_value(t, copied, "hello")
    testing.expect_value(t, new_pane.editor.cursor.col, 2)
    testing.expect_value(t, new_pane.editor.dirty, false)
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
