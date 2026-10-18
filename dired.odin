package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
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
    // Async listing state; the worker never references the Dired itself.
    job          : ^Dired_Load_Job,
    generation   : u64,
    loading      : bool,
    load_failed  : bool,
    apply_ok     : bool,
    // Allocator that owns entries/path (sync loads use context, async jobs use
    // the default allocator because the worker outlives the caller's context).
    allocator    : runtime.Allocator,
}

Dired_Load_Job :: struct {
    thread     : ^thread.Thread,
    mutex      : sync.Mutex,
    cancel     : bool,
    done       : bool,
    generation : u64,
    path       : string,
    sort_by    : DiredSortBy,
    sort_order : DiredSortOrder,
    entries    : [dynamic]DiredEntry,
    ok         : bool,
}

// Canceled jobs whose owner is gone. Joined only after thread.is_done.
dired_orphan_jobs: [dynamic]^Dired_Load_Job
dired_orphan_mutex: sync.Mutex

dired_init :: proc(d: ^Dired) {
    d.entries = make([dynamic]DiredEntry, context.allocator)
    d.orig_entries = make([dynamic]DiredEntry, context.allocator)
    d.cursor = 0
    d.scroll = 0
    d.last_action = time.now()
    d.sort_by = .Name
    d.sort_order = .Asc
    d.is_editing = false
    d.job = nil
    d.generation = 0
    d.loading = false
    d.load_failed = false
    d.apply_ok = false
    d.allocator = context.allocator
}

dired_destroy :: proc(d: ^Dired) {
    dired_orphan_job(&d.job)
    for e in d.entries {
        delete(e.name, d.allocator)
    }
    delete(d.entries)

    for e in d.orig_entries {
        delete(e.name, context.allocator)
    }
    delete(d.orig_entries)

    if d.path != "" {
        delete(d.path, d.allocator)
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

dired_sort_entry_list :: proc(entries: ^[dynamic]DiredEntry, sort_by: DiredSortBy, order: DiredSortOrder) {
    if len(entries^) <= 2 do return // entry 0 is always ".."

    dirs := make([dynamic]DiredEntry, 0, len(entries^), context.allocator)
    defer delete(dirs)
    files := make([dynamic]DiredEntry, 0, len(entries^), context.allocator)
    defer delete(files)

    for i := 1; i < len(entries^); i += 1 {
        entry := entries^[i]
        if entry.is_dir {
            append(&dirs, entry)
        } else {
            append(&files, entry)
        }
    }

    Sort_Context :: struct {
        sort_by:    DiredSortBy,
        sort_order: DiredSortOrder,
    }
    sort_ctx := Sort_Context{sort_by = sort_by, sort_order = order}
    less := proc(a, b: DiredEntry, user_data: rawptr) -> bool {
        ctx := (^Sort_Context)(user_data)
        return dired_compare_entries(a, b, ctx.sort_by, ctx.sort_order)
    }
    slice.sort_by_with_data(dirs[:], less, rawptr(&sort_ctx))
    slice.sort_by_with_data(files[:], less, rawptr(&sort_ctx))

    parent := entries^[0]
    clear(entries)
    append(entries, parent)
    for de in dirs {
        append(entries, de)
    }
    for fe in files {
        append(entries, fe)
    }
}

dired_sort_entries :: proc(d: ^Dired) {
    dired_sort_entry_list(&d.entries, d.sort_by, d.sort_order)
}

// Build a sorted listing for one directory without touching a Dired. Used by
// the synchronous path and the background worker.
dired_scan_path :: proc(
    abs_path: string,
    allocator: runtime.Allocator,
    cancel: ^bool,
    sort_by: DiredSortBy,
    order: DiredSortOrder,
) -> ([dynamic]DiredEntry, bool) {
    if cancel != nil && sync.atomic_load(cancel) do return nil, false

    handle, err := os.open(abs_path)
    if err != nil do return nil, false
    defer os.close(handle)

    files, ferr := os.read_dir(handle, -1, allocator)
    if ferr != nil do return nil, false
    defer os.file_info_slice_delete(files, allocator)

    new_entries := make([dynamic]DiredEntry, 0, len(files) + 1, allocator)
    append(&new_entries, DiredEntry{
        name     = strings.clone("..", allocator),
        is_dir   = true,
        size     = 0,
        mod_time = time.now(),
    })

    for f in files {
        if cancel != nil && sync.atomic_load(cancel) {
            for e in new_entries do delete(e.name, allocator)
            delete(new_entries)
            return nil, false
        }
        if f.name == "." || f.name == ".." do continue
        is_directory := f.type == .Directory
        if f.type == .Symlink {
            if full, join_err := filepath.join([]string{abs_path, f.name}, context.temp_allocator); join_err == nil {
                is_directory = os.is_dir(full)
            }
        }
        append(&new_entries, DiredEntry{
            name     = strings.clone(f.name, allocator),
            is_dir   = is_directory,
            size     = f.size,
            mod_time = f.modification_time,
        })
    }

    dired_sort_entry_list(&new_entries, sort_by, order)
    return new_entries, true
}

dired_install_entries :: proc(d: ^Dired, entries: [dynamic]DiredEntry, abs_path: string, allocator: runtime.Allocator) {
    old_alloc := d.allocator
    for e in d.entries do delete(e.name, old_alloc)
    delete(d.entries)
    if d.path != "" do delete(d.path, old_alloc)

    d.entries = entries
    d.allocator = allocator
    d.path = abs_path

    for orig in d.orig_entries do delete(orig.name, context.allocator)
    clear(&d.orig_entries)
    d.is_editing = false

    d.cursor = 0
    d.scroll = 0
    d.load_failed = false
    d.last_action = time.now()
}

dired_load_path :: proc(d: ^Dired, dir_path: string) -> bool {
    abs_path, abs_err := filepath.abs(dir_path, context.allocator)
    if abs_err != nil {
        abs_path, _ = filepath.clean(dir_path, context.allocator)
    }

    entries, ok := dired_scan_path(abs_path, context.allocator, nil, d.sort_by, d.sort_order)
    if !ok {
        delete(abs_path)
        return false
    }
    dired_install_entries(d, entries, abs_path, context.allocator)
    return true
}

dired_job_worker :: proc(data: rawptr) {
    job := (^Dired_Load_Job)(data)
    alloc := runtime.default_allocator()
    entries, ok := dired_scan_path(job.path, alloc, &job.cancel, job.sort_by, job.sort_order)

    sync.mutex_lock(&job.mutex)
    if sync.atomic_load(&job.cancel) {
        if ok {
            for e in entries do delete(e.name, alloc)
            delete(entries)
        }
        job.ok = false
    } else {
        job.entries = entries
        job.ok = ok
    }
    sync.mutex_unlock(&job.mutex)
    sync.atomic_store(&job.done, true)
}

dired_orphan_job :: proc(job: ^^Dired_Load_Job) {
    if job^ == nil do return
    if dired_orphan_jobs.allocator.procedure == nil {
        dired_orphan_jobs.allocator = runtime.default_allocator()
    }
    sync.atomic_store(&job^.cancel, true)
    sync.mutex_lock(&dired_orphan_mutex)
    append(&dired_orphan_jobs, job^)
    sync.mutex_unlock(&dired_orphan_mutex)
    job^ = nil
}

dired_poll_orphans :: proc() {
    sync.mutex_lock(&dired_orphan_mutex)
    defer sync.mutex_unlock(&dired_orphan_mutex)
    i := 0
    for i < len(dired_orphan_jobs) {
        job := dired_orphan_jobs[i]
        if sync.atomic_load(&job.done) {
            ordered_remove(&dired_orphan_jobs, i)
            if job.ok {
                for e in job.entries do delete(e.name, runtime.default_allocator())
                delete(job.entries)
            }
            if job.path != "" do delete(job.path, runtime.default_allocator())
            free(job, runtime.default_allocator())
        } else {
            i += 1
        }
    }
}

dired_request_load :: proc(d: ^Dired, dir_path: string, sort_by: DiredSortBy, order: DiredSortOrder) {
    dired_orphan_job(&d.job)

    abs_path, abs_err := filepath.abs(dir_path, runtime.default_allocator())
    if abs_err != nil {
        abs_path, _ = filepath.clean(dir_path, runtime.default_allocator())
    }

    d.generation += 1
    job := new(Dired_Load_Job, runtime.default_allocator())
    job.path = abs_path
    job.generation = d.generation
    job.sort_by = sort_by
    job.sort_order = order
    job.cancel = false
    job.done = false
    d.job = job
    d.loading = true
    d.load_failed = false
    background_thread_detached(rawptr(job), dired_job_worker)
}

// Blocking wait used by tests and one-shot callers that need the listing.
dired_wait_load :: proc(d: ^Dired) {
    for d.loading {
        dired_poll(d)
        dired_poll_orphans()
        time.sleep(1 * time.Millisecond)
    }
}

dired_poll :: proc(d: ^Dired) {
    job := d.job
    if job == nil do return

    if !sync.atomic_load(&job.done) do return

    entries: [dynamic]DiredEntry
    ok := false
    generation: u64 = 0
    path := ""
    sync.mutex_lock(&job.mutex)
    entries = job.entries
    job.entries = nil
    ok = job.ok
    generation = job.generation
    path = job.path
    job.path = ""
    sync.mutex_unlock(&job.mutex)
    free(job, runtime.default_allocator())
    d.job = nil
    d.loading = false

    if generation != d.generation || !ok {
        for e in entries do delete(e.name, runtime.default_allocator())
        delete(entries)
        if path != "" do delete(path, runtime.default_allocator())
        if generation == d.generation do d.load_failed = true
        return
    }
    dired_install_entries(d, entries, path, runtime.default_allocator())
}

dired_format_size :: proc(size: i64) -> string {
    if size < 1024 {
        return fmt.tprintf("% 4d B", size)
    } else if size < 1024 * 1024 {
        return fmt.tprintf("% 4.1f KB", f32(size) / 1024.0)
    } else {
        return fmt.tprintf("% 4.1f MB", f32(size) / (1024.0 * 1024.0))
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
    d.apply_ok = false
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

    for raw_line in raw_lines {
        // Preserve spaces: they are legal filename characters. Only strip CR.
        line := strings.trim_right(raw_line, "\r")
        if len(line) == 0 do continue

        is_directory := strings.has_suffix(line, "/")
        clean_name := strings.trim_right(line, "/")
        if clean_name == "." || clean_name == ".." || clean_name == "" do continue

        // '/' would let an edited listing escape the browsed directory.
        if strings.contains(clean_name, "/") {
            return fmt.tprintf("Dired: invalid name '%s' (contains '/'); no changes applied", clean_name)
        }

        append(&new_items, EditItem{
            name   = strings.clone(clean_name),
            is_dir = is_directory,
        })
    }

    // Validate the whole edit before touching the filesystem.
    seen_names := make(map[string]bool, context.temp_allocator)
    for item in new_items {
        if seen_names[item.name] do return fmt.tprintf("Dired: duplicate entry '%s'; no changes applied", item.name)
        seen_names[item.name] = true
    }
    for item in new_items {
        for orig in d.orig_entries {
            if item.name == orig.name && item.is_dir != orig.is_dir {
                return fmt.tprintf("Dired: cannot change '%s' between file and directory; no changes applied", item.name)
            }
        }
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
    d.apply_ok = true

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
        if key == KEY_CMD_PROMPT || (key == KEY_CMD_PROMPT_ALT && is_shift) {
            app_open_command_prompt(app)
            return true
        }

        // Toggle edit mode via 'i' or 'Esc'
        if key == KEY_DIRED_EDIT || key == sdl.K_ESCAPE {
            dired_enter_edit_mode(d, &pane.editor, &app.font, app.window)
            app.cmd_prompt.message = "-- DIRED EDIT -- Add/edit lines (dir/ for folders), :w to save, :q to cancel"
            return true
        }

        // Cycle sort or reverse with the shifted key
        if (is_shift && key == KEY_DIRED_SORT_REVERSE) || key == KEY_DIRED_SORT {
            if is_shift && key == KEY_DIRED_SORT_REVERSE {
                d.sort_order = .Desc if d.sort_order == .Asc else .Asc
            } else {
                dired_cycle_sort(d)
            }
            dired_sort_entries(d)
            app_set_message(app, fmt.tprintf("Dired: sorted by %s (%s)", dired_sort_name(d.sort_by), "desc" if d.sort_order == .Desc else "asc"))
            return true
        }

        // Block navigation with Ctrl+j and Ctrl+k
        if is_ctrl && (key == KEY_DIRED_PAGE_DOWN || key == sdl.K_DOWN) {
            if len(d.entries) > 0 {
                d.cursor = min(len(d.entries) - 1, d.cursor + 5)
            }
            return true
        }

        if is_ctrl && (key == KEY_DIRED_PAGE_UP || key == sdl.K_UP) {
            if len(d.entries) > 0 {
                d.cursor = max(0, d.cursor - 5)
            }
            return true
        }

        if key == KEY_DIRED_DOWN || key == sdl.K_DOWN {
            if len(d.entries) > 0 {
                d.cursor = min(len(d.entries) - 1, d.cursor + 1)
            }
            return true
        }

        if key == KEY_DIRED_UP || key == sdl.K_UP {
            if len(d.entries) > 0 {
                d.cursor = max(0, d.cursor - 1)
            }
            return true
        }

        if key == KEY_DIRED_PARENT || key == KEY_DIRED_PARENT_ALT {
            if d.loading do return true
            parent := filepath.dir(d.path)
            if parent != "" {
                dired_request_load(d, parent, d.sort_by, d.sort_order)
            }
            return true
        }

        if key == KEY_DIRED_OPEN || key == sdl.K_RETURN || key == sdl.K_KP_ENTER {
            if d.loading do return true
            if d.cursor >= 0 && d.cursor < len(d.entries) {
                entry := d.entries[d.cursor]
                if entry.name == ".." {
                    parent := filepath.dir(d.path)
                    if parent != "" {
                        dired_request_load(d, parent, d.sort_by, d.sort_order)
                    }
                } else if entry.is_dir {
                    new_path, _ := filepath.join([]string{d.path, entry.name}, context.allocator)
                    defer delete(new_path)
                    dired_request_load(d, new_path, d.sort_by, d.sort_order)
                } else {
                    target_file, _ := filepath.join([]string{d.path, entry.name}, context.allocator)
                    defer delete(target_file)
                    app_pane_open_file(app, pane, target_file)
                }
            }
            return true
        }

        if key == KEY_DIRED_QUIT {
            if pane != nil && pane.editor.file_path != "" && !strings.has_prefix(pane.editor.file_path, "DIRED") {
                pane.kind = .Editor
            } else if len(app.panes) > 1 {
                app_close_pane(app, pane)
            } else {
                app.running = false
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
    load_suffix := "   (loading...)" if d.loading else ("   (unreadable)" if d.load_failed else "")
    header_line := fmt.tprintf("DIR: %s   %s%s", d.path, sort_info, load_suffix)
    push_line(font, header_line, Vec2{rect.x + 16.0, rect.y + 4.0}, theme.keyword, .HALF)
    hint := fmt.tprintf(
        "<%s>/<Esc> edit, <Enter>/<%s> open, <%s>/<%s> parent, <%s> sort, <:> command",
        key_label(KEY_DIRED_EDIT, {}, .Plain),
        key_label(KEY_DIRED_OPEN, {}, .Plain),
        key_label(KEY_DIRED_PARENT, {}, .Plain),
        key_label(KEY_DIRED_PARENT_ALT, {}, .Plain),
        key_label(KEY_DIRED_SORT, {}, .Plain),
    )
    push_line(font, hint, Vec2{rect.x + 16.0, rect.y + 4.0 + line_h}, theme.comment, .HALF)

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
    status_str := fmt.tprintf(
        "%s-- DIRED --   %d / %d items   (<%s> to sort, <%s>/<Esc> to edit)",
        focus_badge,
        d.cursor + 1,
        len(d.entries),
        key_label(KEY_DIRED_SORT, {}, .Plain),
        key_label(KEY_DIRED_EDIT, {}, .Plain),
    )
    status_color := theme.keyword if is_focused else theme.status_inactive_fg
    push_line(font, status_str, Vec2{rect.x + 10.0, rect.y + rect.h - status_bar_h + 4.0}, status_color, .HALF)

    flush_text(font, renderer)
}
