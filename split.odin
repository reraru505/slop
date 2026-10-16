package main

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

SplitDir :: enum {
    Horizontal, // Top / Bottom (:sp)
    Vertical,   // Left / Right (:vs)
}

PaneKind :: enum {
    Editor,
    Dired,
}

Pane :: struct {
    id     : int,
    kind   : PaneKind,
    editor : Editor,
    dired  : Dired,
    rect   : sdl.FRect,
}

SplitNode :: struct {
    is_leaf : bool,
    pane    : ^Pane,
    dir     : SplitDir,
    ratio   : f32,
    first   : ^SplitNode,
    second  : ^SplitNode,
}

pane_create :: proc(app: ^App, kind: PaneKind) -> ^Pane {
    p := new(Pane)
    p.id = app.next_pane_id
    app.next_pane_id += 1
    p.kind = kind
    dired_init(&p.dired)
    editor_init(&p.editor, &app.font, "", "")
    append(&app.panes, p)
    return p
}

pane_destroy :: proc(app: ^App, p: ^Pane) {
    editor_destroy(&p.editor)
    dired_destroy(&p.dired)
    for i := 0; i < len(app.panes); i += 1 {
        if app.panes[i] == p {
            ordered_remove(&app.panes, i)
            break
        }
    }
    free(p)
}

split_create_leaf :: proc(p: ^Pane) -> ^SplitNode {
    n := new(SplitNode)
    n.is_leaf = true
    n.pane = p
    n.ratio = 0.5
    return n
}

split_destroy_tree :: proc(node: ^SplitNode) {
    if node == nil do return
    if !node.is_leaf {
        split_destroy_tree(node.first)
        split_destroy_tree(node.second)
    }
    free(node)
}

split_compute_rects :: proc(node: ^SplitNode, rect: sdl.FRect) {
    if node == nil do return

    if node.is_leaf {
        if node.pane != nil {
            node.pane.rect = rect
        }
        return
    }

    if node.dir == .Vertical {
        w1 := (rect.w - 1.0) * node.ratio
        w2 := rect.w - 1.0 - w1
        r1 := sdl.FRect{rect.x, rect.y, w1, rect.h}
        r2 := sdl.FRect{rect.x + w1 + 1.0, rect.y, w2, rect.h}
        split_compute_rects(node.first, r1)
        split_compute_rects(node.second, r2)
    } else {
        h1 := (rect.h - 1.0) * node.ratio
        h2 := rect.h - 1.0 - h1
        r1 := sdl.FRect{rect.x, rect.y, rect.w, h1}
        r2 := sdl.FRect{rect.x, rect.y + h1 + 1.0, rect.w, h2}
        split_compute_rects(node.first, r1)
        split_compute_rects(node.second, r2)
    }
}

split_find_node_with_pane :: proc(node: ^SplitNode, p: ^Pane) -> ^SplitNode {
    if node == nil do return nil
    if node.is_leaf {
        if node.pane == p do return node
        return nil
    }
    left := split_find_node_with_pane(node.first, p)
    if left != nil do return left
    return split_find_node_with_pane(node.second, p)
}

split_find_parent :: proc(root, target: ^SplitNode) -> ^SplitNode {
    if root == nil || root.is_leaf do return nil
    if root.first == target || root.second == target do return root
    left := split_find_parent(root.first, target)
    if left != nil do return left
    return split_find_parent(root.second, target)
}

split_get_first_leaf :: proc(node: ^SplitNode) -> ^SplitNode {
    if node == nil do return nil
    if node.is_leaf do return node
    return split_get_first_leaf(node.first)
}

app_split_pane :: proc(app: ^App, target: ^Pane, dir: SplitDir) {
    if target == nil do return
    node := split_find_node_with_pane(app.root_split, target)
    if node == nil do return

    new_pane := pane_create(app, target.kind)

    if target.kind == .Editor {
        text := pt_full_text(&target.editor.table)
        defer delete(text)
        editor_destroy(&new_pane.editor)
        editor_init(&new_pane.editor, &app.font, text, target.editor.file_path)
        new_pane.editor.cursor = target.editor.cursor
        new_pane.editor.scroll_row = target.editor.scroll_row
        new_pane.editor.scroll_col = target.editor.scroll_col
    } else {
        dired_load_path(&new_pane.dired, target.dired.path)
        new_pane.dired.cursor = target.dired.cursor
        new_pane.dired.scroll = target.dired.scroll
    }

    // Convert node to branch
    first_leaf := split_create_leaf(target)
    second_leaf := split_create_leaf(new_pane)

    node.is_leaf = false
    node.dir = dir
    node.ratio = 0.5
    node.first = first_leaf
    node.second = second_leaf
    node.pane = nil

    app.active_pane = new_pane
}

app_close_pane :: proc(app: ^App, target: ^Pane) -> bool {
    if target == nil do return false
    if len(app.panes) <= 1 {
        // Closing the last remaining pane quits the editor
        app.running = false
        return true
    }

    target_node := split_find_node_with_pane(app.root_split, target)
    if target_node == nil do return false

    parent := split_find_parent(app.root_split, target_node)
    if parent == nil do return false

    sibling := parent.second if parent.first == target_node else parent.first

    // Copy sibling content into parent
    parent.is_leaf = sibling.is_leaf
    parent.pane    = sibling.pane
    parent.dir     = sibling.dir
    parent.ratio   = sibling.ratio
    parent.first   = sibling.first
    parent.second  = sibling.second

    free(target_node)
    free(sibling)

    pane_destroy(app, target)

    // Switch focus to another available pane
    first_leaf := split_get_first_leaf(app.root_split)
    if first_leaf != nil {
        app.active_pane = first_leaf.pane
    }

    return true
}

PaneDirection :: enum {
    Left,
    Right,
    Up,
    Down,
}

app_focus_dir :: proc(app: ^App, dir: PaneDirection) {
    if app.active_pane == nil || len(app.panes) <= 1 do return

    cur_rect := app.active_pane.rect
    cx := cur_rect.x + cur_rect.w * 0.5
    cy := cur_rect.y + cur_rect.h * 0.5

    best_pane: ^Pane = nil
    best_dist: f32 = 1e9

    for p in app.panes {
        if p == app.active_pane do continue
        pcx := p.rect.x + p.rect.w * 0.5
        pcy := p.rect.y + p.rect.h * 0.5

        valid := false
        #partial switch dir {
        case .Left:
            if pcx < cx - 10.0 do valid = true
        case .Right:
            if pcx > cx + 10.0 do valid = true
        case .Up:
            if pcy < cy - 10.0 do valid = true
        case .Down:
            if pcy > cy + 10.0 do valid = true
        }

        if valid {
            dx := pcx - cx
            dy := pcy - cy
            dist := dx * dx + dy * dy
            if dist < best_dist {
                best_dist = dist
                best_pane = p
            }
        }
    }

    if best_pane != nil {
        app.active_pane = best_pane
    }
}

app_cycle_pane :: proc(app: ^App) {
    if len(app.panes) <= 1 do return
    for i := 0; i < len(app.panes); i += 1 {
        if app.panes[i] == app.active_pane {
            next_idx := (i + 1) % len(app.panes)
            app.active_pane = app.panes[next_idx]
            break
        }
    }
}
