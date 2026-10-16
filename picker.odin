package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

FilePickerItem :: struct {
    rel_path : string,
    full_path: string,
}

FilePicker :: struct {
    active          : bool,
    root_dir        : string,
    items           : [dynamic]FilePickerItem,
    filtered_indices: [dynamic]int,
    query_buffer    : [128]u8,
    query_len       : int,
    selected_index  : int,
    scroll_offset   : int,
}

file_picker_init :: proc(fp: ^FilePicker) {
    fp.active = false
    fp.root_dir = ""
    fp.items = make([dynamic]FilePickerItem, 0, 256)
    fp.filtered_indices = make([dynamic]int, 0, 256)
    fp.query_len = 0
    fp.selected_index = 0
    fp.scroll_offset = 0
}

file_picker_destroy :: proc(fp: ^FilePicker) {
    for it in fp.items {
        delete(it.rel_path)
        delete(it.full_path)
    }
    delete(fp.items)
    delete(fp.filtered_indices)
    if fp.root_dir != "" do delete(fp.root_dir)
}

file_picker_close :: proc(fp: ^FilePicker, app: ^App = nil) {
    fp.active = false
    if app != nil && app.window != nil {
        needs_text := false
        if app.active_pane != nil {
            if app.active_pane.kind == .Editor && app.active_pane.editor.mode == .Insert {
                needs_text = true
            } else if app.active_pane.kind == .Dired && app.active_pane.dired.is_editing && app.active_pane.editor.mode == .Insert {
                needs_text = true
            }
        }
        if !needs_text {
            _ = sdl.StopTextInput(app.window)
        }
    }
}

fuzzy_match :: proc(pattern, text: string) -> bool {
    if len(pattern) == 0 do return true
    p_idx := 0
    p_bytes := transmute([]u8)pattern
    t_bytes := transmute([]u8)text
    for b in t_bytes {
        if b == p_bytes[p_idx] {
            p_idx += 1
            if p_idx == len(p_bytes) do return true
        }
    }
    return false
}

file_picker_matches :: proc(query, path: string) -> bool {
    if len(query) == 0 do return true
    if strings.contains(path, query) do return true
    if fuzzy_match(query, path) do return true

    tokens := strings.fields(query, context.temp_allocator)
    if len(tokens) > 1 {
        for tok in tokens {
            if !strings.contains(path, tok) && !fuzzy_match(tok, path) {
                return false
            }
        }
        return true
    }
    return false
}

file_picker_filter :: proc(fp: ^FilePicker) {
    clear(&fp.filtered_indices)
    query := strings.to_lower(string(fp.query_buffer[:fp.query_len]), context.temp_allocator)

    for it, idx in fp.items {
        if len(query) == 0 {
            append(&fp.filtered_indices, idx)
            continue
        }

        lower_path := strings.to_lower(it.rel_path, context.temp_allocator)
        if file_picker_matches(query, lower_path) {
            append(&fp.filtered_indices, idx)
        }
    }

    if len(fp.filtered_indices) == 0 {
        fp.selected_index = 0
        fp.scroll_offset = 0
    } else {
        fp.selected_index = clamp(fp.selected_index, 0, len(fp.filtered_indices) - 1)
    }
}

file_picker_open :: proc(fp: ^FilePicker, root: string, window: ^sdl.Window = nil) {
    for it in fp.items {
        delete(it.rel_path)
        delete(it.full_path)
    }
    clear(&fp.items)
    clear(&fp.filtered_indices)

    abs_root, abs_err := filepath.abs(root, context.allocator)
    if abs_err != nil {
        abs_root, _ = filepath.clean(root, context.allocator)
    }
    if fp.root_dir != "" do delete(fp.root_dir)
    fp.root_dir = abs_root

    // Walk directory tree
    w := os.walker_create(abs_root)
    defer os.walker_destroy(&w)

    for info in os.walker_walk(&w) {
        if _, err := os.walker_error(&w); err != nil {
            continue
        }

        // Check if directory should be skipped
        if info.type == .Directory {
            name := info.name
            if name == ".git" || name == ".odin" || name == "bin" ||
               name == ".cache" || name == "node_modules" || name == "target" ||
               name == "build" || name == ".gemini" || name == "__pycache__" {
                os.walker_skip_dir(&w)
                continue
            }
            continue
        }

        // Skip binary and backup files
        if strings.has_suffix(info.name, "~") || strings.has_suffix(info.name, ".swp") {
            continue
        }

        rel, rel_err := filepath.rel(abs_root, info.fullpath, context.allocator)
        if rel_err != .None {
            rel = strings.clone(info.name, context.allocator)
        }

        append(&fp.items, FilePickerItem{
            rel_path  = rel,
            full_path = strings.clone(info.fullpath, context.allocator),
        })
    }

    // Sort items alphabetically by rel_path
    slice.sort_by(fp.items[:], proc(a, b: FilePickerItem) -> bool {
        return a.rel_path < b.rel_path
    })

    fp.query_len = 0
    fp.selected_index = 0
    fp.scroll_offset = 0
    file_picker_filter(fp)
    fp.active = true

    if window != nil {
        _ = sdl.StartTextInput(window)
    }
}

file_picker_handle_event :: proc(fp: ^FilePicker, event: ^sdl.Event, app: ^App) -> bool {
    if !fp.active do return false

    #partial switch event.type {
    case .TEXT_INPUT:
        text_str := string(event.text.text)
        for b in transmute([]u8)text_str {
            if fp.query_len < len(fp.query_buffer) {
                fp.query_buffer[fp.query_len] = b
                fp.query_len += 1
            }
        }
        fp.selected_index = 0
        fp.scroll_offset = 0
        file_picker_filter(fp)
        return true

    case .KEY_DOWN:
        key := event.key.key
        mod := event.key.mod
        is_ctrl := (mod & sdl.KMOD_CTRL) != {}

        if key == sdl.K_ESCAPE || (is_ctrl && (key == sdl.K_C || key == sdl.K_G)) {
            file_picker_close(fp, app)
            return true
        }

        if is_ctrl && key == sdl.K_V {
            if sdl.HasClipboardText() {
                clip_raw := sdl.GetClipboardText()
                if clip_raw != nil {
                    clip := string(cstring(clip_raw))
                    for b in transmute([]u8)clip {
                        if b >= 32 && b <= 126 && fp.query_len < len(fp.query_buffer) {
                            fp.query_buffer[fp.query_len] = b
                            fp.query_len += 1
                        }
                    }
                    fp.selected_index = 0
                    fp.scroll_offset = 0
                    file_picker_filter(fp)
                }
            }
            return true
        }

        if key == sdl.K_BACKSPACE {
            if fp.query_len > 0 {
                fp.query_len -= 1
                for fp.query_len > 0 && (fp.query_buffer[fp.query_len] & 0xC0) == 0x80 {
                    fp.query_len -= 1
                }
                fp.selected_index = 0
                fp.scroll_offset = 0
                file_picker_filter(fp)
            }
            return true
        }

        if is_ctrl && key == sdl.K_U {
            fp.query_len = 0
            fp.selected_index = 0
            fp.scroll_offset = 0
            file_picker_filter(fp)
            return true
        }

        if is_ctrl && key == sdl.K_W {
            for fp.query_len > 0 && fp.query_buffer[fp.query_len - 1] == ' ' {
                fp.query_len -= 1
            }
            for fp.query_len > 0 && fp.query_buffer[fp.query_len - 1] != ' ' && fp.query_buffer[fp.query_len - 1] != '/' {
                fp.query_len -= 1
            }
            fp.selected_index = 0
            fp.scroll_offset = 0
            file_picker_filter(fp)
            return true
        }

        if key == sdl.K_DOWN || (is_ctrl && (key == sdl.K_J || key == sdl.K_N)) {
            if len(fp.filtered_indices) > 0 {
                fp.selected_index = (fp.selected_index + 1) % len(fp.filtered_indices)
            }
            return true
        }

        if key == sdl.K_UP || (is_ctrl && (key == sdl.K_K || key == sdl.K_P)) {
            if len(fp.filtered_indices) > 0 {
                fp.selected_index = (fp.selected_index - 1 + len(fp.filtered_indices)) % len(fp.filtered_indices)
            }
            return true
        }

        if key == sdl.K_RETURN || key == sdl.K_KP_ENTER {
            if len(fp.filtered_indices) > 0 && fp.selected_index < len(fp.filtered_indices) {
                item_idx := fp.filtered_indices[fp.selected_index]
                item := fp.items[item_idx]
                target_path := strings.clone(item.full_path, context.temp_allocator)
                file_picker_close(fp, app)
                app_pane_open_file(app, app.active_pane, target_path)
            }
            return true
        }

        return true // Intercept all other keys while picker is open
    }

    return false
}

file_picker_render :: proc(fp: ^FilePicker, renderer: ^sdl.Renderer, font: ^Font, screen_w: f32, screen_h: f32, theme: ^Theme) {
    if !fp.active do return

    line_h := get_line_height(.HALF)
    scale := get_font_scale_multiplier(.HALF)

    // Dim background overlay
    dim_rect := sdl.FRect{0, 0, screen_w, screen_h}
    sdl.SetRenderDrawColorFloat(renderer, 0.0, 0.0, 0.0, 0.55)
    sdl.RenderFillRect(renderer, &dim_rect)

    // Modal dimensions
    modal_w := min(720.0 * global_ui_scale, screen_w - 40.0)
    modal_h := min(460.0 * global_ui_scale, screen_h - 60.0)
    modal_x := (screen_w - modal_w) / 2.0
    modal_y := max(30.0, (screen_h - modal_h) / 3.0)

    modal_rect := sdl.FRect{modal_x, modal_y, modal_w, modal_h}

    // Modal background
    sdl.SetRenderDrawColorFloat(renderer, theme.bg.r, theme.bg.g, theme.bg.b, 0.98)
    sdl.RenderFillRect(renderer, &modal_rect)

    // Modal border
    sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
    sdl.RenderRect(renderer, &modal_rect)

    // Search input header area
    header_h := line_h + 16.0
    header_rect := sdl.FRect{modal_x, modal_y, modal_w, header_h}
    sdl.SetRenderDrawColorFloat(renderer, theme.cursor_line_bg.r, theme.cursor_line_bg.g, theme.cursor_line_bg.b, 1.0)
    sdl.RenderFillRect(renderer, &header_rect)

    // Header divider line
    div_rect := sdl.FRect{modal_x, modal_y + header_h, modal_w, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
    sdl.RenderFillRect(renderer, &div_rect)

    // Render search prompt
    query_str := string(fp.query_buffer[:fp.query_len])
    prompt_text := fmt.tprintf("> %s", query_str)
    prompt_pos := Vec2{modal_x + 12.0, modal_y + 8.0}
    prompt_end_x := push_line(font, prompt_text, prompt_pos, theme.fg, .HALF)

    // Render input cursor
    cursor_rect := sdl.FRect{prompt_end_x + 2.0, modal_y + 8.0, 2.0 * global_ui_scale, line_h}
    sdl.SetRenderDrawColorFloat(renderer, theme.cursor.r, theme.cursor.g, theme.cursor.b, 1.0)
    sdl.RenderFillRect(renderer, &cursor_rect)

    // Match count on top right
    count_str := fmt.tprintf("%d / %d", len(fp.filtered_indices), len(fp.items))
    count_w := f32(len(count_str)) * 10.0 * scale
    push_line(font, count_str, Vec2{modal_x + modal_w - count_w - 16.0, modal_y + 8.0}, theme.comment, .HALF)

    // Results list area
    list_y := modal_y + header_h + 6.0
    list_h := modal_h - header_h - 12.0
    visible_count := int(list_h / line_h)
    if visible_count <= 0 do visible_count = 1

    // Adjust scroll offset to keep selected_index visible
    if fp.selected_index < fp.scroll_offset {
        fp.scroll_offset = fp.selected_index
    } else if fp.selected_index >= fp.scroll_offset + visible_count {
        fp.scroll_offset = fp.selected_index - visible_count + 1
    }

    // Render items
    for vi in 0 ..< visible_count {
        item_idx_in_filtered := fp.scroll_offset + vi
        if item_idx_in_filtered >= len(fp.filtered_indices) do break

        actual_item_idx := fp.filtered_indices[item_idx_in_filtered]
        item := fp.items[actual_item_idx]

        row_y := list_y + f32(vi) * line_h
        is_selected := (item_idx_in_filtered == fp.selected_index)

        if is_selected {
            sel_rect := sdl.FRect{modal_x + 4.0, row_y, modal_w - 8.0, line_h}
            sdl.SetRenderDrawColorFloat(renderer, theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 0.9)
            sdl.RenderFillRect(renderer, &sel_rect)
        }

        text_color := theme.keyword if is_selected else theme.fg
        push_line(font, item.rel_path, Vec2{modal_x + 14.0, row_y + 2.0}, text_color, .HALF)
    }

    // If no results
    if len(fp.filtered_indices) == 0 {
        push_line(font, "No matching files", Vec2{modal_x + 20.0, list_y + 10.0}, theme.comment, .HALF)
    }
}
