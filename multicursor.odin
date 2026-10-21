package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// Manual multi-cursor support. Shift+C over an active search places one cursor
// at every match; text input and Backspace/Delete then apply at all cursors.

Multi_Entry :: struct {
    row     : int,
    col     : int,
    offset  : int,
    primary : bool,
}

multi_collect_entries :: proc(e: ^Editor) -> [dynamic]Multi_Entry {
    entries := make([dynamic]Multi_Entry, 0, len(e.extra_cursors) + 1, context.temp_allocator)
    append(&entries, Multi_Entry{
        row = e.cursor.row,
        col = e.cursor.col,
        offset = editor_get_cursor_offset(e),
        primary = true,
    })
    for c in e.extra_cursors {
        row := clamp(c.row, 0, pt_get_line_count(&e.buffer.table))
        col := clamp(c.col, 0, editor_get_line_len(e, row))
        append(&entries, Multi_Entry{
            row = row,
            col = col,
            offset = pt_line_to_offset(&e.buffer.table, row) + col,
        })
    }

    // Ascending offset order lets each edit account for the bytes inserted or
    // removed before it.
    for i in 1 ..< len(entries) {
        key := entries[i]
        j := i - 1
        for j >= 0 && entries[j].offset > key.offset {
            entries[j + 1] = entries[j]
            j -= 1
        }
        entries[j + 1] = key
    }
    return entries
}

multi_store_entries :: proc(e: ^Editor, entries: []Multi_Entry) {
    clear(&e.extra_cursors)
    for entry in entries {
        if entry.primary {
            e.cursor.row = entry.row
            e.cursor.col = entry.col
        } else {
            append(&e.extra_cursors, Cursor{
                row = entry.row,
                col = entry.col,
                shape = e.cursor.shape,
                color = e.cursor.color,
            })
        }
    }
    e.selection_anchor = e.cursor
    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
}

multi_advance :: proc(row, col: int, text: string) -> (int, int) {
    newline_count := 0
    last_newline := -1
    for ch, i in text {
        if ch == '\n' {
            newline_count += 1
            last_newline = i
        }
    }
    if last_newline >= 0 {
        return row + newline_count, len(text) - last_newline - 1
    }
    return row, col + len(text)
}

editor_clear_extra_cursors :: proc(e: ^Editor) {
    if e == nil do return
    clear(&e.extra_cursors)
}

// Places a cursor at every occurrence of the active search pattern. The first
// match becomes the primary cursor. Respects a scoped search range.
editor_place_multi_cursors :: proc(e: ^Editor, app: ^App) -> bool {
    if e == nil || app == nil do return false
    clear(&e.extra_cursors)

    if app.last_search == "" || !app.search_highlight {
        app_set_message(app, "E: No highlighted search matches")
        return false
    }

    text := pt_full_text(&e.buffer.table, context.temp_allocator)
    lo := 0
    hi := len(text)
    if app.search_scoped && app.search_scope_pane == app.active_pane {
        lo = clamp(app.search_scope_start, 0, len(text))
        hi = clamp(app.search_scope_end, lo, len(text))
    }

    count := 0
    i := lo
    for i < hi {
        idx := strings.index(text[i:hi], app.last_search)
        if idx < 0 do break
        offset := i + idx
        i = offset + 1

        row := pt_offset_to_line(&e.buffer.table, offset)
        line_start := pt_line_to_offset(&e.buffer.table, row)
        col := editor_clamp_col_to_rune(e, row, offset - line_start)
        count += 1

        if count == 1 {
            e.cursor.row = row
            e.cursor.col = col
            e.selection_anchor = e.cursor
        } else if len(e.extra_cursors) < MULTI_CURSOR_LIMIT {
            append(&e.extra_cursors, Cursor{
                row = row,
                col = col,
                shape = e.cursor.shape,
                color = e.cursor.color,
            })
        }
    }

    if count == 0 {
        app_set_message(app, fmt.tprintf("E: No matches for %s", app.last_search))
        return false
    }

    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
    if count > MULTI_CURSOR_LIMIT + 1 {
        app_set_message(app, fmt.tprintf("%d cursors (limit %d)", MULTI_CURSOR_LIMIT + 1, MULTI_CURSOR_LIMIT + 1))
    } else {
        app_set_message(app, fmt.tprintf("%d cursors", count))
    }
    return true
}

// Inserts text at every cursor as one undo step.
editor_insert_text_multi :: proc(e: ^Editor, text: string) -> bool {
    if e == nil || len(text) == 0 || len(e.extra_cursors) == 0 do return false

    e.completion.active = false
    entries := multi_collect_entries(e)
    defer delete(entries)

    editor_begin_undo_transaction(e)
    defer editor_end_undo_transaction(e)

    // Insert in ascending order, tracking how many bytes earlier insertions
    // added. Every cursor then lands after its own insertion in the final
    // document, including shifts from cursors earlier on the line.
    shift := 0
    previous_original := -1
    previous_final := 0
    for &entry in entries {
        if entry.offset == previous_original {
            entry.offset = previous_final
            continue
        }
        adjusted := entry.offset + shift
        pt_insert(&e.buffer.table, adjusted, text)
        previous_original = entry.offset
        shift += len(text)
        previous_final = adjusted + len(text)
        entry.offset = previous_final
    }

    min_row := max(0, pt_get_line_count(&e.buffer.table))
    for &entry in entries {
        row := pt_offset_to_line(&e.buffer.table, entry.offset)
        line_start := pt_line_to_offset(&e.buffer.table, row)
        entry.row = row
        entry.col = entry.offset - line_start
        min_row = min(min_row, row)
    }

    multi_store_entries(e, entries[:])
    editor_mark_dirty(e, min_row)
    return true
}

// Deletes one rune (backward) or one rune ahead (forward) at every cursor.
editor_delete_multi :: proc(e: ^Editor, backward: bool) -> bool {
    if e == nil || len(e.extra_cursors) == 0 do return false
    if e.read_only do return false

    entries := multi_collect_entries(e)
    defer delete(entries)

    Range :: struct {
        start, end: int,
    }
    ranges := make([dynamic]Range, 0, len(entries), context.temp_allocator)
    defer delete(ranges)
    targets := make([dynamic]int, 0, len(entries), context.temp_allocator)
    defer delete(targets)
    virtual := make([dynamic]bool, 0, len(entries), context.temp_allocator)
    defer delete(virtual)

    total := pt_get_length(&e.buffer.table)
    min_row := e.cursor.row

    for &entry in entries {
        line_len := editor_get_line_len(e, entry.row)
        target := entry.offset
        is_virtual := false
        if backward {
            if entry.col > line_len {
                is_virtual = true
                min_row = min(min_row, entry.row)
            } else if entry.col > 0 {
                prev := editor_prev_rune_start(e, entry.row, entry.col)
                target = entry.offset - (entry.col - prev)
                append(&ranges, Range{target, entry.offset})
                min_row = min(min_row, entry.row)
            } else if entry.row > 0 {
                offset := pt_line_to_offset(&e.buffer.table, entry.row)
                del_len := 1
                if offset >= 2 && pt_byte_at(&e.buffer.table, offset - 1) == '\n' &&
                   pt_byte_at(&e.buffer.table, offset - 2) == '\r' {
                    del_len = 2
                }
                target = offset - del_len
                append(&ranges, Range{target, offset})
                min_row = min(min_row, entry.row - 1)
            }
        } else {
            if entry.offset >= total do continue
            del_len := 1
            if entry.col < line_len {
                _, size := editor_rune_at(e, entry.row, entry.col)
                if size > 0 do del_len = size
            } else if pt_byte_at(&e.buffer.table, entry.offset) == '\r' &&
               entry.offset + 1 < total &&
               pt_byte_at(&e.buffer.table, entry.offset + 1) == '\n' {
                del_len = 2
            }
            append(&ranges, Range{entry.offset, entry.offset + del_len})
            min_row = min(min_row, entry.row)
        }
        append(&targets, target)
        append(&virtual, is_virtual)
    }

    // Apply deletions from the end of the buffer backwards, skipping any that
    // overlap a range already removed.
    for i in 1 ..< len(ranges) {
        key := ranges[i]
        j := i - 1
        for j >= 0 && ranges[j].start < key.start {
            ranges[j + 1] = ranges[j]
            j -= 1
        }
        ranges[j + 1] = key
    }
    applied := make([dynamic]Range, 0, len(ranges), context.temp_allocator)
    defer delete(applied)
    limit := total
    for r in ranges {
        end := min(r.end, limit)
        if r.start >= end do continue
        pt_delete_range(&e.buffer.table, r.start, end - r.start)
        append(&applied, Range{r.start, end})
        limit = r.start
    }

    // Cursor targets shift left by every applied deletion before them.
    for &entry, i in entries {
        target := targets[i]
        shift := 0
        for r in applied {
            if r.start < target do shift += r.end - r.start
        }
        final := max(0, target - shift)
        row := pt_offset_to_line(&e.buffer.table, final)
        line_start := pt_line_to_offset(&e.buffer.table, row)
        entry.row = row
        entry.col = final - line_start
        if virtual[i] && entry.col > 0 do entry.col -= 1
    }

    multi_store_entries(e, entries[:])
    editor_mark_dirty(e, min_row)
    return true
}

multi_move_left :: proc(e: ^Editor, c: ^Cursor) {
    line_len := editor_get_line_len(e, c.row)
    if c.col > line_len {
        c.col -= 1
    } else {
        c.col = editor_prev_rune_start(e, c.row, c.col)
    }
}

multi_move_right :: proc(e: ^Editor, c: ^Cursor) {
    line_len := editor_get_line_len(e, c.row)
    if c.col < line_len {
        c.col = editor_next_rune_end(e, c.row, c.col)
    } else {
        c.col += 1
    }
}

// Moves the primary and all extra cursors together for the basic horizontal
// and vertical motions. Returns false for keys it does not handle.
editor_move_all_cursors :: proc(e: ^Editor, key: sdl.Keycode) -> bool {
    if e == nil || len(e.extra_cursors) == 0 do return false
    total_lines := pt_get_line_count(&e.buffer.table) + 1

    switch key {
    case KEY_MOVE_LEFT, sdl.K_LEFT:
        multi_move_left(e, &e.cursor)
        for &c in e.extra_cursors do multi_move_left(e, &c)
    case KEY_MOVE_RIGHT, sdl.K_RIGHT:
        multi_move_right(e, &e.cursor)
        for &c in e.extra_cursors do multi_move_right(e, &c)
    case KEY_MOVE_DOWN, sdl.K_DOWN:
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = editor_col_for_vertical_move(e, e.cursor.row)
        }
        for &c in e.extra_cursors {
            if c.row + 1 < total_lines {
                c.row += 1
                c.col = min(c.col, editor_get_line_len(e, c.row))
            }
        }
    case KEY_MOVE_UP, sdl.K_UP:
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = editor_col_for_vertical_move(e, e.cursor.row)
        }
        for &c in e.extra_cursors {
            if c.row > 0 {
                c.row -= 1
                c.col = min(c.col, editor_get_line_len(e, c.row))
            }
        }
    case:
        return false
    }

    e.desired_col = editor_visual_col(e, e.cursor.row, e.cursor.col)
    return true
}

// All match offsets for the active search, used by block/other callers.
multi_match_offsets :: proc(e: ^Editor, pattern: string, scoped: bool, scope_start, scope_end: int) -> [dynamic]int {
    result := make([dynamic]int, 0, 16, context.temp_allocator)
    if e == nil || pattern == "" do return result
    text := pt_full_text(&e.buffer.table, context.temp_allocator)
    lo := 0
    hi := len(text)
    if scoped {
        lo = clamp(scope_start, 0, len(text))
        hi = clamp(scope_end, lo, len(text))
    }
    i := lo
    for i < hi {
        idx := strings.index(text[i:hi], pattern)
        if idx < 0 do break
        append(&result, i + idx)
        i = i + idx + 1
    }
    return result
}
