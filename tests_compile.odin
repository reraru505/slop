package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

destroy_parsed_line :: proc(line: ^CompilationLine) {
    if line.text != "" do delete(line.text)
    if line.file_path != "" do delete(line.file_path)
    line^ = {}
}

@(test)
test_compilation_init_state :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    testing.expect_value(t, c.has_regex, true)
    testing.expect_value(t, c.status, "Idle")
    testing.expect_value(t, c.finished, false)
    testing.expect_value(t, len(c.lines), 0)
    fmt.println("  ✓ [Compilation] initial state and error regex compiled")
}

@(test)
test_compilation_parse_line_formats :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    Case :: struct {
        line:     string,
        want_file: string,
        want_line: int,
        want_col:  int,
        want_err:  bool,
        want_warn: bool,
    }

    cases := []Case{
        // Odin style: path(line:col)
        {"src/main.odin(10:5) Error: bad thing", "src/main.odin", 10, 5, true, false},
        // Odin style without a column
        {"src/main.odin(10) Error: bad thing", "src/main.odin", 10, 1, true, false},
        // GCC/Clang/Rust style: path:line:col
        {"src/main.c:12:3: error: expected ';'", "src/main.c", 12, 3, true, false},
        // GCC/Clang style without a column
        {"src/main.c:12: error: expected ';'", "src/main.c", 12, 1, true, false},
        // Column with no trailing message must still be captured
        {"src/main.c:12:3", "src/main.c", 12, 3, true, false},
        // Warnings set is_warn rather than is_error
        {"src/lib.rs:7:9: warning: unused variable", "src/lib.rs", 7, 9, false, true},
        {"main.odin(2:4) warn: something", "main.odin", 2, 4, false, true},
        {"my file.odin(3:2) Warning: deprecated", "my file.odin", 3, 2, false, true},
        // Absolute paths
        {"/tmp/x.zig:4:11: error: expected type", "/tmp/x.zig", 4, 11, true, false},
        // Non-diagnostic lines pass through untouched
        {"just some text", "", 0, 0, false, false},
        {"", "", 0, 0, false, false},
    }

    for tc in cases {
        got := compilation_parse_line(&c, tc.line)
        testing.expect_value(t, got.text, tc.line)
        testing.expect_value(t, got.file_path, tc.want_file)
        testing.expect_value(t, got.line_num, tc.want_line)
        testing.expect_value(t, got.col_num, tc.want_col)
        testing.expect_value(t, got.is_error, tc.want_err)
        testing.expect_value(t, got.is_warn, tc.want_warn)
        destroy_parsed_line(&got)
    }
    fmt.println("  ✓ [Compilation] Odin/GCC/Clang/Rust diagnostic lines parsed")
}

@(test)
test_compilation_paths_match :: proc(t: ^testing.T) {
    testing.expect_value(t, paths_match("a/b", "a/b"), true)
    testing.expect_value(t, paths_match("./a/b", "a/b"), true)
    testing.expect_value(t, paths_match("a/./b", "a/b"), true)
    testing.expect_value(t, paths_match("/tmp/x/../y", "/tmp/y"), true)
    testing.expect_value(t, paths_match("a/b", "a/c"), false)
    fmt.println("  ✓ [Compilation] paths_match normalizes equivalent paths")
}

@(test)
test_compilation_run_command_success :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    compilation_run_command(&c, "printf 'hello world\\n'")
    compilation_wait(&c)
    testing.expect_value(t, c.finished, true)
    testing.expect_value(t, c.exit_code, 0)
    testing.expect(t, strings.has_prefix(c.status, "Finished"), c.status)
    testing.expect_value(t, c.command, "printf 'hello world\\n'")

    found_output := false
    found_banner := false
    for line in c.lines {
        if strings.trim_space(line.text) == "hello world" do found_output = true
        if strings.contains(line.text, "Compilation started:") do found_banner = true
        testing.expect_value(t, line.is_error, false)
    }
    testing.expect_value(t, found_output, true)
    testing.expect_value(t, found_banner, true)
    fmt.println("  ✓ [Compilation] successful command output captured")
}

@(test)
test_compilation_run_command_is_async :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    compilation_run_command(&c, "sleep 0.5")
    // Returns immediately: the subprocess is still running.
    testing.expect_value(t, c.status, "Running...")
    testing.expect(t, c.job != nil)
    testing.expect_value(t, c.finished, false)

    // A second build cancels the first and replaces it.
    compilation_run_command(&c, "printf 'second\\n'")
    testing.expect_value(t, c.status, "Running...")
    testing.expect(t, c.job != nil)

    compilation_wait(&c)
    testing.expect_value(t, c.finished, true)
    testing.expect_value(t, c.exit_code, 0)
    testing.expect(t, c.job == nil)
    found_second := false
    for line in c.lines {
        if strings.trim_space(line.text) == "second" do found_second = true
    }
    testing.expect_value(t, found_second, true)
    fmt.println("  ✓ [Compilation] commands run off-thread and a new start cancels the old build")
}

@(test)
test_compilation_run_command_failure_parses_errors :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    cmd := "printf 'src/main.odin(3:7) Error: boom\\n' >&2; exit 1"
    compilation_run_command(&c, cmd)
    compilation_wait(&c)

    testing.expect_value(t, c.finished, true)
    testing.expect_value(t, c.exit_code, 1)
    testing.expect(t, strings.contains(c.status, "Exited with code 1"), c.status)

    parsed := 0
    for line in c.lines {
        if line.file_path == "src/main.odin" {
            parsed += 1
            testing.expect_value(t, line.line_num, 3)
            testing.expect_value(t, line.col_num, 7)
            testing.expect_value(t, line.is_error, true)
            testing.expect_value(t, line.is_warn, false)
        }
    }
    testing.expect_value(t, parsed, 1)

    // The synthetic final line marks the abnormal exit as an error
    last := c.lines[len(c.lines) - 1]
    testing.expect_value(t, last.is_error, true)
    fmt.println("  ✓ [Compilation] failing command produces parsed diagnostics")
}

@(test)
test_compilation_dispatch_uses_config_keys :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)
    for i in 0 ..< 3 {
        append(&c.lines, CompilationLine{text = strings.clone(fmt.tprintf("line %d", i))})
    }

    app := make_test_app()
    defer destroy_test_app(&app)
    pane := app.active_pane

    ev: sdl.Event
    ev.type = .KEY_DOWN
    ev.key.key = KEY_COMPILE_DOWN
    ev.key.mod = {}
    testing.expect_value(t, compilation_handle_event(&c, &ev, &app, pane), true)
    testing.expect_value(t, c.cursor, 1)

    ev.key.key = KEY_COMPILE_UP
    testing.expect_value(t, compilation_handle_event(&c, &ev, &app, pane), true)
    testing.expect_value(t, c.cursor, 0)
    fmt.println("  ✓ [Compilation] dispatch follows configured key constants")
}

@(test)
test_compilation_working_directory :: proc(t: ^testing.T) {
    dir := "/tmp/odin_editor_tests/compile_cwd"
    _ = os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil)
    defer os.remove_all(dir)
    testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/marker.txt", dir), "") == nil)

    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    compilation_run_command(&c, "test -f marker.txt && printf 'found\\n'", dir)
    compilation_wait(&c)

    found := false
    banner := false
    for line in c.lines {
        if strings.trim_space(line.text) == "found" do found = true
        if strings.contains(line.text, dir) do banner = true
    }
    testing.expect_value(t, found, true)
    testing.expect_value(t, banner, true)
    fmt.println("  ✓ [Compilation] commands run in the configured working directory")
}

@(test)
test_compilation_copy_text :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    lines := []string{"alpha", "beta", "gamma"}
    for text in lines {
        append(&c.lines, CompilationLine{text = strings.clone(text)})
    }

    c.cursor = 1
    testing.expect_value(t, compilation_copy_text(&c, false), "beta")
    testing.expect_value(t, compilation_copy_text(&c, true), "alpha\nbeta\ngamma")

    c.cursor = 99
    testing.expect_value(t, compilation_copy_text(&c, false), "")
    fmt.println("  ✓ [Compilation] current-line and whole-buffer copy text")
}

@(test)
test_compilation_jump_resolves_paths_against_root :: proc(t: ^testing.T) {
    root := "/tmp/odin_editor_tests/compile_jump_root"
    _ = os.remove_all(root)
    testing.expect(t, os.make_directory_all(fmt.tprintf("%s/src", root)) == nil)
    defer os.remove_all(root)

    target := fmt.tprintf("%s/src/main.txt", root)
    testing.expect(t, os.write_entire_file_from_string(target, "line one\nline two\n") == nil)

    app := make_test_app()
    defer destroy_test_app(&app)
    // The jump must use the build directory, not the current project root.
    app.root_dir = strings.clone(fmt.tprintf("%s/wrong_root", root), context.allocator)

    comp_pane := app.active_pane
    app_split_pane(&app, comp_pane, .Horizontal)
    comp_pane.kind = .Compilation
    editor_pane := app.panes[1]

    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)
    c.working_dir = strings.clone(root, context.allocator)
    append(&c.lines, CompilationLine{
        text = strings.clone(""),
        file_path = strings.clone("src/main.txt"),
        line_num = 2,
        col_num = 3,
    })

    compilation_jump_to_current(&c, &app, comp_pane)

    testing.expect_value(t, editor_pane.editor.file_path, target)
    testing.expect_value(t, editor_pane.editor.cursor.row, 1)
    testing.expect_value(t, editor_pane.editor.cursor.col, 2)
    testing.expect_value(t, app.active_pane, editor_pane)
    fmt.println("  ✓ [Compilation] jumps resolve relative compiler paths at the project root")
}

@(test)
test_compilation_recompile_self_alias :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    compilation_run_command(&c, "printf 'alias-ok\\n'")
    compilation_wait(&c)
    testing.expect_value(t, c.finished, true)

    // Recompile passes c.command back in; the old implementation freed it
    // before cloning the argument (use-after-free).
    compilation_run_command(&c, c.command)
    compilation_wait(&c)

    found := false
    for line in c.lines {
        if strings.trim_space(line.text) == "alias-ok" do found = true
    }
    testing.expect_value(t, found, true)
    fmt.println("  ✓ [Compilation] recompile safely aliases its own command")
}

@(test)
test_compilation_cancel_kills_build :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    compilation_run_command(&c, "sleep 10")
    // Wait until the child has actually started before canceling.
    deadline := time.now()
    for {
        sync.mutex_lock(&c.job.mutex)
        started := c.job.process_started
        sync.mutex_unlock(&c.job.mutex)
        if started do break
        if time.since(deadline) > 2 * time.Second do break
        time.sleep(1 * time.Millisecond)
    }

    start := time.now()
    compilation_cancel(&c)
    compilation_wait(&c)
    elapsed := time.since(start)

    testing.expect_value(t, c.finished, true)
    testing.expect_value(t, c.status, "Cancelled")
    testing.expect(t, elapsed < 2 * time.Second, "cancel took too long")
    fmt.println("  ✓ [Compilation] cancel kills a running build without waiting for it")
}

@(test)
test_compilation_destroy_cancels_without_blocking :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)

    compilation_run_command(&c, "sleep 10")
    start := time.now()
    compilation_destroy(&c)
    elapsed := time.since(start)
    testing.expect(t, elapsed < 500 * time.Millisecond, "destroy blocked on a running build")
    compilation_poll_orphans()
    fmt.println("  ✓ [Compilation] destroying a pane cancels its build without blocking")
}
