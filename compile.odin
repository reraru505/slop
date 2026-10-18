package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:text/regex"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

CompilationLine :: struct {
    text      : string,
    file_path : string,
    line_num  : int,
    col_num   : int,
    is_error  : bool,
    is_warn   : bool,
}

// A running build. The worker owns everything except the fields protected by
// mutex; the main thread polls `done` and takes the results.
Compilation_Job :: struct {
    thread:      ^thread.Thread,
    mutex:       sync.Mutex,
    command:     string,
    working_dir: string,
    output:      string,
    exit_code:   int,
    failed:      bool,
    error_text:  string,
    done:        bool,
}

Compilation :: struct {
    command     : string,
    working_dir : string,
    lines       : [dynamic]CompilationLine,
    cursor      : int,
    scroll      : int,
    status      : string,
    exit_code   : int,
    finished    : bool,
    error_regex : regex.Regular_Expression,
    has_regex   : bool,
    last_action : time.Time,
    job         : ^Compilation_Job,
}

compilation_init :: proc(c: ^Compilation) {
    c.command = ""
    c.working_dir = ""
    c.lines = make([dynamic]CompilationLine, context.allocator)
    c.cursor = 0
    c.scroll = 0
    c.status = strings.clone("Idle")
    c.exit_code = 0
    c.finished = false
    c.last_action = time.now()

    // Pattern matching:
    // 1. Odin style: path(line:col) or path(line)
    // 2. GCC/Clang/Rust style: path:line:col or path:line
    pattern := `^(.+?)(?:\(([0-9]+)(?::([0-9]+))?\)|:([0-9]+)(?::([0-9]+))?)(?:[:\s]+(.*))?$`
    r, err := regex.create(pattern)
    if err == nil {
        c.error_regex = r
        c.has_regex = true
    } else {
        c.has_regex = false
    }
}

compilation_destroy :: proc(c: ^Compilation) {
    if c.job != nil {
        job := c.job
        done := false
        sync.mutex_lock(&job.mutex)
        done = job.done
        sync.mutex_unlock(&job.mutex)
        if done {
            thread.join(job.thread)
            thread.destroy(job.thread)
            if job.output != "" do delete(job.output, runtime.default_allocator())
            if job.error_text != "" do delete(job.error_text, runtime.default_allocator())
            if job.command != "" do delete(job.command)
            if job.working_dir != "" do delete(job.working_dir)
            free(job)
        }
        // If the build is still running the worker owns the job; it finishes
        // independently and the OS reclaims the memory at process exit.
        c.job = nil
    }
    if c.has_regex {
        regex.destroy(c.error_regex)
        c.has_regex = false
    }
    for l in c.lines {
        delete(l.text)
        if l.file_path != "" {
            delete(l.file_path)
        }
    }
    delete(c.lines)
    if c.command != "" {
        delete(c.command)
        c.command = ""
    }
    if c.working_dir != "" {
        delete(c.working_dir)
        c.working_dir = ""
    }
    if c.status != "" {
        delete(c.status)
        c.status = ""
    }
}

compilation_parse_line :: proc(c: ^Compilation, line: string) -> CompilationLine {
    result := CompilationLine{
        text      = strings.clone(line),
        file_path = "",
        line_num  = 0,
        col_num   = 0,
        is_error  = false,
        is_warn   = false,
    }

    if !c.has_regex do return result

    trimmed := strings.trim_space(line)
    if len(trimmed) == 0 do return result

    capture, ok := regex.match(c.error_regex, trimmed)
    if !ok do return result
    defer regex.destroy(capture)

    if len(capture.groups) < 3 do return result

    raw_path := strings.trim_space(capture.groups[1])
    if raw_path == "" do return result

    // Group 2 is line number
    raw_line := capture.groups[2]
    l_num, _ := strconv.parse_int(raw_line)
    if l_num <= 0 do return result

    // Group 3 (when present) is the column. Non-participating capture groups
    // are omitted, so a column with no trailing message still gives four
    // groups: full match, path, line, column. If it is a message instead,
    // parse_int fails and the column stays 1.
    c_num := 1
    if len(capture.groups) >= 4 {
        parsed_col, ok_col := strconv.parse_int(capture.groups[3])
        if ok_col && parsed_col > 0 do c_num = parsed_col
    }

    result.file_path = strings.clone(raw_path)
    result.line_num  = l_num
    result.col_num   = c_num

    lower := strings.to_lower(trimmed, context.temp_allocator)
    if strings.contains(lower, "warning") || strings.contains(lower, "warn:") {
        result.is_warn = true
    } else {
        result.is_error = true
    }

    return result
}

// Runs the build off the main thread. Only the mutex-protected fields are
// shared; everything else in Compilation stays main-thread-owned.
compilation_worker :: proc(data: rawptr) {
    job := (^Compilation_Job)(data)
    // Results cross threads, so use a stable allocator rather than whatever
    // context the worker or the test harness happens to use.
    alloc := runtime.default_allocator()
    desc := os.Process_Desc{command = []string{"sh", "-c", job.command}}
    if job.working_dir != "" do desc.working_dir = job.working_dir
    state, stdout, stderr, err := os.process_exec(desc, alloc)

    combined: strings.Builder
    strings.builder_init(&combined, alloc)
    exit_code := 0
    failed := false
    error_text := ""

    if err != nil {
        failed = true
        exit_code = -1
        error_text = fmt.aprintf("%v", err, allocator = alloc)
    } else {
        exit_code = state.exit_code
        if len(stdout) > 0 do strings.write_bytes(&combined, stdout)
        if len(stderr) > 0 {
            if len(stdout) > 0 && stdout[len(stdout) - 1] != '\n' {
                strings.write_byte(&combined, '\n')
            }
            strings.write_bytes(&combined, stderr)
        }
    }
    delete(stdout, alloc)
    delete(stderr, alloc)

    out := strings.to_string(combined) // ownership moves to the main thread

    sync.mutex_lock(&job.mutex)
    job.output = out
    job.exit_code = exit_code
    job.failed = failed
    job.error_text = error_text
    job.done = true
    sync.mutex_unlock(&job.mutex)
}

compilation_finish :: proc(c: ^Compilation, output: string, exit_code: int, failed: bool, error_text: string) {
    alloc := runtime.default_allocator()
    defer if output != "" do delete(output, alloc)
    defer if error_text != "" do delete(error_text, alloc)

    if failed {
        c.exit_code = -1
        c.finished = true
        if c.status != "" do delete(c.status)
        c.status = fmt.aprintf("Failed to start (%s)", error_text)
        append(&c.lines, CompilationLine{
            text = fmt.aprintf("Compilation failed to execute: %s", error_text),
            is_error = true,
        })
        return
    }

    c.exit_code = exit_code
    c.finished = true

    lines := strings.split(output, "\n", context.allocator)
    defer delete(lines)

    error_count := 0
    warn_count := 0
    first_error_idx := -1

    for line in lines {
        if len(line) == 0 && len(c.lines) > 0 && c.lines[len(c.lines)-1].text == "" {
            continue
        }
        cline := compilation_parse_line(c, line)
        if cline.is_error {
            error_count += 1
            if first_error_idx == -1 do first_error_idx = len(c.lines)
        } else if cline.is_warn {
            warn_count += 1
            if first_error_idx == -1 do first_error_idx = len(c.lines)
        }
        append(&c.lines, cline)
    }

    append(&c.lines, CompilationLine{text = strings.clone("")})
    if c.status != "" do delete(c.status)
    if c.exit_code == 0 && error_count == 0 {
        c.status = fmt.aprintf("Finished (%d warnings)", warn_count)
        append(&c.lines, CompilationLine{
            text = fmt.aprintf("Compilation finished successfully (%d warnings).", warn_count),
        })
    } else if c.exit_code == 0 {
        // Some tools print diagnostics but still exit 0.
        c.status = fmt.aprintf("Finished (%d errors, %d warnings)", error_count, warn_count)
        append(&c.lines, CompilationLine{
            text = fmt.aprintf("Compilation completed with %d errors and %d warnings.", error_count, warn_count),
            is_error = true,
        })
    } else {
        c.status = fmt.aprintf("Exited with code %d (%d errors, %d warnings)", c.exit_code, error_count, warn_count)
        append(&c.lines, CompilationLine{
            text = fmt.aprintf("Compilation exited abnormally with code %d (%d errors, %d warnings).", c.exit_code, error_count, warn_count),
            is_error = true,
        })
    }

    if first_error_idx >= 0 {
        c.cursor = first_error_idx
    } else {
        c.cursor = 0
    }
    c.scroll = max(0, c.cursor - 5)
    c.last_action = time.now()
}

compilation_poll :: proc(c: ^Compilation) {
    job := c.job
    if job == nil do return

    done := false
    output: string
    exit_code := 0
    failed := false
    error_text := ""

    sync.mutex_lock(&job.mutex)
    done = job.done
    if done {
        output = job.output
        job.output = ""
        exit_code = job.exit_code
        failed = job.failed
        error_text = job.error_text
        job.error_text = ""
    }
    sync.mutex_unlock(&job.mutex)

    if !done do return

    thread.join(job.thread)
    thread.destroy(job.thread)
    c.job = nil
    compilation_finish(c, output, exit_code, failed, error_text)
    if job.command != "" do delete(job.command)
    if job.working_dir != "" do delete(job.working_dir)
    free(job)
}

// Blocking wait used by tests and any caller that needs the final state.
compilation_wait :: proc(c: ^Compilation) {
    for c.job != nil {
        compilation_poll(c)
        if c.job != nil do time.sleep(1 * time.Millisecond)
    }
}

compilation_run_command :: proc(c: ^Compilation, cmd_str: string, working_dir := "") {
    compilation_poll(c)
    if c.job != nil {
        if c.status != "" do delete(c.status)
        c.status = strings.clone("Compilation already running")
        return
    }

    // cmd_str may alias c.command (recompile passes it), so own the copy
    // before releasing the old one.
    new_command := strings.clone(cmd_str)
    if c.command != "" do delete(c.command)
    c.command = new_command

    // Clear previous output
    for l in c.lines {
        delete(l.text)
        if l.file_path != "" do delete(l.file_path)
    }
    clear(&c.lines)
    c.cursor = 0
    c.scroll = 0

    display_cwd := working_dir
    if display_cwd == "" {
        cwd, _ := os.get_working_directory(context.temp_allocator)
        display_cwd = cwd
    }
    // Remember the actual build directory so diagnostics in this buffer keep
    // resolving correctly even if the project root changes later.
    if c.working_dir != "" do delete(c.working_dir)
    c.working_dir = strings.clone(display_cwd, context.allocator)

    append(&c.lines, CompilationLine{
        text = fmt.aprintf("-*- mode: compilation; default-directory: \"%s\" -*-", display_cwd),
    })
    append(&c.lines, CompilationLine{
        text = fmt.aprintf("Compilation started: %s", new_command),
    })
    append(&c.lines, CompilationLine{text = strings.clone("")})

    c.finished = false
    if c.status != "" do delete(c.status)
    c.status = strings.clone("Running...")

    job := new(Compilation_Job)
    job.command = strings.clone(new_command)
    if working_dir != "" do job.working_dir = strings.clone(working_dir)
    job.thread = thread.create_and_start_with_data(rawptr(job), compilation_worker)
    c.job = job
}

paths_match :: proc(p1, p2: string) -> bool {
    if p1 == p2 do return true

    a1, err1 := filepath.abs(p1, context.temp_allocator)
    if err1 != nil do a1, _ = filepath.clean(p1, context.temp_allocator)
    a2, err2 := filepath.abs(p2, context.temp_allocator)
    if err2 != nil do a2, _ = filepath.clean(p2, context.temp_allocator)
    return a1 == a2
}

compilation_jump_to_current :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    if c.cursor < 0 || c.cursor >= len(c.lines) do return
    entry := c.lines[c.cursor]
    if entry.file_path == "" || entry.line_num <= 0 do return

    // Compiler paths are relative to the build's directory, which may no
    // longer be the current project root.
    target_path := entry.file_path
    if !filepath.is_abs(target_path) {
        if c.working_dir != "" {
            if joined, join_err := filepath.join([]string{c.working_dir, target_path}, context.temp_allocator); join_err == nil {
                target_path = joined
            }
        } else {
            target_path = app_resolve_path(app, target_path)
        }
    }

    // Find target editor pane (preferably another pane)
    target_pane: ^Pane = nil
    for p in app.panes {
        if p != pane && p.kind == .Editor {
            if paths_match(p.editor.file_path, target_path) {
                target_pane = p
                break
            }
        }
    }

    if target_pane == nil {
        for p in app.panes {
            if p != pane && p.kind == .Editor {
                target_pane = p
                break
            }
        }
    }

    if target_pane == nil {
        for p in app.panes {
            if p.kind == .Editor {
                target_pane = p
                break
            }
        }
    }

    if target_pane == nil {
        // No editor pane found; split this pane horizontally
        app_split_pane(app, pane, .Horizontal)
        target_pane = app.active_pane
        target_pane.kind = .Editor
    }

    // Open file in target editor pane if not already opened
    if !paths_match(target_pane.editor.file_path, target_path) {
        app_pane_open_file(app, target_pane, target_path)
    }

    // Position cursor on error line and col
    target_pane.editor.cursor.row = max(0, entry.line_num - 1)
    target_pane.editor.cursor.col = max(0, entry.col_num - 1)
    target_pane.editor.desired_col = target_pane.editor.cursor.col
    editor_clamp_cursor(&target_pane.editor)

    // Center scroll around error
    target_pane.editor.scroll_row = max(0, target_pane.editor.cursor.row - 10)

    app.active_pane = target_pane
    app_set_message(app, fmt.tprintf("%s:%d:%d", entry.file_path, entry.line_num, entry.col_num))
}

compilation_first_error :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    for i := 0; i < len(c.lines); i += 1 {
        if c.lines[i].file_path != "" && (c.lines[i].is_error || c.lines[i].is_warn) {
            c.cursor = i
            compilation_jump_to_current(c, app, pane)
            return
        }
    }
    app.cmd_prompt.message = "No errors in compilation buffer"
}

compilation_next_error :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    for i := c.cursor + 1; i < len(c.lines); i += 1 {
        if c.lines[i].file_path != "" && (c.lines[i].is_error || c.lines[i].is_warn) {
            c.cursor = i
            compilation_jump_to_current(c, app, pane)
            return
        }
    }
    app.cmd_prompt.message = "No further errors in compilation buffer"
}

compilation_prev_error :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    for i := c.cursor - 1; i >= 0; i -= 1 {
        if c.lines[i].file_path != "" && (c.lines[i].is_error || c.lines[i].is_warn) {
            c.cursor = i
            compilation_jump_to_current(c, app, pane)
            return
        }
    }
    app.cmd_prompt.message = "No prior errors in compilation buffer"
}

// Text copied from the compilation buffer: the current line, or everything.
compilation_copy_text :: proc(c: ^Compilation, all: bool, allocator := context.temp_allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, 0, 256, allocator)

    if all {
        for line, i in c.lines {
            strings.write_string(&b, line.text)
            if i + 1 < len(c.lines) do strings.write_byte(&b, '\n')
        }
    } else if c.cursor >= 0 && c.cursor < len(c.lines) {
        strings.write_string(&b, c.lines[c.cursor].text)
    }

    return strings.to_string(b)
}

compilation_copy :: proc(c: ^Compilation, app: ^App, all: bool) {
    text := compilation_copy_text(c, all)
    if text == "" {
        app_set_message(app, "Nothing to copy")
        return
    }

    c_text := strings.clone_to_cstring(text, context.temp_allocator)
    _ = sdl.SetClipboardText(c_text)
    app_set_message(app, "Copied the compilation buffer" if all else "Copied the current line")
}

compilation_handle_event :: proc(c: ^Compilation, event: ^sdl.Event, app: ^App, pane: ^Pane) -> bool {
    #partial switch event.type {
    case .KEY_DOWN:
        c.last_action = time.now()
        key := event.key.key
        mod := event.key.mod
        is_shift := (mod & sdl.KMOD_SHIFT) != {}

        if key == KEY_CMD_PROMPT || (key == KEY_CMD_PROMPT_ALT && is_shift) {
            app_open_command_prompt(app)
            return true
        }

        if key == KEY_COMPILE_DOWN || key == sdl.K_DOWN {
            if len(c.lines) > 0 {
                c.cursor = min(len(c.lines) - 1, c.cursor + 1)
            }
            return true
        }

        if key == KEY_COMPILE_UP || key == sdl.K_UP {
            if len(c.lines) > 0 {
                c.cursor = max(0, c.cursor - 1)
            }
            return true
        }

        if key == KEY_COMPILE_NEXT_ERROR {
            compilation_next_error(c, app, pane)
            return true
        }

        if key == KEY_COMPILE_PREV_ERROR {
            compilation_prev_error(c, app, pane)
            return true
        }

        if key == KEY_COMPILE_JUMP || key == sdl.K_RETURN || key == sdl.K_KP_ENTER {
            compilation_jump_to_current(c, app, pane)
            return true
        }

        if key == KEY_COMPILE_RECOMPILE || key == KEY_COMPILE_RECOMPILE_ALT {
            if c.command != "" {
                workdir := c.working_dir
                if workdir == "" do workdir = app_picker_root(app)
                compilation_run_command(c, c.command, workdir)
                app_set_message(app, fmt.tprintf("Recompiled: %s", c.command))
            }
            return true
        }

        if is_shift && key == KEY_COMPILE_YANK_ALL {
            compilation_copy(c, app, true)
            return true
        }

        if key == KEY_COMPILE_YANK {
            compilation_copy(c, app, false)
            return true
        }

        if key == KEY_COMPILE_QUIT {
            if len(app.panes) > 1 {
                app_close_pane(app, pane)
            } else {
                app.running = false
            }
            return true
        }

    case .MOUSE_WHEEL:
        if event.wheel.y > 0 {
            c.cursor = max(0, c.cursor - 3)
        } else if event.wheel.y < 0 {
            c.cursor = min(max(0, len(c.lines) - 1), c.cursor + 3)
        }
        return true
    }

    return false
}

compilation_render :: proc(c: ^Compilation, renderer: ^sdl.Renderer, font: ^Font, rect: sdl.FRect, is_focused: bool, theme: ^Theme) {
    if rect.w < 50 || rect.h < 50 do return

    line_h := get_line_height(.HALF)

    header_h := line_h * 1.5
    status_bar_h := line_h + 8.0
    body_h := rect.h - header_h - status_bar_h

    visible_lines := int(body_h / line_h)
    if visible_lines <= 0 do visible_lines = 1

    if c.cursor < c.scroll {
        c.scroll = c.cursor
    } else if c.cursor >= c.scroll + visible_lines {
        c.scroll = c.cursor - visible_lines + 1
    }

    clip := sdl.Rect{i32(rect.x), i32(rect.y), i32(rect.w), i32(rect.h)}
    sdl.SetRenderClipRect(renderer, &clip)
    defer sdl.SetRenderClipRect(renderer, nil)

    // Background
    bg_color := theme.bg
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    bg_rect := rect
    sdl.RenderFillRect(renderer, &bg_rect)

    // Header
    header_rect := sdl.FRect{rect.x, rect.y, rect.w, header_h}
    sdl.SetRenderDrawColorFloat(renderer, theme.cursor_line_bg.r, theme.cursor_line_bg.g, theme.cursor_line_bg.b, theme.cursor_line_bg.a)
    sdl.RenderFillRect(renderer, &header_rect)

    header_text := fmt.tprintf("*compilation* : %s", c.command if c.command != "" else "[No command]")
    push_line(font, header_text, Vec2{rect.x + 12.0, rect.y + 4.0}, theme.fg, .HALF)

    div_rect := sdl.FRect{rect.x, rect.y + header_h - 1.0, rect.w, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, theme.border.r, theme.border.g, theme.border.b, theme.border.a)
    sdl.RenderFillRect(renderer, &div_rect)

    // Lines
    for i in 0 ..< visible_lines {
        idx := c.scroll + i
        if idx >= len(c.lines) do break

        line := c.lines[idx]
        y_pos := rect.y + header_h + f32(i) * line_h

        // Highlight line under cursor
        if idx == c.cursor && is_focused {
            sel_rect := sdl.FRect{rect.x, y_pos, rect.w, line_h}
            sdl.SetRenderDrawColor(renderer, 36, 40, 52, 255)
            sdl.RenderFillRect(renderer, &sel_rect)

            mark_rect := sdl.FRect{rect.x, y_pos, 3.0, line_h}
            sdl.SetRenderDrawColor(renderer, 97, 175, 239, 255)
            sdl.RenderFillRect(renderer, &mark_rect)
        }

        text_color := sdl.FColor{0.8, 0.8, 0.85, 1.0}
        if line.is_error {
            text_color = sdl.FColor{0.95, 0.45, 0.45, 1.0}
        } else if line.is_warn {
            text_color = sdl.FColor{0.95, 0.8, 0.35, 1.0}
        } else if strings.has_prefix(line.text, "-*-") || strings.has_prefix(line.text, "Compilation") {
            text_color = sdl.FColor{0.5, 0.75, 0.95, 1.0}
        }

        if len(line.text) > 0 {
            push_line(font, line.text, Vec2{rect.x + 12.0, y_pos}, text_color, .HALF)
        }
    }

    // Status bar
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
    status_info := fmt.tprintf(
        "%s-- COMPILATION --  [%s]   <Enter> jump, <%s/%s> next/prev, <%s> recompile, <%s> copy",
        focus_badge,
        c.status,
        key_label(KEY_COMPILE_NEXT_ERROR, {}, .Plain),
        key_label(KEY_COMPILE_PREV_ERROR, {}, .Plain),
        key_label(KEY_COMPILE_RECOMPILE, {}, .Plain),
        key_label(KEY_COMPILE_YANK, {}, .Plain),
    )
    status_color := sdl.FColor{0.45, 0.85, 0.55, 1.0} if (c.finished && c.exit_code == 0) else sdl.FColor{0.95, 0.5, 0.45, 1.0}
    push_line(font, status_info, Vec2{rect.x + 10.0, rect.y + rect.h - status_bar_h + 4.0}, status_color, .HALF)

    flush_text(font, renderer)
}
