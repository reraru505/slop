package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
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

pane_has_unsaved_changes :: proc(p: ^Pane) -> bool {
    return p != nil && p.kind == .Editor && p.editor.buffer.dirty && !p.editor.read_only
}

app_has_unsaved_changes :: proc(app: ^App) -> bool {
    for p in app.panes {
        if pane_has_unsaved_changes(p) do return true
    }
    return false
}

app_close_current_pane :: proc(app: ^App, force: bool) {
    if app.active_pane == nil do return
    if !force && pane_has_unsaved_changes(app.active_pane) {
        app_set_message(app, "E37: No write since last change (add ! to override)")
        return
    }
    app_close_pane(app, app.active_pane)
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
    root_dir         : string,
    file_picker      : FilePicker,
    last_compile_cmd : string,
    current_theme_id : ThemeId,
    theme            : Theme,
    running          : bool,
    font_density     : f32,
    lsp_manager      : LspManager,
}

// Current project root. Falls back to the working directory for callers
// (mostly tests) that build an App without running load().
app_picker_root :: proc(app: ^App) -> string {
    if app.root_dir != "" do return app.root_dir
    return app.working_dir
}

// Change the project root. This is the base directory for compilation, the
// picker, relative :e/:sp/:vs paths, and LSP workspaces. The session working
// directory (`:pwd`) is independent and only changes with :cd.
app_set_project_root :: proc(app: ^App, dir: string) {
    if app.root_dir != "" do delete(app.root_dir)
    app.root_dir = strings.clone(dir, context.allocator)
    lsp_manager_set_project_root(&app.lsp_manager, dir)
}

// Resolve a user-supplied path against the project root. Absolute paths are
// returned unchanged; every other path is rooted at the project directory.
app_resolve_path :: proc(app: ^App, path: string) -> string {
    p := expand_home_path(path)
    if p == "" || filepath.is_abs(p) do return p

    root := app_picker_root(app)
    if root == "" do return p

    joined, err := filepath.join([]string{root, p}, context.temp_allocator)
    if err != nil do return p
    return joined
}

// Lookup only: rendering and request paths must never fork a server during
// draw. Clients are spawned from lsp_manager_poll in update().
app_get_lsp_for_file :: proc(app: ^App, file_path: string) -> ^LspClient {
    if app == nil || file_path == "" do return nil
    lang := language_from_file_path(file_path)
    return lsp_manager_peek(&app.lsp_manager, lang, file_path)
}

app_lsp_doc_open :: proc(app: ^App, e: ^Editor, text: string) {
    if app == nil || e == nil || e.buffer == nil || e.buffer.file_path == "" || strings.has_prefix(e.buffer.file_path, "*") do return
    lsp_manager_open_doc(&app.lsp_manager, e.buffer.file_path, text)
    e.lsp_doc_open = true
}

app_lsp_doc_close :: proc(app: ^App, e: ^Editor) {
    if app == nil || e == nil || e.buffer == nil || !e.lsp_doc_open do return
    lsp_manager_close_doc(&app.lsp_manager, e.buffer.file_path)
    e.lsp_doc_open = false
}

app_lsp_doc_change :: proc(app: ^App, file_path, text: string) {
    if app == nil || file_path == "" do return
    lsp_manager_change_doc(&app.lsp_manager, file_path, text)
}

app_get_active_lsp :: proc(app: ^App) -> ^LspClient {
    if app == nil || app.active_pane == nil || app.active_pane.kind != .Editor do return nil
    return app_get_lsp_for_file(app, app.active_pane.editor.buffer.file_path)
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

completion_has :: proc(matches: ^[dynamic]string, candidate: string) -> bool {
    for m in matches^ do if m == candidate do return true
    return false
}

// Collect executable names from the PATH that start with prefix.
collect_path_commands :: proc(
    path_env, prefix, cmd_prefix: string,
    matches: ^[dynamic]string,
    limit: int,
) {
    if path_env == "" || limit <= 0 do return
    for entry in strings.split(path_env, ":", context.temp_allocator) {
        dir := entry
        if dir == "" do dir = "."
        handle, err := os.open(dir)
        if err != nil do continue
        files, ferr := os.read_dir(handle, -1, context.temp_allocator)
        os.close(handle)
        if ferr != nil do continue

        for f in files {
            if f.type == .Directory do continue
            if f.mode & os.Permissions_Execute_All == {} do continue
            if strings.has_prefix(f.name, ".") && !strings.has_prefix(prefix, ".") do continue
            if !strings.has_prefix(f.name, prefix) do continue
            candidate := fmt.aprintf("%s %s", cmd_prefix, f.name)
            if completion_has(matches, candidate) {
                delete(candidate)
                continue
            }
            append(matches, candidate)
            if len(matches^) >= limit do return
        }
    }
}

// Complete the final token of a compile command as a filesystem path. head is
// the already-typed prefix (including its trailing space), if any.
complete_path_token :: proc(
    cmd_prefix, head, token: string,
    matches: ^[dynamic]string,
    base_dir := "",
) {
    base := base_dir
    if base == "" do base = "."

    search_dir := base
    dir_part := ""
    name_prefix := token
    if slash := strings.last_index_byte(token, '/'); slash >= 0 {
        dir_no_slash := token[:slash]
        dir_part = token[:slash + 1]
        name_prefix = token[slash + 1:]

        if dir_no_slash == "" && strings.has_prefix(token, "/") {
            // "/us" has an empty dir component but is rooted at filesystem /.
            search_dir = "/"
        } else if filepath.is_abs(dir_no_slash) {
            search_dir = dir_no_slash
        } else if dir_no_slash == "~" || strings.has_prefix(dir_no_slash, "~/") {
            search_dir = expand_home_path(dir_no_slash)
        } else if dir_no_slash == "" {
            search_dir = base
        } else if joined, err := filepath.join([]string{base, dir_no_slash}, context.temp_allocator); err == nil {
            search_dir = joined
        } else {
            search_dir = dir_no_slash
        }
    }

    handle, err := os.open(search_dir)
    if err != nil do return
    files, ferr := os.read_dir(handle, -1, context.temp_allocator)
    os.close(handle)
    if ferr != nil do return

    for f in files {
        if strings.has_prefix(f.name, ".") && !strings.has_prefix(name_prefix, ".") do continue
        if !strings.has_prefix(f.name, name_prefix) do continue
        joined := fmt.tprintf("%s%s", dir_part, f.name)
        if f.type == .Directory do joined = fmt.tprintf("%s/", joined)
        candidate := fmt.aprintf("%s %s%s", cmd_prefix, head, joined)
        if !completion_has(matches, candidate) {
            append(matches, candidate)
        } else {
            delete(candidate)
        }
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
                for th in THEME_NAMES {
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
            case "compile", "make":
                raw_args := curr_str[first_space + 1:]
                last_space := strings.last_index_byte(raw_args, ' ')
                head := ""
                token := raw_args
                if last_space >= 0 {
                    head = raw_args[:last_space + 1]
                    token = raw_args[last_space + 1:]
                }

                start := len(p.matches)
                if last_space < 0 {
                    // Completing the command itself: PATH executables.
                    path_env := os.get_env("PATH", context.temp_allocator)
                    collect_path_commands(path_env, token, cmd_prefix, &p.matches, 100)
                }
                // Arguments (and command tokens containing '/') complete as paths.
                if !strings.has_prefix(token, "-") {
                    complete_path_token(cmd_prefix, head, token, &p.matches, app_picker_root(app))
                }
                if len(p.matches) > start {
                    slice.sort_by(p.matches[start:], proc(a, b: string) -> bool {
                        return a < b
                    })
                }

            case "e", "edit", "sp", "split", "vs", "vsplit", "cd", "root":
                if cmd_prefix == "root" && strings.has_prefix("here", arg_prefix) {
                    append(&p.matches, fmt.aprintf("%s here", cmd_prefix))
                }
                base_dir := app_picker_root(app)
                if base_dir == "" do base_dir = "."
                search_dir := base_dir
                name_prefix := arg_prefix
                if slash_idx := strings.last_index_byte(arg_prefix, '/'); slash_idx >= 0 {
                    dir_no_slash := arg_prefix[:slash_idx]
                    name_prefix = arg_prefix[slash_idx+1:]
                    if dir_no_slash == "" && strings.has_prefix(arg_prefix, "/") {
                        search_dir = "/"
                    } else if filepath.is_abs(dir_no_slash) {
                        search_dir = dir_no_slash
                    } else if dir_no_slash == "~" || strings.has_prefix(dir_no_slash, "~/") {
                        search_dir = expand_home_path(dir_no_slash)
                    } else if dir_no_slash == "" {
                        search_dir = base_dir
                    } else if joined, err := filepath.join([]string{base_dir, dir_no_slash}, context.temp_allocator); err == nil {
                        search_dir = joined
                    } else {
                        search_dir = dir_no_slash
                    }
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
                "w", "wa", "wq", "wqa", "q", "qa", "q!", "x",
                "split", "sp", "vsplit", "vs",
                "dired", "edit", "e",
                "compile", "recompile", "make",
                "cnext", "cn", "cprev", "cp", "cfirst", "crewind",
                "bnext", "bn",
                "theme", "colorscheme",
                "sort", "cd", "pwd", "root", "files", "zoom", "linespace", "lineheight", "help",
                "qa!", "goto", "line", "d", "h", "?", "find", "picker", "next-error", "prev-error",
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

app_pane_open_file :: proc(app: ^App, pane: ^Pane, file_path: string, force := false) -> bool {
    if pane == nil do return false

    target_path := file_path
    if target_path != "" && !strings.has_prefix(target_path, "*") {
        target_path = lsp_abs_path(target_path, context.temp_allocator)
    }

    // Refuse to silently replace a modified or read-only editor buffer.
    if pane.kind == .Editor {
        if pane.editor.read_only && !force {
            app_set_message(app, "Buffer is read-only")
            return false
        }
        if pane.editor.buffer.dirty && !force {
            app_set_message(app, "E37: No write since last change (use :e! to override)")
            return false
        }
    }

    // Any editor replacement ends a wdired session in this pane.
    pane.dired.is_editing = false

    data, err := os.read_entire_file(target_path, context.allocator)
    initial_text := ""
    if err == nil && data != nil {
        initial_text = string(data)
    }

    // :e / :e! on a file that is already open reloads the shared buffer in
    // place so every split view sees the fresh contents. The dirty guard above
    // has already refused a plain reload when there are unsaved changes.
    if target_path != "" && pane.kind == .Editor && pane.editor.buffer != nil &&
       pane.editor.buffer.file_path == target_path {
        editor_replace_buffer_text(&pane.editor, initial_text)
        pane.editor.buffer.needs_lsp_sync = true
        pane.editor.buffer.last_edit_time = time.now()
        if data != nil do delete(data)
        return true
    }

    app_lsp_doc_close(app, &pane.editor)
    editor_destroy(&pane.editor)
    editor_init(&pane.editor, &app.font, initial_text, target_path)

    // read_entire_file can return a partial buffer together with an error.
    if data != nil do delete(data)

    pane.kind = .Editor
    app.active_pane = pane

    full_text := pt_full_text(&pane.editor.buffer.table)
    defer delete(full_text)
    app_lsp_doc_open(app, &pane.editor, full_text)
    return true
}

app_pane_open_dired :: proc(app: ^App, pane: ^Pane, dir_path: string) {
    if pane == nil do return
    // Dired keeps the old editor buffer hidden but still allocated. Converting
    // a modified or read-only buffer would hide it from the quit guard (and
    // wdired's editor_init would destroy it), so refuse.
    if pane.kind == .Editor {
        if pane.editor.read_only {
            app_set_message(app, "Buffer is read-only")
            return
        }
        if pane.editor.buffer.dirty {
            app_set_message(app, "E37: No write since last change (save before :dired)")
            return
        }
    }
    abs_dir := lsp_abs_path(dir_path, context.temp_allocator)
    if !os.is_dir(abs_dir) {
        app_set_message(app, fmt.tprintf("Not a directory: %s", dir_path))
        return
    }
    app_lsp_doc_close(app, &pane.editor)
    pane.kind = .Dired
    app.active_pane = pane
    dired_request_load(&pane.dired, abs_dir, pane.dired.sort_by, pane.dired.sort_order)
}

app_pane_open :: proc(app: ^App, pane: ^Pane, target: string, force := false) {
    if os.is_dir(target) {
        app_pane_open_dired(app, pane, target)
    } else {
        app_pane_open_file(app, pane, target, force)
    }
}

app_open_file :: proc(app: ^App, file_path: string) {
    app_pane_open_file(app, app.active_pane, file_path)
}

app_open_dired :: proc(app: ^App, dir_path: string) {
    app_pane_open_dired(app, app.active_pane, dir_path)
}

// Re-bake the font atlas at the current UI scale. Glyphs are rasterized at
// native pixel size, so this keeps text sharp when zooming.
app_reload_font :: proc(app: ^App) {
    if app == nil || app.renderer == nil do return
    font_reload(&app.font, app.renderer, app.window)
    for p in app.panes {
        p.editor.char_advance = font_cell_width(&app.font)
    }
}

app_open_help :: proc(app: ^App) {
    if app == nil || app.active_pane == nil do return

    // Focus an existing help buffer instead of opening another split.
    for p in app.panes {
        if p.kind == .Editor && p.editor.buffer.file_path == HELP_FILE_PATH {
            app.active_pane = p
            return
        }
    }

    // app_split_pane copies according to the target's kind. Temporarily present
    // it as an editor so :help from a compilation/dired pane has no side effects.
    target := app.active_pane
    original_kind := target.kind
    target.kind = .Editor
    app_split_pane(app, target, .Horizontal)
    target.kind = original_kind

    help_pane := app.active_pane
    if help_pane == nil do return
    help_pane.kind = .Editor
    editor_destroy(&help_pane.editor)
    help_text := help_render(context.allocator)
    defer delete(help_text)
    editor_init(&help_pane.editor, &app.font, help_text, HELP_FILE_PATH)
    help_pane.editor.read_only = true
    help_pane.editor.buffer.dirty = false
}

app_run_compile :: proc(app: ^App, cmd_str: string) {
    workdir := app_picker_root(app)
    target_cmd := strings.trim_space(cmd_str)
    if target_cmd == "" {
        if app.last_compile_cmd != "" {
            target_cmd = app.last_compile_cmd
        } else {
            makefile := "Makefile"
            if workdir != "" {
                if joined, err := filepath.join([]string{workdir, "Makefile"}, context.temp_allocator); err == nil {
                    makefile = joined
                }
            }
            if os.exists(makefile) {
                target_cmd = "make"
            } else {
                target_cmd = "odin check ."
            }
        }
    }
    // target_cmd may alias app.last_compile_cmd (recompile passes it), so
    // clone before freeing the old value.
    owned_cmd := strings.clone(target_cmd)
    if app.last_compile_cmd != "" do delete(app.last_compile_cmd)
    app.last_compile_cmd = owned_cmd

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

    compilation_run_command(&comp_pane.compilation, owned_cmd, workdir)
    // Focus the output buffer so j/k, y/Y, and error navigation work
    // immediately, including when a previous compilation pane already exists.
    app.active_pane = comp_pane
    app_set_message(app, fmt.tprintf("Compilation: %s", comp_pane.compilation.status))
}

// Write every modified, named editor buffer. Shared split views are written
// once, and wdired listings in progress are applied first. Returns false when
// any write failed, in which case the caller must not quit.
app_write_all :: proc(app: ^App) -> bool {
    if app == nil do return false

    written := 0
    seen: [dynamic]^Buffer
    defer delete(seen)

    for p in app.panes {
        if p == nil do continue
        if p.kind == .Dired && p.dired.is_editing {
            msg := dired_apply_edits(&p.dired, &p.editor)
            _ = sdl.StopTextInput(app.window)
            if !p.dired.apply_ok {
                app_set_message(app, msg)
                return false
            }
            written += 1
            continue
        }
        if p.kind != .Editor do continue
        e := &p.editor
        b := e.buffer
        if b == nil || b.file_path == "" || !b.dirty do continue
        if e.read_only do continue

        already := false
        for existing in seen {
            if existing == b {
                already = true
                break
            }
        }
        if already do continue
        append(&seen, b)

        if !editor_save_file(e, app) {
            app_set_message(app, fmt.tprintf("Failed to write %s", b.file_path))
            return false
        }
        written += 1
    }

    if written == 0 {
        app_set_message(app, "No modified buffers to write")
    } else {
        app_set_message(app, fmt.tprintf("%d buffer(s) written", written))
    }
    return true
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
                e := &app.active_pane.editor
                if e.read_only {
                    app_set_message(app, "Buffer is read-only")
                } else if editor_save_file(e, app) {
                    app_set_message(app, fmt.tprintf("\"%s\" written", e.buffer.file_path))
                } else if e.buffer.file_path == "" {
                    app_set_message(app, "E32: No file name")
                }
            } else {
                app_set_message(app, "Cannot write non-file buffer")
            }
        }
    } else if cmd == "wa" || cmd == "wall" {
        _ = app_write_all(app)
    } else if cmd == "q" {
        if app.active_pane != nil && app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
            app.active_pane.dired.is_editing = false
            _ = sdl.StopTextInput(app.window)
            app_set_message(app, "Dired: edit cancelled")
            return
        }
        app_close_current_pane(app, false)
    } else if cmd == "q!" {
        app_close_current_pane(app, true)
    } else if cmd == "wq" || cmd == "x" {
        if app.active_pane != nil {
            if app.active_pane.kind == .Dired && app.active_pane.dired.is_editing {
                msg := dired_apply_edits(&app.active_pane.dired, &app.active_pane.editor)
                app_set_message(app, msg)
                _ = sdl.StopTextInput(app.window)
                if app.active_pane.dired.apply_ok {
                    app_close_current_pane(app, false)
                }
            } else if app.active_pane.kind == .Editor {
                e := &app.active_pane.editor
                if e.read_only {
                    app_set_message(app, "Buffer is read-only")
                } else if editor_save_file(e, app) {
                    app_close_pane(app, app.active_pane)
                } else if e.buffer.file_path == "" {
                    app_set_message(app, "E32: No file name")
                }
            }
        }
    } else if cmd == "wqa" || cmd == "wqall" || cmd == "xa" {
        if app_write_all(app) && !app_has_unsaved_changes(app) {
            app.running = false
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
    } else if cmd == "qa" {
        if app_has_unsaved_changes(app) {
            app_set_message(app, "E37: No write since last change (add ! to override)")
            return
        }
        app.running = false
    } else if cmd == "qa!" {
        app.running = false
    } else if cmd == "sp" || cmd == "split" {
        app_split_pane(app, app.active_pane, .Horizontal)
        app_set_message(app, "Horizontal split")
    } else if cmd == "vs" || cmd == "vsplit" {
        app_split_pane(app, app.active_pane, .Vertical)
        app_set_message(app, "Vertical split")
    } else if cmd == "dired" || cmd == "d" || cmd == "e ." {
        dir := app_picker_root(app)
        if dir == "" do dir = "."
        if app.active_pane != nil && app.active_pane.kind == .Editor && app.active_pane.editor.buffer.file_path != "" {
            dir = filepath.dir(app.active_pane.editor.buffer.file_path)
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
    } else if strings.has_prefix(cmd, "e! ") || strings.has_prefix(cmd, "edit! ") {
        target := strings.trim_space(cmd[3:] if strings.has_prefix(cmd, "e! ") else cmd[6:])
        app_pane_open(app, app.active_pane, app_resolve_path(app, target), force = true)
    } else if strings.has_prefix(cmd, "e ") || strings.has_prefix(cmd, "edit ") {
        target := strings.trim_space(cmd[2:] if strings.has_prefix(cmd, "e ") else cmd[5:])
        app_pane_open(app, app.active_pane, app_resolve_path(app, target))
    } else if cmd == "e" || cmd == "edit" {
        if app.active_pane != nil && app.active_pane.kind == .Editor && app.active_pane.editor.buffer.file_path != "" {
            _ = app_pane_open_file(app, app.active_pane, app.active_pane.editor.buffer.file_path)
        } else {
            app_set_message(app, "Usage: :e <path>")
        }
    } else if strings.has_prefix(cmd, "sp ") || strings.has_prefix(cmd, "split ") {
        target := strings.trim_space(cmd[3:] if strings.has_prefix(cmd, "sp ") else cmd[6:])
        app_split_pane(app, app.active_pane, .Horizontal)
        if target != "" {
            app_pane_open(app, app.active_pane, app_resolve_path(app, target))
        }
    } else if strings.has_prefix(cmd, "vs ") || strings.has_prefix(cmd, "vsplit ") {
        target := strings.trim_space(cmd[3:] if strings.has_prefix(cmd, "vs ") else cmd[7:])
        app_split_pane(app, app.active_pane, .Vertical)
        if target != "" {
            app_pane_open(app, app.active_pane, app_resolve_path(app, target))
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
            next_id := ThemeId((int(app.current_theme_id) + 1) % THEME_COUNT)
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
                theme_names := THEME_NAMES
                app_set_message(app, fmt.tprintf(
                    "Unknown theme: %s (options: %s)",
                    arg,
                    strings.join(theme_names[:], ", ", context.temp_allocator),
                ))
            }
        }
    } else if strings.has_prefix(cmd, "cd ") || cmd == "cd" {
        arg := strings.trim_space(cmd[3:]) if strings.has_prefix(cmd, "cd ") else ""
        if arg == "" {
            arg = os.get_env("HOME", context.temp_allocator)
            if arg == "" do arg = "."
        }
        arg = expand_home_path(arg)
        // Relative :cd paths resolve against the session directory, falling
        // back to the project root. The editor never calls chdir(); all path
        // resolution is explicit, which keeps process-global state stable.
        if arg != "" && !filepath.is_abs(arg) {
            base := app.working_dir
            if base == "" do base = app_picker_root(app)
            if joined, join_err := filepath.join([]string{base, arg}, context.temp_allocator); join_err == nil {
                arg = joined
            }
        }
        abs_target, abs_err := filepath.abs(arg, context.temp_allocator)
        if abs_err == nil && os.is_dir(abs_target) {
            if app.working_dir != "" do delete(app.working_dir)
            app.working_dir = strings.clone(abs_target, context.allocator)
            // The project scope follows an explicit cd.
            app_set_project_root(app, abs_target)
            app_set_message(app, fmt.tprintf("Working dir: %s", app.working_dir))
        } else {
            app_set_message(app, fmt.tprintf("Invalid directory: %s", arg))
        }
    } else if strings.has_prefix(cmd, "root ") || cmd == "root" {
        arg := strings.trim_space(cmd[5:]) if strings.has_prefix(cmd, "root ") else ""
        if arg == "" {
            app_set_message(app, fmt.tprintf("Project root: %s", app_picker_root(app)))
        } else {
            if arg == "here" do arg = app_here_directory(app)
            if arg == "" {
                app_set_message(app, "No directory here")
            } else {
                arg = app_resolve_path(app, arg)
                abs_target, abs_err := filepath.abs(arg, context.temp_allocator)
                if abs_err == nil && os.is_dir(abs_target) {
                    app_set_project_root(app, abs_target)
                    app_set_message(app, fmt.tprintf("Project root: %s", app.root_dir))
                } else {
                    app_set_message(app, fmt.tprintf("Invalid directory: %s", arg))
                }
            }
        }
    } else if cmd == "pwd" {
        root := app_picker_root(app)
        if root != "" && root != app.working_dir {
            app_set_message(app, fmt.tprintf("Working dir: %s (root: %s)", app.working_dir, root))
        } else {
            app_set_message(app, fmt.tprintf("Working dir: %s", app.working_dir))
        }
    } else if cmd[0] >= '0' && cmd[0] <= '9' {
        line, ok := strconv.parse_int(cmd)
        if ok {
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                editor_goto_line(&app.active_pane.editor, line)
                app_set_message(app, fmt.tprintf("Line %d", app.active_pane.editor.cursor.row + 1))
            } else {
                app_set_message(app, "Not an editor buffer")
            }
        } else {
            app_set_message(app, fmt.tprintf("Unknown command: :%s", cmd))
        }
    } else if strings.has_prefix(cmd, "goto ") || strings.has_prefix(cmd, "line ") || cmd == "goto" || cmd == "line" {
        arg := ""
        if strings.has_prefix(cmd, "goto ") do arg = strings.trim_space(cmd[5:])
        else if strings.has_prefix(cmd, "line ") do arg = strings.trim_space(cmd[5:])
        line, ok := strconv.parse_int(arg)
        if ok && line > 0 {
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                editor_goto_line(&app.active_pane.editor, line)
                app_set_message(app, fmt.tprintf("Line %d", app.active_pane.editor.cursor.row + 1))
            } else {
                app_set_message(app, "Not an editor buffer")
            }
        } else {
            app_set_message(app, "Usage: :goto <line>")
        }
    } else if cmd == "help" || cmd == "h" || cmd == "?" {
        app_open_help(app)
    } else if cmd == "files" || cmd == "find" || cmd == "picker" {
        file_picker_open(&app.file_picker, app_picker_root(app), app.window)
    } else if cmd == "zoom" || cmd == "scale" {
        app_set_message(app, fmt.tprintf(
            "Zoom: %.0f%% (usage: :zoom <0.5 .. 2.5>)",
            global_ui_scale * 100.0,
        ))
    } else if strings.has_prefix(cmd, "zoom ") || strings.has_prefix(cmd, "scale ") {
        val_str := strings.trim_space(cmd[5:] if strings.has_prefix(cmd, "zoom ") else cmd[6:])
        scale_val, ok := strconv.parse_f32(val_str)
        if ok && scale_val >= 0.5 && scale_val <= 2.5 {
            global_ui_scale = scale_val
            app_reload_font(app)
            app_set_message(app, fmt.tprintf("UI Scale: %.2f", global_ui_scale))
        } else {
            app_set_message(app, "Usage: :zoom <0.5 .. 2.5>")
        }
    } else if strings.has_prefix(cmd, "linespace ") || strings.has_prefix(cmd, "lineheight ") {
        val_str := strings.trim_space(cmd[10:] if strings.has_prefix(cmd, "linespace ") else cmd[11:])
        spacing_val, ok := strconv.parse_f32(val_str)
        if ok && spacing_val >= 1.0 && spacing_val <= 2.0 {
            line_spacing = spacing_val
            app_set_message(app, fmt.tprintf("Line spacing: %.2f", line_spacing))
        } else {
            app_set_message(app, "Usage: :linespace <1.0 .. 2.0>")
        }
    } else if cmd == "linespace" || cmd == "lineheight" {
        app_set_message(app, fmt.tprintf("Line spacing: %.2f (usage: :linespace <1.0 .. 2.0>)", line_spacing))
    } else {
        app_set_message(app, fmt.tprintf("Unknown command: :%s", cmd))
    }
}

// Directory implied by "here": the Dired listing, the current file's
// directory, or the working directory for scratch/help buffers.
app_here_directory :: proc(app: ^App) -> string {
    if app == nil || app.active_pane == nil do return ""
    p := app.active_pane
    if p.kind == .Dired {
        return p.dired.path
    }
    if p.kind == .Editor && p.editor.buffer.file_path != "" && !strings.has_prefix(p.editor.buffer.file_path, "*") {
        dir := filepath.dir(p.editor.buffer.file_path)
        if dir != "" && dir != "." do return dir
    }
    return app.working_dir
}

// Expand a leading ~ or ~/ using $HOME. Returns the trimmed input otherwise.
expand_home_path :: proc(path: string) -> string {
    trimmed := strings.trim_space(path)
    if trimmed != "~" && !strings.has_prefix(trimmed, "~/") {
        return trimmed
    }

    home := os.get_env("HOME", context.temp_allocator)
    if home == "" do return trimmed
    if trimmed == "~" do return home

    joined, err := filepath.join([]string{home, trimmed[2:]}, context.temp_allocator)
    if err != nil do return trimmed
    return joined
}

// Pick the project root used by the file picker at startup:
//   1. DEFAULT_ROOT_DIRECTORY from config.odin, if it names a directory
//   2. the directory given on the command line
//   3. the project containing the file given on the command line
//   4. the process working directory
resolve_startup_root :: proc(cwd: string) -> string {
    if DEFAULT_ROOT_DIRECTORY != "" {
        expanded := expand_home_path(DEFAULT_ROOT_DIRECTORY)
        abs, err := filepath.abs(expanded, context.temp_allocator)
        if err == nil && os.is_dir(abs) {
            return strings.clone(abs, context.allocator)
        }
    }

    if len(os.args) > 1 {
        arg := os.args[1]
        abs, err := filepath.abs(arg, context.temp_allocator)
        if err == nil && os.is_dir(abs) {
            return strings.clone(abs, context.allocator)
        }
        return lsp_find_project_root(arg, cwd)
    }

    return strings.clone(cwd, context.allocator)
}

load :: proc(app: ^App) {
    sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "wayland")

    // HIGH_PIXEL_DENSITY makes the backbuffer match the display scale; without
    // it SDL renders at 1x and the compositor upscales, blurring all text.
    flags := sdl.WINDOW_RESIZABLE | sdl.WINDOW_HIGH_PIXEL_DENSITY
    if !sdl.CreateWindowAndRenderer(WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT, flags, &app.window, &app.renderer) {
        panic("Failed to create SDL window and renderer")
    }

    // Keep drawing in logical (window) coordinates while SDL renders at the
    // display's native pixel density.
    win_w, win_h: i32
    sdl.GetWindowSize(app.window, &win_w, &win_h)
    _ = sdl.SetRenderLogicalPresentation(app.renderer, win_w, win_h, .LETTERBOX)

    app.current_theme_id = DEFAULT_THEME
    app.theme = theme_get(app.current_theme_id)
    app.font_density = sdl.GetWindowPixelDensity(app.window)
    app.font = load_font(app.renderer, app.window)
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

    app.root_dir = resolve_startup_root(app.working_dir)

    file_picker_init(&app.file_picker)

    // Open the project root (or cwd fallback) when no file/dir is given.
    target_path := app_picker_root(app)
    if len(os.args) > 1 {
        target_path = os.args[1]
        // Resolve CLI-relative paths now, while the process cwd is still the
        // launch directory. Later :cd/:root changes must not reinterpret them.
        if !filepath.is_abs(target_path) {
            if abs, err := filepath.abs(target_path, context.temp_allocator); err == nil {
                target_path = abs
            } else if launch_cwd, err_cwd := os.get_working_directory(context.temp_allocator); err_cwd == nil {
                if joined, join_err := filepath.join([]string{launch_cwd, target_path}, context.temp_allocator); join_err == nil {
                    target_path = joined
                }
            }
        }
    }

    initial_pane: ^Pane
    if os.is_dir(target_path) {
        initial_pane = pane_create(app, .Dired)
        dired_request_load(&initial_pane.dired, target_path, .Name, .Asc)
    } else {
        initial_pane = pane_create(app, .Editor)
        data, err := os.read_entire_file(target_path, context.allocator)
        initial_text := ""
        if err == nil && data != nil {
            initial_text = string(data)
        }
        editor_destroy(&initial_pane.editor)
        editor_init(&initial_pane.editor, &app.font, initial_text, target_path)
        // A failed read may still return a partial allocated buffer.
        if data != nil do delete(data)
    }

    // Initialize LSP manager with the project scope, not the launch cwd.
    lsp_manager_init(&app.lsp_manager, app_picker_root(app))

    app.active_pane = initial_pane
    app.root_split = split_create_leaf(initial_pane)
    app.running = true

    if initial_pane.kind == .Editor && initial_pane.editor.buffer.file_path != "" {
        full_text := pt_full_text(&initial_pane.editor.buffer.table)
        defer delete(full_text)
        app_lsp_doc_open(app, &initial_pane.editor, full_text)
    }
}

update :: proc(app: ^App) {
    // Moving between displays with different scale factors changes the pixel
    // density; re-bake so glyphs stay native-resolution.
    density := sdl.GetWindowPixelDensity(app.window)
    if density > 0 && abs(density - app.font_density) > 0.01 {
        app.font_density = density
        app_reload_font(app)
    }

    // Collect finished background builds and picker scans. Poll every pane:
    // a compilation pane can be repurposed to an editor while its build runs.
    for p in app.panes {
        compilation_poll(&p.compilation)
        dired_poll(&p.dired)
    }
    compilation_poll_orphans()
    dired_poll_orphans()
    file_picker_poll(&app.file_picker)
    lsp_manager_poll(&app.lsp_manager)
    if app.lsp_manager.last_message != "" {
        app_set_message(app, app.lsp_manager.last_message)
        delete(app.lsp_manager.last_message)
        app.lsp_manager.last_message = ""
    }

    event: sdl.Event
    for sdl.PollEvent(&event) {
        if event.type == .QUIT {
            if app_has_unsaved_changes(app) {
                app_set_message(app, "E37: No write since last change (use :qa! to force quit)")
            } else {
                app.running = false
            }
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
                        // Remove the rest of a UTF-8 codepoint.
                        for len(app.cmd_prompt.buffer) > 0 &&
                            (app.cmd_prompt.buffer[len(app.cmd_prompt.buffer) - 1] & 0xC0) == 0x80 {
                            pop(&app.cmd_prompt.buffer)
                        }
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
            if is_ctrl && (key == KEY_ZOOM_IN || key == KEY_ZOOM_IN_ALT) {
                global_ui_scale = min(2.5, global_ui_scale + 0.1)
                app_reload_font(app)
                app_set_message(app, fmt.tprintf("Zoom: %.0f%%", global_ui_scale * 100.0))
                continue
            }
            if is_ctrl && (key == KEY_ZOOM_OUT || key == KEY_ZOOM_OUT_ALT) {
                global_ui_scale = max(0.5, global_ui_scale - 0.1)
                app_reload_font(app)
                app_set_message(app, fmt.tprintf("Zoom: %.0f%%", global_ui_scale * 100.0))
                continue
            }
            if is_ctrl && (key == KEY_ZOOM_RESET || key == KEY_ZOOM_RESET_ALT) {
                global_ui_scale = DEFAULT_UI_SCALE
                app_reload_font(app)
                app_set_message(app, fmt.tprintf("Zoom reset (%.0f%%)", global_ui_scale * 100.0))
                continue
            }

            // Handle pending leader key (Space)
            if app.pending_leader {
                app.pending_leader = false
                app.cmd_prompt.message = ""
                if key == KEY_LEADER_FILES {
                    file_picker_open(&app.file_picker, app_picker_root(app), app.window)
                    continue
                }
            }

            // Clear any transient message on new keypress
            app.cmd_prompt.message = ""

            // Handle pending Ctrl+w split navigation prefix
            if app.pending_w_cmd {
                app.pending_w_cmd = false
                if key == KEY_WINDOW_LEFT {
                    app_focus_dir(app, .Left)
                } else if key == KEY_WINDOW_DOWN {
                    app_focus_dir(app, .Down)
                } else if key == KEY_WINDOW_UP {
                    app_focus_dir(app, .Up)
                } else if key == KEY_WINDOW_RIGHT {
                    app_focus_dir(app, .Right)
                } else if key == KEY_WINDOW_SPLIT_H {
                    app_split_pane(app, app.active_pane, .Horizontal)
                } else if key == KEY_WINDOW_SPLIT_V {
                    app_split_pane(app, app.active_pane, .Vertical)
                } else if key == KEY_WINDOW_CYCLE {
                    app_cycle_pane(app)
                } else if key == KEY_WINDOW_CLOSE || key == KEY_WINDOW_CLOSE_ALT {
                    app_close_current_pane(app, false)
                }
                continue
            }

            // Check for Ctrl+w initiation (when not in Insert mode)
            if !is_insert && is_ctrl && key == KEY_WINDOW_PREFIX {
                app.pending_w_cmd = true
                continue
            }

            // Trigger leader key on Space when not in Insert mode
            if !is_insert && !is_ctrl && !is_alt && key == KEY_LEADER {
                app.pending_leader = true
                app_set_message(app, fmt.tprintf(
                    "Leader: <%s> (%s: file picker)",
                    key_label(KEY_LEADER, {}, .Plain),
                    key_label(KEY_LEADER_FILES, {}, .Plain),
                ))
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
    for client in app.lsp_manager.clients {
        if client != nil && lsp_is_running(client) {
            lsp_update(client, app)
        }
    }

    active_lsp := app_get_active_lsp(app)
    if active_lsp != nil {
        // Handle completions transfer to active editor
        if len(active_lsp.completions) > 0 {
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                e := &app.active_pane.editor
                file_matches := active_lsp.completions_file == "" || paths_match(e.buffer.file_path, active_lsp.completions_file)
                if file_matches && e.mode == .Insert {
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
            if active_lsp.completions_file != "" {
                delete(active_lsp.completions_file)
                active_lsp.completions_file = ""
            }
        }

        // Handle Go to Definition result
        if loc, ok := active_lsp.last_definition.?; ok {
            active_lsp.last_definition = nil
            defer if loc.file_path != "" do delete(loc.file_path)
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                cur_abs, _ := filepath.abs(app.active_pane.editor.buffer.file_path, context.temp_allocator)
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
            show_hover := true
            if app.active_pane != nil && app.active_pane.kind == .Editor && active_lsp.last_hover_file != "" {
                show_hover = paths_match(app.active_pane.editor.buffer.file_path, active_lsp.last_hover_file)
            }
            if show_hover {
                display_line := lsp_hover_one_line(active_lsp.last_hover)
                if display_line == "" do display_line = strings.trim_space(active_lsp.last_hover)
                app_set_message(app, fmt.tprintf("Hover: %s", display_line))
            }
            delete(active_lsp.last_hover)
            active_lsp.last_hover = ""
            if active_lsp.last_hover_file != "" {
                delete(active_lsp.last_hover_file)
                active_lsp.last_hover_file = ""
            }
        }

        // Handle Range Formatting edits
        if len(active_lsp.last_edits) > 0 {
            if app.active_pane != nil && app.active_pane.kind == .Editor {
                e := &app.active_pane.editor
                file_matches := active_lsp.last_edits_file == "" || paths_match(e.buffer.file_path, active_lsp.last_edits_file)
                if file_matches {
                    editor_apply_lsp_edits(e, active_lsp.last_edits[:])
                    app_set_message(app, fmt.tprintf("LSP: Formatted range (%d edits)", len(active_lsp.last_edits)))
                }
            }
            for ed in active_lsp.last_edits do delete(ed.new_text)
            clear(&active_lsp.last_edits)
            if active_lsp.last_edits_file != "" {
                delete(active_lsp.last_edits_file)
                active_lsp.last_edits_file = ""
            }
        }
    }

    // Debounced LSP textDocument/didChange across open editor panes
    for pane in app.panes {
        if pane != nil && pane.kind == .Editor {
            e := &pane.editor
            if e.buffer.needs_lsp_sync && time.since(e.buffer.last_edit_time) > 250 * time.Millisecond {
                e.buffer.needs_lsp_sync = false
                if e.buffer.file_path != "" {
                    full_text := pt_full_text(&e.buffer.table)
                    defer delete(full_text)
                    app_lsp_doc_change(app, e.buffer.file_path, full_text)
                }
            }
        }
    }
}

draw :: proc(app: ^App) {
    w, h: i32
    sdl.GetWindowSize(app.window, &w, &h)
    _ = sdl.SetRenderLogicalPresentation(app.renderer, w, h, .LETTERBOX)

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
            editor_sync_view(&p.editor)
            editor_render(&p.editor, app.renderer, &app.font, p.rect, is_focused, &app.theme, app_get_lsp_for_file(app, p.editor.buffer.file_path))
        case .Dired:
            if p.dired.is_editing {
                editor_sync_view(&p.editor)
                editor_render(&p.editor, app.renderer, &app.font, p.rect, is_focused, &app.theme, app_get_lsp_for_file(app, p.editor.buffer.file_path))
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
        pane_hint := fmt.tprintf(
            "%s (%s: split, %s: vsplit, %s/%s/%s/%s: move, %s: cycle, %s: close)",
            key_label(KEY_WINDOW_PREFIX, sdl.KMOD_CTRL, .Plain),
            key_label(KEY_WINDOW_SPLIT_H, {}, .Plain),
            key_label(KEY_WINDOW_SPLIT_V, {}, .Plain),
            key_label(KEY_WINDOW_LEFT, {}, .Plain),
            key_label(KEY_WINDOW_DOWN, {}, .Plain),
            key_label(KEY_WINDOW_UP, {}, .Plain),
            key_label(KEY_WINDOW_RIGHT, {}, .Plain),
            key_label(KEY_WINDOW_CYCLE, {}, .Plain),
            key_label(KEY_WINDOW_CLOSE, {}, .Plain),
        )
        push_line(
           &app.font,
           pane_hint,
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
    if app.root_dir != "" {
        delete(app.root_dir)
        app.root_dir = ""
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

    font_destroy(&app.font)
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
