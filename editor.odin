package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

EditorMode :: enum {
    Normal,
    Insert,
    Visual,
    Command,
}

Editor :: struct {
    table            : PieceTable,
    cursor           : Cursor,
    selection_anchor : Cursor,
    mode             : EditorMode,
    scroll_row       : int,
    scroll_col       : int,
    last_action      : time.Time,
    pending_cmd      : rune,
    font_scale       : FONT_SCALE,
    char_advance     : f32,
    file_path        : string,
    dirty            : bool,
    command_buffer   : [dynamic]u8,
    status_message   : string,
    desired_col      : int,
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
    e.selection_anchor = e.cursor
    e.desired_col = 0
    e.scroll_row = 0
    e.scroll_col = 0
    e.last_action = time.now()
    e.pending_cmd = 0
    e.file_path = strings.clone(file_path)
    e.dirty = false
    e.command_buffer = make([dynamic]u8, context.allocator)
    e.status_message = ""
}

editor_destroy :: proc(e: ^Editor) {
    pt_destroy(&e.table)
    delete(e.command_buffer)
    if e.file_path != "" {
        delete(e.file_path)
        e.file_path = ""
    }
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

editor_realize_virtual_spaces :: proc(e: ^Editor) {
    line_len := editor_get_line_len(e, e.cursor.row)
    if e.cursor.col > line_len {
        spaces_needed := e.cursor.col - line_len
        spaces := make([]u8, spaces_needed, context.temp_allocator)
        for i in 0 ..< spaces_needed {
            spaces[i] = ' '
        }
        start_off := pt_line_to_offset(&e.table, e.cursor.row)
        pt_insert(&e.table, start_off + line_len, string(spaces))
        e.dirty = true
    }
}

editor_clamp_cursor :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    e.cursor.row = clamp(e.cursor.row, 0, max(0, total_lines - 1))
    e.cursor.col = max(0, e.cursor.col)
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

    if new_mode == .Insert || new_mode == .Command {
        e.cursor.shape = .Bar
        if window != nil do _ = sdl.StartTextInput(window)
    } else {
        e.cursor.shape = .Block
        if window != nil do _ = sdl.StopTextInput(window)
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
        e.status_message = "File saved successfully."
        return true
    }
    e.status_message = "Error: Failed to save file."
    return false
}

// Word movement helpers
is_word_char :: proc(b: byte) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

editor_skip_whitespace_forward :: proc(e: ^Editor) {
    line_len := editor_get_line_len(e, e.cursor.row)
    start_off := pt_line_to_offset(&e.table, e.cursor.row)
    for e.cursor.col < line_len {
        b := pt_byte_at(&e.table, start_off + e.cursor.col)
        if b != ' ' && b != '\t' do break
        e.cursor.col += 1
    }
}

editor_motion_word_forward :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    line_len := editor_get_line_len(e, e.cursor.row)

    if e.cursor.col >= line_len {
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = 0
            editor_skip_whitespace_forward(e)
        }
        return
    }

    start_off := pt_line_to_offset(&e.table, e.cursor.row)
    cur_byte := pt_byte_at(&e.table, start_off + e.cursor.col)

    if is_word_char(cur_byte) {
        for e.cursor.col < line_len && is_word_char(pt_byte_at(&e.table, start_off + e.cursor.col)) {
            e.cursor.col += 1
        }
    } else if cur_byte != ' ' && cur_byte != '\t' {
        for e.cursor.col < line_len {
            b := pt_byte_at(&e.table, start_off + e.cursor.col)
            if is_word_char(b) || b == ' ' || b == '\t' do break
            e.cursor.col += 1
        }
    }

    // Skip whitespace
    for e.cursor.col < line_len {
        b := pt_byte_at(&e.table, start_off + e.cursor.col)
        if b != ' ' && b != '\t' do break
        e.cursor.col += 1
    }

    if e.cursor.col >= line_len && e.cursor.row + 1 < total_lines {
        e.cursor.row += 1
        e.cursor.col = 0
        editor_skip_whitespace_forward(e)
    }

    editor_clamp_cursor(e)
}

editor_motion_word_backward :: proc(e: ^Editor) {
    if e.cursor.col == 0 {
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = editor_get_line_len(e, e.cursor.row)
        } else {
            return
        }
    }

    start_off := pt_line_to_offset(&e.table, e.cursor.row)

    // Skip whitespace backward
    for e.cursor.col > 0 {
        b := pt_byte_at(&e.table, start_off + e.cursor.col - 1)
        if b != ' ' && b != '\t' do break
        e.cursor.col -= 1
    }

    if e.cursor.col == 0 do return

    prev_byte := pt_byte_at(&e.table, start_off + e.cursor.col - 1)
    if is_word_char(prev_byte) {
        for e.cursor.col > 0 && is_word_char(pt_byte_at(&e.table, start_off + e.cursor.col - 1)) {
            e.cursor.col -= 1
        }
    } else {
        for e.cursor.col > 0 {
            b := pt_byte_at(&e.table, start_off + e.cursor.col - 1)
            if is_word_char(b) || b == ' ' || b == '\t' do break
            e.cursor.col -= 1
        }
    }

    editor_clamp_cursor(e)
}

// Scope and paragraph motions
editor_line_brace_delta :: proc(line: string) -> int {
    delta := 0
    in_string := false
    escaped := false

    for i := 0; i < len(line); i += 1 {
        c := line[i]
        if escaped {
            escaped = false
            continue
        }
        if c == '\\' && in_string {
            escaped = true
            continue
        }
        if c == '"' || c == '`' {
            in_string = !in_string
            continue
        }
        if in_string do continue

        // Check for line comment //
        if i + 1 < len(line) && c == '/' && line[i + 1] == '/' {
            break
        }

        if c == '{' {
            delta += 1
        } else if c == '}' {
            delta -= 1
        }
    }
    return delta
}

editor_get_line_indent :: proc(e: ^Editor, row: int) -> (indent: int, first_char_col: int, is_blank: bool) {
    line_str, ok := pt_line_text(&e.table, row)
    if !ok do return 0, 0, true
    defer delete(line_str)

    indent = 0
    first_char_col = 0
    is_blank = true

    for i := 0; i < len(line_str); i += 1 {
        c := line_str[i]
        if c == ' ' {
            indent += 1
        } else if c == '\t' {
            indent += 4
        } else if c == '\r' || c == '\n' {
            continue
        } else {
            is_blank = false
            first_char_col = i
            break
        }
    }

    if is_blank {
        first_char_col = 0
    }
    return indent, first_char_col, is_blank
}

editor_is_line_blank :: proc(e: ^Editor, row: int) -> bool {
    line_str, ok := pt_line_text(&e.table, row)
    if !ok do return true
    defer delete(line_str)

    for i := 0; i < len(line_str); i += 1 {
        c := line_str[i]
        if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
            return false
        }
    }
    return true
}

editor_motion_scope_up :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    if total_lines <= 1 || e.cursor.row <= 0 {
        e.cursor.row = 0
        new_len := editor_get_line_len(e, 0)
        max_c := max(0, new_len - 1)
        if e.mode == .Visual do max_c = new_len
        e.cursor.col = min(max_c, e.desired_col)
        editor_clamp_cursor(e)
        return
    }

    cur_row := e.cursor.row
    target_row := 0

    if editor_is_line_blank(e, cur_row) {
        // When on a blank line: skip preceding blank lines, then find the blank line above that paragraph
        r := cur_row - 1
        for r >= 0 && editor_is_line_blank(e, r) {
            r -= 1
        }
        for r >= 0 {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }
            r -= 1
        }
    } else {
        // When on text: find preceding blank line or enclosing scope header
        cur_indent, _, _ := editor_get_line_indent(e, cur_row)
        brace_depth := 0
        r := cur_row - 1
        for r >= 0 {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }

            line_str, ok := pt_line_text(&e.table, r)
            if ok {
                b_delta := editor_line_brace_delta(line_str)
                delete(line_str)
                brace_depth += b_delta
                indent, _, _ := editor_get_line_indent(e, r)
                if brace_depth > 0 || indent < cur_indent {
                    target_row = r
                    break
                }
            }
            r -= 1
        }
    }

    e.cursor.row = target_row
    new_len := editor_get_line_len(e, e.cursor.row)
    max_c := max(0, new_len - 1)
    if e.mode == .Visual do max_c = new_len
    e.cursor.col = min(max_c, e.desired_col)
    editor_clamp_cursor(e)
}

editor_motion_scope_down :: proc(e: ^Editor) {
    total_lines := pt_get_line_count(&e.table) + 1
    if total_lines <= 1 || e.cursor.row >= total_lines - 1 {
        e.cursor.row = max(0, total_lines - 1)
        new_len := editor_get_line_len(e, e.cursor.row)
        max_c := max(0, new_len - 1)
        if e.mode == .Visual do max_c = new_len
        e.cursor.col = min(max_c, e.desired_col)
        editor_clamp_cursor(e)
        return
    }

    cur_row := e.cursor.row
    target_row := total_lines - 1

    if editor_is_line_blank(e, cur_row) {
        // When on a blank line: skip following blank lines, then find the blank line below that paragraph
        r := cur_row + 1
        for r < total_lines && editor_is_line_blank(e, r) {
            r += 1
        }
        for r < total_lines {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }
            r += 1
        }
    } else {
        // When on text: find following blank line or closing scope boundary
        cur_indent, _, _ := editor_get_line_indent(e, cur_row)
        brace_depth := 0
        r := cur_row + 1
        for r < total_lines {
            if editor_is_line_blank(e, r) {
                target_row = r
                break
            }

            line_str, ok := pt_line_text(&e.table, r)
            if ok {
                b_delta := editor_line_brace_delta(line_str)
                delete(line_str)
                brace_depth += b_delta
                indent, _, _ := editor_get_line_indent(e, r)
                if brace_depth < 0 || indent < cur_indent {
                    target_row = r
                    break
                }
            }
            r += 1
        }
    }

    e.cursor.row = target_row
    new_len := editor_get_line_len(e, e.cursor.row)
    max_c := max(0, new_len - 1)
    if e.mode == .Visual do max_c = new_len
    e.cursor.col = min(max_c, e.desired_col)
    editor_clamp_cursor(e)
}


// Selection helpers
editor_get_selection_range :: proc(e: ^Editor) -> (start: Cursor, end: Cursor) {
    if e.cursor.row < e.selection_anchor.row ||
       (e.cursor.row == e.selection_anchor.row && e.cursor.col < e.selection_anchor.col) {
        return e.cursor, e.selection_anchor
    }
    return e.selection_anchor, e.cursor
}

editor_delete_selection :: proc(e: ^Editor) {
    start_sel, end_sel := editor_get_selection_range(e)
    total_len := pt_get_length(&e.table)
    start_off := pt_line_to_offset(&e.table, start_sel.row) + start_sel.col

    end_line_len := editor_get_line_len(e, end_sel.row)
    is_full_line := (start_sel.col == 0 && end_sel.col >= end_line_len)

    end_col := min(end_sel.col + 1, end_line_len)
    end_off := pt_line_to_offset(&e.table, end_sel.row) + end_col

    if is_full_line {
        if end_off < total_len && pt_byte_at(&e.table, end_off) == '\n' {
            end_off += 1
        } else if end_off + 1 < total_len && pt_byte_at(&e.table, end_off) == '\r' && pt_byte_at(&e.table, end_off + 1) == '\n' {
            end_off += 2
        } else if start_off > 0 && pt_byte_at(&e.table, start_off - 1) == '\n' {
            start_off -= 1
        }
    }

    if end_off > start_off {
        pt_delete_range(&e.table, start_off, end_off - start_off)
        e.dirty = true
    }

    e.cursor = start_sel
    e.cursor.col = min(e.cursor.col, editor_get_line_len(e, e.cursor.row))
    e.desired_col = e.cursor.col
    editor_set_mode(e, .Normal, nil)
}

editor_yank_selection :: proc(e: ^Editor) {
    start_sel, end_sel := editor_get_selection_range(e)
    total_len := pt_get_length(&e.table)
    start_off := pt_line_to_offset(&e.table, start_sel.row) + start_sel.col

    end_line_len := editor_get_line_len(e, end_sel.row)
    is_full_line := (start_sel.col == 0 && end_sel.col >= end_line_len)

    end_col := min(end_sel.col + 1, end_line_len)
    end_off := pt_line_to_offset(&e.table, end_sel.row) + end_col

    if is_full_line {
        if end_off < total_len && pt_byte_at(&e.table, end_off) == '\n' {
            end_off += 1
        } else if end_off + 1 < total_len && pt_byte_at(&e.table, end_off) == '\r' && pt_byte_at(&e.table, end_off + 1) == '\n' {
            end_off += 2
        }
    }

    if end_off > start_off {
        sel_text, ok := pt_text(&e.table, start_off, end_off - start_off)
        if ok {
            defer delete(sel_text)
            c_text := strings.clone_to_cstring(sel_text)
            defer delete(c_text)
            _ = sdl.SetClipboardText(c_text)
            e.status_message = "Yanked selection."
        }
    }

    e.cursor = start_sel
    editor_set_mode(e, .Normal, nil)
}

editor_paste :: proc(e: ^Editor) {
    if !sdl.HasClipboardText() do return
    clip_raw := sdl.GetClipboardText()
    if clip_raw == nil do return
    clip := string(cstring(clip_raw))
    if len(clip) == 0 do return

    if e.mode == .Visual {
        editor_delete_selection(e)
    }
    editor_realize_virtual_spaces(e)
    offset := editor_get_cursor_offset(e)
    pt_insert(&e.table, offset, clip)
    e.cursor.col += len(clip)
    e.desired_col = e.cursor.col
    e.dirty = true
}

editor_move_lines :: proc(e: ^Editor, dir: int) {
    total_lines := pt_get_line_count(&e.table) + 1
    if total_lines <= 1 do return

    r_start := e.cursor.row
    r_end := e.cursor.row
    if e.mode == .Visual {
        r_start = min(e.selection_anchor.row, e.cursor.row)
        r_end = max(e.selection_anchor.row, e.cursor.row)
    }

    if dir > 0 { // Move Down
        if r_end >= total_lines - 1 do return

        // Ensure file ends with newline before moving into bottom-most position
        total_len := pt_get_length(&e.table)
        if total_len > 0 && pt_byte_at(&e.table, total_len - 1) != '\n' {
            pt_insert(&e.table, total_len, "\n")
            total_lines = pt_get_line_count(&e.table) + 1
        }

        block_start := pt_line_to_offset(&e.table, r_start)
        block_end := pt_line_to_offset(&e.table, r_end + 1)

        target_row := r_end + 1
        target_start := block_end
        target_end := pt_line_to_offset(&e.table, target_row + 1) if target_row + 1 < total_lines else pt_get_length(&e.table)
        target_len := target_end - target_start
        if target_len <= 0 do return

        target_text, ok := pt_text(&e.table, target_start, target_len)
        if !ok do return
        defer delete(target_text)

        pt_delete_range(&e.table, target_start, target_len)
        pt_insert(&e.table, block_start, target_text)

        e.cursor.row += 1
        e.selection_anchor.row += 1
        e.desired_col = e.cursor.col
        e.dirty = true

    } else if dir < 0 { // Move Up
        if r_start <= 0 do return

        // Ensure file ends with newline
        total_len := pt_get_length(&e.table)
        if total_len > 0 && pt_byte_at(&e.table, total_len - 1) != '\n' {
            pt_insert(&e.table, total_len, "\n")
            total_lines = pt_get_line_count(&e.table) + 1
        }

        target_row := r_start - 1
        target_start := pt_line_to_offset(&e.table, target_row)
        target_end := pt_line_to_offset(&e.table, r_start)
        target_len := target_end - target_start
        if target_len <= 0 do return

        target_text, ok := pt_text(&e.table, target_start, target_len)
        if !ok do return
        defer delete(target_text)

        pt_delete_range(&e.table, target_start, target_len)

        new_insert_offset := pt_line_to_offset(&e.table, r_end) if r_end < total_lines - 1 else pt_get_length(&e.table)
        pt_insert(&e.table, new_insert_offset, target_text)

        e.cursor.row -= 1
        e.selection_anchor.row -= 1
        e.desired_col = e.cursor.col
        e.dirty = true
    }
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
        // ESC = Insert / Normal toggle
        editor_set_mode(e, .Normal, window)
        return true

    case sdl.K_RETURN, sdl.K_KP_ENTER:
        editor_realize_virtual_spaces(e)
        offset := editor_get_cursor_offset(e)
        pt_insert(&e.table, offset, "\n")
        e.cursor.row += 1
        e.cursor.col = 0
        e.desired_col = 0
        e.dirty = true
        return true

    case sdl.K_TAB:
        editor_realize_virtual_spaces(e)
        offset := editor_get_cursor_offset(e)
        pt_insert(&e.table, offset, "    ")
        e.cursor.col += 4
        e.desired_col = e.cursor.col
        e.dirty = true
        return true

    case sdl.K_BACKSPACE:
        line_len := editor_get_line_len(e, e.cursor.row)
        if e.cursor.col > line_len {
            e.cursor.col -= 1
            e.desired_col = e.cursor.col
        } else if e.cursor.col > 0 {
            offset := editor_get_cursor_offset(e)
            pt_delete_range(&e.table, offset - 1, 1)
            e.cursor.col -= 1
            e.desired_col = e.cursor.col
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
            e.desired_col = e.cursor.col
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
        e.desired_col = e.cursor.col
        return true

    case sdl.K_RIGHT:
        e.cursor.col += 1
        e.desired_col = e.cursor.col
        return true

    case sdl.K_UP:
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = e.desired_col
        }
        return true

    case sdl.K_DOWN:
        total_lines := pt_get_line_count(&e.table) + 1
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = e.desired_col
        }
        return true
    }
    return false
}

editor_handle_command_key :: proc(e: ^Editor, key: sdl.Keycode, window: ^sdl.Window, app: ^App) -> bool {
    switch key {
    case sdl.K_ESCAPE:
        editor_set_mode(e, .Normal, window)
        clear(&e.command_buffer)
        return true

    case sdl.K_BACKSPACE:
        if len(e.command_buffer) > 0 {
            pop(&e.command_buffer)
        } else {
            editor_set_mode(e, .Normal, window)
        }
        return true

    case sdl.K_RETURN, sdl.K_KP_ENTER:
        cmd := strings.trim_space(string(e.command_buffer[:]))
        editor_set_mode(e, .Normal, window)
        clear(&e.command_buffer)

        if cmd == "w" {
            editor_save_file(e)
        } else if cmd == "q" {
            app.running = false
        } else if cmd == "wq" || cmd == "x" {
            editor_save_file(e)
            app.running = false
        } else if cmd == "dired" || cmd == "d" || cmd == "e ." {
            dir := filepath.dir(e.file_path)
            if dir == "" do dir = "."
            app_open_dired(app, dir)
        } else if strings.has_prefix(cmd, "e ") {
            target := strings.trim_space(cmd[2:])
            if os.is_dir(target) {
                app_open_dired(app, target)
            } else {
                app_open_file(app, target)
            }
        } else if cmd != "" {
            e.status_message = fmt.tprintf("Unknown command: :%s", cmd)
        }
        return true

    case:
        if !sdl.TextInputActive(window) && key >= 32 && key <= 126 {
            append(&e.command_buffer, u8(key))
            return true
        }
    }
    return false
}

editor_handle_normal_key :: proc(e: ^Editor, key: sdl.Keycode, mod: sdl.Keymod, window: ^sdl.Window, app: ^App) -> bool {
    total_lines := pt_get_line_count(&e.table) + 1
    line_len := editor_get_line_len(e, e.cursor.row)
    is_shift := (mod & sdl.KMOD_SHIFT) != {}
    is_ctrl  := (mod & sdl.KMOD_CTRL) != {}

    // Multi-key commands
    if e.pending_cmd == 'g' {
        e.pending_cmd = 0
        if key == sdl.K_G {
            e.cursor.row = 0
            e.cursor.col = 0
            return true
        }
    }

    // Ctrl+l: word forward
    if is_ctrl && key == sdl.K_L {
        editor_motion_word_forward(e)
        e.desired_col = e.cursor.col
        return true
    }

    // Ctrl+h: word backward
    if is_ctrl && key == sdl.K_H {
        editor_motion_word_backward(e)
        e.desired_col = e.cursor.col
        return true
    }

    // Ctrl+j: scope / paragraph jump down
    if is_ctrl && key == sdl.K_J {
        editor_motion_scope_down(e)
        return true
    }

    // Ctrl+k: scope / paragraph jump up
    if is_ctrl && key == sdl.K_K {
        editor_motion_scope_up(e)
        return true
    }

    // Ctrl+x: toggle visual mode selection
    if is_ctrl && key == sdl.K_X {
        if e.mode == .Visual {
            editor_set_mode(e, .Normal, window)
        } else {
            e.mode = .Visual
            e.selection_anchor = e.cursor
            e.cursor.shape = .Block
        }
        return true
    }

    // Colon ':' opens global command prompt
    if key == sdl.K_COLON || (key == sdl.K_SEMICOLON && is_shift) {
        app_open_command_prompt(app)
        return true
    }

    switch key {
    // ESC = Insert / Normal toggle
    case sdl.K_ESCAPE:
        if e.mode == .Visual {
            editor_set_mode(e, .Normal, window)
        } else {
            editor_set_mode(e, .Insert, window)
        }
        return true

    // H: Jump to start of line
    case sdl.K_H:
        if is_shift {
            e.cursor.col = 0
            e.desired_col = 0
            return true
        }
        e.cursor.col = max(0, e.cursor.col - 1)
        e.desired_col = e.cursor.col
        return true

    // L: Jump to end of line or right (virtual edit)
    case sdl.K_L:
        if is_shift {
            e.cursor.col = line_len
            e.desired_col = line_len
            return true
        }
        e.cursor.col += 1
        e.desired_col = e.cursor.col
        return true

    // Navigation: j, k
    case sdl.K_J, sdl.K_DOWN:
        if e.cursor.row + 1 < total_lines {
            e.cursor.row += 1
            e.cursor.col = e.desired_col
        }
        return true

    case sdl.K_K, sdl.K_UP:
        if e.cursor.row > 0 {
            e.cursor.row -= 1
            e.cursor.col = e.desired_col
        }
        return true

    case sdl.K_LEFT:
        e.cursor.col = max(0, e.cursor.col - 1)
        e.desired_col = e.cursor.col
        return true

    case sdl.K_RIGHT:
        e.cursor.col += 1
        e.desired_col = e.cursor.col
        return true

    // Line start / end
    case sdl.K_0:
        e.cursor.col = 0
        e.desired_col = 0
        return true

    case sdl.K_4:
        if is_shift {
            e.cursor.col = line_len
            e.desired_col = 999999
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

    case sdl.K_Q:
        if app.active_pane != nil && app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
            app.active_pane.dired.is_editing = false
            _ = sdl.StopTextInput(window)
            app.cmd_prompt.message = "Dired: edit cancelled"
            return true
        }

    // Dash '-' opens parent directory in Dired
    case sdl.K_MINUS:
        dir := filepath.dir(e.file_path)
        if dir == "" do dir = "."
        app_open_dired(app, dir)
        return true

    // Enter Insert Mode
    case sdl.K_I:
        if e.mode != .Visual {
            if is_shift {
                e.cursor.col = 0
            }
            e.desired_col = e.cursor.col
            editor_set_mode(e, .Insert, window)
            return true
        }

    case sdl.K_A:
        if e.mode != .Visual {
            if is_shift {
                e.cursor.col = line_len
            } else {
                e.cursor.col += 1
            }
            e.desired_col = e.cursor.col
            editor_set_mode(e, .Insert, window)
            return true
        }

    // New lines (o, O, Enter)
    case sdl.K_O, sdl.K_RETURN, sdl.K_KP_ENTER:
        if e.mode != .Visual {
            if key == sdl.K_O && is_shift {
                start_off := pt_line_to_offset(&e.table, e.cursor.row)
                pt_insert(&e.table, start_off, "\n")
                e.cursor.col = 0
                e.desired_col = 0
            } else {
                start_off := pt_line_to_offset(&e.table, e.cursor.row)
                insert_pos := start_off + line_len
                pt_insert(&e.table, insert_pos, "\n")
                e.cursor.row += 1
                e.cursor.col = 0
                e.desired_col = 0
            }
            e.dirty = true
            editor_set_mode(e, .Insert, window)
            return true
        }

    // Line selection with X (Kakoune / Helix style)
    case sdl.K_X:
        if e.mode != .Visual {
            e.mode = .Visual
            e.cursor.shape = .Block
            e.selection_anchor = Cursor{row = e.cursor.row, col = 0}
            e.cursor.col = max(0, line_len)
            e.desired_col = e.cursor.col
        } else {
            if e.cursor.row + 1 < total_lines {
                e.cursor.row += 1
                e.cursor.col = max(0, editor_get_line_len(e, e.cursor.row))
                e.desired_col = e.cursor.col
            }
        }
        return true

    // Deletion with D (single char in Normal, selection in Visual)
    case sdl.K_D:
        if e.mode == .Visual {
            editor_delete_selection(e)
            return true
        }
        if line_len > 0 && e.cursor.col < line_len {
            offset := pt_line_to_offset(&e.table, e.cursor.row) + e.cursor.col
            pt_delete_range(&e.table, offset, 1)
            e.dirty = true
        } else if e.cursor.row + 1 < total_lines {
            offset := pt_line_to_offset(&e.table, e.cursor.row) + line_len
            pt_delete_range(&e.table, offset, 1)
            e.dirty = true
        }
        return true

    case sdl.K_P:
        editor_paste(e)
        return true

    case sdl.K_Y:
        if e.mode == .Visual {
            editor_yank_selection(e)
            return true
        }

    case sdl.K_C:
        if e.mode == .Visual {
            editor_delete_selection(e)
            editor_set_mode(e, .Insert, window)
            return true
        }

    // Undo / Redo
    case sdl.K_U:
        pt_undo(&e.table)
        e.dirty = true
        editor_clamp_cursor(e)
        return true
    }

    return false
}

editor_handle_event :: proc(e: ^Editor, event: ^sdl.Event, window: ^sdl.Window, app: ^App) -> bool {
    #partial switch event.type {
    case .TEXT_INPUT:
        if e.mode == .Insert {
            text_str := string(event.text.text)
            if len(text_str) > 0 {
                editor_realize_virtual_spaces(e)
                offset := editor_get_cursor_offset(e)
                pt_insert(&e.table, offset, text_str)
                e.cursor.col += len(text_str)
                e.desired_col = e.cursor.col
                e.dirty = true
                e.last_action = time.now()
            }
            return true
        } else if e.mode == .Command {
            text_str := string(event.text.text)
            for b in transmute([]u8)text_str {
                append(&e.command_buffer, b)
            }
            return true
        }

    case .KEY_DOWN:
        e.last_action = time.now()
        e.status_message = ""
        key := event.key.key
        mod := event.key.mod
        is_ctrl := (mod & sdl.KMOD_CTRL) != {}
        is_alt  := (mod & sdl.KMOD_ALT) != {}

        // A-j: Move line or selection down
        if is_alt && key == sdl.K_J {
            editor_move_lines(e, 1)
            return true
        }

        // A-k: Move line or selection up
        if is_alt && key == sdl.K_K {
            editor_move_lines(e, -1)
            return true
        }

        // A-w: Copy selection (yank)
        if is_alt && key == sdl.K_W {
            if e.mode == .Visual {
                editor_yank_selection(e)
                return true
            }
        }

        // C-y: Paste clipboard
        if is_ctrl && key == sdl.K_Y {
            editor_paste(e)
            return true
        }

        if is_ctrl && key == sdl.K_S {
            editor_save_file(e)
            return true
        }

        if is_ctrl && key == sdl.K_Z {
            pt_undo(&e.table)
            e.dirty = true
            editor_clamp_cursor(e)
            return true
        }

        if is_ctrl && key == sdl.K_R {
            pt_redo(&e.table)
            e.dirty = true
            editor_clamp_cursor(e)
            return true
        }

        if e.mode == .Insert {
            return editor_handle_insert_key(e, key, mod, window)
        } else if e.mode == .Command {
            return editor_handle_command_key(e, key, window, app)
        } else {
            return editor_handle_normal_key(e, key, mod, window, app)
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

editor_render :: proc(e: ^Editor, renderer: ^sdl.Renderer, font: ^Font, rect: sdl.FRect, is_focused: bool, theme: ^Theme) {
    if rect.w < 50 || rect.h < 50 do return

    scale := get_font_scale_multiplier(e.font_scale)
    line_h := get_line_height(e.font_scale)
    char_w := e.char_advance * scale

    total_lines := pt_get_line_count(&e.table) + 1

    status_bar_h := line_h + 8.0
    editor_h := rect.h - status_bar_h

    digits := 1
    tmp := total_lines
    for tmp >= 10 {
        tmp /= 10
        digits += 1
    }
    digits = max(3, digits)
    gutter_w := f32(digits + 2) * char_w

    visible_lines := int(editor_h / line_h)
    visible_cols := int((rect.w - gutter_w) / char_w)
    if visible_lines <= 0 do visible_lines = 1
    if visible_cols <= 0 do visible_cols = 1

    editor_scroll_to_cursor(e, visible_lines, visible_cols)

    // Clip rendering to this pane's rectangle
    clip := sdl.Rect{i32(rect.x), i32(rect.y), i32(rect.w), i32(rect.h)}
    sdl.SetRenderClipRect(renderer, &clip)
    defer sdl.SetRenderClipRect(renderer, nil)

    // 1. Background
    bg_color := theme.bg
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    bg_rect := rect
    sdl.RenderFillRect(renderer, &bg_rect)

    // 2. Gutter background
    gutter_rect := sdl.FRect{
        x = rect.x,
        y = rect.y,
        w = gutter_w,
        h = editor_h,
    }
    sdl.SetRenderDrawColorFloat(renderer, theme.gutter_bg.r, theme.gutter_bg.g, theme.gutter_bg.b, theme.gutter_bg.a)
    sdl.RenderFillRect(renderer, &gutter_rect)

    // 3. Gutter separator line
    sep_rect := sdl.FRect{
        x = rect.x + gutter_w - 1.0,
        y = rect.y,
        w = 1.0,
        h = editor_h,
    }
    sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
    sdl.RenderFillRect(renderer, &sep_rect)

    // 4. Current line highlight
    if is_focused && e.cursor.row >= e.scroll_row && e.cursor.row < e.scroll_row + visible_lines {
        hl_y := rect.y + f32(e.cursor.row - e.scroll_row) * line_h
        hl_rect := sdl.FRect{
            x = rect.x + gutter_w,
            y = hl_y,
            w = rect.w - gutter_w,
            h = line_h,
        }
        sdl.SetRenderDrawColorFloat(renderer, theme.cursor_line_bg.r, theme.cursor_line_bg.g, theme.cursor_line_bg.b, theme.cursor_line_bg.a)
        sdl.RenderFillRect(renderer, &hl_rect)
    }

    // 5. Visual Mode selection highlight rectangles
    if e.mode == .Visual {
        start_sel, end_sel := editor_get_selection_range(e)
        for i in 0 ..< visible_lines {
            line_idx := e.scroll_row + i
            if line_idx >= total_lines do break
            if line_idx < start_sel.row || line_idx > end_sel.row do continue

            y_pos := rect.y + f32(i) * line_h
            line_len := editor_get_line_len(e, line_idx)

            c0 := 0
            c1 := line_len

            if line_idx == start_sel.row && line_idx == end_sel.row {
                c0 = start_sel.col
                c1 = end_sel.col + 1
            } else if line_idx == start_sel.row {
                c0 = start_sel.col
                c1 = max(line_len + 1, start_sel.col + 1)
            } else if line_idx == end_sel.row {
                c0 = 0
                c1 = end_sel.col + 1
            } else {
                c0 = 0
                c1 = line_len + 1
            }

            if c1 > c0 {
                sel_x := rect.x + gutter_w + 4.0 + f32(c0 - e.scroll_col) * char_w
                sel_w := f32(c1 - c0) * char_w
                sel_rect := sdl.FRect{
                    x = sel_x,
                    y = y_pos,
                    w = sel_w,
                    h = line_h,
                }
                sdl.SetRenderDrawColorFloat(renderer, theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, theme.selection_bg.a)
                sdl.RenderFillRect(renderer, &sel_rect)
            }
        }
    }

    // 6. Block Cursor (rendered behind text)
    cx := rect.x + gutter_w + 4.0 + f32(e.cursor.col - e.scroll_col) * char_w
    cy := rect.y + f32(e.cursor.row - e.scroll_row) * line_h
    cursor_visible := is_focused && cursor_is_visible(&e.cursor, e.last_action)
    e.cursor.color = theme.cursor

    if is_focused && e.cursor.shape == .Block {
        render_cursor(&e.cursor, renderer, cx, cy, char_w, line_h, e.last_action)
    }

    // 7. Push visible lines into font batcher
    inverted_cursor_char_color := theme.bg
    active_line_num_color := theme.gutter_active_fg
    normal_line_num_color := theme.gutter_fg

    for i in 0 ..< visible_lines {
        line_idx := e.scroll_row + i
        if line_idx >= total_lines do break

        y_pos := rect.y + f32(i) * line_h

        // Line number in gutter
        line_num_str := fmt.tprintf("%*d ", digits, line_idx + 1)
        ln_color := normal_line_num_color
        if is_focused && line_idx == e.cursor.row {
            ln_color = active_line_num_color
        }
        push_line(font, line_num_str, Vec2{rect.x + char_w * 0.5, y_pos}, ln_color, e.font_scale)

        // Line text
        line_str, ok := pt_line_text(&e.table, line_idx)
        if ok {
            defer delete(line_str)
            if e.scroll_col < len(line_str) {
                visible_str := line_str[e.scroll_col:]

                hl_col := -1
                if is_focused && (e.mode == .Normal || e.mode == .Visual) && cursor_visible && line_idx == e.cursor.row {
                    hl_col = e.cursor.col - e.scroll_col
                }

                line_colors := make([]sdl.FColor, len(line_str), context.temp_allocator)
                syntax_highlight_line(e.file_path, line_str, theme, line_colors)
                visible_colors := line_colors[e.scroll_col:]

                push_editor_line(
                    font,
                    visible_str,
                    Vec2{rect.x + gutter_w + 4.0, y_pos},
                    theme.fg,
                    e.font_scale,
                    hl_col,
                    inverted_cursor_char_color,
                    visible_colors,
                )
            }
        }
    }

    // 8. Status Bar
    status_bar_rect := sdl.FRect{
        x = rect.x,
        y = rect.y + editor_h,
        w = rect.w,
        h = status_bar_h,
    }
    sb_bg := theme.status_bg if is_focused else theme.status_inactive_bg
    sdl.SetRenderDrawColorFloat(renderer, sb_bg.r, sb_bg.g, sb_bg.b, sb_bg.a)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    mode_text := "-- NORMAL --"
    status_color := theme.keyword
    switch e.mode {
    case .Normal:
        mode_text = "-- NORMAL --"
        status_color = theme.keyword
    case .Insert:
        mode_text = "-- INSERT --"
        status_color = theme.string_lit
    case .Visual:
        mode_text = "-- VISUAL --"
        status_color = theme.fn_name
    case .Command:
        mode_text = "-- COMMAND --"
        status_color = theme.number_lit
    }

    if !is_focused {
        status_color = theme.status_inactive_fg
    }

    dirty_indicator := " [+]" if e.dirty else ""
    file_display := e.file_path if e.file_path != "" else "[No Name]"
    focus_badge := "[ACTIVE] " if is_focused else ""
    status_info := fmt.tprintf("%s%s   %s%s   Line %d/%d, Col %d", focus_badge, mode_text, file_display, dirty_indicator, e.cursor.row + 1, total_lines, e.cursor.col + 1)
    if e.status_message != "" {
        status_info = fmt.tprintf("%s   | %s", status_info, e.status_message)
    }

    push_line(font, status_info, Vec2{rect.x + 10.0, rect.y + editor_h + 4.0}, status_color, e.font_scale)

    // Flush text
    flush_text(font, renderer)

    // 9. Bar Cursor (in Insert Mode)
    if is_focused && e.cursor.shape == .Bar {
        render_cursor(&e.cursor, renderer, cx, cy, char_w, line_h, e.last_action)
    }
}
