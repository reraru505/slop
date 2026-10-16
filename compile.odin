package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:text/regex"
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

Compilation :: struct {
    command     : string,
    lines       : [dynamic]CompilationLine,
    cursor      : int,
    scroll      : int,
    status      : string,
    exit_code   : int,
    finished    : bool,
    error_regex : regex.Regular_Expression,
    has_regex   : bool,
    last_action : time.Time,
}

compilation_init :: proc(c: ^Compilation) {
    c.command = ""
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

    // Group 3 is column number if 4 or more groups
    c_num := 1
    if len(capture.groups) >= 5 {
        parsed_col, _ := strconv.parse_int(capture.groups[3])
        if parsed_col > 0 do c_num = parsed_col
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

compilation_run_command :: proc(c: ^Compilation, cmd_str: string) {
    if c.command != "" {
        delete(c.command)
    }
    c.command = strings.clone(cmd_str)

    // Clear previous output
    for l in c.lines {
        delete(l.text)
        if l.file_path != "" do delete(l.file_path)
    }
    clear(&c.lines)

    cwd, _ := os.get_working_directory(context.temp_allocator)
    append(&c.lines, CompilationLine{
        text = fmt.aprintf("-*- mode: compilation; default-directory: \"%s\" -*-", cwd),
    })
    append(&c.lines, CompilationLine{
        text = fmt.aprintf("Compilation started: %s", cmd_str),
    })
    append(&c.lines, CompilationLine{text = strings.clone("")})

    desc := os.Process_Desc{
        command = []string{"sh", "-c", cmd_str},
    }

    state, stdout, stderr, err := os.process_exec(desc, context.allocator)
    defer delete(stdout)
    defer delete(stderr)

    if err != nil {
        c.exit_code = -1
        c.finished = true
        if c.status != "" do delete(c.status)
        c.status = fmt.aprintf("Failed to start (%v)", err)
        append(&c.lines, CompilationLine{
            text = fmt.aprintf("Compilation failed to execute: %v", err),
            is_error = true,
        })
        return
    }

    c.exit_code = state.exit_code
    c.finished = true

    // Process output lines
    combined: strings.Builder
    strings.builder_init(&combined, context.allocator)
    defer strings.builder_destroy(&combined)

    if len(stdout) > 0 {
        strings.write_bytes(&combined, stdout)
    }
    if len(stderr) > 0 {
        if len(stdout) > 0 && stdout[len(stdout)-1] != '\n' {
            strings.write_string(&combined, "\n")
        }
        strings.write_bytes(&combined, stderr)
    }

    out_str := strings.to_string(combined)
    lines := strings.split(out_str, "\n", context.allocator)
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
    if c.exit_code == 0 {
        c.status = fmt.aprintf("Finished (%d warnings)", warn_count)
        append(&c.lines, CompilationLine{
            text = fmt.aprintf("Compilation finished successfully (%d warnings).", warn_count),
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

paths_match :: proc(p1, p2: string) -> bool {
    if p1 == p2 do return true
    c1, _ := filepath.clean(p1, context.temp_allocator)
    c2, _ := filepath.clean(p2, context.temp_allocator)
    return c1 == c2
}

compilation_jump_to_current :: proc(c: ^Compilation, app: ^App, pane: ^Pane) {
    if c.cursor < 0 || c.cursor >= len(c.lines) do return
    entry := c.lines[c.cursor]
    if entry.file_path == "" || entry.line_num <= 0 do return

    // Find target editor pane (preferably another pane)
    target_pane: ^Pane = nil
    for p in app.panes {
        if p != pane && p.kind == .Editor {
            if paths_match(p.editor.file_path, entry.file_path) {
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
    if !paths_match(target_pane.editor.file_path, entry.file_path) {
        app_pane_open_file(app, target_pane, entry.file_path)
    }

    // Position cursor on error line and col
    target_pane.editor.cursor.row = max(0, entry.line_num - 1)
    target_pane.editor.cursor.col = max(0, entry.col_num - 1)
    target_pane.editor.desired_col = target_pane.editor.cursor.col
    editor_clamp_cursor(&target_pane.editor)

    // Center scroll around error
    target_pane.editor.scroll_row = max(0, target_pane.editor.cursor.row - 10)

    app.active_pane = target_pane
    app.cmd_prompt.message = fmt.tprintf("%s:%d:%d", entry.file_path, entry.line_num, entry.col_num)
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

compilation_handle_event :: proc(c: ^Compilation, event: ^sdl.Event, app: ^App, pane: ^Pane) -> bool {
    #partial switch event.type {
    case .KEY_DOWN:
        c.last_action = time.now()
        key := event.key.key
        mod := event.key.mod
        is_shift := (mod & sdl.KMOD_SHIFT) != {}
        is_ctrl := (mod & sdl.KMOD_CTRL) != {}

        if key == sdl.K_COLON || (key == sdl.K_SEMICOLON && is_shift) {
            app_open_command_prompt(app)
            return true
        }

        switch key {
        case sdl.K_J, sdl.K_DOWN:
            if len(c.lines) > 0 {
                c.cursor = min(len(c.lines) - 1, c.cursor + 1)
            }
            return true

        case sdl.K_K, sdl.K_UP:
            if len(c.lines) > 0 {
                c.cursor = max(0, c.cursor - 1)
            }
            return true

        case sdl.K_N:
            compilation_next_error(c, app, pane)
            return true

        case sdl.K_P:
            compilation_prev_error(c, app, pane)
            return true

        case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_L:
            compilation_jump_to_current(c, app, pane)
            return true

        case sdl.K_R, sdl.K_G:
            if c.command != "" {
                compilation_run_command(c, c.command)
                app.cmd_prompt.message = fmt.tprintf("Recompiled: %s", c.command)
            }
            return true

        case sdl.K_Q:
            if len(app.panes) > 1 {
                app_close_pane(app, pane)
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

compilation_render :: proc(c: ^Compilation, renderer: ^sdl.Renderer, font: ^Font, rect: sdl.FRect, is_focused: bool) {
    if rect.w < 50 || rect.h < 50 do return

    scale := get_font_scale_multiplier(.HALF)
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
    bg_color := sdl.FColor{0.07, 0.08, 0.1, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, bg_color.r, bg_color.g, bg_color.b, bg_color.a)
    bg_rect := rect
    sdl.RenderFillRect(renderer, &bg_rect)

    // Header
    header_rect := sdl.FRect{rect.x, rect.y, rect.w, header_h}
    sdl.SetRenderDrawColor(renderer, 24, 27, 34, 255)
    sdl.RenderFillRect(renderer, &header_rect)

    header_text := fmt.tprintf("*compilation* : %s", c.command if c.command != "" else "[No command]")
    push_line(font, header_text, Vec2{rect.x + 12.0, rect.y + 4.0}, sdl.FColor{0.8, 0.85, 0.95, 1.0}, .HALF)

    div_rect := sdl.FRect{rect.x, rect.y + header_h - 1.0, rect.w, 1.0}
    sdl.SetRenderDrawColor(renderer, 44, 48, 58, 255)
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
    status_bar_bg := sdl.FColor{0.14, 0.16, 0.22, 1.0} if is_focused else sdl.FColor{0.1, 0.11, 0.14, 1.0}
    sdl.SetRenderDrawColorFloat(renderer, status_bar_bg.r, status_bar_bg.g, status_bar_bg.b, status_bar_bg.a)
    sdl.RenderFillRect(renderer, &status_bar_rect)

    focus_badge := "[ACTIVE] " if is_focused else ""
    status_info := fmt.tprintf("%s-- COMPILATION --  [%s]   <Enter> jump to error, <n/p> next/prev, <r> recompile", focus_badge, c.status)
    status_color := sdl.FColor{0.45, 0.85, 0.55, 1.0} if (c.finished && c.exit_code == 0) else sdl.FColor{0.95, 0.5, 0.45, 1.0}
    push_line(font, status_info, Vec2{rect.x + 10.0, rect.y + rect.h - status_bar_h + 4.0}, status_color, .HALF)

    flush_text(font, renderer)
}
