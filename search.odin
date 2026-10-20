package main

import "core:fmt"
import "core:strings"

// Plain-text search. Patterns are literal (no regex), matching Vim's `/`
// navigation without pulling a regex engine into every keystroke.
//
// The search works on the full document text and maps the match offset back to
// a line and byte column. Matching is case-sensitive.

Search_Match :: struct {
    offset  : int,
    row     : int,
    col     : int,
    wrapped : bool,
    found   : bool,
}

// Finds `pattern` at/after `start_offset` (forward) or before it (backward).
// `inclusive` includes a match starting exactly at start_offset. When nothing
// matches in the requested direction, the search wraps around the document.
search_find_in_text :: proc(
    text, pattern: string,
    start_offset, direction: int,
    inclusive: bool,
) -> (offset: int, wrapped: bool, found: bool) {
    if pattern == "" || len(text) == 0 do return 0, false, false

    n := len(text)
    start := clamp(start_offset, 0, n)

    if direction >= 0 {
        from := start
        if !inclusive {
            from = min(n, start + 1)
        }
        if from < n {
            if idx := strings.index(text[from:], pattern); idx >= 0 {
                return from + idx, false, true
            }
        }
        if idx := strings.index(text, pattern); idx >= 0 {
            return idx, true, true
        }
        return 0, false, false
    }

    // Backward: remember the last match at or before the limit, scanning from
    // the start so overlapping occurrences are all considered.
    limit := start if inclusive else start - 1
    last := -1
    i := 0
    for i < n {
        idx := strings.index(text[i:], pattern)
        if idx < 0 do break
        abs := i + idx
        if abs > limit do break
        last = abs
        i = abs + 1
    }
    if last >= 0 do return last, false, true

    // Nothing before the cursor: wrap to the last occurrence in the document.
    last = -1
    i = 0
    for i < n {
        idx := strings.index(text[i:], pattern)
        if idx < 0 do break
        abs := i + idx
        last = abs
        i = abs + 1
    }
    if last >= 0 do return last, true, true
    return 0, false, false
}

app_search_pane :: proc(app: ^App) -> ^Pane {
    if app == nil || app.active_pane == nil do return nil
    p := app.active_pane
    if p.kind == .Editor do return p
    if p.kind == .Dired && p.dired.is_editing do return p
    return nil
}

// Moves the active editor view to the next match. Returns false when the
// pattern is not found (the cursor is left where it was).
app_search_apply :: proc(
    app: ^App,
    pattern: string,
    direction: int,
    start_offset: int,
    inclusive: bool,
) -> bool {
    p := app_search_pane(app)
    if p == nil || pattern == "" do return false
    e := &p.editor

    text := pt_full_text(&e.buffer.table)
    defer delete(text)

    offset, wrapped, found := search_find_in_text(text, pattern, start_offset, direction, inclusive)
    if !found {
        app_set_message(app, fmt.tprintf("E486: Pattern not found: %s", pattern))
        return false
    }

    row := pt_offset_to_line(&e.buffer.table, offset)
    line_start := pt_line_to_offset(&e.buffer.table, row)
    e.cursor.row = row
    e.cursor.col = editor_clamp_col_to_rune(e, row, offset - line_start)
    e.desired_col = editor_visual_col(e, row, e.cursor.col)
    if e.mode != .Visual {
        e.selection_anchor = e.cursor
    }
    e.pending_cmd = 0

    if app.last_search != pattern {
        new_search := strings.clone(pattern)
        if app.last_search != "" do delete(app.last_search)
        app.last_search = new_search
    }
    app.search_direction = direction

    if wrapped {
        if direction >= 0 {
            app_set_message(app, fmt.tprintf("Search wrapped to top: %s", pattern))
        } else {
            app_set_message(app, fmt.tprintf("Search wrapped to bottom: %s", pattern))
        }
    } else {
        app_set_message(app, fmt.tprintf("/%s", pattern))
    }
    return true
}

// Submits the `/` prompt. An empty pattern repeats the previous search.
app_submit_search :: proc(app: ^App) {
    cp := &app.cmd_prompt
    pattern := strings.clone(string(cp.buffer[:]), context.temp_allocator)
    source := cp.source_pane
    origin_row := cp.origin_row
    origin_col := cp.origin_col

    app_close_command_prompt(app)

    // Search belongs to the pane the prompt was opened from, even if a mouse
    // click moved focus while the prompt was active.
    if source != nil {
        app.active_pane = source
    }
    if app.active_pane == nil do return

    if pattern == "" {
        if app.last_search == "" {
            app_set_message(app, "E35: No previous search pattern")
            return
        }
        pattern = app.last_search
    }

    p := app_search_pane(app)
    if p == nil do return
    e := &p.editor
    row := clamp(origin_row, 0, pt_get_line_count(&e.buffer.table))
    col := clamp(origin_col, 0, editor_get_line_len(e, row))
    start := pt_line_to_offset(&e.buffer.table, row) + col
    _ = app_search_apply(app, pattern, 1, start, true)
}

// `n` and `N`: repeat the last search in the current or opposite direction.
app_search_repeat :: proc(app: ^App, reverse: bool) {
    if app == nil do return
    if app.last_search == "" {
        app_set_message(app, "E35: No previous search pattern")
        return
    }
    p := app_search_pane(app)
    if p == nil do return

    direction := app.search_direction
    if direction == 0 do direction = 1
    if reverse do direction = -direction

    start := editor_get_cursor_offset(&p.editor)
    _ = app_search_apply(app, app.last_search, direction, start, false)
}

// Esc in the search prompt restores the view it was opened from.
app_cancel_search_prompt :: proc(app: ^App) {
    cp := &app.cmd_prompt
    if cp.source_pane != nil {
        e := &cp.source_pane.editor
        e.cursor.row = cp.origin_row
        e.cursor.col = cp.origin_col
        e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
        e.selection_anchor = e.cursor
        e.scroll_row = cp.origin_scroll_row
        e.scroll_col = cp.origin_scroll_col
    }
    app_close_command_prompt(app)
}
