package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

DiredSortBy :: enum {
    Name,
    Size,
    Time,
}

DiredSortOrder :: enum {
    Asc,
    Desc,
}

DiredEntry :: struct {
    name     : string,
    is_dir   : bool,
    size     : i64,
    mod_time : time.Time,
}

Dired :: struct {
    path         : string,
    entries      : [dynamic]DiredEntry,
    cursor       : int,
    scroll       : int,
    last_action  : time.Time,
    sort_by      : DiredSortBy,
    sort_order   : DiredSortOrder,
    is_editing   : bool,
    orig_entries : [dynamic]DiredEntry,
}

dired_init :: proc(d: ^Dired) {
    d.entries = make([dynamic]DiredEntry, context.allocator)
    d.orig_entries = make([dynamic]DiredEntry, context.allocator)
    d.cursor = 0
    d.scroll = 0
    d.last_action = time.now()
    d.sort_by = .Name
    d.sort_order = .Asc
    d.is_editing = false
}

dired_destroy :: proc(d: ^Dired) {
    for e in d.entries {
        delete(e.name)
    }
    delete(d.entries)

    for e in d.orig_entries {
        delete(e.name)
    }
    delete(d.orig_entries)

    if d.path != "" {
        delete(d.path)
        d.path = ""
    }
}

dired_sort_name :: proc(sort_by: DiredSortBy) -> string {
    switch sort_by {
    case .Name: return "Name"
    case .Size: return "Size"
    case .Time: return "Time"
    }
    return "Name"
}

dired_cycle_sort :: proc(d: ^Dired) {
    switch d.sort_by {
    case .Name: d.sort_by = .Size
    case .Size: d.sort_by = .Time
    case .Time: d.sort_by = .Name
    }
}

dired_compare_entries :: proc(a, b: DiredEntry, sort_by: DiredSortBy, order: DiredSortOrder) -> bool {
    result := false
    switch sort_by {
    case .Name:
        result = strings.compare(a.name, b.name) < 0
    case .Size:
        if a.size == b.size {
            result = strings.compare(a.name, b.name) < 0
        } else {
            result = a.size < b.size
        }
    case .Time:
        diff := time.diff(a.mod_time, b.mod_time)
        if diff == 0 {
            result = strings.compare(a.name, b.name) < 0
        } else {
            // By default for Time, newer files first
            result = diff > 0
        }
    }

    if order == .Desc {
        result = !result
    }
    return result
}

dired_sort_entries :: proc(d: ^Dired) {
    if len(d.entries) <= 2 do return // entry 0 is always ".."

    dirs := make([dynamic]DiredEntry, context.allocator)
    defer delete(dirs)
    files := make([dynamic]DiredEntry, context.allocator)
    defer delete(files)

    for i := 1; i < len(d.entries); i += 1 {
        entry := d.entries[i]
        if entry.is_dir {
            append(&dirs, entry)
        } else {
            append(&files, entry)
        }
    }

    // Sort directories
    for i := 0; i < len(dirs); i += 1 {
        for j := i + 1; j < len(dirs); j += 1 {
            if !dired_compare_entries(dirs[i], dirs[j], d.sort_by, d.sort_order) {
                dirs[i], dirs[j] = dirs[j], dirs[i]
            }
        }
    }

    // Sort files
    for i := 0; i < len(files); i += 1 {
        for j := i + 1; j < len(files); j += 1 {
            if !dired_compare_entries(files[i], files[j], d.sort_by, d.sort_order) {
                files[i], files[j] = files[j], files[i]
            }
        }
    }

    parent := d.entries[0]
    clear(&d.entries)
    append(&d.entries, parent)
    for de in dirs {
        append(&d.entries, de)
    }
    for fe in files {
        append(&d.entries, fe)
    }
}

dired_load_path :: proc(d: ^Dired, dir_path: string) -> bool {
    for e in d.entries {
        delete(e.name)
    }
    clear(&d.entries)

    abs_path, abs_err := filepath.abs(dir_path, context.allocator)
    if abs_err != nil {
        abs_path, _ = filepath.clean(dir_path, context.allocator)
    }
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
        name     = strings.clone(".."),
        is_dir   = true,
        size     = 0,
        mod_time = time.now(),
    })

    for f in files {
        if f.name == "." || f.name == ".." do continue
        is_directory := f.type == .Directory

        entry := DiredEntry{
            name     = strings.clone(f.name),
            is_dir   = is_directory,
            size     = f.size,
            mod_time = f.modification_time,
        }
        append(&d.entries, entry)
    }

    dired_sort_entries(d)

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

dired_enter_edit_mode :: proc(d: ^Dired, e: ^Editor, font: ^Font, window: ^sdl.Window) {
    d.is_editing = true

    for orig in d.orig_entries {
        delete(orig.name)
    }
    clear(&d.orig_entries)

    b: strings.Builder
    strings.builder_init(&b, context.allocator)
    defer strings.builder_destroy(&b)

    for i := 1; i < len(d.entries); i += 1 {
        entry := d.entries[i]
        append(&d.orig_entries, DiredEntry{
            name     = strings.clone(entry.name),
            is_dir   = entry.is_dir,
            size     = entry.size,
            mod_time = entry.mod_time,
        })

        if entry.is_dir {
            strings.write_string(&b, entry.name)
            strings.write_string(&b, "/\n")
        } else {
            strings.write_string(&b, entry.name)
            strings.write_string(&b, "\n")
        }
    }

    full_text := strings.to_string(b)
    editor_destroy(e)
    display_title := fmt.tprintf("DIRED [%s] (edit mode: :w to save, :q to cancel)", d.path)
    editor_init(e, font, full_text, display_title)

    target_row := max(0, d.cursor - 1)
    e.cursor.row = target_row
    e.cursor.col = 0
    e.desired_col = 0
    editor_set_mode(e, .Insert, window)
}

dired_apply_edits :: proc(d: ^Dired, e: ^Editor) -> string {
    full_text := pt_full_text(&e.table)
    defer delete(full_text)

    raw_lines := strings.split(full_text, "\n", context.allocator)
    defer delete(raw_lines)

    EditItem :: struct {
        name   : string,
        is_dir : bool,
    }

    new_items := make([dynamic]EditItem, context.allocator)
    defer {
        for item in new_items {
            delete(item.name)
        }
        delete(new_items)
    }

    for line in raw_lines {
        trimmed := strings.trim_space(line)
        trimmed = strings.trim_right(trimmed, "\r")
        if len(trimmed) == 0 do continue

        is_directory := strings.has_suffix(trimmed, "/")
        clean_name := strings.trim_right(trimmed, "/")
        if clean_name == "." || clean_name == ".." || clean_name == "" do continue

        append(&new_items, EditItem{
            name   = strings.clone(clean_name),
            is_dir = is_directory,
        })
    }

    orig_matched := make([]bool, len(d.orig_entries), context.allocator)
    defer delete(orig_matched)
    new_matched := make([]bool, len(new_items), context.allocator)
    defer delete(new_matched)

    // Phase 1: Match identical names (unchanged items)
    for ni := 0; ni < len(new_items); ni += 1 {
        for oi := 0; oi < len(d.orig_entries); oi += 1 {
            if !orig_matched[oi] && !new_matched[ni] {
                if d.orig_entries[oi].name == new_items[ni].name && d.orig_entries[oi].is_dir == new_items[ni].is_dir {
                    orig_matched[oi] = true
                    new_matched[ni] = true
                    break
                }
            }
        }
    }

    renamed_count := 0
    created_count := 0
    deleted_count := 0

    // Phase 2: Pair unmatched original with unmatched new (Renames)
    for oi := 0; oi < len(d.orig_entries); oi += 1 {
        if orig_matched[oi] do continue
        for ni := 0; ni < len(new_items); ni += 1 {
            if new_matched[ni] do continue

            old_path, _ := filepath.join([]string{d.path, d.orig_entries[oi].name}, context.allocator)
            defer delete(old_path)
            new_path, _ := filepath.join([]string{d.path, new_items[ni].name}, context.allocator)
            defer delete(new_path)

            if os.rename(old_path, new_path) == nil {
                renamed_count += 1
                orig_matched[oi] = true
                new_matched[ni] = true
                break
            }
        }
    }

    // Phase 3: Create remaining unmatched new items
    for ni := 0; ni < len(new_items); ni += 1 {
        if new_matched[ni] do continue

        new_path, _ := filepath.join([]string{d.path, new_items[ni].name}, context.allocator)
        defer delete(new_path)

        if new_items[ni].is_dir {
            if os.make_directory(new_path) == nil {
                created_count += 1
                new_matched[ni] = true
            }
        } else {
            if os.write_entire_file(new_path, "") == nil {
                created_count += 1
                new_matched[ni] = true
            }
        }
    }

    // Phase 4: Delete remaining unmatched original items
    for oi := 0; oi < len(d.orig_entries); oi += 1 {
        if orig_matched[oi] do continue

        old_path, _ := filepath.join([]string{d.path, d.orig_entries[oi].name}, context.allocator)
        defer delete(old_path)

        if os.remove(old_path) == nil {
            deleted_count += 1
            orig_matched[oi] = true
        }
    }

    // Refresh directory & sort
    dired_load_path(d, d.path)
    d.is_editing = false

    return fmt.tprintf("Dired: applied changes (%d created, %d renamed, %d deleted)", created_count, renamed_count, deleted_count)
}

dired_handle_event :: proc(d: ^Dired, event: ^sdl.Event, app: ^App, pane: ^Pane) -> bool {
    #partial switch event.type {
    case .KEY_DOWN:
        d.last_action = time.now()
        key := event.key.key
        mod := event.key.mod
        is_shift := (mod & sdl.KMOD_SHIFT) != {}
        is_ctrl := (mod & sdl.KMOD_CTRL) != {}

        // Command mode trigger ':' from Dired
        if key == sdl.K_COLON || (key == sdl.K_SEMICOLON && is_shift) {
            app_open_command_prompt(app)
            return true
        }

        // Toggle edit mode via 'i' or 'Esc'
        if key == sdl.K_I || key == sdl.K_ESCAPE {
            dired_enter_edit_mode(d, &pane.editor, &app.font, app.window)
            app.cmd_prompt.message = "-- DIRED EDIT -- Add/edit lines (dir/ for folders), :w to save, :q to cancel"
            return true
        }

        // Cycle sort with 's' or reverse with 'S'
        if key == sdl.K_S {
            if is_shift {
                d.sort_order = .Desc if d.sort_order == .Asc else .Asc
            } else {
                dired_cycle_sort(d)
            }
            dired_sort_entries(d)
            app.cmd_prompt.message = fmt.tprintf("Dired: sorted by %s (%s)", dired_sort_name(d.sort_by), "desc" if d.sort_order == .Desc else "asc")
            return true
        }

        // Block navigation with Ctrl+j and Ctrl+k
        if is_ctrl && (key == sdl.K_J || key == sdl.K_DOWN) {
            if len(d.entries) > 0 {
                d.cursor = min(len(d.entries) - 1, d.cursor + 5)
            }
            return true
        }

        if is_ctrl && (key == sdl.K_K || key == sdl.K_UP) {
            if len(d.entries) > 0 {
                d.cursor = max(0, d.cursor - 5)
            }
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
            if parent != "" {
                dired_load_path(d, parent)
            }
            return true

        case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_L:
            if d.cursor >= 0 && d.cursor < len(d.entries) {
                entry := d.entries[d.cursor]
                if entry.name == ".." {
                    parent := filepath.dir(d.path)
                    if parent != "" {
                        dired_load_path(d, parent)
                    }
                } else if entry.is_dir {
                    new_path, _ := filepath.join([]string{d.path, entry.name}, context.allocator)
                    defer delete(new_path)
                    dired_load_path(d, new_path)
                } else {
                    target_file, _ := filepath.join([]string{d.path, entry.name}, context.allocator)
                    defer delete(target_file)
                    app_pane_open_file(app, pane, target_file)
                }
            }
            return true

        case sdl.K_Q:
            if pane != nil && pane.editor.file_path != "" && !strings.has_prefix(pane.editor.file_path, "DIRED") {
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

dired_render :: proc(d: ^Dired, renderer: ^sdl.Renderer, font: ^Font, rect: sdl.FRect, is_focused: bool, theme: ^Theme) {
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
    bg_color := theme.bg
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
    sdl.SetRenderDrawColorFloat(renderer, theme.cursor_line_bg.r, theme.cursor_line_bg.g, theme.cursor_line_bg.b, theme.cursor_line_bg.a)
    sdl.RenderFillRect(renderer, &header_rect)

    sort_info := fmt.tprintf("[Sort: %s (%s)]", dired_sort_name(d.sort_by), "desc" if d.sort_order == .Desc else "asc")
    header_line := fmt.tprintf("DIR: %s   %s", d.path, sort_info)
    push_line(font, header_line, Vec2{rect.x + 16.0, rect.y + 4.0}, theme.keyword, .HALF)
    push_line(font, "<i>/<Esc> edit, <Enter>/<l> open, <h>/<-> parent, <s> sort, <:> command", Vec2{rect.x + 16.0, rect.y + 4.0 + line_h}, theme.comment, .HALF)

    div_rect := sdl.FRect{
        x = rect.x,
        y = rect.y + header_h - 1.0,
        w = rect.w,
        h = 1.0,
    }
    sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
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
            sdl.SetRenderDrawColorFloat(renderer, theme.cursor_line_bg.r, theme.cursor_line_bg.g, theme.cursor_line_bg.b, theme.cursor_line_bg.a)
            sdl.RenderFillRect(renderer, &sel_rect)

            mark_rect := sdl.FRect{
                x = rect.x,
                y = y_pos,
                w = 3.0,
                h = line_h,
            }
            sdl.SetRenderDrawColorFloat(renderer, theme.cursor.r, theme.cursor.g, theme.cursor.b, theme.cursor.a)
            sdl.RenderFillRect(renderer, &mark_rect)
        }

        if entry.is_dir {
            name_str := fmt.tprintf("%s/", entry.name)
            push_line(font, name_str, Vec2{rect.x + 24.0, y_pos}, theme.fn_name, .HALF)
        } else {
            push_line(font, entry.name, Vec2{rect.x + 24.0, y_pos}, theme.fg, .HALF)

            size_str := dired_format_size(entry.size)
            size_x := max(rect.x + rect.w - 140.0, rect.x + 250.0)
            push_line(font, size_str, Vec2{size_x, y_pos}, theme.comment, .HALF)
        }
    }

    // 4. Status Bar
    status_bar_rect := sdl.FRect{
        x = rect.x,
        y = rect.y + rect.h - status_bar_h,
        w = rect.w,
        h = status_bar_h,
    }
    status_bar_bg := theme.status_bg if is_focused else theme.status_inactive_bg
    sdl.SetRenderDrawColorFloat(renderer, status_bar_bg.r, status_bar_bg.g, status_bar_bg.b, status_bar_bg.a)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    focus_badge := "[ACTIVE] " if is_focused else ""
    status_str := fmt.tprintf("%s-- DIRED --   %d / %d items   (<s> to sort, <i>/<Esc> to edit)", focus_badge, d.cursor + 1, len(d.entries))
    status_color := theme.keyword if is_focused else theme.status_inactive_fg
    push_line(font, status_str, Vec2{rect.x + 10.0, rect.y + rect.h - status_bar_h + 4.0}, status_color, .HALF)

    flush_text(font, renderer)
}
