package main

import "core:testing"
import "core:fmt"
import sdl "vendor:sdl3"

@(test)
test_syntax_language_detection :: proc(t: ^testing.T) {
    testing.expect_value(t, language_from_file_path("main.odin"), LanguageKind.Odin)
    testing.expect_value(t, language_from_file_path("build.zig"), LanguageKind.Zig)
    testing.expect_value(t, language_from_file_path("test.c"), LanguageKind.C)
    testing.expect_value(t, language_from_file_path("header.h"), LanguageKind.C)
    testing.expect_value(t, language_from_file_path("app.cpp"), LanguageKind.Cpp)
    testing.expect_value(t, language_from_file_path("engine.cc"), LanguageKind.Cpp)
    testing.expect_value(t, language_from_file_path("lib.rs"), LanguageKind.Rust)
    testing.expect_value(t, language_from_file_path("server.go"), LanguageKind.Go)
    testing.expect_value(t, language_from_file_path("math.c3"), LanguageKind.C3)
    testing.expect_value(t, language_from_file_path("math.c3i"), LanguageKind.C3)
    testing.expect_value(t, language_from_file_path("main.ha"), LanguageKind.Hare)
    testing.expect_value(t, language_from_file_path("test.rela"), LanguageKind.Rela)
    testing.expect_value(t, language_from_file_path("script.sh"), LanguageKind.Bash)
    testing.expect_value(t, language_from_file_path("deploy.bash"), LanguageKind.Bash)
    testing.expect_value(t, language_from_file_path("config.lua"), LanguageKind.Lua)
    testing.expect_value(t, language_from_file_path("Cargo.toml"), LanguageKind.Toml)
    testing.expect_value(t, language_from_file_path("project.kdl"), LanguageKind.Kdl)
    testing.expect_value(t, language_from_file_path("Makefile"), LanguageKind.Makefile)
    testing.expect_value(t, language_from_file_path("makefile"), LanguageKind.Makefile)
    testing.expect_value(t, language_from_file_path("GNUmakefile"), LanguageKind.Makefile)
    testing.expect_value(t, language_from_file_path("notes.txt"), LanguageKind.Plaintext)
    fmt.println("  ✓ [Syntax] All 13 language file extensions & names verified")
}

check_line_colored :: proc(t: ^testing.T, file_name: string, line: string, theme: ^Theme) -> bool {
    colors := make([]sdl.FColor, len(line), context.temp_allocator)
    syntax_highlight_line(file_name, line, theme, colors)
    has_non_fg := false
    for col in colors {
        if col != theme.fg {
            has_non_fg = true
            break
        }
    }
    return has_non_fg
}

@(test)
test_syntax_all_languages_highlighting :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    // Odin
    testing.expect_value(t, check_line_colored(t, "main.odin", "package main", &th), true)
    testing.expect_value(t, check_line_colored(t, "main.odin", "// this is a comment", &th), true)
    testing.expect_value(t, check_line_colored(t, "main.odin", `msg := "hello world"`, &th), true)

    // Zig
    testing.expect_value(t, check_line_colored(t, "main.zig", `const std = @import("std");`, &th), true)
    testing.expect_value(t, check_line_colored(t, "main.zig", "pub fn main() void {", &th), true)
    testing.expect_value(t, check_line_colored(t, "main.zig", "/// doc comment", &th), true)

    // C
    testing.expect_value(t, check_line_colored(t, "main.c", "#include <stdio.h>", &th), true)
    testing.expect_value(t, check_line_colored(t, "main.c", "int main(int argc, char** argv) {", &th), true)

    // C++
    testing.expect_value(t, check_line_colored(t, "main.cpp", "template<typename T> class Foo {", &th), true)

    // Rust
    testing.expect_value(t, check_line_colored(t, "lib.rs", "pub fn compute() -> Result<u32, Error> {", &th), true)
    testing.expect_value(t, check_line_colored(t, "lib.rs", "let mut buffer = String::new();", &th), true)

    // Go
    testing.expect_value(t, check_line_colored(t, "main.go", "package main", &th), true)
    testing.expect_value(t, check_line_colored(t, "main.go", "func handler(w http.ResponseWriter, r *http.Request) {", &th), true)

    // C3
    testing.expect_value(t, check_line_colored(t, "math.c3", "module math;", &th), true)
    testing.expect_value(t, check_line_colored(t, "math.c3", "fn void calculate() {", &th), true)

    // Hare
    testing.expect_value(t, check_line_colored(t, "main.ha", "use fmt;", &th), true)
    testing.expect_value(t, check_line_colored(t, "main.ha", "export fn main() void = {", &th), true)

    // Rela
    testing.expect_value(t, check_line_colored(t, "app.rela", "fn process(data) {", &th), true)
    testing.expect_value(t, check_line_colored(t, "app.rela", "let result = compute(123);", &th), true)

    // Bash
    testing.expect_value(t, check_line_colored(t, "run.sh", "#!/bin/bash", &th), true)
    testing.expect_value(t, check_line_colored(t, "run.sh", `echo "Running $VAR..."`, &th), true)

    // Lua
    testing.expect_value(t, check_line_colored(t, "init.lua", "local function setup(opts)", &th), true)
    testing.expect_value(t, check_line_colored(t, "init.lua", "-- comment line", &th), true)

    // TOML
    testing.expect_value(t, check_line_colored(t, "Cargo.toml", "[dependencies]", &th), true)
    testing.expect_value(t, check_line_colored(t, "Cargo.toml", `version = "1.0.0"`, &th), true)

    // KDL
    testing.expect_value(t, check_line_colored(t, "config.kdl", `node "my-value" key=true 42`, &th), true)

    // Makefile
    testing.expect_value(t, check_line_colored(t, "Makefile", "all: text-editor", &th), true)
    testing.expect_value(t, check_line_colored(t, "Makefile", "\t$(CC) -o $@ $<", &th), true)
    fmt.println("  ✓ [Syntax] Token coloring across all 13 languages verified")
}

@(test)
test_syntax_identifier_helpers :: proc(t: ^testing.T) {
    testing.expect_value(t, is_ident_char_start('a'), true)
    testing.expect_value(t, is_ident_char_start('Z'), true)
    testing.expect_value(t, is_ident_char_start('_'), true)
    testing.expect_value(t, is_ident_char_start('0'), false)
    testing.expect_value(t, is_ident_char_start('$'), false)

    testing.expect_value(t, is_ident_char_continue('a'), true)
    testing.expect_value(t, is_ident_char_continue('7'), true)
    testing.expect_value(t, is_ident_char_continue('_'), true)
    testing.expect_value(t, is_ident_char_continue('-'), false)
    fmt.println("  ✓ [Syntax] identifier character classes verified")
}

@(test)
test_syntax_keyword_classifiers :: proc(t: ^testing.T) {
    // Odin
    testing.expect_value(t, is_odin_keyword("proc"), true)
    testing.expect_value(t, is_odin_keyword("package"), true)
    testing.expect_value(t, is_odin_keyword("defer"), true)
    testing.expect_value(t, is_odin_keyword("Proc"), false)
    testing.expect_value(t, is_odin_keyword("nonsense"), false)
    testing.expect_value(t, is_odin_builtin_type("int"), true)
    testing.expect_value(t, is_odin_builtin_type("string"), true)
    testing.expect_value(t, is_odin_builtin_type("byte"), true)
    testing.expect_value(t, is_odin_builtin_type("String"), false)
    testing.expect_value(t, is_odin_constant("true"), true)
    testing.expect_value(t, is_odin_constant("nil"), true)
    testing.expect_value(t, is_odin_constant("false"), true)
    testing.expect_value(t, is_odin_constant("True"), false)

    // Zig
    testing.expect_value(t, is_zig_keyword("const"), true)
    testing.expect_value(t, is_zig_keyword("fn"), true)
    testing.expect_value(t, is_zig_keyword("comptime"), true)
    testing.expect_value(t, is_zig_keyword("not_a_keyword"), false)
    testing.expect_value(t, is_zig_type("i32"), true)
    testing.expect_value(t, is_zig_type("usize"), true)
    testing.expect_value(t, is_zig_type("I32"), false)
    testing.expect_value(t, is_zig_constant("null"), true)
    testing.expect_value(t, is_zig_constant("undefined"), true)
    testing.expect_value(t, is_zig_constant("nil"), false)

    // C / C++
    testing.expect_value(t, is_c_keyword("static"), true)
    testing.expect_value(t, is_c_keyword("template"), true)
    testing.expect_value(t, is_c_keyword("Static"), false)
    testing.expect_value(t, is_c_type("size_t"), true)
    testing.expect_value(t, is_c_type("uint64_t"), true)
    testing.expect_value(t, is_c_type("int32"), true)
    testing.expect_value(t, is_c_type("integer"), false)
    testing.expect_value(t, is_c_constant("NULL"), true)
    testing.expect_value(t, is_c_constant("nullptr"), true)
    testing.expect_value(t, is_c_constant("null"), false)

    // Rust
    testing.expect_value(t, is_rust_keyword("impl"), true)
    testing.expect_value(t, is_rust_keyword("mut"), true)
    testing.expect_value(t, is_rust_keyword("Mut"), false)
    testing.expect_value(t, is_rust_type("u32"), true)
    testing.expect_value(t, is_rust_type("String"), true)
    testing.expect_value(t, is_rust_type("string"), false)
    testing.expect_value(t, is_rust_constant("None"), true)
    testing.expect_value(t, is_rust_constant("Ok"), true)
    testing.expect_value(t, is_rust_constant("nil"), false)

    // Go
    testing.expect_value(t, is_go_keyword("func"), true)
    testing.expect_value(t, is_go_keyword("chan"), true)
    testing.expect_value(t, is_go_keyword("funcs"), false)
    testing.expect_value(t, is_go_type("rune"), true)
    testing.expect_value(t, is_go_type("any"), true)
    testing.expect_value(t, is_go_type("void"), false)
    testing.expect_value(t, is_go_builtin("append"), true)
    testing.expect_value(t, is_go_builtin("panic"), true)
    testing.expect_value(t, is_go_builtin("printf"), false)
    testing.expect_value(t, is_go_constant("iota"), true)
    testing.expect_value(t, is_go_constant("nil"), true)
    testing.expect_value(t, is_go_constant("null"), false)

    // C3 / Hare / Rela
    testing.expect_value(t, is_c3_keyword("fault"), true)
    testing.expect_value(t, is_c3_keyword("foreach_r"), true)
    testing.expect_value(t, is_c3_type("anyfault"), true)
    testing.expect_value(t, is_c3_type("rune"), false)
    testing.expect_value(t, is_hare_keyword("nullable"), true)
    testing.expect_value(t, is_hare_keyword("yield"), true)
    testing.expect_value(t, is_hare_type("valist"), true)
    testing.expect_value(t, is_hare_type("string"), false)
    testing.expect_value(t, is_rela_keyword("dref"), true)
    testing.expect_value(t, is_rela_keyword("foreach"), false)
    testing.expect_value(t, is_rela_type("pointer"), true)
    testing.expect_value(t, is_rela_type("u32"), false)

    // Bash / Lua
    testing.expect_value(t, is_bash_keyword("fi"), true)
    testing.expect_value(t, is_bash_keyword("readonly"), true)
    testing.expect_value(t, is_bash_keyword("endif"), false)
    testing.expect_value(t, is_bash_builtin("printf"), true)
    testing.expect_value(t, is_bash_builtin("sudo"), true)
    testing.expect_value(t, is_bash_builtin("ls"), false)
    testing.expect_value(t, is_lua_keyword("elseif"), true)
    testing.expect_value(t, is_lua_keyword("repeat"), true)
    testing.expect_value(t, is_lua_keyword("function_end"), false)
    testing.expect_value(t, is_lua_builtin("setmetatable"), true)
    testing.expect_value(t, is_lua_builtin("require"), true)
    testing.expect_value(t, is_lua_builtin("println"), false)
    fmt.println("  ✓ [Syntax] keyword/type/constant tables for all languages verified")
}

@(test)
test_syntax_odin_token_positions :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    // package main
    line1 := "package main"
    c1 := make([]sdl.FColor, len(line1), context.temp_allocator)
    syntax_highlight_line("a.odin", line1, &th, c1)
    for i in 0 ..< 7 do testing.expect_value(t, c1[i], th.keyword)
    for i in 8 ..< len(line1) do testing.expect_value(t, c1[i], th.fg)

    // x := 42
    line2 := "x := 42"
    c2 := make([]sdl.FColor, len(line2), context.temp_allocator)
    syntax_highlight_line("a.odin", line2, &th, c2)
    testing.expect_value(t, c2[0], th.fg)
    testing.expect_value(t, c2[2], th.operator) // ':'
    testing.expect_value(t, c2[3], th.operator) // '='
    testing.expect_value(t, c2[5], th.number_lit)
    testing.expect_value(t, c2[6], th.number_lit)

    // msg := "hi"
    line3 := `msg := "hi"`
    c3 := make([]sdl.FColor, len(line3), context.temp_allocator)
    syntax_highlight_line("a.odin", line3, &th, c3)
    for i in 0 ..< 3 do testing.expect_value(t, c3[i], th.fg)
    for i in 7 ..< len(line3) do testing.expect_value(t, c3[i], th.string_lit)

    // foo() -> function name + punctuation
    line4 := "foo()"
    c4 := make([]sdl.FColor, len(line4), context.temp_allocator)
    syntax_highlight_line("a.odin", line4, &th, c4)
    for i in 0 ..< 3 do testing.expect_value(t, c4[i], th.fn_name)
    testing.expect_value(t, c4[3], th.punctuation)
    testing.expect_value(t, c4[4], th.punctuation)

    // MyType -> type name; true -> constant
    line5 := "MyType"
    c5 := make([]sdl.FColor, len(line5), context.temp_allocator)
    syntax_highlight_line("a.odin", line5, &th, c5)
    for i in 0 ..< len(line5) do testing.expect_value(t, c5[i], th.type_name)
    line6 := "true"
    c6 := make([]sdl.FColor, len(line6), context.temp_allocator)
    syntax_highlight_line("a.odin", line6, &th, c6)
    for i in 0 ..< len(line6) do testing.expect_value(t, c6[i], th.constant)

    // #load "core:fmt" -> directive + string
    line7 := `#load "core:fmt"`
    c7 := make([]sdl.FColor, len(line7), context.temp_allocator)
    syntax_highlight_line("a.odin", line7, &th, c7)
    for i in 0 ..< 5 do testing.expect_value(t, c7[i], th.directive)
    testing.expect_value(t, c7[5], th.fg)
    for i in 6 ..< len(line7) do testing.expect_value(t, c7[i], th.string_lit)
    fmt.println("  ✓ [Syntax] Odin keyword/type/constant/string/number positions verified")
}

@(test)
test_syntax_comment_styles :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    cases := []struct {
        file, line: string,
    }{
        {"a.zig", "// comment"},
        {"a.c", "// comment"},
        {"a.cpp", "// comment"},
        {"a.rs", "// comment"},
        {"a.go", "// comment"},
        {"a.c3", "// comment"},
        {"a.ha", "// comment"},
        {"a.rela", "// comment"},
        {"a.sh", "# comment"},
        {"a.lua", "-- comment"},
        {"a.toml", "# comment"},
        {"a.kdl", "// comment"},
        {"Makefile", "# comment"},
    }

    for tc in cases {
        colors := make([]sdl.FColor, len(tc.line), context.temp_allocator)
        syntax_highlight_line(tc.file, tc.line, &th, colors)
        testing.expectf(t, colors[0] == th.comment, "%s: first char should be comment-colored", tc.file)
        testing.expectf(t, colors[len(colors) - 1] == th.comment, "%s: last char should be comment-colored", tc.file)
    }
    fmt.println("  ✓ [Syntax] line-comment prefixes colored for all languages")
}

@(test)
test_syntax_plaintext_and_capacity :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    // Plaintext leaves the default foreground untouched
    line := "package main // not code"
    colors := make([]sdl.FColor, len(line), context.temp_allocator)
    syntax_highlight_line("notes.txt", line, &th, colors)
    for c in colors do testing.expect_value(t, c, th.fg)

    // Highlighting never writes past len(line), even with extra capacity
    line2 := "s := \"abc\" // tail"
    sentinel := sdl.FColor{0.123, 0.456, 0.789, 1.0}
    buf := make([]sdl.FColor, len(line2) + 4, context.temp_allocator)
    for i in len(line2) ..< len(buf) do buf[i] = sentinel
    syntax_highlight_line("a.odin", line2, &th, buf)
    for i in len(line2) ..< len(buf) do testing.expect_value(t, buf[i], sentinel)
    fmt.println("  ✓ [Syntax] plaintext and out-of-range color slots untouched")
}

@(test)
test_syntax_resilience :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    // Empty line should not crash
    colors_empty: [0]sdl.FColor
    syntax_highlight_line("test.zig", "", &th, colors_empty[:])

    // Malformed/unclosed quotes and escapes should not crash or read out of bounds
    unclosed := []string{
        `"unclosed string`,
        `'c`,
        `/* unclosed multiline comment`,
        `"trailing backslash \`,
        `#!/bin/bash $`,
    }

    for s in unclosed {
        colors := make([]sdl.FColor, len(s), context.temp_allocator)
        syntax_highlight_line("test.odin", s, &th, colors)
        syntax_highlight_line("test.zig", s, &th, colors)
        syntax_highlight_line("test.rs", s, &th, colors)
        syntax_highlight_line("test.c", s, &th, colors)
        syntax_highlight_line("test.sh", s, &th, colors)
    }
    fmt.println("  ✓ [Syntax] Unterminated strings & escape sequences safe")
}

@(test)
test_syntax_toml_header_with_comment :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)
    line := "[table] # a]b"
    colors := make([]sdl.FColor, len(line), context.temp_allocator)
    syntax_highlight_line("Cargo.toml", line, &th, colors)

    testing.expect_value(t, colors[0], th.type_name)
    testing.expect_value(t, colors[6], th.type_name)
    testing.expect_value(t, colors[8], th.comment)
    testing.expect_value(t, colors[11], th.comment)
    fmt.println("  ✓ [Syntax] TOML headers stop before trailing comments")
}

// Runs the stateful highlighter over a sequence of lines and returns the
// outgoing state plus the colors of the last line.
highlight_sequence_last :: proc(path: string, lines: []string, th: ^Theme) -> (Syntax_State, []sdl.FColor) {
    state: Syntax_State
    last: []sdl.FColor
    for line in lines {
        colors := make([]sdl.FColor, len(line), context.temp_allocator)
        state = syntax_highlight_line_state(path, line, th, colors, state)
        last = colors
    }
    return state, last
}

@(test)
test_syntax_multiline_odin_block_and_raw :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    state, last := highlight_sequence_last("a.odin", []string{
        "/* outer",
        "/* inner */ still outer",
        "end */ let value = 1",
    }, &th)
    testing.expect_value(t, state.kind, Syntax_State_Kind.Normal)
    testing.expect_value(t, last[0], th.comment)

    state2, last2 := highlight_sequence_last("a.odin", []string{
        "/* outer",
        "/* nested",
        "*/ still outer",
    }, &th)
    testing.expect_value(t, state2.kind, Syntax_State_Kind.Block_Comment)
    testing.expect_value(t, state2.depth, 1)
    testing.expect_value(t, last2[0], th.comment)
    _ = last2 // rest of the line is comment

    state3, last3 := highlight_sequence_last("a.odin", []string{
        "msg := `raw",
        "still raw",
        "done`",
    }, &th)
    testing.expect_value(t, state3.kind, Syntax_State_Kind.Normal)
    testing.expect_value(t, last3[0], th.string_lit)

    _, last4 := highlight_sequence_last("a.odin", []string{"msg := `raw", "still raw"}, &th)
    testing.expect_value(t, last4[0], th.string_lit)

    fmt.println("  ✓ [Syntax] Odin block comments nest and raw strings span lines")
}

@(test)
test_syntax_multiline_c_rust_go :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    c_state, c_last := highlight_sequence_last("a.c", []string{
        "int x; /* start",
        "middle",
        "end */ int y;",
    }, &th)
    testing.expect_value(t, c_state.kind, Syntax_State_Kind.Normal)
    testing.expect_value(t, c_last[0], th.comment)

    r_state, _ := highlight_sequence_last("a.rs", []string{
        "/* outer",
        "/* inner",
        "*/",
    }, &th)
    testing.expect_value(t, r_state.kind, Syntax_State_Kind.Block_Comment)
    testing.expect_value(t, r_state.depth, 1)

    _, r_raw := highlight_sequence_last("a.rs", []string{
        "let s = r#\"one",
        "two",
        "three\"#;",
    }, &th)
    testing.expect_value(t, r_raw[0], th.string_lit)

    _, go_raw := highlight_sequence_last("a.go", []string{
        "s := `one",
        "two",
        "three`",
    }, &th)
    testing.expect_value(t, go_raw[0], th.string_lit)

    fmt.println("  ✓ [Syntax] C/Rust/Go block comments and raw strings continue")
}

@(test)
test_syntax_multiline_lua_toml_bash :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)

    lua_state, _ := highlight_sequence_last("a.lua", []string{
        "--[=[ comment",
        "still comment",
    }, &th)
    testing.expect_value(t, lua_state.kind, Syntax_State_Kind.Block_Comment)
    testing.expect_value(t, lua_state.bracket_level, 1)

    _, lua_end := highlight_sequence_last("a.lua", []string{
        "--[=[ comment",
        "still comment",
        "]=] local x = 1",
    }, &th)
    testing.expect_value(t, lua_end[4], th.keyword)

    toml_state, _ := highlight_sequence_last("a.toml", []string{
        `desc = """line one`,
        "line two",
    }, &th)
    testing.expect_value(t, toml_state.kind, Syntax_State_Kind.Quoted_String)

    bash_state, _ := highlight_sequence_last("a.sh", []string{
        "cat <<EOF",
        "body line",
    }, &th)
    testing.expect_value(t, bash_state.kind, Syntax_State_Kind.Here_Doc)

    bash_done, bash_last := highlight_sequence_last("a.sh", []string{
        "cat <<EOF",
        "body line",
        "EOF",
        "echo done",
    }, &th)
    testing.expect_value(t, bash_done.kind, Syntax_State_Kind.Normal)
    testing.expect_value(t, bash_last[0], th.fn_name)

    bash_quote, _ := highlight_sequence_last("a.sh", []string{
        `echo "one`,
        "two",
    }, &th)
    testing.expect_value(t, bash_quote.kind, Syntax_State_Kind.Quoted_String)

    fmt.println("  ✓ [Syntax] Lua long comments, TOML triple strings, Bash heredocs/quotes")
}

@(test)
test_editor_syntax_state_cache_invalidation :: proc(t: ^testing.T) {
    th := theme_get(.GruberDarker)
    e: Editor
    editor_init(&e, nil, "/* start\nmiddle\nend */ let x = 1", "a.odin")
    defer editor_destroy(&e)

    mid_state := editor_ensure_syntax_state(&e, 1, &th)
    testing.expect_value(t, mid_state.kind, Syntax_State_Kind.Block_Comment)
    after_state := editor_ensure_syntax_state(&e, 2, &th)
    testing.expect_value(t, after_state.kind, Syntax_State_Kind.Block_Comment)
    final_state := editor_ensure_syntax_state(&e, 3, &th)
    testing.expect_value(t, final_state.kind, Syntax_State_Kind.Normal)

    // Removing the opening delimiter on line 0 must invalidate lines below.
    pt_replace(&e.table, 0, 2, "")
    editor_invalidate_syntax(&e, 0)
    changed := editor_ensure_syntax_state(&e, 1, &th)
    testing.expect_value(t, changed.kind, Syntax_State_Kind.Normal)

    fmt.println("  ✓ [Syntax] per-line state cache invalidates after edits")
}
