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
        d.path = ""
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

    // Parent directory entry ".."
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

dired_handle_event :: proc(d: ^Dired, event: ^sdl.Event, app: ^App, pane: ^Pane) -> bool {
    #partial switch event.type {
    case .KEY_DOWN:
        d.last_action = time.now()
        key := event.key.key
        mod := event.key.mod
        is_shift := (mod & sdl.KMOD_SHIFT) != {}

        // Command mode trigger ':' from Dired!
        if key == sdl.K_COLON || (key == sdl.K_SEMICOLON && is_shift) {
            app_open_command_prompt(app)
            return true
        }

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
                    // Directly replace current split with the selected file!
                    app_pane_open_file(app, pane, target_file)
                }
            }
            return true

        case sdl.K_ESCAPE, sdl.K_Q:
            if pane != nil && pane.editor.file_path != "" {
                pane.kind = .Editor
            } else if len(app.panes) > 1 {
                app_close_pane(app, pane)
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

dired_render :: proc(d: ^Dired, renderer: ^sdl.Renderer, font: ^Font, rect: sdl.FRect, is_focused: bool) {
    if rect.w < 50 || rect.h < 50 do return

    scale := get_font_scale_multiplier(.HALF)
    line_h := get_line_height(.HALF)

    header_h := line_h * 2.0
    status_bar_h := line_h + 8.0
    body_h := rect.h - header_h - status_bar_h

    visible_lines := int(body_h / line_h)
    if visible_lines <= 0 do visible_lines = 1

    if d.cursor < d.scroll {
        d.scroll = d.cursor
    } else if d.cursor >= d.scroll + visible_lines {
        d.scroll = d.cursor - visible_lines + 1
    }

    // Set hardware clip rect so Dired content cannot bleed outside its split
    clip := sdl.Rect{i32(rect.x), i32(rect.y), i32(rect.w), i32(rect.h)}
    sdl.SetRenderClipRect(renderer, &clip)
    defer sdl.SetRenderClipRect(renderer, nil)

    // 1. Background
    bg_color := sdl.FColor{0.08, 0.08, 0.1, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    bg_rect := rect
    sdl.RenderFillRect(renderer, &bg_rect)

    // 2. Header
    header_rect := sdl.FRect{
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = header_h,
    }
    sdl.SetRenderDrawColor(renderer, 28, 30, 38, 255)
    sdl.RenderFillRect(renderer, &header_rect)

    header_line := fmt.tprintf("DIR: %s", d.path)
    push_line(font, header_line, Vec2{rect.x + 16.0, rect.y + 4.0}, sdl.FColor{0.95, 0.85, 0.45, 1.0}, .HALF)
    push_line(font, "Press <Enter>/<l> to open, <h>/<-> for parent, <:> for commands", Vec2{rect.x + 16.0, rect.y + 4.0 + line_h}, sdl.FColor{0.5, 0.55, 0.65, 1.0}, .HALF)

    div_rect := sdl.FRect{
        x = rect.x,
        y = rect.y + header_h - 1.0,
        w = rect.w,
        h = 1.0,
    }
    sdl.SetRenderDrawColor(renderer, 48, 52, 64, 255)
    sdl.RenderFillRect(renderer, &div_rect)

    // 3. Entries
    for i in 0 ..< visible_lines {
        idx := d.scroll + i
        if idx >= len(d.entries) do break

        entry := d.entries[idx]
        y_pos := rect.y + header_h + f32(i) * line_h

        if idx == d.cursor && is_focused {
            sel_rect := sdl.FRect{
                x = rect.x,
                y = y_pos,
                w = rect.w,
                h = line_h,
            }
            sdl.SetRenderDrawColor(renderer, 36, 40, 52, 255)
            sdl.RenderFillRect(renderer, &sel_rect)

            mark_rect := sdl.FRect{
                x = rect.x,
                y = y_pos,
                w = 3.0,
                h = line_h,
            }
            sdl.SetRenderDrawColor(renderer, 97, 175, 239, 255)
            sdl.RenderFillRect(renderer, &mark_rect)
        }

        if entry.is_dir {
            name_str := fmt.tprintf("%s/", entry.name)
            push_line(font, name_str, Vec2{rect.x + 24.0, y_pos}, sdl.FColor{0.45, 0.75, 0.98, 1.0}, .HALF)
        } else {
            push_line(font, entry.name, Vec2{rect.x + 24.0, y_pos}, sdl.FColor{0.9, 0.9, 0.9, 1.0}, .HALF)

            size_str := dired_format_size(entry.size)
            size_x := max(rect.x + rect.w - 140.0, rect.x + 250.0)
            push_line(font, size_str, Vec2{size_x, y_pos}, sdl.FColor{0.5, 0.5, 0.55, 1.0}, .HALF)
        }
    }

    // 4. Status Bar
    status_bar_rect := sdl.FRect{
        x = rect.x,
        y = rect.y + rect.h - status_bar_h,
        w = rect.w,
        h = status_bar_h,
    }
    status_bar_bg := is_focused ? sdl.FColor{0.14, 0.16, 0.22, 1.0} : sdl.FColor{0.1, 0.11, 0.14, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, status_bar_bg.r, status_bar_bg.g, status_bar_bg.b, status_bar_bg.a)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    focus_badge := is_focused ? "[ACTIVE] " : ""
    status_str := fmt.tprintf("%s-- DIRED --   %d / %d items", focus_badge, d.cursor + 1, len(d.entries))
    status_color := is_focused ? sdl.FColor{0.95, 0.75, 0.3, 1.0} : sdl.FColor{0.6, 0.6, 0.6, 1.0}
    push_line(font, status_str, Vec2{rect.x + 10.0, rect.y + rect.h - status_bar_h + 4.0}, status_color, .HALF)

    flush_text(font, renderer)
}
