package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

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

    line_spacing = 1.0
    fmt.println("  ✓ [App] :linespace adjusts and validates line-height multiplier")
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

    help_text := pt_full_text(&help_pane.editor.table)
    defer delete(help_text)
    testing.expect_value(t, help_text, HELP_TEXT)
    testing.expect(t, strings.contains(help_text, "Odin Text Editor - Help"))
    testing.expect(t, strings.contains(help_text, "Ctrl+Space"))
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
    testing.expect_value(t, pt_get_length(&help_pane.editor.table), len(HELP_TEXT))
    testing.expect_value(t, help_pane.editor.status_message, "Buffer is read-only")
    editor_set_mode(&help_pane.editor, .Normal, nil)

    // Navigation remains available
    help_pane.editor.cursor.row = 0
    send_key_event(&help_pane.editor, sdl.K_J)
    testing.expect_value(t, help_pane.editor.cursor.row, 1)

    // Destructive normal-mode keys are rejected
    send_key_event(&help_pane.editor, sdl.K_D)
    testing.expect_value(t, pt_get_length(&help_pane.editor.table), len(HELP_TEXT))
    testing.expect_value(t, help_pane.editor.status_message, "Buffer is read-only")

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
