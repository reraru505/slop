package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:text/regex"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
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
    thread:          ^thread.Thread,
    mutex:           sync.Mutex,
    command:         string,
    working_dir:     string,
    output:          string,
    exit_code:       int,
    failed:          bool,
    cancelled:       bool,
    error_text:      string,
    done:            bool,
    // Process cancellation state; guarded by mutex, `cancel` is atomic.
    process:         os.Process,
    process_started: bool,
    process_reaped:  bool,
    cancel:          bool,
}

// Jobs whose Compilation owner is gone. They are only joined after the worker
// thread has finished, so cancel/close never blocks on a running build.
compilation_orphans: [dynamic]^Compilation_Job
compilation_orphan_mutex: sync.Mutex

Compilation :: struct {
    command     : string,
    working_dir : string,
    lines       : [dynamic]CompilationLine,
    cursor      : int,
    cursor_col  : int,
    desired_col : int,
    scroll      : int,
    // Visual character selection (v or mouse drag).
    selecting   : bool,
    anchor_row  : int,
    anchor_col  : int,
    dragging    : bool,
    drag_row    : int,
    drag_col    : int,
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
    c.cursor_col = 0
    c.desired_col = 0
    c.scroll = 0
    c.selecting = false
    c.anchor_row = 0
    c.anchor_col = 0
    c.dragging = false
    c.drag_row = 0
    c.drag_col = 0
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

compilation_job_done :: proc(job: ^Compilation_Job) -> bool {
    return sync.atomic_load(&job.done)
}

compilation_free_job :: proc(job: ^Compilation_Job) {
    if job == nil do return
    if job.thread != nil {
        thread.join(job.thread)
        thread.destroy(job.thread)
        job.thread = nil
    }
    if job.output != "" do delete(job.output, runtime.default_allocator())
    if job.error_text != "" do delete(job.error_text, runtime.default_allocator())
    if job.command != "" do delete(job.command, runtime.default_allocator())
    if job.working_dir != "" do delete(job.working_dir, runtime.default_allocator())
    free(job, runtime.default_allocator())
}

// Cancel a build and detach it. If the worker is already done it is joined
// immediately; otherwise the orphan reaper owns it until it finishes.
compilation_abandon_job :: proc(c: ^Compilation) {
    job := c.job
    if job == nil do return
    c.job = nil
    compilation_set_cancelled(job)
    if compilation_job_done(job) {
        compilation_free_job(job)
    } else {
        if compilation_orphans.allocator.procedure == nil {
            compilation_orphans.allocator = runtime.default_allocator()
        }
        sync.mutex_lock(&compilation_orphan_mutex)
        append(&compilation_orphans, job)
        sync.mutex_unlock(&compilation_orphan_mutex)
    }
}

compilation_poll_orphans :: proc() {
    sync.mutex_lock(&compilation_orphan_mutex)
    defer sync.mutex_unlock(&compilation_orphan_mutex)
    i := 0
    for i < len(compilation_orphans) {
        job := compilation_orphans[i]
        if compilation_job_done(job) {
            ordered_remove(&compilation_orphans, i)
            compilation_free_job(job)
        } else {
            i += 1
        }
    }
}

compilation_cancel :: proc(c: ^Compilation) {
    if c.job != nil do compilation_set_cancelled(c.job)
}

compilation_destroy :: proc(c: ^Compilation) {
    compilation_abandon_job(c)
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

// Kill the build's process group when it is a session leader, then the direct
// child. Safe to call before the process starts or after it is reaped.
compilation_kill_job :: proc(job: ^Compilation_Job) {
    sync.mutex_lock(&job.mutex)
    p := job.process
    started := job.process_started
    reaped := job.process_reaped
    sync.mutex_unlock(&job.mutex)
    if !started || reaped || p.pid == 0 do return

    if posix.getpgid(posix.pid_t(p.pid)) == posix.pid_t(p.pid) {
        _ = posix.kill(-posix.pid_t(p.pid), .SIGKILL)
    }
    _ = os.process_kill(p)
}

compilation_set_cancelled :: proc(job: ^Compilation_Job) {
    sync.atomic_store(&job.cancel, true)
    compilation_kill_job(job)
}

// Runs the build off the main thread. The worker owns the process handle until
// it publishes `done`; the main thread may kill the process concurrently.
compilation_worker :: proc(data: rawptr) {
    job := (^Compilation_Job)(data)
    alloc := runtime.default_allocator()

    if sync.atomic_load(&job.cancel) {
        sync.mutex_lock(&job.mutex)
        job.cancelled = true
        sync.mutex_unlock(&job.mutex)
        sync.atomic_store(&job.done, true)
        return
    }

    // Pipe creation, spawning, and closing the parent's write end must be
    // serialized: process_start changes descriptor inheritance process-wide.
    read_end: ^os.File
    process: os.Process
    start_err: os.Error
    pipe_err: os.Error
    sync.mutex_lock(&process_spawn_mutex)
    {
        write_end: ^os.File
        read_end, write_end, pipe_err = os.pipe()
        if pipe_err != nil {
            sync.mutex_unlock(&process_spawn_mutex)
            sync.mutex_lock(&job.mutex)
            job.failed = true
            job.exit_code = -1
            job.error_text = fmt.aprintf("pipe: %v", pipe_err, allocator = alloc)
            sync.mutex_unlock(&job.mutex)
            sync.atomic_store(&job.done, true)
            return
        }

        desc := os.Process_Desc{command = []string{"setsid", "sh", "-c", job.command}}
        if job.working_dir != "" do desc.working_dir = job.working_dir
        desc.stdout = write_end
        desc.stderr = write_end

        process, start_err = os.process_start(desc)
        if start_err != nil {
            // `setsid` is optional; fall back to a direct shell.
            os.close(write_end)
            read_end, write_end, pipe_err = os.pipe()
            if pipe_err != nil {
                os.close(read_end)
                sync.mutex_unlock(&process_spawn_mutex)
                sync.mutex_lock(&job.mutex)
                job.failed = true
                job.exit_code = -1
                job.error_text = fmt.aprintf("pipe: %v", pipe_err, allocator = alloc)
                sync.mutex_unlock(&job.mutex)
                sync.atomic_store(&job.done, true)
                return
            }
            desc = os.Process_Desc{command = []string{"sh", "-c", job.command}}
            if job.working_dir != "" do desc.working_dir = job.working_dir
            desc.stdout = write_end
            desc.stderr = write_end
            process, start_err = os.process_start(desc)
        }

        if start_err == nil {
            os.close(write_end)
        } else {
            os.close(read_end)
            os.close(write_end)
        }
    }
    sync.mutex_unlock(&process_spawn_mutex)

    if start_err != nil {
        sync.mutex_lock(&job.mutex)
        job.failed = true
        job.exit_code = -1
        job.error_text = fmt.aprintf("%v", start_err, allocator = alloc)
        sync.mutex_unlock(&job.mutex)
        sync.atomic_store(&job.done, true)
        return
    }

    sync.mutex_lock(&job.mutex)
    job.process = process
    job.process_started = true
    should_cancel := sync.atomic_load(&job.cancel)
    sync.mutex_unlock(&job.mutex)
    if should_cancel do compilation_kill_job(job)

    combined: strings.Builder
    strings.builder_init(&combined, alloc)
    read_buf: [8192]u8
    kill_attempted := false
    for {
        n, read_err := os.read(read_end, read_buf[:])
        if n > 0 do strings.write_bytes(&combined, read_buf[:n])
        if sync.atomic_load(&job.cancel) && !kill_attempted {
            compilation_kill_job(job)
            kill_attempted = true
        }
        if read_err != nil || n <= 0 do break
    }
    os.close(read_end)

    // The pipe is at EOF. Wait for the child, but never forever: a command
    // that closed its output and daemonized would otherwise wedge the worker.
    state, wait_err := os.process_wait(process, 5 * time.Second)
    if wait_err != nil {
        compilation_kill_job(job)
        state, wait_err = os.process_wait(process, 2 * time.Second)
    }

    sync.mutex_lock(&job.mutex)
    job.process_reaped = true
    sync.mutex_unlock(&job.mutex)

    exit_code := 0
    failed := false
    error_text := ""
    if wait_err != nil {
        failed = true
        exit_code = -1
        error_text = fmt.aprintf("%v", wait_err, allocator = alloc)
    } else {
        exit_code = state.exit_code
    }

    out := strings.to_string(combined)
    cancelled := sync.atomic_load(&job.cancel)
    sync.mutex_lock(&job.mutex)
    job.output = out
    job.exit_code = exit_code
    job.failed = failed
    job.cancelled = cancelled
    job.error_text = error_text
    sync.mutex_unlock(&job.mutex)
    sync.atomic_store(&job.done, true)
}

compilation_finish :: proc(c: ^Compilation, output: string, exit_code: int, failed, cancelled: bool, error_text: string) {
    alloc := runtime.default_allocator()
    defer if output != "" do delete(output, alloc)
    defer if error_text != "" do delete(error_text, alloc)

    if cancelled {
        c.exit_code = exit_code
        c.finished = true
        if c.status != "" do delete(c.status)
        c.status = strings.clone("Cancelled")
        append(&c.lines, CompilationLine{text = strings.clone("Compilation cancelled.")})
        c.last_action = time.now()
        return
    }

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

    c.selecting = false
    compilation_set_cursor(c, first_error_idx if first_error_idx >= 0 else 0, 0)
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
    cancelled := false
    error_text := ""

    done = sync.atomic_load(&job.done)
    sync.mutex_lock(&job.mutex)
    if done {
        output = job.output
        job.output = ""
        exit_code = job.exit_code
        failed = job.failed
        cancelled = job.cancelled
        error_text = job.error_text
        job.error_text = ""
    }
    sync.mutex_unlock(&job.mutex)

    if !done do return

    c.job = nil
    compilation_free_job(job)
    compilation_finish(c, output, exit_code, failed, cancelled, error_text)
}

// Blocking wait used by tests and any caller that needs the final state.
compilation_wait :: proc(c: ^Compilation) {
    for c.job != nil {
        compilation_poll(c)
        compilation_poll_orphans()
        if c.job != nil do time.sleep(1 * time.Millisecond)
    }
    compilation_poll_orphans()
}

compilation_run_command :: proc(c: ^Compilation, cmd_str: string, working_dir := "") {
    compilation_poll(c)
    // A new command cancels the previous build instead of refusing to start.
    if c.job != nil do compilation_abandon_job(c)

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
    c.cursor_col = 0
    c.desired_col = 0
    c.scroll = 0
    c.selecting = false
    c.dragging = false

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

    job := new(Compilation_Job, runtime.default_allocator())
    job.command = strings.clone(new_command, runtime.default_allocator())
    if working_dir != "" do job.working_dir = strings.clone(working_dir, runtime.default_allocator())
    job.thread = background_thread(rawptr(job), compilation_worker)
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
            c.selecting = false
            compilation_set_cursor(c, i, 0)
            compilation_jump_to_current(c, app, pane)
            return
        }
    }
    app.cmd_prompt.message = "No errors in compilation buffer"
}

compilation_next_error :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    for i := c.cursor + 1; i < len(c.lines); i += 1 {
        if c.lines[i].file_path != "" && (c.lines[i].is_error || c.lines[i].is_warn) {
            c.selecting = false
            compilation_set_cursor(c, i, 0)
            compilation_jump_to_current(c, app, pane)
            return
        }
    }
    app.cmd_prompt.message = "No further errors in compilation buffer"
}

compilation_prev_error :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    for i := c.cursor - 1; i >= 0; i -= 1 {
        if c.lines[i].file_path != "" && (c.lines[i].is_error || c.lines[i].is_warn) {
            c.selecting = false
            compilation_set_cursor(c, i, 0)
            compilation_jump_to_current(c, app, pane)
            return
        }
    }
    app.cmd_prompt.message = "No prior errors in compilation buffer"
}

compilation_line_len :: proc(c: ^Compilation, row: int) -> int {
    if row < 0 || row >= len(c.lines) do return 0
    n := len(c.lines[row].text)
    if n > 0 && c.lines[row].text[n - 1] == '\r' do n -= 1
    return n
}

compilation_next_rune_end :: proc(text: string, col: int) -> int {
    n := len(text)
    if n > 0 && text[n - 1] == '\r' do n -= 1
    return utf8_next_boundary(text[:n], col)
}

compilation_clamp_cursor :: proc(c: ^Compilation) {
    if len(c.lines) == 0 {
        c.cursor = 0
        c.cursor_col = 0
        c.desired_col = 0
        return
    }
    c.cursor = clamp(c.cursor, 0, len(c.lines) - 1)
    line := c.lines[c.cursor].text
    n := compilation_line_len(c, c.cursor)
    c.cursor_col = clamp(c.cursor_col, 0, n)
    c.cursor_col = utf8_clamp_boundary(line[:n], c.cursor_col)
}

compilation_set_cursor :: proc(c: ^Compilation, row, col: int) {
    c.cursor = row
    c.cursor_col = col
    compilation_clamp_cursor(c)
    c.desired_col = compilation_visual_col(c, c.cursor, c.cursor_col)
}

compilation_visual_col :: proc(c: ^Compilation, row, byte_col: int) -> int {
    if row < 0 || row >= len(c.lines) do return 0
    line := c.lines[row].text
    n := compilation_line_len(c, row)
    col := clamp(byte_col, 0, n)
    visual := 0
    i := 0
    for i < col {
        r, size := utf8.decode_rune_in_string(line[i:])
        if size <= 0 {
            size = 1
            r = utf8.RUNE_ERROR
        }
        visual += TAB_WIDTH if r == '\t' else rune_display_width(r)
        i += size
    }
    if byte_col > n do visual += byte_col - n
    return visual
}

compilation_byte_col_for_visual :: proc(c: ^Compilation, row, visual_col: int) -> int {
    if visual_col <= 0 do return 0
    if row < 0 || row >= len(c.lines) do return 0
    line := c.lines[row].text
    n := compilation_line_len(c, row)
    visual := 0
    i := 0
    for i < n {
        r, size := utf8.decode_rune_in_string(line[i:])
        if size <= 0 {
            size = 1
            r = utf8.RUNE_ERROR
        }
        width := TAB_WIDTH if r == '\t' else rune_display_width(r)
        if visual + width > visual_col do return i
        visual += width
        if visual == visual_col do return i + size
        i += size
    }
    return n
}

compilation_move_row :: proc(c: ^Compilation, delta: int) {
    if len(c.lines) == 0 do return
    row := clamp(c.cursor + delta, 0, len(c.lines) - 1)
    col := compilation_byte_col_for_visual(c, row, c.desired_col)
    c.cursor = row
    c.cursor_col = col
    compilation_clamp_cursor(c)
}

compilation_move_col :: proc(c: ^Compilation, delta: int) {
    if len(c.lines) == 0 do return
    line := c.lines[c.cursor].text
    n := compilation_line_len(c, c.cursor)
    if delta < 0 {
        c.cursor_col = utf8_prev_boundary(line[:n], c.cursor_col)
    } else {
        c.cursor_col = utf8_next_boundary(line[:n], c.cursor_col)
    }
    c.desired_col = compilation_visual_col(c, c.cursor, c.cursor_col)
}

// Half-open byte bounds of the visual selection (anchor and cursor inclusive
// at the cursor end, matching the editor's Visual mode).
compilation_selection_bounds :: proc(c: ^Compilation) -> (r0, c0, r1, c1: int) {
    if !c.selecting || len(c.lines) == 0 do return 0, 0, -1, 0
    ar := clamp(c.anchor_row, 0, len(c.lines) - 1)
    ac := clamp(c.anchor_col, 0, compilation_line_len(c, ar))
    cr := clamp(c.cursor, 0, len(c.lines) - 1)
    cc := clamp(c.cursor_col, 0, compilation_line_len(c, cr))

    if ar < cr || (ar == cr && ac <= cc) {
        r0, c0 = ar, ac
        r1 = cr
        c1 = compilation_next_rune_end(c.lines[cr].text, cc)
    } else {
        r0, c0 = cr, cc
        r1 = ar
        c1 = compilation_next_rune_end(c.lines[ar].text, ac)
    }
    return
}

compilation_line_at_y :: proc(c: ^Compilation, rect: sdl.FRect, y: f32) -> int {
    line_h := get_line_height(.HALF)
    header_h := line_h * 1.5
    status_h := line_h + 8.0
    if y < rect.y + header_h || y >= rect.y + rect.h - status_h do return -1
    row := c.scroll + int((y - rect.y - header_h) / line_h)
    if row < 0 || row >= len(c.lines) do return -1
    return row
}

compilation_col_at_x :: proc(c: ^Compilation, rect: sdl.FRect, x: f32, row: int) -> int {
    cell_w := g_font_metrics.cell_width * get_font_scale_multiplier(.HALF)
    if cell_w <= 0 do return 0
    visual := max(0, int((x - (rect.x + 12.0)) / cell_w))
    return compilation_byte_col_for_visual(c, row, visual)
}

// Text copied from the compilation buffer: the selection, the current line, or
// everything.
compilation_copy_text :: proc(c: ^Compilation, all: bool, allocator := context.temp_allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, 0, 256, allocator)

    if all {
        for line, i in c.lines {
            strings.write_string(&b, line.text)
            if i + 1 < len(c.lines) do strings.write_byte(&b, '\n')
        }
    } else if c.selecting {
        r0, c0, r1, c1 := compilation_selection_bounds(c)
        if r1 >= r0 && !(r0 == r1 && c1 <= c0) {
            if r0 == r1 {
                line := c.lines[r0].text
                strings.write_string(&b, line[c0:min(c1, len(line))])
            } else {
                first := c.lines[r0].text
                first_len := compilation_line_len(c, r0)
                strings.write_string(&b, first[min(c0, first_len):first_len])
                for r in r0 + 1 ..= r1 {
                    strings.write_byte(&b, '\n')
                    line := c.lines[r].text
                    if r == r1 {
                        strings.write_string(&b, line[:min(c1, len(line))])
                    } else {
                        strings.write_string(&b, line[:compilation_line_len(c, r)])
                    }
                }
            }
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
    if all {
        app_set_message(app, "Copied the compilation buffer")
    } else if c.selecting {
        app_set_message(app, "Copied the selection")
    } else {
        app_set_message(app, "Copied the current line")
    }
}

compilation_handle_event :: proc(c: ^Compilation, event: ^sdl.Event, app: ^App, pane: ^Pane) -> bool {
    #partial switch event.type {
    case .MOUSE_BUTTON_DOWN:
        if event.button.button != sdl.BUTTON_LEFT do return false
        row := compilation_line_at_y(c, pane.rect, event.button.y)
        if row < 0 do return true
        col := compilation_col_at_x(c, pane.rect, event.button.x, row)
        if event.button.clicks >= 2 {
            c.selecting = true
            c.anchor_row = row
            c.anchor_col = 0
            compilation_set_cursor(c, row, compilation_line_len(c, row))
            c.dragging = false
        } else if (sdl.GetModState() & sdl.KMOD_SHIFT) != {} {
            if !c.selecting {
                c.selecting = true
                c.anchor_row = c.cursor
                c.anchor_col = c.cursor_col
            }
            compilation_set_cursor(c, row, col)
            c.dragging = false
        } else {
            compilation_set_cursor(c, row, col)
            c.selecting = false
            c.dragging = true
            c.drag_row = row
            c.drag_col = col
        }
        return true

    case .MOUSE_MOTION:
        if !c.dragging do return false
        row := compilation_line_at_y(c, pane.rect, event.motion.y)
        if row < 0 do return true
        col := compilation_col_at_x(c, pane.rect, event.motion.x, row)
        if row != c.drag_row || col != c.drag_col {
            c.selecting = true
            c.anchor_row = c.drag_row
            c.anchor_col = c.drag_col
        }
        compilation_set_cursor(c, row, col)
        return true

    case .MOUSE_BUTTON_UP:
        if event.button.button == sdl.BUTTON_LEFT && c.dragging do c.dragging = false
        return true

    case .KEY_DOWN:
        c.last_action = time.now()
        key := event.key.key
        mod := event.key.mod
        is_shift := (mod & sdl.KMOD_SHIFT) != {}
        is_alt := (mod & sdl.KMOD_ALT) != {}

        if key == KEY_CMD_PROMPT || (key == KEY_CMD_PROMPT_ALT && is_shift) {
            app_open_command_prompt(app)
            return true
        }

        // M-w (Alt+W) is the copy binding shared with editor Visual mode.
        if is_alt && key == KEY_COMPILE_YANK_ALT {
            compilation_copy(c, app, false)
            return true
        }

        if key == KEY_COMPILE_VISUAL {
            if c.selecting {
                c.selecting = false
            } else {
                c.selecting = true
                c.anchor_row = c.cursor
                c.anchor_col = c.cursor_col
            }
            return true
        }

        if key == sdl.K_ESCAPE {
            c.selecting = false
            return true
        }

        if is_shift && !c.selecting {
            c.selecting = true
            c.anchor_row = c.cursor
            c.anchor_col = c.cursor_col
        }

        if key == KEY_COMPILE_DOWN || key == sdl.K_DOWN {
            compilation_move_row(c, 1)
            return true
        }

        if key == KEY_COMPILE_UP || key == sdl.K_UP {
            compilation_move_row(c, -1)
            return true
        }

        if key == sdl.K_LEFT {
            compilation_move_col(c, -1)
            return true
        }

        if key == sdl.K_RIGHT {
            compilation_move_col(c, 1)
            return true
        }

        if key == sdl.K_HOME {
            compilation_set_cursor(c, c.cursor, 0)
            return true
        }

        if key == sdl.K_END {
            compilation_set_cursor(c, c.cursor, compilation_line_len(c, c.cursor))
            return true
        }

        if key == sdl.K_PAGEUP {
            compilation_move_row(c, -20)
            return true
        }

        if key == sdl.K_PAGEDOWN {
            compilation_move_row(c, 20)
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
            compilation_move_row(c, -3)
        } else if event.wheel.y < 0 {
            compilation_move_row(c, 3)
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
    sel_r0, sel_c0, sel_r1, sel_c1 := 0, 0, -1, 0
    if c.selecting {
        sel_r0, sel_c0, sel_r1, sel_c1 = compilation_selection_bounds(c)
    }
    text_x := rect.x + 12.0
    cell_w := g_font_metrics.cell_width * get_font_scale_multiplier(.HALF)
    caret_rect: sdl.FRect
    caret_visible := false

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

        // Visual selection spans characters, including across lines.
        if c.selecting && idx >= sel_r0 && idx <= sel_r1 {
            n := compilation_line_len(c, idx)
            sc0 := 0
            sc1 := n
            if idx == sel_r0 do sc0 = min(sel_c0, n)
            if idx == sel_r1 do sc1 = min(sel_c1, n)
            if sc0 < sc1 {
                v0 := compilation_visual_col(c, idx, sc0)
                v1 := compilation_visual_col(c, idx, sc1)
                if v1 > v0 {
                    sx := text_x + f32(v0) * cell_w
                    sel_rect := sdl.FRect{sx, y_pos, f32(v1 - v0) * cell_w, line_h}
                    sdl.SetRenderDrawColorFloat(renderer, theme.selection_bg.r, theme.selection_bg.g, theme.selection_bg.b, 0.9)
                    sdl.RenderFillRect(renderer, &sel_rect)
                }
            }
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
            push_line(font, line.text, Vec2{text_x, y_pos}, text_color, .HALF)
        }

        if idx == c.cursor && is_focused {
            caret_x := text_x + f32(compilation_visual_col(c, idx, c.cursor_col)) * cell_w
            caret_rect = sdl.FRect{caret_x, y_pos, max(2.0, 2.0 * global_ui_scale), line_h}
            caret_visible = true
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
    visual_badge := " [VISUAL] " if c.selecting else ""
    status_info := fmt.tprintf(
        "%s-- COMPILATION --%s [%s]  <Enter> jump, <%s/%s> next/prev, <%s> recompile, <%s>/<%s> copy, <%s> all, <%s> select",
        focus_badge,
        visual_badge,
        c.status,
        key_label(KEY_COMPILE_NEXT_ERROR, {}, .Plain),
        key_label(KEY_COMPILE_PREV_ERROR, {}, .Plain),
        key_label(KEY_COMPILE_RECOMPILE, {}, .Plain),
        key_label(KEY_COMPILE_YANK, {}, .Plain),
        key_label(KEY_COMPILE_YANK_ALT, sdl.KMOD_ALT, .Plain),
        key_label(KEY_COMPILE_YANK_ALL, sdl.KMOD_SHIFT, .Shift_Letter),
        key_label(KEY_COMPILE_VISUAL, {}, .Plain),
    )
    status_color := sdl.FColor{0.45, 0.85, 0.55, 1.0} if (c.finished && c.exit_code == 0) else sdl.FColor{0.95, 0.5, 0.45, 1.0}
    push_line(font, status_info, Vec2{rect.x + 10.0, rect.y + rect.h - status_bar_h + 4.0}, status_color, .HALF)

    flush_text(font, renderer)
    if caret_visible {
        sdl.SetRenderDrawColorFloat(renderer, theme.cursor.r, theme.cursor.g, theme.cursor.b, 0.9)
        sdl.RenderFillRect(renderer, &caret_rect)
    }
}
