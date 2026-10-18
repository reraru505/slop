package main

import "core:fmt"
import "core:strings"
import "core:testing"

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
test_compilation_run_command_failure_parses_errors :: proc(t: ^testing.T) {
    c: Compilation
    compilation_init(&c)
    defer compilation_destroy(&c)

    cmd := "printf 'src/main.odin(3:7) Error: boom\\n' >&2; exit 1"
    compilation_run_command(&c, cmd)

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
