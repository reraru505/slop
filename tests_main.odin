package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

free_path_matches :: proc(matches: ^[dynamic]string) {
    for m in matches^ do delete(m)
    clear(matches)
}

set_command_buffer :: proc(app: ^App, command: string) {
    clear(&app.cmd_prompt.buffer)
    for b in transmute([]u8)command {
        append(&app.cmd_prompt.buffer, b)
    }
}

@(test)
test_app_message_truncation :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    long_msg := strings.repeat("y", 600, context.temp_allocator)
    app_set_message(&app, long_msg)
    testing.expect_value(t, len(app.cmd_prompt.message), 512)

    app_set_message(&app, "short")
    testing.expect_value(t, app.cmd_prompt.message, "short")
    fmt.println("  ✓ [App] command-bar messages truncate at buffer size")
}

@(test)
test_app_command_prompt_completion :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    // Base command completion: prefix "c"
    set_command_buffer(&app, "c")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, app.cmd_prompt.in_completion, true)
    testing.expect_value(t, len(app.cmd_prompt.matches), 9)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "compile")

    // Reverse from the first match wraps to the last
    app_reset_command_completion(&app.cmd_prompt)
    set_command_buffer(&app, "c")
    app_command_prompt_tab(&app, false)
    app_command_prompt_tab(&app, true)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "cd")

    // No matches leaves the buffer untouched and completion inactive
    app_reset_command_completion(&app.cmd_prompt)
    set_command_buffer(&app, "zzz")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, app.cmd_prompt.in_completion, false)
    testing.expect_value(t, len(app.cmd_prompt.matches), 0)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "zzz")

    // Subcommand completion for themes
    app_reset_command_completion(&app.cmd_prompt)
    set_command_buffer(&app, "theme ")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, app.cmd_prompt.in_completion, true)
    testing.expect_value(t, len(app.cmd_prompt.matches), 4)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "theme gruber-darker")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "theme naysayer")

    // Subcommand completion for sort
    app_reset_command_completion(&app.cmd_prompt)
    set_command_buffer(&app, "sort rev")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, len(app.cmd_prompt.matches), 2)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "sort rev")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "sort reverse")
    fmt.println("  ✓ [App] command-name and subcommand Tab completion verified")
}

@(test)
test_app_theme_commands :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    app_execute_command(&app, "theme naysayer")
    testing.expect_value(t, app.current_theme_id, ThemeId.Naysayer)
    testing.expect_value(t, app.theme.id, ThemeId.Naysayer)
    testing.expect_value(t, app.cmd_prompt.message, "Theme: naysayer")

    // Bare ":theme" cycles to the next theme
    app_execute_command(&app, "theme")
    testing.expect_value(t, app.current_theme_id, ThemeId.Kanagawa)
    testing.expect_value(t, app.cmd_prompt.message, "Theme: kanagawa")

    app_execute_command(&app, "colorscheme hemisu")
    testing.expect_value(t, app.current_theme_id, ThemeId.Hemisu)
    testing.expect_value(t, app.theme.name, "hemisu")

    app_execute_command(&app, "theme solarized")
    testing.expect_value(t, app.current_theme_id, ThemeId.Hemisu) // unchanged
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "Unknown theme: solarized"))
    fmt.println("  ✓ [App] :theme/:colorscheme switching and cycling verified")
}

@(test)
test_compile_path_command_collection :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/compile_path"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    exec_mode := os.Permissions_Read_All + os.Permissions{.Execute_User}
    names := []string{"cargofake", "cargo-other", "cargo-noexec"}
    for name in names {
        path := fmt.tprintf("%s/%s", dir, name)
        testing.expect(t, os.write_entire_file_from_string(path, "") == nil)
    }
    testing.expect(t, os.chmod(fmt.tprintf("%s/cargofake", dir), exec_mode) == nil)
    testing.expect(t, os.chmod(fmt.tprintf("%s/cargo-other", dir), exec_mode) == nil)

    matches: [dynamic]string
    defer {
        for m in matches do delete(m)
        delete(matches)
    }

    collect_path_commands(dir, "cargo", "compile", &matches, 100)
    testing.expect_value(t, len(matches), 2)
    testing.expect_value(t, completion_has(&matches, "compile cargofake"), true)
    testing.expect_value(t, completion_has(&matches, "compile cargo-other"), true)
    testing.expect_value(t, completion_has(&matches, "compile cargo-noexec"), false)

    // The limit is honored.
    free_path_matches(&matches)
    collect_path_commands(dir, "cargo", "compile", &matches, 1)
    testing.expect_value(t, len(matches), 1)
    fmt.println("  ✓ [App] PATH command completion finds executables only")
}

@(test)
test_compile_path_token_completion :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/compile_files"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/main.c", dir), "") == nil)
    testing.expect(t, os.make_directory(fmt.tprintf("%s/sub", dir)) == nil)

    matches: [dynamic]string
    defer {
        for m in matches do delete(m)
        delete(matches)
    }

    complete_path_token("compile", "", fmt.tprintf("%s/ma", dir), &matches)
    testing.expect_value(t, len(matches), 1)
    testing.expect_value(t, matches[0], fmt.tprintf("compile %s/main.c", dir))

    free_path_matches(&matches)
    complete_path_token("compile", "gcc -O2 ", fmt.tprintf("%s/su", dir), &matches)
    testing.expect_value(t, len(matches), 1)
    testing.expect_value(t, matches[0], fmt.tprintf("compile gcc -O2 %s/sub/", dir))

    // Relative tokens complete against the supplied project root.
    free_path_matches(&matches)
    complete_path_token("compile", "", "ma", &matches, dir)
    testing.expect_value(t, len(matches), 1)
    testing.expect_value(t, matches[0], "compile main.c")

    free_path_matches(&matches)
    complete_path_token("compile", "", "su", &matches, dir)
    testing.expect_value(t, len(matches), 1)
    testing.expect_value(t, matches[0], "compile sub/")

    // A root component at "/" must search the filesystem root.
    free_path_matches(&matches)
    complete_path_token("compile", "", "/us", &matches, dir)
    testing.expect(t, len(matches) > 0)
    if len(matches) > 0 {
        testing.expect(t, strings.has_prefix(matches[0], "compile /usr"), matches[0])
    }
    fmt.println("  ✓ [App] compile arguments complete as project-relative paths")
}

@(test)
test_app_dirty_quit_guard :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    app.running = true
    app.active_pane.editor.dirty = true

    app_execute_command(&app, "q")
    testing.expect_value(t, len(app.panes), 1)
    testing.expect_value(t, app.running, true)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "E37"))

    // Force-close the last pane; the app asks to quit.
    app_execute_command(&app, "q!")
    testing.expect_value(t, app.running, false)

    // :qa refuses while another buffer is dirty; :qa! forces it.
    app.running = true
    app.active_pane.editor.dirty = true
    app_execute_command(&app, "qa")
    testing.expect_value(t, app.running, true)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "E37"))
    app_execute_command(&app, "qa!")
    testing.expect_value(t, app.running, false)

    // :wq on an unnamed buffer does not close it.
    app.running = true
    app.active_pane.editor.dirty = true
    app_execute_command(&app, "wq")
    testing.expect_value(t, len(app.panes), 1)
    testing.expect_value(t, app.running, true)
    testing.expect_value(t, app.cmd_prompt.message, "E32: No file name")
    fmt.println("  ✓ [App] dirty-buffer guards for :q / :q! / :qa / :qa! / :wq")
}

@(test)
test_app_goto_line_command :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    set_editor_text(&app.active_pane.editor, "zero\none\ntwo\nthree\nfour")

    app_execute_command(&app, "3")
    testing.expect_value(t, app.active_pane.editor.cursor.row, 2)
    testing.expect_value(t, app.cmd_prompt.message, "Line 3")

    app_execute_command(&app, "goto 5")
    testing.expect_value(t, app.active_pane.editor.cursor.row, 4)
    testing.expect_value(t, app.cmd_prompt.message, "Line 5")

    // Out-of-range lines clamp to the last line.
    app_execute_command(&app, "999")
    testing.expect_value(t, app.active_pane.editor.cursor.row, 4)

    app_execute_command(&app, "goto nope")
    testing.expect_value(t, app.cmd_prompt.message, "Usage: :goto <line>")
    fmt.println("  ✓ [App] :<n> and :goto <n> jump with clamping")
}

@(test)
test_app_linespace_command :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    old_spacing := line_spacing
    defer line_spacing = old_spacing

    app_execute_command(&app, "linespace 1.25")
    testing.expect_value(t, line_spacing, 1.25)
    testing.expect_value(t, app.cmd_prompt.message, "Line spacing: 1.25")

    // Out-of-range values are rejected and leave the setting unchanged
    app_execute_command(&app, "lineheight 0.5")
    testing.expect_value(t, line_spacing, 1.25)
    testing.expect_value(t, app.cmd_prompt.message, "Usage: :linespace <1.0 .. 2.0>")

    // Querying without an argument reports the current value
    app_execute_command(&app, "lineheight")
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "Line spacing: 1.25"))

    line_spacing = DEFAULT_LINE_SPACING
    fmt.println("  ✓ [App] :linespace adjusts and validates line-height multiplier")
}

@(test)
test_help_template_tokens_render :: proc(t: ^testing.T) {
    rendered := help_render(context.allocator)
    defer delete(rendered)

    // Empty braces and a lone opening brace in prose must survive untouched.
    testing.expect(t, strings.contains(rendered, "() [] {}"))
    testing.expect(t, strings.contains(rendered, "( [ { ' \""))

    // Every non-empty token in the template must resolve.
    template := HELP_TEMPLATE
    for i := 0; i < len(template); i += 1 {
        if template[i] != '{' do continue
        j := i + 1
        for j < len(template) && is_help_token_char(template[j]) do j += 1
        if j > i + 1 && j < len(template) && template[j] == '}' {
            name := template[i + 1:j]
            _, known := help_token_value(name)
            testing.expectf(t, known, "unresolved help token {%s}", name)
            i = j
        }
    }

    // The title follows the configured editor name.
    help_title := fmt.tprintf("%s - Help", EDITOR_NAME)
    testing.expect(t, strings.contains(rendered, help_title))
    underline := strings.repeat("=", len(help_title), context.temp_allocator)
    testing.expect(t, strings.contains(rendered, underline))

    // Labels are derived from config constants rather than hardcoded text.
    completion_label := key_label(KEY_COMPLETION_TRIGGER, sdl.KMOD_CTRL, .Plain)
    testing.expect(t, strings.contains(rendered, completion_label))
    testing.expect(t, strings.contains(rendered, key_label(KEY_LINE_END_DOLLAR, sdl.KMOD_SHIFT, .Shift_Symbol)))
    testing.expect(t, strings.contains(rendered, help_line_spacing_label()))

    split_h, has_split_h := help_token_value("split_h")
    testing.expect_value(t, has_split_h, true)
    testing.expect(t, strings.contains(rendered, split_h))

    gg, has_gg := help_token_value("gg")
    testing.expect_value(t, has_gg, true)
    testing.expect(t, strings.contains(rendered, gg))

    copy_line, has_copy := help_token_value("compile_yank")
    testing.expect_value(t, has_copy, true)
    testing.expect(t, strings.contains(rendered, copy_line))
    copy_all, has_copy_all := help_token_value("compile_yank_all")
    testing.expect_value(t, has_copy_all, true)
    testing.expect(t, strings.contains(rendered, copy_all))

    // No known placeholder should leak verbatim into the rendered text.
    testing.expect(t, !strings.contains(rendered, "{completion_trigger}"))
    testing.expect(t, !strings.contains(rendered, "{split_h}"))
    testing.expect(t, !strings.contains(rendered, "{compile_yank}"))
    fmt.println("  ✓ [Help] template tokens resolve from configuration")
}

@(test)
test_app_misc_commands :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    app_execute_command(&app, "pwd")
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "Working dir:"), app.cmd_prompt.message)

    app_execute_command(&app, "sort")
    testing.expect_value(t, app.cmd_prompt.message, "Not in a Dired buffer")

    app_execute_command(&app, "w")
    testing.expect_value(t, app.cmd_prompt.message, "E32: No file name")

    app_execute_command(&app, "definitely_not_a_command")
    testing.expect_value(t, app.cmd_prompt.message, "Unknown command: :definitely_not_a_command")

    // Empty commands are ignored and do not overwrite the previous message
    app_execute_command(&app, "   ")
    testing.expect_value(t, app.cmd_prompt.message, "Unknown command: :definitely_not_a_command")

    // :q on the final pane requests shutdown
    app.running = true
    app_execute_command(&app, "q")
    testing.expect_value(t, app.running, false)
    testing.expect_value(t, len(app.panes), 1)
    fmt.println("  ✓ [App] :pwd/:sort/:w/unknown/:q dispatch verified")
}

@(test)
test_app_open_file_and_dired :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/app_open"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    file_path := "/tmp/odin_editor_tests/app_open/sample.txt"
    testing.expect(t, os.write_entire_file_from_string(file_path, "file contents") == nil)

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane

    app_pane_open_file(&app, pane, file_path)
    testing.expect_value(t, pane.kind, PaneKind.Editor)
    testing.expect_value(t, pane.editor.file_path, file_path)
    testing.expect_value(t, app.active_pane, pane)
    text := pt_full_text(&pane.editor.table)
    testing.expect_value(t, text, "file contents")
    delete(text)

    // Opening a nonexistent file yields an empty buffer with that path
    missing := "/tmp/odin_editor_tests/app_open/missing.txt"
    app_pane_open_file(&app, pane, missing)
    testing.expect_value(t, pane.editor.file_path, missing)
    testing.expect_value(t, pt_get_length(&pane.editor.table), 0)

    // Opening a directory switches the pane to Dired
    app_pane_open_dired(&app, pane, dir)
    testing.expect_value(t, pane.kind, PaneKind.Dired)
    testing.expect_value(t, pane.dired.path, dir)
    testing.expect_value(t, app.active_pane, pane)

    // LSP lookup is only available for editor files
    app_pane_open_file(&app, pane, file_path)
    testing.expect(t, app_get_active_lsp(&app) == nil) // no file_path set on LSP manager/client
    app_pane_open_dired(&app, pane, dir)
    testing.expect(t, app_get_active_lsp(&app) == nil)
    fmt.println("  ✓ [App] file/dired pane opening and LSP lookup guards verified")
}

@(test)
test_app_help_command :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    app_execute_command(&app, "help")
    testing.expect_value(t, len(app.panes), 2)
    help_pane := app.active_pane
    testing.expect(t, help_pane != app.panes[0])
    testing.expect_value(t, help_pane.kind, PaneKind.Editor)
    testing.expect_value(t, help_pane.editor.file_path, HELP_FILE_PATH)
    testing.expect_value(t, help_pane.editor.read_only, true)
    testing.expect_value(t, help_pane.editor.dirty, false)

    want := help_render(context.allocator)
    defer delete(want)
    help_text := pt_full_text(&help_pane.editor.table)
    defer delete(help_text)
    testing.expect_value(t, help_text, want)
    help_title := fmt.tprintf("%s - Help", EDITOR_NAME)
    testing.expect(t, strings.contains(help_text, help_title))
    completion_label := key_label(KEY_COMPLETION_TRIGGER, sdl.KMOD_CTRL, .Plain)
    testing.expect(t, strings.contains(help_text, completion_label))
    testing.expect(t, strings.contains(help_text, "wdired"))

    // Repeating :help (or an alias) focuses the existing buffer
    app_execute_command(&app, "help")
    testing.expect_value(t, len(app.panes), 2)
    testing.expect_value(t, app.active_pane, help_pane)
    app_execute_command(&app, "h")
    testing.expect_value(t, len(app.panes), 2)
    app_execute_command(&app, "?")
    testing.expect_value(t, len(app.panes), 2)

    // Typing is ignored even if Insert mode is forced on the buffer
    editor_set_mode(&help_pane.editor, .Insert, nil)
    simulate_typing(&help_pane.editor, "x")
    testing.expect_value(t, pt_get_length(&help_pane.editor.table), len(want))
    testing.expect_value(t, help_pane.editor.status_message, "Buffer is read-only")
    editor_set_mode(&help_pane.editor, .Normal, nil)

    // Navigation remains available
    help_pane.editor.cursor.row = 0
    send_key_event(&help_pane.editor, KEY_MOVE_DOWN)
    testing.expect_value(t, help_pane.editor.cursor.row, 1)

    // Destructive normal-mode keys are rejected
    send_key_event(&help_pane.editor, KEY_DELETE_CHAR)
    testing.expect_value(t, pt_get_length(&help_pane.editor.table), len(want))
    testing.expect_value(t, help_pane.editor.status_message, "Buffer is read-only")

    // :w must not create a file for a read-only buffer (or close it via :wq)
    app_execute_command(&app, "w")
    testing.expect_value(t, app.cmd_prompt.message, "Buffer is read-only")
    testing.expect_value(t, len(app.panes), 2)

    // Closing the help pane restores the original pane
    app_execute_command(&app, "q")
    testing.expect_value(t, len(app.panes), 1)

    // "help" participates in command completion
    set_command_buffer(&app, "hel")
    app_command_prompt_tab(&app, false)
    testing.expect_value(t, string(app.cmd_prompt.buffer[:]), "help")
    app_reset_command_completion(&app.cmd_prompt)
    fmt.println("  ✓ [App] :help opens a read-only cheat sheet in a split")
}

@(test)
test_app_open_completion_doc_split :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)
    orig := app.active_pane

    append(&orig.editor.completion.items, LspCompletionItem{
        label         = strings.clone("foo"),
        detail        = strings.clone("fn foo()"),
        documentation = strings.clone("Documentation here"),
        insert_text   = strings.clone("foo"),
    })
    orig.editor.completion.selected = 0
    orig.editor.completion.active = true

    editor_open_completion_doc(&orig.editor, &app)
    testing.expect_value(t, len(app.panes), 2)
    doc_pane := app.active_pane
    testing.expect(t, doc_pane != orig)
    testing.expect_value(t, doc_pane.kind, PaneKind.Editor)
    testing.expect_value(t, doc_pane.editor.file_path, "*doc: foo*")
    testing.expect_value(t, doc_pane.editor.read_only, true)

    doc_text := pt_full_text(&doc_pane.editor.table)
    defer delete(doc_text)
    testing.expect(t, strings.contains(doc_text, "// Symbol: foo"))
    testing.expect(t, strings.contains(doc_text, "// Detail: fn foo()"))
    testing.expect(t, strings.contains(doc_text, "Documentation here"))
    testing.expect_value(t, orig.editor.completion.active, false)
    fmt.println("  ✓ [App] Shift+Enter completion docs open in a vertical split")
}

@(test)
test_app_root_command :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    dir := "/tmp/odin_editor_tests/app_root"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    app_execute_command(&app, fmt.tprintf("root %s", dir))
    testing.expect_value(t, app.root_dir, dir)
    testing.expect_value(t, app.working_dir, dir)
    testing.expect_value(t, app.lsp_manager.working_dir, dir)
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "Project root:"))
    testing.expect_value(t, app_picker_root(&app), dir)
    testing.expect_value(t, app_resolve_path(&app, "src/main.odin"), fmt.tprintf("%s/src/main.odin", dir))

    app_execute_command(&app, "root")
    testing.expect(t, strings.contains(app.cmd_prompt.message, dir))

    app_execute_command(&app, "root /definitely/not/a/dir")
    testing.expect_value(t, app.root_dir, dir)
    testing.expect(t, strings.has_prefix(app.cmd_prompt.message, "Invalid directory"))
    fmt.println("  ✓ [App] :root sets and reports the file-picker project root")
}

@(test)
test_app_root_here_from_dired :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/app_root_here"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    app := make_test_app()
    defer destroy_test_app(&app)

    pane := app.active_pane
    pane.kind = .Dired
    pane.dired.path = strings.clone(dir, context.allocator)

    app_execute_command(&app, "root here")
    testing.expect_value(t, app.root_dir, dir)
    testing.expect(t, strings.contains(app.cmd_prompt.message, dir))
    fmt.println("  ✓ [App] :root here adopts the current Dired directory")
}

@(test)
test_app_recompile_self_alias :: proc(t: ^testing.T) {
    app := make_test_app()
    defer destroy_test_app(&app)

    app.last_compile_cmd = strings.clone("printf 'recompiled\\n'")
    app_run_compile(&app, app.last_compile_cmd)

    comp: ^Pane
    for p in app.panes {
        if p.kind == .Compilation {
            comp = p
            break
        }
    }
    testing.expect(t, comp != nil)
    if comp == nil do return

    compilation_wait(&comp.compilation)
    testing.expect_value(t, comp.compilation.finished, true)
    found := false
    for line in comp.compilation.lines {
        if strings.trim_space(line.text) == "recompiled" do found = true
    }
    testing.expect_value(t, found, true)
    testing.expect_value(t, app.last_compile_cmd, "printf 'recompiled\\n'")
    fmt.println("  ✓ [App] :recompile clones its command before freeing")
}

@(test)
test_app_dired_refuses_dirty_editor :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/dirty_dired"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane
    pane.editor.dirty = true

    app_pane_open_dired(&app, pane, dir)
    testing.expect_value(t, pane.kind, PaneKind.Editor)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "E37"))

    pane.editor.dirty = false
    app_pane_open_dired(&app, pane, dir)
    testing.expect_value(t, pane.kind, PaneKind.Dired)
    fmt.println("  ✓ [App] :dired refuses to hide a modified editor buffer")
}

@(test)
test_app_edit_command_dispatches :: proc(t: ^testing.T) {
    path := "/tmp/odin_editor_tests/edit_command.txt"
    _ = os.remove(path)
    testing.expect(t, os.write_entire_file_from_string(path, "edit me") == nil)
    defer os.remove(path)

    app := make_test_app()
    defer destroy_test_app(&app)

    app_execute_command(&app, fmt.tprintf("edit %s", path))
    testing.expect_value(t, app.active_pane.editor.file_path, path)
    text := pt_full_text(&app.active_pane.editor.table)
    defer delete(text)
    testing.expect_value(t, text, "edit me")
    fmt.println("  ✓ [App] :edit dispatches like :e")
}

@(test)
test_app_open_file_guards_dirty_and_read_only :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/open_guards"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)

    a := fmt.tprintf("%s/a.txt", dir)
    b := fmt.tprintf("%s/b.txt", dir)
    testing.expect(t, os.write_entire_file_from_string(a, "aaa") == nil)
    testing.expect(t, os.write_entire_file_from_string(b, "bbb") == nil)

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane

    // Dirty buffers are not silently replaced.
    set_editor_text(&pane.editor, "unsaved")
    pane.editor.dirty = true
    testing.expect_value(t, app_pane_open_file(&app, pane, b), false)
    testing.expect(t, strings.contains(app.cmd_prompt.message, "E37"))
    text := pt_full_text(&pane.editor.table)
    testing.expect_value(t, text, "unsaved")
    delete(text)

    // Forced :e! replaces it.
    app_execute_command(&app, fmt.tprintf("e! %s", b))
    testing.expect_value(t, pane.editor.file_path, b)
    testing.expect_value(t, pane.editor.dirty, false)

    // Read-only buffers are not replaced, even when clean.
    pane.editor.read_only = true
    testing.expect_value(t, app_pane_open_file(&app, pane, a), false)
    testing.expect_value(t, app.cmd_prompt.message, "Buffer is read-only")

    // Opening a file cancels a stale wdired editing flag.
    pane.editor.read_only = false
    pane.dired.is_editing = true
    testing.expect_value(t, app_pane_open_file(&app, pane, a), true)
    testing.expect_value(t, pane.dired.is_editing, false)
    fmt.println("  ✓ [App] file retargeting guards dirty/read-only and clears wdired")
}
