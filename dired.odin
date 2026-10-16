package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

DiredEntry :: struct {
    name   : string,
    is_dir : bool,
    size   : i64,
}

Dired :: struct {
    path        : string,
    entries     : [dynamic]DiredEntry,
    cursor      : int,
    scroll      : int,
    last_action : time.Time,
}

dired_init :: proc(d: ^Dired) {
    d.entries = make([dynamic]DiredEntry, context.allocator)
    d.cursor = 0
    d.scroll = 0
    d.last_action = time.now()
}

dired_destroy :: proc(d: ^Dired) {
    for e in d.entries {
        delete(e.name)
    }
    delete(d.entries)
    if d.path != "" {
        delete(d.path)
    }
}

dired_load_path :: proc(d: ^Dired, dir_path: string) -> bool {
    for e in d.entries {
        delete(e.name)
    }
    clear(&d.entries)

    abs_path, _ := filepath.clean(dir_path, context.allocator)
    if d.path != "" do delete(d.path)
    d.path = abs_path

    handle, err := os.open(abs_path)
    if err != nil do return false
    defer os.close(handle)

    files, ferr := os.read_dir(handle, -1, context.allocator)
    if ferr != nil do return false
    defer os.file_info_slice_delete(files, context.allocator)

    // Always add parent directory entry ".."
    append(&d.entries, DiredEntry{
        name   = strings.clone(".."),
        is_dir = true,
        size   = 0,
    })

    temp_dirs := make([dynamic]DiredEntry, context.allocator)
    defer delete(temp_dirs)
    temp_files := make([dynamic]DiredEntry, context.allocator)
    defer delete(temp_files)

    for f in files {
        if f.name == "." || f.name == ".." do continue
        is_directory := f.type == .Directory

        entry := DiredEntry{
            name   = strings.clone(f.name),
            is_dir = is_directory,
            size   = f.size,
        }
        if is_directory {
            append(&temp_dirs, entry)
        } else {
            append(&temp_files, entry)
        }
    }

    slice.sort_by(temp_dirs[:], proc(a, b: DiredEntry) -> bool {
        return strings.compare(a.name, b.name) < 0
    })
    slice.sort_by(temp_files[:], proc(a, b: DiredEntry) -> bool {
        return strings.compare(a.name, b.name) < 0
    })

    for d_entry in temp_dirs {
        append(&d.entries, d_entry)
    }
    for f_entry in temp_files {
        append(&d.entries, f_entry)
    }

    d.cursor = 0
    d.scroll = 0
    d.last_action = time.now()
    return true
}

dired_format_size :: proc(size: i64) -> string {
    if size < 1024 {
        return fmt.tprintf("%4d B", size)
    } else if size < 1024 * 1024 {
        return fmt.tprintf("%4.1f KB", f32(size) / 1024.0)
    } else {
        return fmt.tprintf("%4.1f MB", f32(size) / (1024.0 * 1024.0))
    }
}

dired_handle_event :: proc(d: ^Dired, event: ^sdl.Event, app: ^App) -> bool {
    #partial switch event.type {
    case .KEY_DOWN:
        d.last_action = time.now()
        key := event.key.key
        mod := event.key.mod

        switch key {
        case sdl.K_J, sdl.K_DOWN:
            if len(d.entries) > 0 {
                d.cursor = min(len(d.entries) - 1, d.cursor + 1)
            }
            return true

        case sdl.K_K, sdl.K_UP:
            if len(d.entries) > 0 {
                d.cursor = max(0, d.cursor - 1)
            }
            return true

        case sdl.K_H, sdl.K_MINUS:
            parent := filepath.dir(d.path)
            if parent == "" do parent = ".."
            dired_load_path(d, parent)
            return true

        case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_L:
            if d.cursor >= 0 && d.cursor < len(d.entries) {
                entry := d.entries[d.cursor]
                if entry.name == ".." {
                    parent := filepath.dir(d.path)
                    if parent == "" do parent = ".."
                    dired_load_path(d, parent)
                } else if entry.is_dir {
                    new_path, _ := filepath.join([]string{d.path, entry.name}, context.allocator)
                    defer delete(new_path)
                    dired_load_path(d, new_path)
                } else {
                    target_file, _ := filepath.join([]string{d.path, entry.name}, context.allocator)
                    defer delete(target_file)
                    app_open_file(app, target_file)
                }
            }
            return true

        case sdl.K_ESCAPE, sdl.K_Q:
            if app.editor.file_path != "" {
                app.view = .Editor
            }
            return true
        }

    case .MOUSE_WHEEL:
        if event.wheel.y > 0 {
            d.cursor = max(0, d.cursor - 3)
        } else if event.wheel.y < 0 {
            d.cursor = min(max(0, len(d.entries) - 1), d.cursor + 3)
        }
        return true
    }

    return false
}

dired_render :: proc(d: ^Dired, renderer: ^sdl.Renderer, font: ^Font, window_w, window_h: i32) {
    scale := get_font_scale_multiplier(.HALF)
    line_h := get_line_height(.HALF)

    header_h := line_h * 2.0
    status_bar_h := line_h + 8.0
    body_h := f32(window_h) - header_h - status_bar_h

    visible_lines := int(body_h / line_h)
    if visible_lines <= 0 do visible_lines = 1

    if d.cursor < d.scroll {
        d.scroll = d.cursor
    } else if d.cursor >= d.scroll + visible_lines {
        d.scroll = d.cursor - visible_lines + 1
    }

    // 1. Background
    bg_color := sdl.FColor{0.08, 0.08, 0.1, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    sdl.RenderClear(renderer)

    // 2. Header
    header_rect := sdl.FRect{
        x = 0,
        y = 0,
        w = f32(window_w),
        h = header_h,
    }
    sdl.SetRenderDrawColor(renderer, 28, 30, 38, 255)
    sdl.RenderFillRect(renderer, &header_rect)

    header_line := fmt.tprintf("DIR: %s", d.path)
    push_line(font, header_line, Vec2{16.0, 4.0}, sdl.FColor{0.95, 0.85, 0.45, 1.0}, .HALF)
    push_line(font, "Press <Enter>/<l> to open, <h>/<-> for parent, <j>/<k> to move", Vec2{16.0, 4.0 + line_h}, sdl.FColor{0.5, 0.55, 0.65, 1.0}, .HALF)

    div_rect := sdl.FRect{
        x = 0,
        y = header_h - 1.0,
        w = f32(window_w),
        h = 1.0,
    }
    sdl.SetRenderDrawColor(renderer, 48, 52, 64, 255)
    sdl.RenderFillRect(renderer, &div_rect)

    // 3. Entries
    for i in 0 ..< visible_lines {
        idx := d.scroll + i
        if idx >= len(d.entries) do break

        entry := d.entries[idx]
        y_pos := header_h + f32(i) * line_h

        if idx == d.cursor {
            sel_rect := sdl.FRect{
                x = 0,
                y = y_pos,
                w = f32(window_w),
                h = line_h,
            }
            sdl.SetRenderDrawColor(renderer, 36, 40, 52, 255)
            sdl.RenderFillRect(renderer, &sel_rect)

            mark_rect := sdl.FRect{
                x = 0,
                y = y_pos,
                w = 3.0,
                h = line_h,
            }
            sdl.SetRenderDrawColor(renderer, 97, 175, 239, 255)
            sdl.RenderFillRect(renderer, &mark_rect)
        }

        if entry.is_dir {
            name_str := fmt.tprintf("%s/", entry.name)
            push_line(font, name_str, Vec2{24.0, y_pos}, sdl.FColor{0.45, 0.75, 0.98, 1.0}, .HALF)
        } else {
            push_line(font, entry.name, Vec2{24.0, y_pos}, sdl.FColor{0.9, 0.9, 0.9, 1.0}, .HALF)

            size_str := dired_format_size(entry.size)
            size_x := max(f32(window_w) - 160.0, 450.0)
            push_line(font, size_str, Vec2{size_x, y_pos}, sdl.FColor{0.5, 0.5, 0.55, 1.0}, .HALF)
        }
    }

    // 4. Status Bar
    status_bar_rect := sdl.FRect{
        x = 0,
        y = f32(window_h) - status_bar_h,
        w = f32(window_w),
        h = status_bar_h,
    }
    sdl.SetRenderDrawColor(renderer, 35, 38, 48, 255)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    status_str := fmt.tprintf("-- DIRED --   %d / %d items", d.cursor + 1, len(d.entries))
    push_line(font, status_str, Vec2{10.0, f32(window_h) - status_bar_h + 4.0}, sdl.FColor{0.95, 0.75, 0.3, 1.0}, .HALF)

    flush_text(font, renderer)
}
