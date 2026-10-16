package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

EditorMode :: enum {
    Normal,
    Insert,
}

Editor :: struct {
    table        : PieceTable,
    cursor       : Cursor,
    mode         : EditorMode,
    scroll_row   : int,
    scroll_col   : int,
    last_action  : time.Time,
    pending_cmd  : rune,
    font_scale   : FONT_SCALE,
    char_advance : f32,
    file_path    : string,
    dirty        : bool,
}

editor_init :: proc(e: ^Editor, font: ^Font, initial_text := "", file_path := "") {
    pt_init(&e.table, initial_text)
    e.char_advance = find_biggest_advance(font)
    e.font_scale = .HALF
    e.mode = .Normal
    e.cursor = Cursor{
        col   = 0,
        row   = 0,
        shape = .Block,
        color = sdl.FColor{0.92, 0.92, 0.92, 1.0},
    }
    e.scroll_row = 0
    e.scroll_col = 0
    e.last_action = time.now()
    e.pending_cmd = 0
    e.file_path = file_path
    e.dirty = false
}

editor_destroy :: proc(e: ^Editor) {
    pt_destroy(&e.table)
}

editor_get_line_len :: proc(e: ^Editor, row: int) -> int {
    total_lines := pt_get_line_count(&e.table) + 1
    if row < 0 || row >= total_lines do return 0

    start_off := pt_line_to_offset(&e.table, row)
    if row + 1 < total_lines {
        next_off := pt_line_to_offset(&e.table, row + 1)
        len := next_off - start_off - 1
        if len > 0 && pt_byte_at(&e.table, start_off + len - 1) == '\r' {
            len -= 1
        }
        return max(0, len)
    } else {
        total_len := pt_get_length(&e.table)
        return max(0, total_len - start_off)
    }
}

editor_get_cursor_offset :: proc(e: ^Editor) -> int {
    start_off := pt_line_to_offset(&e.table, e.cursor.row)
    line_len := editor_get_line_len(e, e.cursor.row)
    col := clamp(e.cursor.col, 0, line_len)
    return start_off + col
}

editor_clamp_cursor :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    e.cursor.row = clamp(e.cursor.row, 0, max(0, total_lines - 1))
    line_len := editor_get_line_len(e, e.cursor.row)
    if e.mode == .Normal {
        e.cursor.col = clamp(e.cursor.col, 0, max(0, line_len - 1))
    } else {
        e.cursor.col = clamp(e.cursor.col, 0, line_len)
    }
}

editor_scroll_to_cursor :: proc(e: ^Editor, visible_lines: int, visible_cols: int) {
    if visible_lines <= 0 || visible_cols <= 0 do return

    margin := 2
    if visible_lines <= 4 do margin = 0

    if e.cursor.row < e.scroll_row + margin {
        e.scroll_row = max(0, e.cursor.row - margin)
    } else if e.cursor.row >= e.scroll_row + visible_lines - margin {
        e.scroll_row = e.cursor.row - visible_lines + 1 + margin
    }

    if e.cursor.col < e.scroll_col {
        e.scroll_col = e.cursor.col
    } else if e.cursor.col >= e.scroll_col + visible_cols {
        e.scroll_col = e.cursor.col - visible_cols + 1
    }
}

editor_set_mode :: proc(e: ^Editor, new_mode: EditorMode, window: ^sdl.Window) {
    e.mode = new_mode
    e.last_action = time.now()
    e.pending_cmd = 0

    if new_mode == .Insert {
        e.cursor.shape = .Bar
        _ = sdl.StartTextInput(window)
    } else {
        e.cursor.shape = .Block
        _ = sdl.StopTextInput(window)
        editor_clamp_cursor(e)
    }
}

editor_save_file :: proc(e: ^Editor) -> bool {
    if e.file_path == "" do return false
    full := pt_full_text(&e.table)
    defer delete(full)
    err := os.write_entire_file(e.file_path, transmute([]u8)full)
    if err == nil {
        e.dirty = false
        return true
    }
    return false
}

editor_delete_current_line :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    start_off := pt_line_to_offset(&e.table, e.cursor.row)

    if e.cursor.row + 1 < total_lines {
        next_off := pt_line_to_offset(&e.table, e.cursor.row + 1)
        pt_delete_range(&e.table, start_off, next_off - start_off)
    } else if e.cursor.row > 0 {
        prev_start := pt_line_to_offset(&e.table, e.cursor.row - 1)
        prev_len := editor_get_line_len(e, e.cursor.row - 1)
        del_start := prev_start + prev_len
        total_len := pt_get_length(&e.table)
        pt_delete_range(&e.table, del_start, total_len - del_start)
        e.cursor.row -= 1
    } else {
        total_len := pt_get_length(&e.table)
        if total_len > 0 {
            pt_delete_range(&e.table, 0, total_len)
        }
        e.cursor.col = 0
    }
    e.dirty = true
    editor_clamp_cursor(e)
}

editor_handle_insert_key :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod, window: ^sdl.Window) -> bool {
    switch key {
    case sdl.K_ESCAPE:
        editor_set_mode(e, .Normal, window)
        return true

    case sdl.K_RETURN, sdl.K_KP_ENTER:
        offset := editor_get_cursor_offset(e)
        pt_insert(&e.table, offset, "\n")
        e.cursor.row += 1
        e.cursor.col = 0
        e.dirty = true
        return true

    case sdl.K_TAB:
        offset := editor_get_cursor_offset(e)
        pt_insert(&e.table, offset, "    ")
        e.cursor.col += 4
        e.dirty = true
        return true

    case sdl.K_BACKSPACE:
        if e.cursor.col > 0 {
            offset := editor_get_cursor_offset(e)
            pt_delete_range(&e.table, offset - 1, 1)
            e.cursor.col -= 1
            e.dirty = true
        } else if e.cursor.row > 0 {
            prev_len := editor_get_line_len(e, e.cursor.row - 1)
            offset := pt_line_to_offset(&e.table, e.cursor.row)
            del_len := 1
            del_pos := offset - 1
            if del_pos > 0 && pt_byte_at(&e.table, del_pos - 1) == '\r' {
                del_pos -= 1
                del_len = 2
            }
            pt_delete_range(&e.table, del_pos, del_len)
            e.cursor.row -= 1
            e.cursor.col = prev_len
            e.dirty = true
        }
        return true

    case sdl.K_DELETE:
        offset := editor_get_cursor_offset(e)
        if offset < pt_get_length(&e.table) {
            del_len := 1
            if pt_byte_at(&e.table, offset) == '\r' &&
               offset + 1 < pt_get_length(&e.table) &&
               pt_byte_at(&e.table, offset + 1) == '\n' {
                del_len = 2
            }
            pt_delete_range(&e.table, offset, del_len)
            e.dirty = true
        }
        return true

    case sdl.K_LEFT:
        e.cursor.col = max(0, e.cursor.col - 1)
        return true

    case sdl.K_RIGHT:
        line_len := editor_get_line_len(e, e.cursor.row)
        e.cursor.col = min(line_len, e.cursor.col + 1)
        return true

    case sdl.K_UP:
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            line_len := editor_get_line_len(e, e.cursor.row)
            e.cursor.col = min(line_len, e.cursor.col)
        }
        return true

    case sdl.K_DOWN:
        total_lines := pt_get_line_count(&e.table) + 1
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            line_len := editor_get_line_len(e, e.cursor.row)
            e.cursor.col = min(line_len, e.cursor.col)
        }
        return true
    }
    return false
}

editor_handle_normal_key :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod, window: ^sdl.Window) -> bool {
    total_lines := pt_get_line_count(&e.table) + 1
    line_len := editor_get_line_len(e, e.cursor.row)
    is_shift := (mod & sdl.KMOD_SHIFT) != {}

    // Multi-key commands
    if e.pending_cmd == 'd' {
        e.pending_cmd = 0
        if key == sdl.K_D {
            editor_delete_current_line(e)
            return true
        }
    }

    if e.pending_cmd == 'g' {
        e.pending_cmd = 0
        if key == sdl.K_G {
            e.cursor.row = 0
            e.cursor.col = 0
            return true
        }
    }

    switch key {
    // Navigation: hjkl
    case sdl.K_H, sdl.K_LEFT:
        e.cursor.col = max(0, e.cursor.col - 1)
        return true

    case sdl.K_L, sdl.K_RIGHT:
        max_col := max(0, line_len - 1)
        e.cursor.col = min(max_col, e.cursor.col + 1)
        return true

    case sdl.K_J, sdl.K_DOWN:
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            new_len := editor_get_line_len(e, e.cursor.row)
            e.cursor.col = min(max(0, new_len - 1), e.cursor.col)
        }
        return true

    case sdl.K_K, sdl.K_UP:
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            new_len := editor_get_line_len(e, e.cursor.row)
            e.cursor.col = min(max(0, new_len - 1), e.cursor.col)
        }
        return true

    // Line start / end
    case sdl.K_0:
        e.cursor.col = 0
        return true

    case sdl.K_4:
        if is_shift {
            e.cursor.col = max(0, line_len - 1)
            return true
        }

    // Top / bottom
    case sdl.K_G:
        if is_shift {
            e.cursor.row = max(0, total_lines - 1)
            e.cursor.col = 0
        } else {
            e.pending_cmd = 'g'
        }
        return true

    // Enter Insert Mode
    case sdl.K_I:
        if is_shift {
            e.cursor.col = 0
        }
        editor_set_mode(e, .Insert, window)
        return true

    case sdl.K_A:
        if is_shift {
            e.cursor.col = line_len
        } else {
            e.cursor.col = min(line_len, e.cursor.col + 1)
        }
        editor_set_mode(e, .Insert, window)
        return true

    // New lines
    case sdl.K_O:
        if is_shift {
            start_off := pt_line_to_offset(&e.table, e.cursor.row)
            pt_insert(&e.table, start_off, "\n")
            e.cursor.col = 0
        } else {
            start_off := pt_line_to_offset(&e.table, e.cursor.row)
            insert_pos := start_off + line_len
            pt_insert(&e.table, insert_pos, "\n")
            e.cursor.row += 1
            e.cursor.col = 0
        }
        e.dirty = true
        editor_set_mode(e, .Insert, window)
        return true

    // Deletions
    case sdl.K_X:
        if line_len > 0 {
            offset := editor_get_cursor_offset(e)
            pt_delete_range(&e.table, offset, 1)
            new_len := editor_get_line_len(e, e.cursor.row)
            e.cursor.col = min(max(0, new_len - 1), e.cursor.col)
            e.dirty = true
        }
        return true

    case sdl.K_D:
        e.pending_cmd = 'd'
        return true

    // Undo / Redo
    case sdl.K_U:
        pt_undo(&e.table)
        e.dirty = true
        editor_clamp_cursor(e)
        return true
    }

    return false
}

editor_handle_event :: proc(e: ^Editor, event: ^sdl.Event, window: ^sdl.Window) -> bool {
    #partial switch event.type {
    case .TEXT_INPUT:
        if e.mode == .Insert {
            text_str := string(event.text.text)
            if len(text_str) > 0 {
                offset := editor_get_cursor_offset(e)
                pt_insert(&e.table, offset, text_str)
                e.cursor.col += len(text_str)
                e.dirty = true
                e.last_action = time.now()
            }
            return true
        }

    case .KEY_DOWN:
        e.last_action = time.now()
        key := event.key.key
        mod := event.key.mod
        is_ctrl := (mod & sdl.KMOD_CTRL) != {}

        // Ctrl+S to save
        if is_ctrl && key == sdl.K_S {
            editor_save_file(e)
            return true
        }

        // Ctrl+Z for Undo
        if is_ctrl && key == sdl.K_Z {
            pt_undo(&e.table)
            e.dirty = true
            editor_clamp_cursor(e)
            return true
        }

        // Ctrl+R for Redo
        if is_ctrl && key == sdl.K_R {
            pt_redo(&e.table)
            e.dirty = true
            editor_clamp_cursor(e)
            return true
        }

        if e.mode == .Insert {
            return editor_handle_insert_key(e, key, mod, window)
        } else {
            return editor_handle_normal_key(e, key, mod, window)
        }

    case .MOUSE_WHEEL:
        if event.wheel.y > 0 {
            e.scroll_row = max(0, e.scroll_row - 3)
        } else if event.wheel.y < 0 {
            total_lines := pt_get_line_count(&e.table) + 1
            e.scroll_row = min(max(0, total_lines - 1), e.scroll_row + 3)
        }
        return true
    }

    return false
}

editor_render :: proc(e: ^Editor, renderer: ^sdl.Renderer, font: ^Font, window_w, window_h: i32) {
    scale := get_font_scale_multiplier(e.font_scale)
    line_h := get_line_height(e.font_scale)
    char_w := e.char_advance * scale

    total_lines := pt_get_line_count(&e.table) + 1

    status_bar_h := line_h + 8.0
    editor_h := f32(window_h) - status_bar_h

    // Calculate gutter width based on line count digits
    digits := 1
    tmp := total_lines
    for tmp >= 10 {
        tmp /= 10
        digits += 1
    }
    digits = max(3, digits)
    gutter_w := f32(digits + 2) * char_w

    visible_lines := int(editor_h / line_h)
    visible_cols := int((f32(window_w) - gutter_w) / char_w)

    editor_scroll_to_cursor(e, visible_lines, visible_cols)

    // 1. Background
    bg_color := sdl.FColor{0.08, 0.08, 0.1, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    sdl.RenderClear(renderer)

    // 2. Gutter background
    gutter_rect := sdl.FRect{
        x = 0,
        y = 0,
        w = gutter_w,
        h = editor_h,
    }
    sdl.SetRenderDrawColor(renderer, 30, 30, 34, 255)
    sdl.RenderFillRect(renderer, &gutter_rect)

    // 3. Gutter separator line
    sep_rect := sdl.FRect{
        x = gutter_w - 1.0,
        y = 0,
        w = 1.0,
        h = editor_h,
    }
    sdl.SetRenderDrawColor(renderer, 48, 48, 56, 255)
    sdl.RenderFillRect(renderer, &sep_rect)

    // 4. Current line highlight
    if e.cursor.row >= e.scroll_row && e.cursor.row < e.scroll_row + visible_lines {
        hl_y := f32(e.cursor.row - e.scroll_row) * line_h
        hl_rect := sdl.FRect{
            x = gutter_w,
            y = hl_y,
            w = f32(window_w) - gutter_w,
            h = line_h,
        }
        sdl.SetRenderDrawColor(renderer, 32, 34, 40, 255)
        sdl.RenderFillRect(renderer, &hl_rect)
    }

    // 5. Block Cursor (rendered behind text)
    cx := gutter_w + 4.0 + f32(e.cursor.col - e.scroll_col) * char_w
    cy := f32(e.cursor.row - e.scroll_row) * line_h
    cursor_visible := cursor_is_visible(&e.cursor, e.last_action)

    if e.cursor.shape == .Block {
        render_cursor(&e.cursor, renderer, cx, cy, char_w, line_h, e.last_action)
    }

    // 6. Push visible lines into font batcher
    code_text_color := sdl.FColor{0.9, 0.9, 0.9, 1.0}
    inverted_cursor_char_color := bg_color
    active_line_num_color := sdl.FColor{0.95, 0.85, 0.45, 1.0}
    normal_line_num_color := sdl.FColor{0.4, 0.45, 0.5, 1.0}

    for i in 0 ..< visible_lines {
        line_idx := e.scroll_row + i
        if line_idx >= total_lines do break

        y_pos := f32(i) * line_h

        // Line number in gutter
        line_num_str := fmt.tprintf("%*d ", digits, line_idx + 1)
        ln_color := normal_line_num_color
        if line_idx == e.cursor.row {
            ln_color = active_line_num_color
        }
        push_line(font, line_num_str, Vec2{char_w * 0.5, y_pos}, ln_color, e.font_scale)

        // Line text
        line_str, ok := pt_line_text(&e.table, line_idx)
        if ok {
            defer delete(line_str)
            if e.scroll_col < len(line_str) {
                visible_str := line_str[e.scroll_col:]

                // Invert character color under normal-mode block cursor
                hl_col := -1
                if e.mode == .Normal && cursor_visible && line_idx == e.cursor.row {
                    hl_col = e.cursor.col - e.scroll_col
                }

                push_editor_line(
                    font,
                    visible_str,
                    Vec2{gutter_w + 4.0, y_pos},
                    code_text_color,
                    e.font_scale,
                    hl_col,
                    inverted_cursor_char_color,
                )
            }
        }
    }

    // 7. Status Bar
    status_bar_rect := sdl.FRect{
        x = 0,
        y = editor_h,
        w = f32(window_w),
        h = status_bar_h,
    }
    sdl.SetRenderDrawColor(renderer, 35, 38, 48, 255)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    mode_text := e.mode == .Normal ? "-- NORMAL --" : "-- INSERT --"
    status_color := sdl.FColor{0.4, 0.8, 0.5, 1.0}
    if e.mode == .Insert {
        status_color = sdl.FColor{0.9, 0.6, 0.2, 1.0}
    }

    dirty_indicator := e.dirty ? " [+]" : ""
    file_display := e.file_path != "" ? e.file_path : "Untitled"
    status_info := fmt.tprintf("%s   %s%s   Line %d/%d, Col %d", mode_text, file_display, dirty_indicator, e.cursor.row + 1, total_lines, e.cursor.col + 1)

    push_line(font, status_info, Vec2{10.0, editor_h + 4.0}, status_color, e.font_scale)

    // Single flush for all text
    flush_text(font, renderer)

    // 8. Bar Cursor (rendered on top of text in Insert Mode)
    if e.cursor.shape == .Bar {
        render_cursor(&e.cursor, renderer, cx, cy, char_w, line_h, e.last_action)
    }
}
