package main

import "core:fmt"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

// Plain-text search across editor, dired, and compilation buffers. Patterns
// are literal (no regex) and case-sensitive.
//
// Matches are found on a buffer's full text and mapped back to that buffer's
// cursor representation: (row, byte column) for editors and compilation
// output, and an entry index for dired listings.

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

// Matches stay painted after Enter until the next `/` clears them.
app_search_pattern :: proc(app: ^App) -> string {
    if app == nil || !app.search_highlight do return ""
    return app.last_search
}

// Shared match styling used by every buffer renderer.
draw_search_match :: proc(renderer: ^sdl.Renderer, x, y, w, h: f32) {
    band := sdl.FRect{x, y, w, h}
    sdl.SetRenderDrawColorFloat(
        renderer,
        SEARCH_HIGHLIGHT.r,
        SEARCH_HIGHLIGHT.g,
        SEARCH_HIGHLIGHT.b,
        SEARCH_HIGHLIGHT.a,
    )
    sdl.RenderFillRect(renderer, &band)

    edge := sdl.FRect{x, y + max(0.0, h - 1.5), w, 1.5}
    sdl.SetRenderDrawColorFloat(
        renderer,
        SEARCH_HIGHLIGHT_EDGE.r,
        SEARCH_HIGHLIGHT_EDGE.g,
        SEARCH_HIGHLIGHT_EDGE.b,
        SEARCH_HIGHLIGHT_EDGE.a,
    )
    sdl.RenderFillRect(renderer, &edge)
}

search_row_and_start :: proc(text: string, offset: int) -> (row, line_start: int) {
    row = 0
    line_start = 0
    for i in 0 ..< clamp(offset, 0, len(text)) {
        if text[i] == '\n' {
            row += 1
            line_start = i + 1
        }
    }
    return
}

// Every pane kind can be searched. Dired and compilation buffers use their own
// line lists, so their search text is rebuilt on demand.
app_search_pane :: proc(app: ^App) -> ^Pane {
    if app == nil || app.active_pane == nil do return nil
    p := app.active_pane
    #partial switch p.kind {
    case .Editor, .Dired, .Compilation:
        return p
    }
    return nil
}

// Joined search text for a pane. Editors use the piece table directly; dired
// listings use the displayed names (directories with a trailing slash), and
// compilation output uses its lines with newlines between them. Cursor offsets
// are computed against the same representation.
app_search_text :: proc(p: ^Pane, allocator := context.temp_allocator) -> string {
    if p == nil do return ""
    switch p.kind {
    case .Editor:
        return pt_full_text(&p.editor.buffer.table, allocator)
    case .Dired:
        if p.dired.is_editing {
            return pt_full_text(&p.editor.buffer.table, allocator)
        }
        b: strings.Builder
        strings.builder_init(&b, 0, max(64, len(p.dired.entries) * 16), allocator)
        for entry in p.dired.entries {
            strings.write_string(&b, entry.name)
            if entry.is_dir do strings.write_byte(&b, '/')
            strings.write_byte(&b, '\n')
        }
        return strings.to_string(b)
    case .Compilation:
        b: strings.Builder
        strings.builder_init(&b, 0, max(64, len(p.compilation.lines) * 32), allocator)
        for line in p.compilation.lines {
            strings.write_string(&b, line.text)
            strings.write_byte(&b, '\n')
        }
        return strings.to_string(b)
    }
    return ""
}

// Offset of the pane's current cursor in the text returned by app_search_text.
app_search_cursor_offset :: proc(p: ^Pane) -> int {
    if p == nil do return 0
    switch p.kind {
    case .Editor:
        return editor_get_cursor_offset(&p.editor)
    case .Dired:
        if p.dired.is_editing {
            return editor_get_cursor_offset(&p.editor)
        }
        offset := 0
        n := clamp(p.dired.cursor, 0, len(p.dired.entries))
        for i in 0 ..< n {
            entry := p.dired.entries[i]
            offset += len(entry.name) + 1
            if entry.is_dir do offset += 1
        }
        return offset
    case .Compilation:
        offset := 0
        n := clamp(p.compilation.cursor, 0, len(p.compilation.lines))
        for i in 0 ..< n {
            offset += len(p.compilation.lines[i].text) + 1
        }
        offset += clamp(p.compilation.cursor_col, 0, compilation_line_len(&p.compilation, n))
        return offset
    }
    return 0
}

// Record the pattern and report where the match landed. `search_direction`
// is deliberately not touched here: it is the direction of the last search
// command (`/`), so repeated n/N/p keep moving the same way instead of
// reversing on every keystroke.
app_search_commit :: proc(app: ^App, pattern: string, direction: int, wrapped: bool) {
    if app.last_search != pattern {
        new_search := strings.clone(pattern)
        if app.last_search != "" do delete(app.last_search)
        app.last_search = new_search
    }

    if wrapped {
        if direction >= 0 {
            app_set_message(app, fmt.tprintf("Search wrapped to top: %s", pattern))
        } else {
            app_set_message(app, fmt.tprintf("Search wrapped to bottom: %s", pattern))
        }
    } else {
        app_set_message(app, fmt.tprintf("/%s", pattern))
    }
}

// Moves the active buffer's cursor to the next match. Returns false when the
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

    text := app_search_text(p, context.temp_allocator)
    offset, wrapped, found := search_find_in_text(text, pattern, start_offset, direction, inclusive)
    if !found {
        app_set_message(app, fmt.tprintf("E486: Pattern not found: %s", pattern))
        return false
    }

    switch p.kind {
    case .Editor:
        search_move_editor(&p.editor, offset)
    case .Dired:
        if p.dired.is_editing {
            search_move_editor(&p.editor, offset)
        } else {
            row, _ := search_row_and_start(text, offset)
            p.dired.cursor = clamp(row, 0, max(0, len(p.dired.entries) - 1))
            p.dired.last_action = time.now()
        }
    case .Compilation:
        row, line_start := search_row_and_start(text, offset)
        c := &p.compilation
        c.cursor = clamp(row, 0, max(0, len(c.lines) - 1))
        c.cursor_col = clamp(offset - line_start, 0, compilation_line_len(c, c.cursor))
        c.desired_col = compilation_visual_col(c, c.cursor, c.cursor_col)
        c.selecting = false
        c.linewise = false
        c.dragging = false
        c.pending_g = false
    }

    app.search_highlight = true
    app_search_commit(app, pattern, direction, wrapped)
    return true
}

search_move_editor :: proc(e: ^Editor, offset: int) {
    row := pt_offset_to_line(&e.buffer.table, offset)
    line_start := pt_line_to_offset(&e.buffer.table, row)
    e.cursor.row = row
    e.cursor.col = editor_clamp_col_to_rune(e, row, offset - line_start)
    e.desired_col = editor_visual_col(e, row, e.cursor.col)
    if e.mode != .Visual do e.selection_anchor = e.cursor
    e.pending_cmd = 0
}

// Submits the `/` prompt. An empty pattern repeats the previous search.
app_submit_search :: proc(app: ^App) {
    cp := &app.cmd_prompt
    pattern := strings.clone(string(cp.buffer[:]), context.temp_allocator)
    source := cp.source_pane
    start := cp.origin_offset

    app_close_command_prompt(app)

    // Search belongs to the pane the prompt was opened from, even if a mouse
    // click moved focus while the prompt was active.
    if source != nil {
        app.active_pane = source
    }
    if app.active_pane == nil do return

    // An empty prompt repeats the last pattern from after the cursor, like
    // `n`; a freshly typed pattern may match the character under the cursor.
    repeating := pattern == ""
    if repeating {
        if app.last_search == "" {
            app_set_message(app, "E35: No previous search pattern")
            return
        }
        pattern = app.last_search
    }

    if app_search_apply(app, pattern, 1, start, !repeating) {
        // Every `/` command searches forward, including an empty repeat.
        app.search_direction = 1
    }
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

    start := app_search_cursor_offset(p)
    // A dired cursor identifies an entry, not the matched bytes within it.
    // Move forward from the end of that entry so `n` cannot match it again.
    if direction > 0 && p.kind == .Dired && !p.dired.is_editing {
        if p.dired.cursor >= 0 && p.dired.cursor < len(p.dired.entries) {
            entry := p.dired.entries[p.dired.cursor]
            start += len(entry.name) + (1 if entry.is_dir else 0)
        }
    }
    _ = app_search_apply(app, app.last_search, direction, start, false)
}

// Esc in the search prompt restores the view it was opened from.
app_cancel_search_prompt :: proc(app: ^App) {
    cp := &app.cmd_prompt
    if cp.source_pane != nil {
        p := cp.source_pane
        switch p.kind {
        case .Editor:
            search_restore_editor(&p.editor, cp.origin_row, cp.origin_col, cp.origin_scroll_row, cp.origin_scroll_col)
        case .Dired:
            if p.dired.is_editing {
                search_restore_editor(&p.editor, cp.origin_row, cp.origin_col, cp.origin_scroll_row, cp.origin_scroll_col)
            } else {
                p.dired.cursor = cp.origin_row
                p.dired.scroll = cp.origin_scroll_row
            }
        case .Compilation:
            c := &p.compilation
            c.cursor = cp.origin_row
            c.cursor_col = cp.origin_col
            c.desired_col = compilation_visual_col(c, c.cursor, c.cursor_col)
            c.scroll = cp.origin_scroll_row
        }
    }
    app_close_command_prompt(app)
}

search_restore_editor :: proc(e: ^Editor, row, col, scroll_row, scroll_col: int) {
    e.cursor.row = row
    e.cursor.col = col
    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
    e.selection_anchor = e.cursor
    e.scroll_row = scroll_row
    e.scroll_col = scroll_col
}
