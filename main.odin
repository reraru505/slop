package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

TARGET :: 16_660 * time.Microsecond

CommandPrompt :: struct {
    active  : bool,
    buffer  : [dynamic]u8,
    message : string,
}

App :: struct {
    window        : ^sdl.Window,
    renderer      : ^sdl.Renderer,
    font          : Font,
    panes         : [dynamic]^Pane,
    active_pane   : ^Pane,
    root_split    : ^SplitNode,
    next_pane_id  : int,
    cmd_prompt    : CommandPrompt,
    pending_w_cmd : bool,
    running       : bool,
}

app_open_command_prompt :: proc(app: ^App) {
    app.cmd_prompt.active = true
    clear(&app.cmd_prompt.buffer)
    app.cmd_prompt.message = ""
    _ = sdl.StartTextInput(app.window)
}

app_close_command_prompt :: proc(app: ^App) {
    app.cmd_prompt.active = false
    clear(&app.cmd_prompt.buffer)
    if app.active_pane == nil || app.active_pane.kind != .Editor || app.active_pane.editor.mode != .Insert {
        _ = sdl.StopTextInput(app.window)
    }
}

app_pane_open_file :: proc(app: ^App, pane: ^Pane, file_path: string) {
    if pane == nil do return
    data, err := os.read_entire_file(file_path, context.allocator)
    initial_text := ""
    if err == nil {
        initial_text = string(data)
    }

    editor_destroy(&pane.editor)
    editor_init(&pane.editor, &app.font, initial_text, file_path)

    if err == nil {
        delete(data)
    }

    pane.kind = .Editor
    app.active_pane = pane
}

app_pane_open_dired :: proc(app: ^App, pane: ^Pane, dir_path: string) {
    if pane == nil do return
    if dired_load_path(&pane.dired, dir_path) {
        pane.kind = .Dired
        app.active_pane = pane
    }
}

app_pane_open :: proc(app: ^App, pane: ^Pane, target: string) {
    if os.is_dir(target) {
        app_pane_open_dired(app, pane, target)
    } else {
        app_pane_open_file(app, pane, target)
    }
}

app_open_file :: proc(app: ^App, file_path: string) {
    app_pane_open_file(app, app.active_pane, file_path)
}

app_open_dired :: proc(app: ^App, dir_path: string) {
    app_pane_open_dired(app, app.active_pane, dir_path)
}

app_execute_command :: proc(app: ^App, raw_cmd: string) {
    cmd := strings.trim_space(raw_cmd)
    if cmd == "" do return

    if cmd == "w" {
        if app.active_pane != nil && app.active_pane.kind == .Editor {
            if editor_save_file(&app.active_pane.editor) {
                app.cmd_prompt.message = fmt.tprintf("\"%s\" written", app.active_pane.editor.file_path)
            } else {
                app.cmd_prompt.message = "E32: No file name"
            }
        } else {
            app.cmd_prompt.message = "Cannot write non-file buffer"
        }
    } else if cmd == "q" {
        app_close_pane(app, app.active_pane)
    } else if cmd == "wq" || cmd == "x" {
        if app.active_pane != nil && app.active_pane.kind == .Editor {
            editor_save_file(&app.active_pane.editor)
        }
        app_close_pane(app, app.active_pane)
    } else if cmd == "qa" || cmd == "q!" {
        app.running = false
    } else if cmd == "sp" || cmd == "split" {
        app_split_pane(app, app.active_pane, .Horizontal)
        app.cmd_prompt.message = "Horizontal split"
    } else if cmd == "vs" || cmd == "vsplit" {
        app_split_pane(app, app.active_pane, .Vertical)
        app.cmd_prompt.message = "Vertical split"
    } else if cmd == "dired" || cmd == "d" || cmd == "e ." {
        dir := "."
        if app.active_pane != nil && app.active_pane.kind == .Editor && app.active_pane.editor.file_path != "" {
            dir = filepath.dir(app.active_pane.editor.file_path)
            if dir == "" do dir = "."
        } else if app.active_pane != nil && app.active_pane.kind == .Dired && app.active_pane.dired.path != "" {
            dir = app.active_pane.dired.path
        }
        app_pane_open_dired(app, app.active_pane, dir)
    } else if strings.has_prefix(cmd, "e ") {
        target := strings.trim_space(cmd[2:])
        app_pane_open(app, app.active_pane, target)
    } else if strings.has_prefix(cmd, "sp ") || strings.has_prefix(cmd, "split ") {
        target := strings.trim_space(cmd[3:] if strings.has_prefix(cmd, "sp ") else cmd[6:])
        app_split_pane(app, app.active_pane, .Horizontal)
        if target != "" {
            app_pane_open(app, app.active_pane, target)
        }
    } else if strings.has_prefix(cmd, "vs ") || strings.has_prefix(cmd, "vsplit ") {
        target := strings.trim_space(cmd[3:] if strings.has_prefix(cmd, "vs ") else cmd[7:])
        app_split_pane(app, app.active_pane, .Vertical)
        if target != "" {
            app_pane_open(app, app.active_pane, target)
        }
    } else if cmd == "bn" || cmd == "bnext" {
        app_cycle_pane(app)
    } else {
        app.cmd_prompt.message = fmt.tprintf("Unknown command: :%s", cmd)
    }
}

load :: proc(app: ^App) {
    sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "wayland")

    if !sdl.CreateWindowAndRenderer("Odin Text Editor", 1024, 768, sdl.WINDOW_RESIZABLE, &app.window, &app.renderer) {
        panic("Failed to create SDL window and renderer")
    }

    app.font = load_font(app.renderer)
    app.panes = make([dynamic]^Pane, context.allocator)
    app.cmd_prompt.buffer = make([dynamic]u8, context.allocator)
    app.next_pane_id = 1

    target_path := "."
    if len(os.args) > 1 {
        target_path = os.args[1]
    }

    initial_pane: ^Pane
    if os.is_dir(target_path) {
        initial_pane = pane_create(app, .Dired)
        dired_load_path(&initial_pane.dired, target_path)
    } else {
        initial_pane = pane_create(app, .Editor)
        data, err := os.read_entire_file(target_path, context.allocator)
        initial_text := ""
        if err == nil {
            initial_text = string(data)
        }
        editor_destroy(&initial_pane.editor)
        editor_init(&initial_pane.editor, &app.font, initial_text, target_path)
        if err == nil {
            delete(data)
        }
    }

    app.active_pane = initial_pane
    app.root_split = split_create_leaf(initial_pane)
    app.running = true
}

update :: proc(app: ^App) {
    event: sdl.Event
    for sdl.PollEvent(&event) {
        if event.type == .QUIT {
            app.running = false
            break
        }

        #partial switch event.type {
        case .MOUSE_BUTTON_DOWN:
            if event.button.button == sdl.BUTTON_LEFT {
                mx := f32(event.button.x)
                my := f32(event.button.y)
                for p in app.panes {
                    if mx >= p.rect.x && mx < p.rect.x + p.rect.w &&
                       my >= p.rect.y && my < p.rect.y + p.rect.h {
                        app.active_pane = p
                        break
                    }
                }
            }

        case .TEXT_INPUT:
            if app.cmd_prompt.active {
                text_str := string(event.text.text)
                for b in transmute([]u8)text_str {
                    append(&app.cmd_prompt.buffer, b)
                }
                continue
            }

        case .KEY_DOWN:
            key := event.key.key
            mod := event.key.mod
            is_ctrl := (mod & sdl.KMOD_CTRL) != {}

            // If command prompt is active, intercept all keys
            if app.cmd_prompt.active {
                switch key {
                case sdl.K_ESCAPE:
                    app_close_command_prompt(app)
                case sdl.K_BACKSPACE:
                    if len(app.cmd_prompt.buffer) > 0 {
                        pop(&app.cmd_prompt.buffer)
                    } else {
                        app_close_command_prompt(app)
                    }
                case sdl.K_RETURN, sdl.K_KP_ENTER:
                    cmd := string(app.cmd_prompt.buffer[:])
                    app_close_command_prompt(app)
                    app_execute_command(app, cmd)
                }
                continue
            }

            // Clear any transient message on new keypress
            app.cmd_prompt.message = ""

            // Handle pending Ctrl+w split navigation prefix
            if app.pending_w_cmd {
                app.pending_w_cmd = false
                switch key {
                case sdl.K_H:
                    app_focus_dir(app, .Left)
                case sdl.K_J:
                    app_focus_dir(app, .Down)
                case sdl.K_K:
                    app_focus_dir(app, .Up)
                case sdl.K_L:
                    app_focus_dir(app, .Right)
                case sdl.K_S:
                    app_split_pane(app, app.active_pane, .Horizontal)
                case sdl.K_V:
                    app_split_pane(app, app.active_pane, .Vertical)
                case sdl.K_W:
                    app_cycle_pane(app)
                case sdl.K_Q, sdl.K_C:
                    app_close_pane(app, app.active_pane)
                }
                continue
            }

            // Check for Ctrl+w initiation (when not in Insert mode)
            is_insert := app.active_pane != nil && app.active_pane.kind == .Editor && app.active_pane.editor.mode == .Insert
            if !is_insert && is_ctrl && key == sdl.K_W {
                app.pending_w_cmd = true
                continue
            }
        }

        // Dispatch remaining events to active pane
        if app.active_pane != nil {
            switch app.active_pane.kind {
            case .Editor:
                editor_handle_event(&app.active_pane.editor, &event, app.window, app)
            case .Dired:
                dired_handle_event(&app.active_pane.dired, &event, app, app.active_pane)
            }
        }
    }
}

draw :: proc(app: ^App) {
    w, h: i32
    sdl.GetWindowSize(app.window, &w, &h)

    cmd_bar_h := get_line_height(.HALF) + 6.0
    main_area_h := f32(h) - cmd_bar_h
    main_area := sdl.FRect{0, 0, f32(w), main_area_h}

    // Recompute split layout
    split_compute_rects(app.root_split, main_area)

    // Render global background
    sdl.SetRenderDrawColor(app.renderer, 20, 20, 24, 255)
    sdl.RenderClear(app.renderer)

    // Render all panes
    for p in app.panes {
        is_focused := (p == app.active_pane)
        switch p.kind {
        case .Editor:
            editor_render(&p.editor, app.renderer, &app.font, p.rect, is_focused)
        case .Dired:
            dired_render(&p.dired, app.renderer, &app.font, p.rect, is_focused)
        }
    }

    // Render split separators / borders between panes
    for p in app.panes {
        // Draw 1px right border if not at right edge
        if p.rect.x + p.rect.w < f32(w) - 0.5 {
            border_rect := sdl.FRect{
                x = p.rect.x + p.rect.w,
                y = p.rect.y,
                w = 1.0,
                h = p.rect.h,
            }
            sdl.SetRenderDrawColor(app.renderer, 48, 52, 64, 255)
            sdl.RenderFillRect(app.renderer, &border_rect)
        }
        // Draw 1px bottom border if not at bottom of main area
        if p.rect.y + p.rect.h < main_area_h - 0.5 {
            border_rect := sdl.FRect{
                x = p.rect.x,
                y = p.rect.y + p.rect.h,
                w = p.rect.w,
                h = 1.0,
            }
            sdl.SetRenderDrawColor(app.renderer, 48, 52, 64, 255)
            sdl.RenderFillRect(app.renderer, &border_rect)
        }
    }

    // Render bottom global command line / status bar
    cmd_bar_rect := sdl.FRect{
        x = 0,
        y = main_area_h,
        w = f32(w),
        h = cmd_bar_h,
    }
    sdl.SetRenderDrawColor(app.renderer, 18, 19, 24, 255)
    sdl.RenderFillRect(app.renderer, &cmd_bar_rect)

    // Divider line above cmd bar
    div_rect := sdl.FRect{0, main_area_h, f32(w), 1.0}
    sdl.SetRenderDrawColor(app.renderer, 42, 45, 54, 255)
    sdl.RenderFillRect(app.renderer, &div_rect)

    if app.cmd_prompt.active {
        cmd_str := fmt.tprintf(":%s", string(app.cmd_prompt.buffer[:]))
        push_line(&app.font, cmd_str, Vec2{10.0, main_area_h + 3.0}, sdl.FColor{1.0, 0.9, 0.4, 1.0}, .HALF)

        // Command cursor
        char_w := app.panes[0].editor.char_advance * get_font_scale_multiplier(.HALF) if len(app.panes) > 0 else 10.0
        cur_x := 10.0 + f32(len(cmd_str)) * char_w
        cur_rect := sdl.FRect{cur_x, main_area_h + 3.0, 2.0, get_line_height(.HALF)}
        sdl.SetRenderDrawColor(app.renderer, 255, 255, 255, 255)
        sdl.RenderFillRect(app.renderer, &cur_rect)
    } else if app.pending_w_cmd {
        push_line(&app.font, "Ctrl+W (s: split, v: vsplit, h/j/k/l: move, w: cycle, q: close)", Vec2{10.0, main_area_h + 3.0}, sdl.FColor{0.95, 0.6, 0.2, 1.0}, .HALF)
    } else if app.cmd_prompt.message != "" {
        msg_color := sdl.FColor{0.9, 0.45, 0.45, 1.0} if strings.has_prefix(app.cmd_prompt.message, "Unknown") || strings.has_prefix(app.cmd_prompt.message, "Cannot") || strings.has_prefix(app.cmd_prompt.message, "E32") else sdl.FColor{0.6, 0.85, 0.6, 1.0}
        push_line(&app.font, app.cmd_prompt.message, Vec2{10.0, main_area_h + 3.0}, msg_color, .HALF)
    }

    flush_text(&app.font, app.renderer)
    sdl.RenderPresent(app.renderer)
}

cleanup :: proc(app: ^App) {
    split_destroy_tree(app.root_split)
    app.root_split = nil

    for p in app.panes {
        editor_destroy(&p.editor)
        dired_destroy(&p.dired)
        free(p)
    }
    delete(app.panes)
    delete(app.cmd_prompt.buffer)

    sdl.DestroyRenderer(app.renderer)
    sdl.DestroyWindow(app.window)
    sdl.Quit()
}

main :: proc() {
    app: App
    load(&app)
    defer cleanup(&app)

    for app.running {
        frame_start := time.now()

        update(&app)
        draw(&app)

        elapsed := time.since(frame_start)
        remaining := TARGET - elapsed
        if remaining > 0 {
            time.sleep(remaining)
        }
    }
}
