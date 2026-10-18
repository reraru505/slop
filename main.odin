package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:sys/posix"
import sdl "vendor:sdl3"

TARGET :: 16_660 * time.Microsecond

CommandPrompt :: struct {
    active        : bool,
    buffer        : [dynamic]u8,
    message       : string,
    message_buf   : [512]u8,
    matches       : [dynamic]string,
    match_index   : int,
    in_completion : bool,
}

app_reset_command_completion :: proc(prompt: ^CommandPrompt) {
    if prompt == nil do return
    for m in prompt.matches {
        delete(m)
    }
    clear(&prompt.matches)
    prompt.match_index = -1
    prompt.in_completion = false
}

app_set_message :: proc(app: ^App, msg: string) {
    if app == nil do return
    n := copy(app.cmd_prompt.message_buf[:], msg)
    app.cmd_prompt.message = string(app.cmd_prompt.message_buf[:n])
}

App :: struct {
    window           : ^sdl.Window,
    renderer         : ^sdl.Renderer,
    font             : Font,
    panes            : [dynamic]^Pane,
    active_pane      : ^Pane,
    root_split       : ^SplitNode,
    next_pane_id     : int,
    cmd_prompt       : CommandPrompt,
    pending_w_cmd    : bool,
    pending_leader   : bool,
    working_dir      : string,
    file_picker      : FilePicker,
    last_compile_cmd : string,
    current_theme_id : ThemeId,
    theme            : Theme,
    running          : bool,
    lsp_manager      : LspManager,
}

app_get_lsp_for_file :: proc(app: ^App, file_path: string) -> ^LspClient {
    if app == nil || file_path == "" do return nil
    lang := language_from_file_path(file_path)
    return lsp_manager_get_client(&app.lsp_manager, lang, file_path)
}

app_get_active_lsp :: proc(app: ^App) -> ^LspClient {
    if app == nil || app.active_pane == nil || app.active_pane.kind != .Editor do return nil
    return app_get_lsp_for_file(app, app.active_pane.editor.file_path)
}

app_open_command_prompt :: proc(app: ^App) {
    app.cmd_prompt.active = true
    clear(&app.cmd_prompt.buffer)
    app_reset_command_completion(&app.cmd_prompt)
    app.cmd_prompt.message = ""
    _ = sdl.StartTextInput(app.window) 
}

app_close_command_prompt :: proc(app: ^App) {
    app.cmd_prompt.active = false
    clear(&app.cmd_prompt.buffer)
    app_reset_command_completion(&app.cmd_prompt)
    if app.active_pane == nil || app.active_pane.kind != .Editor || app.active_pane.editor.mode != .Insert {
        _ = sdl.StopTextInput(app.window)
    }
}

app_command_prompt_tab :: proc(app: ^App, reverse: bool = false) {
    p := &app.cmd_prompt
    if !p.in_completion {
        curr_str := string(p.buffer[:])
        app_reset_command_completion(p)

        // 1. Check if completing a subcommand / argument (contains space)
        if first_space := strings.index_byte(curr_str, ' '); first_space >= 0 {
            cmd_prefix := curr_str[:first_space]
            arg_prefix := strings.trim_space(curr_str[first_space+1:])

            switch cmd_prefix {
            case "theme", "colorscheme":
                themes := []string{"gruber-darker", "naysayer", "kanagawa", "hemisu"}
                for th in themes {
                    if strings.has_prefix(th, arg_prefix) {
                        append(&p.matches, fmt.aprintf("%s %s", cmd_prefix, th))
                    }
                }
            case "sort":
                sorts := []string{"name", "size", "time", "rev", "reverse"}
                for s in sorts {
                    if strings.has_prefix(s, arg_prefix) {
                        append(&p.matches, fmt.aprintf("%s %s", cmd_prefix, s))
                    }
                }
            case "e", "edit", "sp", "split", "vs", "vsplit", "cd":
                search_dir := "."
                name_prefix := arg_prefix
                if slash_idx := strings.last_index_byte(arg_prefix, '/'); slash_idx >= 0 {
                    search_dir = arg_prefix[:slash_idx]
                    if search_dir == "" do search_dir = "/"
                    name_prefix = arg_prefix[slash_idx+1:]
                }

                handle, err := os.open(search_dir)
                if err == nil {
                    defer os.close(handle)
                    files, ferr := os.read_dir(handle, -1, context.temp_allocator)
                    if ferr == nil {
                        for f in files {
                            if strings.has_prefix(f.name, ".") && !strings.has_prefix(name_prefix, ".") {
                                continue
                            }
                            if strings.has_prefix(f.name, name_prefix) {
                                joined := f.name
                                if slash_idx := strings.last_index_byte(arg_prefix, '/'); slash_idx >= 0 {
                                    dir_part := arg_prefix[:slash_idx+1]
                                    joined = fmt.tprintf("%s%s", dir_part, f.name)
                                }
                                if f.type == .Directory {
                                    joined = fmt.tprintf("%s/", joined)
                                }
                                append(&p.matches, fmt.aprintf("%s %s", cmd_prefix, joined))
                            }
                        }
                    }
                }
            }
        } else {
            // 2. Completing base command
            ALL_COMMANDS := []string{
                "w", "wq", "q", "qa", "q!", "x",
                "split", "sp", "vsplit", "vs",
                "dired", "edit", "e",
                "compile", "recompile", "make",
                "cnext", "cn", "cprev", "cp", "cfirst", "crewind",
                "bnext", "bn",
                "theme", "colorscheme",
                "sort", "cd",
            }
            for cmd in ALL_COMMANDS {
                if strings.has_prefix(cmd, curr_str) {
                    append(&p.matches, strings.clone(cmd, context.allocator))
                }
            }
        }

        if len(p.matches) == 0 do return
        p.in_completion = true
        p.match_index = 0
    } else {
        if len(p.matches) == 0 do return
        if reverse {
            p.match_index = (p.match_index - 1 + len(p.matches)) % len(p.matches)
        } else {
            p.match_index = (p.match_index + 1) % len(p.matches)
        }
    }

    selected := p.matches[p.match_index]
    clear(&p.buffer)
    for b in transmute([]u8)selected {
        append(&p.buffer, b)
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

    if file_path != "" {
        if lsp := app_get_lsp_for_file(app, file_path); lsp != nil && lsp.running {
            full_text := pt_full_text(&pane.editor.table)
            defer delete(full_text)
            lsp_did_open(lsp, file_path, full_text)
        }
    }
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

app_run_compile :: proc(app: ^App, cmd_str: string) {
    target_cmd := strings.trim_space(cmd_str)
    if target_cmd == "" {
        if app.last_compile_cmd != "" {
            target_cmd = app.last_compile_cmd
        } else {
            if os.exists("Makefile") {
                target_cmd = "make"
            } else {
                target_cmd = "odin check ."
            }
        }
    }
    if app.last_compile_cmd != "" do delete(app.last_compile_cmd)
    app.last_compile_cmd = strings.clone(target_cmd)

    comp_pane: ^Pane = nil
    for p in app.panes {
        if p.kind == .Compilation {
            comp_pane = p
            break
        }
    }

    if comp_pane == nil {
        app_split_pane(app, app.active_pane, .Horizontal)
        comp_pane = app.active_pane
        comp_pane.kind = .Compilation
    }

    compilation_run_command(&comp_pane.compilation, target_cmd)
    app.cmd_prompt.message = fmt.tprintf("Compilation: %s", comp_pane.compilation.status)
}

app_execute_command :: proc(app: ^App, raw_cmd: string) {
    cmd := strings.trim_space(raw_cmd)
    if cmd == "" do return

    if cmd == "w" {
        if app.active_pane != nil {
            if app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
                msg := dired_apply_edits(&app.active_pane.dired, &app.active_pane.editor)
                app_set_message(app, msg)
                _ = sdl.StopTextInput(app.window)
            } else if app.active_pane.kind == .Editor {
                if editor_save_file(&app.active_pane.editor, app) {
                    app_set_message(app, fmt.tprintf("\"%s\" written", app.active_pane.editor.file_path))
                } else {
                    app_set_message(app, "E32: No file name")
                }
            } else {
                app_set_message(app, "Cannot write non-file buffer")
            }
        }
    } else if cmd == "q" {
        if app.active_pane != nil && app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
            app.active_pane.dired.is_editing = false
            _ = sdl.StopTextInput(app.window)
            app_set_message(app, "Dired: edit cancelled")
            return
        }
        app_close_pane(app, app.active_pane)
    } else if cmd == "wq" || cmd == "x" {
        if app.active_pane != nil {
            if app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
                msg := dired_apply_edits(&app.active_pane.dired, &app.active_pane.editor)
                app_set_message(app, msg)
                _ = sdl.StopTextInput(app.window)
            } else if app.active_pane.kind == .Editor {
                editor_save_file(&app.active_pane.editor, app)
                app_close_pane(app, app.active_pane)
            }
        }
    } else if strings.has_prefix(cmd, "sort ") || cmd == "sort" {
        sub := strings.trim_space(cmd[4:] if strings.has_prefix(cmd, "sort ") else "")
        if app.active_pane != nil && app.active_pane.kind == .Dired {
            if sub == "size" {
                app.active_pane.dired.sort_by = .Size
            } else if sub == "time" {
                app.active_pane.dired.sort_by = .Time
            } else if sub == "name" {
                app.active_pane.dired.sort_by = .Name
            } else if sub == "rev" || sub == "reverse" {
                app.active_pane.dired.sort_order = .Desc if app.active_pane.dired.sort_order == .Asc else .Asc
            } else {
                dired_cycle_sort(&app.active_pane.dired)
            }
            dired_sort_entries(&app.active_pane.dired)
            app_set_message(app, fmt.tprintf("Dired: sorted by %s (%s)", dired_sort_name(app.active_pane.dired.sort_by), "desc" if app.active_pane.dired.sort_order == .Desc else "asc"))
        } else {
            app_set_message(app, "Not in a Dired buffer")
        }
    } else if cmd == "qa" || cmd == "q!" {
        app.running = false
    } else if cmd == "sp" || cmd == "split" {
        app_split_pane(app, app.active_pane, .Horizontal)
        app_set_message(app, "Horizontal split")
    } else if cmd == "vs" || cmd == "vsplit" {
        app_split_pane(app, app.active_pane, .Vertical)
        app_set_message(app, "Vertical split")
    } else if cmd == "dired" || cmd == "d" || cmd == "e ." {
        dir := "."
        if app.active_pane != nil && app.active_pane.kind == .Editor && app.active_pane.editor.file_path != "" {
            dir = filepath.dir(app.active_pane.editor.file_path)
            if dir == "" do dir = "."
        } else if app.active_pane != nil && app.active_pane.kind == .Dired && app.active_pane.dired.path != "" {
            dir = app.active_pane.dired.path
        }
        app_pane_open_dired(app, app.active_pane, dir)
    } else if strings.has_prefix(cmd, "compile ") || cmd == "compile" || strings.has_prefix(cmd, "make ") || cmd == "make" {
        cmd_arg := ""
        if strings.has_prefix(cmd, "compile ") {
            cmd_arg = strings.trim_space(cmd[8:])
        } else if strings.has_prefix(cmd, "make ") {
            cmd_arg = strings.trim_space(cmd[5:])
        }
        app_run_compile(app, cmd_arg)
    } else if cmd == "recompile" {
        app_run_compile(app, app.last_compile_cmd)
    } else if cmd == "cfirst" || cmd == "crewind" {
        comp_pane: ^Pane = nil
        for p in app.panes {
            if p.kind == .Compilation {
                comp_pane = p
                break
            }
        }
        if comp_pane != nil {
            compilation_first_error(&comp_pane.compilation, app, comp_pane)
        } else {
            app.cmd_prompt.message = "No compilation buffer"
        }
    } else if cmd == "cn" || cmd == "cnext" || cmd == "next-error" {
        comp_pane: ^Pane = nil
        for p in app.panes {
            if p.kind == .Compilation {
                comp_pane = p
                break
            }
        }
        if comp_pane != nil {
            compilation_next_error(&comp_pane.compilation, app, comp_pane)
        } else {
            app.cmd_prompt.message = "No compilation buffer"
        }
    } else if cmd == "cp" || cmd == "cprev" || cmd == "prev-error" {
        comp_pane: ^Pane = nil
        for p in app.panes {
            if p.kind == .Compilation {
                comp_pane = p
                break
            }
        }
        if comp_pane != nil {
            compilation_prev_error(&comp_pane.compilation, app, comp_pane)
        } else {
            app.cmd_prompt.message = "No compilation buffer"
        }
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
    } else if strings.has_prefix(cmd, "theme ") || cmd == "theme" || strings.has_prefix(cmd, "colorscheme ") || cmd == "colorscheme" {
        arg := ""
        if strings.has_prefix(cmd, "theme ") {
            arg = strings.trim_space(cmd[6:])
        } else if strings.has_prefix(cmd, "colorscheme ") {
            arg = strings.trim_space(cmd[12:])
        }
        if arg == "" {
            next_id := ThemeId((int(app.current_theme_id) + 1) % 4)
            app.current_theme_id = next_id
            app.theme = theme_get(next_id)
            app_set_message(app, fmt.tprintf("Theme: %s", app.theme.name))
        } else {
            id, ok := theme_from_name(arg)
            if ok {
                app.current_theme_id = id
                app.theme = theme_get(id)
                app_set_message(app, fmt.tprintf("Theme: %s", app.theme.name))
            } else {
                app_set_message(app, fmt.tprintf("Unknown theme: %s (options: gruber-darker, naysayer, kanagawa, hemisu)", arg))
            }
        }
    } else if strings.has_prefix(cmd, "cd ") || cmd == "cd" {
        arg := strings.trim_space(cmd[3:]) if strings.has_prefix(cmd, "cd ") else ""
        if arg == "" {
            arg = os.get_env("HOME", context.temp_allocator)
            if arg == "" do arg = "."
        }
        abs_target, abs_err := filepath.abs(arg, context.temp_allocator)
        if abs_err == nil && os.is_dir(abs_target) {
            if app.working_dir != "" do delete(app.working_dir)
            app.working_dir = strings.clone(abs_target, context.allocator)
            _ = os.set_working_directory(app.working_dir)
            app_set_message(app, fmt.tprintf("Working dir: %s", app.working_dir))
        } else {
            app_set_message(app, fmt.tprintf("Invalid directory: %s", arg))
        }
    } else if cmd == "pwd" {
        app_set_message(app, fmt.tprintf("Working dir: %s", app.working_dir))
    } else if cmd == "files" || cmd == "find" || cmd == "picker" {
        file_picker_open(&app.file_picker, app.working_dir, app.window)
    } else if strings.has_prefix(cmd, "zoom ") || strings.has_prefix(cmd, "scale ") {
        val_str := strings.trim_space(cmd[5:] if strings.has_prefix(cmd, "zoom ") else cmd[6:])
        scale_val, ok := strconv.parse_f32(val_str)
        if ok && scale_val >= 0.25 && scale_val <= 3.0 {
            global_ui_scale = scale_val
            app_set_message(app, fmt.tprintf("UI Scale: %.2f", global_ui_scale))
        } else {
            app_set_message(app, "Usage: :zoom <0.5 .. 2.5>")
        }
    } else {
        app_set_message(app, fmt.tprintf("Unknown command: :%s", cmd))
    }
}

load :: proc(app: ^App) {
    sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "wayland")

    if !sdl.CreateWindowAndRenderer("Odin Text Editor", 1024, 768, sdl.WINDOW_RESIZABLE, &app.window, &app.renderer) {
        panic("Failed to create SDL window and renderer")
    }

    app.current_theme_id = DEFAULT_THEME
    app.theme = theme_get(app.current_theme_id)
    app.font = load_font(app.renderer)
    app.panes = make([dynamic]^Pane, context.allocator)
    app.cmd_prompt.buffer = make([dynamic]u8, context.allocator)
    app.cmd_prompt.matches = make([dynamic]string, context.allocator)
    app.next_pane_id = 1

    // Initialize working directory
    cwd, cwd_err := os.get_working_directory(context.allocator)
    if cwd_err == nil {
        app.working_dir = cwd
    } else {
        app.working_dir = strings.clone(".", context.allocator)
    }

    file_picker_init(&app.file_picker)

    target_path := app.working_dir
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

    // Initialize LSP manager
    lsp_manager_init(&app.lsp_manager, app.working_dir)

    app.active_pane = initial_pane
    app.root_split = split_create_leaf(initial_pane)
    app.running = true

    if initial_pane.kind == .Editor && initial_pane.editor.file_path != "" {
        if lsp := app_get_lsp_for_file(app, initial_pane.editor.file_path); lsp != nil && lsp.running {
            full_text := pt_full_text(&initial_pane.editor.table)
            defer delete(full_text)
            lsp_did_open(lsp, initial_pane.editor.file_path, full_text)
        }
    }
}

update :: proc(app: ^App) {
    event: sdl.Event
    for sdl.PollEvent(&event) {
        if event.type == .QUIT {
            app.running = false
            break
        }

        // If file picker is active, route event to it first
        if app.file_picker.active {
            if file_picker_handle_event(&app.file_picker, &event, app) {
                continue
            }
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
                if app.cmd_prompt.in_completion {
                    app_reset_command_completion(&app.cmd_prompt)
                }
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
            is_alt := (mod & sdl.KMOD_ALT) != {}

            is_insert := false
            if app.active_pane != nil {
                if app.active_pane.kind == .Editor {
                    is_insert = app.active_pane.editor.mode == .Insert
                } else if app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
                    is_insert = app.active_pane.editor.mode == .Insert
                }
            }

            // If command prompt is active, intercept all keys
            if app.cmd_prompt.active {
                switch key {
                case sdl.K_ESCAPE:
                    app_close_command_prompt(app)
                case sdl.K_TAB:
                    is_shift := (mod & sdl.KMOD_SHIFT) != {}
                    app_command_prompt_tab(app, reverse = is_shift)
                case sdl.K_BACKSPACE:
                    if app.cmd_prompt.in_completion {
                        app_reset_command_completion(&app.cmd_prompt)
                    }
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

            // Zoom controls
            if is_ctrl && (key == sdl.K_EQUALS || key == sdl.K_KP_PLUS) {
                global_ui_scale = min(2.5, global_ui_scale + 0.1)
                app_set_message(app, fmt.tprintf("Zoom: %.0f%%", global_ui_scale * 100.0))
                continue
            }
            if is_ctrl && (key == sdl.K_MINUS || key == sdl.K_KP_MINUS) {
                global_ui_scale = max(0.5, global_ui_scale - 0.1)
                app_set_message(app, fmt.tprintf("Zoom: %.0f%%", global_ui_scale * 100.0))
                continue
            }
            if is_ctrl && (key == sdl.K_0 || key == sdl.K_KP_0) {
                global_ui_scale = 1.0
                app_set_message(app, "Zoom reset (100%)")
                continue
            }

            // Handle pending leader key (Space)
            if app.pending_leader {
                app.pending_leader = false
                app.cmd_prompt.message = ""
                if key == sdl.K_F {
                    file_picker_open(&app.file_picker, app.working_dir, app.window)
                    continue
                }
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
            if !is_insert && is_ctrl && key == sdl.K_W {
                app.pending_w_cmd = true
                continue
            }

            // Trigger leader key on Space when not in Insert mode
            if !is_insert && !is_ctrl && !is_alt && key == sdl.K_SPACE {
                app.pending_leader = true
                app_set_message(app, "Leader: <Space> (f: file picker)")
                continue
            }
        }

        // Dispatch remaining events to active pane
        if app.active_pane != nil {
            switch app.active_pane.kind {
            case .Editor:
                editor_handle_event(&app.active_pane.editor, &event, app.window, app)
            case .Dired:
                if app.active_pane.dired.is_editing {
                    editor_handle_event(&app.active_pane.editor, &event, app.window, app)
                } else {
                    dired_handle_event(&app.active_pane.dired, &event, app, app.active_pane)
                }
            case .Compilation:
                compilation_handle_event(&app.active_pane.compilation, &event, app, app.active_pane)
            }
        }
    }

    // LSP update and response dispatch for all running servers
    for server_kind in LspServerKind {
        client := app.lsp_manager.clients[server_kind]
        if client != nil && client.running {
            lsp_update(client, app)
        }
    }

    active_lsp := app_get_active_lsp(app)
    if active_lsp != nil {
        // Handle completions transfer to active editor
        if len(active_lsp.completions) > 0 {
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                e := &app.active_pane.editor
                if e.mode == .Insert {
                    for c in e.completion.all_items {
                        delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
                    }
                    clear(&e.completion.all_items)
                    for c in active_lsp.completions {
                        append(&e.completion.all_items, LspCompletionItem{
                            label         = strings.clone(c.label),
                            detail        = strings.clone(c.detail),
                            documentation = strings.clone(c.documentation),
                            insert_text   = strings.clone(c.insert_text),
                            kind          = c.kind,
                        })
                    }
                    editor_filter_completions(e)
                }
            }
            for c in active_lsp.completions {
                delete(c.label); delete(c.detail); delete(c.documentation); delete(c.insert_text)
            }
            clear(&active_lsp.completions)
        }

        // Handle Go to Definition result
        if loc, ok := active_lsp.last_definition.?; ok {
            active_lsp.last_definition = nil
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                cur_abs, _ := filepath.abs(app.active_pane.editor.file_path, context.temp_allocator)
                if cur_abs != loc.file_path {
                    app_pane_open_file(app, app.active_pane, loc.file_path)
                }
                e := &app.active_pane.editor
                e.cursor.row = loc.row
                e.cursor.col = loc.col
                e.desired_col = loc.col
                editor_clamp_cursor(e)
                app_set_message(app, fmt.tprintf("Definition: %s:%d:%d", filepath.base(loc.file_path), loc.row + 1, loc.col + 1))
            }
        }

        // Handle Hover result
        if active_lsp.last_hover != "" {
            clean_hover := strings.trim_space(active_lsp.last_hover)
            first_nl := strings.index(clean_hover, "\n")
            display_line := clean_hover
            if first_nl >= 0 do display_line = clean_hover[:first_nl]
            app_set_message(app, fmt.tprintf("Hover: %s", display_line))
            delete(active_lsp.last_hover)
            active_lsp.last_hover = ""
        }

        // Handle Range Formatting edits
        if len(active_lsp.last_edits) > 0 {
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                e := &app.active_pane.editor
                editor_apply_lsp_edits(e, active_lsp.last_edits[:])
                app_set_message(app, fmt.tprintf("LSP: Formatted range (%d edits)", len(active_lsp.last_edits)))
            }
            for ed in active_lsp.last_edits do delete(ed.new_text)
            clear(&active_lsp.last_edits)
        }
    }

    // Debounced LSP textDocument/didChange across open editor panes
    for pane in app.panes {
        if pane != nil && pane.kind == .Editor {
            e := &pane.editor
            if e.needs_lsp_sync && time.since(e.last_edit_time) > 250 * time.Millisecond {
                e.needs_lsp_sync = false
                if lsp := app_get_lsp_for_file(app, e.file_path); lsp != nil && lsp.running && e.file_path != "" {
                    full_text := pt_full_text(&e.table)
                    defer delete(full_text)
                    lsp_did_change(lsp, e.file_path, full_text)
                }
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
    sdl.SetRenderDrawColorFloat(app.renderer, app.theme.bg.r, app.theme.bg.g, app.theme.bg.b, app.theme.bg.a)
    sdl.RenderClear(app.renderer)

    // Render all panes
    for p in app.panes {
        is_focused := (p == app.active_pane)
        switch p.kind {
        case .Editor:
            editor_render(&p.editor, app.renderer, &app.font, p.rect, is_focused, &app.theme, app_get_lsp_for_file(app, p.editor.file_path))
        case .Dired:
            if p.dired.is_editing {
                editor_render(&p.editor, app.renderer, &app.font, p.rect, is_focused, &app.theme, app_get_lsp_for_file(app, p.editor.file_path))
            } else {
                dired_render(&p.dired, app.renderer, &app.font, p.rect, is_focused, &app.theme)
            }
        case .Compilation:
            compilation_render(&p.compilation, app.renderer, &app.font, p.rect, is_focused, &app.theme)
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
            sdl.SetRenderDrawColorFloat(app.renderer, app.theme.border.r, app.theme.border.g, app.theme.border.b, app.theme.border.a)
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
            sdl.SetRenderDrawColorFloat(app.renderer, app.theme.border.r, app.theme.border.g, app.theme.border.b, app.theme.border.a)
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
    sdl.SetRenderDrawColorFloat(app.renderer, app.theme.cmd_bar_bg.r, app.theme.cmd_bar_bg.g, app.theme.cmd_bar_bg.b, app.theme.cmd_bar_bg.a)
    sdl.RenderFillRect(app.renderer, &cmd_bar_rect)

    // Divider line above cmd bar
    div_rect := sdl.FRect{0, main_area_h, f32(w), 1.0}
    sdl.SetRenderDrawColorFloat(app.renderer, app.theme.border.r, app.theme.border.g, app.theme.border.b, app.theme.border.a)
    sdl.RenderFillRect(app.renderer, &div_rect)

    if app.cmd_prompt.active {
        cmd_str := fmt.tprintf(":%s", string(app.cmd_prompt.buffer[:]))
        push_line(&app.font, cmd_str, Vec2{10.0, main_area_h + 3.0}, app.theme.keyword, .HALF)

        // Command cursor
        char_w := app.panes[0].editor.char_advance * get_font_scale_multiplier(.HALF) if len(app.panes) > 0 else 10.0
        cur_x := 10.0 + f32(len(cmd_str)) * char_w
        cur_rect := sdl.FRect{cur_x, main_area_h + 3.0, 2.0, get_line_height(.HALF)}
        sdl.SetRenderDrawColorFloat(app.renderer, app.theme.cursor.r, app.theme.cursor.g, app.theme.cursor.b, app.theme.cursor.a)
        sdl.RenderFillRect(app.renderer, &cur_rect)

        // Render completion matches preview if in completion with candidates
        if app.cmd_prompt.in_completion && len(app.cmd_prompt.matches) > 1 {
            b := strings.builder_make(context.temp_allocator)
            strings.write_string(&b, "  [")
            max_shown := min(6, len(app.cmd_prompt.matches))
            for i := 0; i < max_shown; i += 1 {
                m := app.cmd_prompt.matches[i]
                if i == app.cmd_prompt.match_index {
                    strings.write_string(&b, "*")
                    strings.write_string(&b, m)
                    strings.write_string(&b, "*")
                } else {
                    strings.write_string(&b, m)
                }
                if i + 1 < max_shown {
                    strings.write_string(&b, " ")
                }
            }
            if len(app.cmd_prompt.matches) > max_shown {
                strings.write_string(&b, " ...")
            }
            strings.write_string(&b, "]")
            sugg_str := strings.to_string(b)
            push_line(&app.font, sugg_str, Vec2{cur_x + 8.0, main_area_h + 3.0}, app.theme.comment, .HALF)
        }
    } else if app.pending_w_cmd {
        push_line(
           &app.font, 
           "Ctrl+W (s: split, v: vsplit, h/j/k/l: move, w: cycle, q: close)", 
           Vec2{10.0, main_area_h + 3.0}, 
           sdl.FColor{0.95, 0.6, 0.2, 1.0}, 
           .HALF ,
         )
    } else if app.cmd_prompt.message != "" {
        msg_color := sdl.FColor{0.9, 0.45, 0.45, 1.0} if 
        strings.has_prefix(app.cmd_prompt.message, "Unknown") || 
        strings.has_prefix(app.cmd_prompt.message, "Cannot") || 
        strings.has_prefix(app.cmd_prompt.message, "E32") else 
        sdl.FColor{0.6, 0.85, 0.6, 1.0}

        push_line(&app.font, app.cmd_prompt.message, Vec2{10.0, main_area_h + 3.0}, msg_color, .HALF)
    }

    // Render file picker modal overlay if active
    if app.file_picker.active {
        file_picker_render(&app.file_picker, app.renderer, &app.font, f32(w), f32(h), &app.theme)
    }

    flush_text(&app.font, app.renderer)
    sdl.RenderPresent(app.renderer)
}

cleanup :: proc(app: ^App) {
    file_picker_destroy(&app.file_picker)
    if app.working_dir != "" {
        delete(app.working_dir)
        app.working_dir = ""
    }

    split_destroy_tree(app.root_split)
    app.root_split = nil

    for p in app.panes {
        editor_destroy(&p.editor)
        dired_destroy(&p.dired)
        compilation_destroy(&p.compilation)
        free(p)
    }
    delete(app.panes)
    delete(app.cmd_prompt.buffer)
    app_reset_command_completion(&app.cmd_prompt)
    delete(app.cmd_prompt.matches)
    if app.last_compile_cmd != "" {
        delete(app.last_compile_cmd)
        app.last_compile_cmd = ""
    }

    sdl.DestroyRenderer(app.renderer)
    sdl.DestroyWindow(app.window)
    lsp_manager_stop_all(&app.lsp_manager)
    sdl.Quit()
}

main :: proc() {
    posix.sigignore(.SIGPIPE)
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
        free_all(context.temp_allocator)
    }
}
