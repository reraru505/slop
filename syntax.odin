package main

import "core:strings"
import sdl "vendor:sdl3"

is_ident_char_start :: proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}

is_ident_char_continue :: proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// ============================================================================
// ODIN
// ============================================================================

is_odin_keyword :: proc(word: string) -> bool {
    switch word {
    case "proc", "struct", "enum", "union", "bit_set", "bit_field", "map", "dynamic",
         "if", "else", "when", "for", "in", "switch", "case", "break", "continue",
         "fallthrough", "return", "defer", "package", "import", "foreign", "using",
         "context", "or_return", "or_break", "or_continue", "distinct", "opaque",
         "inline", "no_inline", "auto_cast", "cast", "transmute", "size_of",
         "align_of", "offset_of", "type_of", "typeid_of":
        return true
    }
    return false
}

is_odin_builtin_type :: proc(word: string) -> bool {
    switch word {
    case "int", "uint", "uintptr", "rawptr", "string", "cstring", "bool", "b8", "b16", "b32", "b64",
         "byte", "rune", "typeid", "any",
         "i8", "i16", "i32", "i64", "i128",
         "u8", "u16", "u32", "u64", "u128",
         "f16", "f32", "f64",
         "complex32", "complex64", "complex128",
         "quaternion64", "quaternion128", "quaternion256":
        return true
    }
    return false
}

is_odin_constant :: proc(word: string) -> bool {
    switch word {
    case "true", "false", "nil":
        return true
    }
    return false
}

syntax_highlight_odin_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // 2. String literals ("...")
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // 3. Raw string literals (`...`)
        if c == '`' {
            start := i
            i += 1
            for i < n {
                if line[i] == '`' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // 4. Character literals ('c')
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // 5. Directives & Attributes (#... or @...)
        if c == '#' || c == '@' {
            start := i
            i += 1
            for i < n && is_ident_char_continue(line[i]) {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.directive
            continue
        }

        // 6. Numeric literals
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // 7. Identifiers / Keywords / Types / Function calls
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) {
                i += 1
            }
            word := line[start : i]

            is_func := false
            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            if peek < n && line[peek] == '(' {
                is_func = true
            } else if peek + 1 < n && line[peek] == ':' && line[peek + 1] == ':' {
                p2 := peek + 2
                for p2 < n && (line[p2] == ' ' || line[p2] == '\t') do p2 += 1
                if p2 + 4 <= n && line[p2 : p2 + 4] == "proc" {
                    is_func = true
                }
            }

            color := theme.fg
            if is_odin_keyword(word) {
                color = theme.keyword
            } else if is_odin_builtin_type(word) {
                color = theme.type_name
            } else if is_odin_constant(word) {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if word[0] >= 'A' && word[0] <= 'Z' {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        // 8. Operators & punctuation
        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '~', '^', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// ZIG
// ============================================================================

is_zig_keyword :: proc(word: string) -> bool {
    switch word {
    case "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm",
         "async", "await", "break", "callconv", "catch", "comptime", "const",
         "continue", "defer", "dump", "else", "enum", "errdefer", "error",
         "export", "extern", "fn", "for", "if", "inline", "noalias", "noinline",
         "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume",
         "return", "linksection", "struct", "suspend", "switch", "test",
         "threadlocal", "try", "union", "unreachable", "usingnamespace", "var",
         "volatile", "while":
        return true
    }
    return false
}

is_zig_type :: proc(word: string) -> bool {
    switch word {
    case "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "i128", "u128",
         "isize", "usize", "c_char", "c_short", "c_ushort", "c_int", "c_uint",
         "c_long", "c_ulong", "c_longlong", "c_ulonglong", "c_longdouble",
         "f16", "f32", "f64", "f80", "f128", "bool", "void", "noreturn",
         "type", "anyerror", "anyopaque":
        return true
    }
    return false
}

is_zig_constant :: proc(word: string) -> bool {
    switch word {
    case "true", "false", "null", "undefined":
        return true
    }
    return false
}

syntax_highlight_zig_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    // Multiline string literal \\...
    trimmed := strings.trim_left_space(line)
    if strings.has_prefix(trimmed, "\\\\") {
        idx := strings.index(line, "\\\\")
        if idx >= 0 {
            for j in idx ..< n do colors[j] = theme.string_lit
            return
        }
    }

    i := 0
    for i < n {
        c := line[i]

        // Comments //
        if c == '/' && i + 1 < n && line[i + 1] == '/' {
            for j in i ..< n do colors[j] = theme.comment
            break
        }

        // Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Characters
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Builtins @import, @as, etc.
        if c == '@' {
            start := i
            i += 1
            for i < n && is_ident_char_continue(line[i]) do i += 1
            for k in start ..< i do colors[k] = theme.directive
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_zig_keyword(word) {
                color = theme.keyword
            } else if is_zig_type(word) {
                color = theme.type_name
            } else if is_zig_constant(word) {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if word[0] >= 'A' && word[0] <= 'Z' {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// C / C++
// ============================================================================

is_c_keyword :: proc(word: string) -> bool {
    switch word {
    case "auto", "break", "case", "const", "continue", "default", "do", "else",
         "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
         "return", "sizeof", "static", "struct", "switch", "typedef", "union",
         "volatile", "while",
         "class", "public", "private", "protected", "virtual", "override", "final",
         "template", "typename", "namespace", "using", "new", "delete", "try",
         "catch", "throw", "constexpr", "consteval", "constinit", "decltype",
         "explicit", "export", "friend", "mutable", "noexcept", "operator",
         "static_assert", "static_cast", "dynamic_cast", "reinterpret_cast",
         "const_cast", "concept", "requires", "co_await", "co_return", "co_yield":
        return true
    }
    return false
}

is_c_type :: proc(word: string) -> bool {
    switch word {
    case "void", "char", "short", "int", "long", "float", "double", "signed",
         "unsigned", "bool", "_Bool", "size_t", "ssize_t", "int8_t", "int16_t",
         "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
         "uintptr_t", "intptr_t", "ptrdiff_t", "wchar_t", "string", "vector",
         "map", "unordered_map", "set", "unique_ptr", "shared_ptr", "int32",
         "uint32", "int64", "uint64":
        return true
    }
    return false
}

is_c_constant :: proc(word: string) -> bool {
    switch word {
    case "NULL", "nullptr", "true", "false", "this":
        return true
    }
    return false
}

syntax_highlight_c_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // 2. Preprocessor directive #...
        if c == '#' {
            start := i
            i += 1
            for i < n && (is_ident_char_continue(line[i]) || line[i] == ' ') do i += 1
            for k in start ..< i do colors[k] = theme.directive

            // If #include <...>
            for i < n && (line[i] == ' ' || line[i] == '\t') do i += 1
            if i < n && line[i] == '<' {
                s_start := i
                for i < n && line[i] != '>' do i += 1
                if i < n && line[i] == '>' do i += 1
                for k in s_start ..< i do colors[k] = theme.string_lit
            }
            continue
        }

        // 3. Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // 4. Characters
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // 5. Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == 'u' || line[i] == 'U' || line[i] == 'l' || line[i] == 'L' || line[i] == 'f' || line[i] == 'F') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // 6. Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_c_keyword(word) {
                color = theme.keyword
            } else if is_c_type(word) {
                color = theme.type_name
            } else if is_c_constant(word) {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if (word[0] >= 'A' && word[0] <= 'Z') || strings.has_suffix(word, "_t") {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// RUST
// ============================================================================

is_rust_keyword :: proc(word: string) -> bool {
    switch word {
    case "as", "async", "await", "break", "const", "continue", "crate", "dyn",
         "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
         "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
         "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
         "where", "while":
        return true
    }
    return false
}

is_rust_type :: proc(word: string) -> bool {
    switch word {
    case "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64",
         "u128", "usize", "f32", "f64", "str", "bool", "char", "String", "Vec",
         "Option", "Result", "Box", "Rc", "Arc", "Cell", "RefCell", "HashMap",
         "HashSet", "BTreeMap", "BTreeSet":
        return true
    }
    return false
}

is_rust_constant :: proc(word: string) -> bool {
    switch word {
    case "true", "false", "Some", "None", "Ok", "Err":
        return true
    }
    return false
}

syntax_highlight_rust_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // 2. Attributes #[...] or #![...]
        if c == '#' && i + 1 < n && (line[i + 1] == '[' || (line[i + 1] == '!' && i + 2 < n && line[i + 2] == '[')) {
            start := i
            i += 2
            if line[start + 1] == '!' do i += 1
            depth := 1
            for i < n && depth > 0 {
                if line[i] == '[' do depth += 1
                else if line[i] == ']' do depth -= 1
                i += 1
            }
            for k in start ..< i do colors[k] = theme.directive
            continue
        }

        // 3. Raw strings r"..." or r#"..."#
        if c == 'r' && i + 1 < n && (line[i + 1] == '"' || line[i + 1] == '#') {
            start := i
            i += 1
            hashes := 0
            for i < n && line[i] == '#' {
                hashes += 1
                i += 1
            }
            if i < n && line[i] == '"' {
                i += 1
                for i < n {
                    if line[i] == '"' {
                        match := true
                        for h in 0 ..< hashes {
                            if i + 1 + h >= n || line[i + 1 + h] != '#' {
                                match = false
                                break
                            }
                        }
                        if match {
                            i += 1 + hashes
                            break
                        }
                    }
                    i += 1
                }
                for k in start ..< i do colors[k] = theme.string_lit
                continue
            }
            i = start
        }

        // 4. Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // 5. Characters or lifetimes ('c' vs 'a)
        if c == '\'' {
            start := i
            i += 1
            if i < n && line[i] == '\\' && i + 2 < n && line[i + 2] == '\'' {
                i += 3
                for k in start ..< i do colors[k] = theme.string_lit
                continue
            } else if i + 1 < n && line[i + 1] == '\'' {
                i += 2
                for k in start ..< i do colors[k] = theme.string_lit
                continue
            } else if i < n && is_ident_char_start(line[i]) {
                for i < n && is_ident_char_continue(line[i]) do i += 1
                for k in start ..< i do colors[k] = theme.type_name
                continue
            }
        }

        // 6. Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // 7. Identifiers & Macros
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            is_macro := (i < n && line[i] == '!')
            if is_macro do i += 1

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && (line[peek] == '(' || line[peek] == '[' || line[peek] == '{') && is_macro) ||
                       (peek < n && line[peek] == '(')

            color := theme.fg
            if is_macro {
                color = theme.directive
            } else if is_rust_keyword(word) {
                color = theme.keyword
            } else if is_rust_type(word) {
                color = theme.type_name
            } else if is_rust_constant(word) {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if word[0] >= 'A' && word[0] <= 'Z' {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// GO
// ============================================================================

is_go_keyword :: proc(word: string) -> bool {
    switch word {
    case "break", "case", "chan", "const", "continue", "default", "defer",
         "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
         "interface", "map", "package", "range", "return", "select", "struct",
         "switch", "type", "var":
        return true
    }
    return false
}

is_go_type :: proc(word: string) -> bool {
    switch word {
    case "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
         "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
         "uint8", "uint16", "uint32", "uint64", "uintptr", "any":
        return true
    }
    return false
}

is_go_builtin :: proc(word: string) -> bool {
    switch word {
    case "append", "cap", "close", "complex", "copy", "delete", "imag", "len",
         "make", "new", "panic", "print", "println", "real", "recover":
        return true
    }
    return false
}

is_go_constant :: proc(word: string) -> bool {
    switch word {
    case "true", "false", "iota", "nil":
        return true
    }
    return false
}

syntax_highlight_go_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Raw strings `...`
        if c == '`' {
            start := i
            i += 1
            for i < n {
                if line[i] == '`' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Characters
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_go_keyword(word) {
                color = theme.keyword
            } else if is_go_type(word) {
                color = theme.type_name
            } else if is_go_builtin(word) {
                color = theme.fn_name
            } else if is_go_constant(word) {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if word[0] >= 'A' && word[0] <= 'Z' {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// C3
// ============================================================================

is_c3_keyword :: proc(word: string) -> bool {
    switch word {
    case "module", "import", "fn", "struct", "union", "enum", "fault", "distinct",
         "bitstruct", "macro", "typedef", "def", "interface", "const", "var",
         "if", "else", "switch", "case", "default", "for", "foreach", "foreach_r",
         "while", "do", "defer", "return", "break", "continue", "nextcase",
         "asm", "assert", "try", "catch", "tlocal", "inline", "noinline", "cast":
        return true
    }
    return false
}

is_c3_type :: proc(word: string) -> bool {
    switch word {
    case "void", "bool", "char", "ichan", "short", "ushort", "int", "uint",
         "long", "ulong", "int128", "uint128", "float", "double", "float16",
         "float128", "iptr", "uptr", "isz", "usz", "typeid", "any", "anyfault":
        return true
    }
    return false
}

syntax_highlight_c3_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // Directives ($... or @...)
        if c == '$' || c == '@' {
            start := i
            i += 1
            for i < n && is_ident_char_continue(line[i]) do i += 1
            for k in start ..< i do colors[k] = theme.directive
            continue
        }

        // Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Characters
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_c3_keyword(word) {
                color = theme.keyword
            } else if is_c3_type(word) {
                color = theme.type_name
            } else if word == "true" || word == "false" || word == "null" {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if word[0] >= 'A' && word[0] <= 'Z' {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// HARE
// ============================================================================

is_hare_keyword :: proc(word: string) -> bool {
    switch word {
    case "export", "fn", "def", "let", "const", "type", "for", "if", "else",
         "switch", "case", "match", "return", "yield", "break", "continue",
         "abort", "assert", "alloc", "free", "append", "insert", "delete",
         "len", "size", "offset", "as", "is", "static", "nullable", "use":
        return true
    }
    return false
}

is_hare_type :: proc(word: string) -> bool {
    switch word {
    case "void", "bool", "size", "uintptr", "u8", "u16", "u32", "u64",
         "i8", "i16", "i32", "i64", "f32", "f64", "rune", "str", "valist",
         "nullable", "opaque":
        return true
    }
    return false
}

syntax_highlight_hare_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // Comments //
        if c == '/' && i + 1 < n && line[i + 1] == '/' {
            for j in i ..< n do colors[j] = theme.comment
            break
        }

        // Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Raw strings `...`
        if c == '`' {
            start := i
            i += 1
            for i < n {
                if line[i] == '`' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Characters
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && (line[i + 1] == 'x' || line[i + 1] == 'b' || line[i + 1] == 'o') {
                i += 2
            }
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_hare_keyword(word) {
                color = theme.keyword
            } else if is_hare_type(word) {
                color = theme.type_name
            } else if word == "true" || word == "false" || word == "null" {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// RELA (from user's language project /home/fnln/Projects/rela)
// ============================================================================

is_rela_keyword :: proc(word: string) -> bool {
    switch word {
    case "package", "foreign", "struct", "enum", "if", "else", "elif", "for",
         "in", "return", "break", "cast", "mov", "len", "inc", "dec",
         "ref", "dref", "type", "stack":
        return true
    }
    return false
}

is_rela_type :: proc(word: string) -> bool {
    switch word {
    case "i32", "f32", "i64", "f64", "u64", "string", "char", "bool", "ptr", "pointer":
        return true
    }
    return false
}

syntax_highlight_rela_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // Comments // and /* */
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // Strings
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Characters
        if c == '\'' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '\'' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && line[i + 1] == 'x' do i += 2
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.' || line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_rela_keyword(word) {
                color = theme.keyword
            } else if is_rela_type(word) {
                color = theme.type_name
            } else if word == "true" || word == "false" {
                color = theme.constant
            } else if is_func {
                color = theme.fn_name
            } else if word[0] >= 'A' && word[0] <= 'Z' {
                color = theme.type_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// BASH
// ============================================================================

is_bash_keyword :: proc(word: string) -> bool {
    switch word {
    case "if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
         "while", "until", "do", "done", "in", "function", "time", "return",
         "exit", "local", "export", "readonly", "source", "alias", "unalias",
         "set", "unset", "eval", "exec", "declare", "typeset":
        return true
    }
    return false
}

is_bash_builtin :: proc(word: string) -> bool {
    switch word {
    case "echo", "printf", "read", "cd", "pwd", "test", "true", "false",
         "cat", "grep", "sed", "awk", "find", "mkdir", "rm", "cp", "mv",
         "chmod", "chown", "kill", "sleep", "sudo":
        return true
    }
    return false
}

syntax_highlight_bash_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    // Shebang #!...
    if strings.has_prefix(line, "#!") {
        for j in 0 ..< n do colors[j] = theme.directive
        return
    }

    i := 0
    for i < n {
        c := line[i]

        // Comments #
        if c == '#' {
            for j in i ..< n do colors[j] = theme.comment
            break
        }

        // Variables $VAR, ${VAR}, $1, $@, etc.
        if c == '$' {
            start := i
            i += 1
            if i < n && line[i] == '{' {
                i += 1
                for i < n && line[i] != '}' do i += 1
                if i < n && line[i] == '}' do i += 1
            } else if i < n && (line[i] == '?' || line[i] == '!' || line[i] == '@' || line[i] == '#' || line[i] == '$' || line[i] == '*' || (line[i] >= '0' && line[i] <= '9')) {
                i += 1
            } else {
                for i < n && is_ident_char_continue(line[i]) do i += 1
            }
            for k in start ..< i do colors[k] = theme.directive
            continue
        }

        // Double quoted strings (allowing $ variable highlight inside)
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '$' {
                    // Highlight string up to here
                    for k in start ..< i do colors[k] = theme.string_lit
                    v_start := i
                    i += 1
                    if i < n && line[i] == '{' {
                        i += 1
                        for i < n && line[i] != '}' do i += 1
                        if i < n && line[i] == '}' do i += 1
                    } else if i < n && (line[i] == '?' || line[i] == '!' || line[i] == '@' || line[i] == '#' || line[i] == '$' || line[i] == '*' || (line[i] >= '0' && line[i] <= '9')) {
                        i += 1
                    } else {
                        for i < n && is_ident_char_continue(line[i]) do i += 1
                    }
                    for k in v_start ..< i do colors[k] = theme.directive
                    start = i
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Single quoted strings
        if c == '\'' {
            start := i
            i += 1
            for i < n && line[i] != '\'' do i += 1
            if i < n && line[i] == '\'' do i += 1
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            for i < n && (line[i] >= '0' && line[i] <= '9') do i += 1
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && (is_ident_char_continue(line[i]) || line[i] == '-') do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek + 1 < n && line[peek] == '(' && line[peek + 1] == ')')

            color := theme.fg
            if is_bash_keyword(word) {
                color = theme.keyword
            } else if is_bash_builtin(word) || is_func {
                color = theme.fn_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case '|', '&', ';', '<', '>', '=', '+', '-':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// LUA
// ============================================================================

is_lua_keyword :: proc(word: string) -> bool {
    switch word {
    case "and", "break", "do", "else", "elseif", "end", "false", "for",
         "function", "goto", "if", "in", "local", "nil", "not", "or",
         "repeat", "return", "then", "true", "until", "while":
        return true
    }
    return false
}

is_lua_builtin :: proc(word: string) -> bool {
    switch word {
    case "print", "type", "tostring", "tonumber", "pairs", "ipairs", "next",
         "assert", "error", "pcall", "xpcall", "setmetatable", "getmetatable",
         "rawget", "rawset", "require", "table", "string", "math", "io",
         "os", "coroutine", "package", "self":
        return true
    }
    return false
}

syntax_highlight_lua_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    for i < n {
        c := line[i]

        // Comments -- and --[[ ... ]]
        if c == '-' && i + 1 < n && line[i + 1] == '-' {
            if i + 3 < n && line[i + 2] == '[' && line[i + 3] == '[' {
                j := i + 4
                closed := false
                for j + 1 < n {
                    if line[j] == ']' && line[j + 1] == ']' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            } else {
                for j in i ..< n do colors[j] = theme.comment
                break
            }
        }

        // Multiline strings [[...]]
        if c == '[' && i + 1 < n && line[i + 1] == '[' {
            start := i
            i += 2
            for i + 1 < n {
                if line[i] == ']' && line[i + 1] == ']' {
                    i += 2
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Strings "..." and '...'
        if c == '"' || c == '\'' {
            quote := c
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == quote {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' {
            start := i
            if c == '0' && i + 1 < n && line[i + 1] == 'x' do i += 2
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         (line[i] >= 'a' && line[i] <= 'f') ||
                         (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '.') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && is_ident_char_continue(line[i]) do i += 1
            word := line[start : i]

            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
            is_func := (peek < n && line[peek] == '(')

            color := theme.fg
            if is_lua_keyword(word) {
                if word == "true" || word == "false" || word == "nil" {
                    color = theme.constant
                } else {
                    color = theme.keyword
                }
            } else if is_lua_builtin(word) {
                color = theme.type_name
            } else if is_func {
                color = theme.fn_name
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '~', '#', '^':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// TOML
// ============================================================================

syntax_highlight_toml_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    trimmed := strings.trim_left_space(line)
    // Table headers [section] or [[array_section]]
    if strings.has_prefix(trimmed, "[") {
        idx := strings.index(line, "[")
        if idx >= 0 {
            // Only look for the closing bracket before any comment, so a ']'
            // inside the trailing comment cannot extend the header.
            comment_idx := strings.index_byte(line, '#')
            header_end := n if comment_idx < 0 else comment_idx
            end_idx := strings.last_index(line[:header_end], "]")
            if end_idx >= idx {
                for k in idx ..= end_idx do colors[k] = theme.type_name
                if comment_idx >= 0 {
                    for k in comment_idx ..< n do colors[k] = theme.comment
                }
                return
            }
        }
    }

    i := 0
    has_seen_eq := false
    for i < n {
        c := line[i]

        // Comments #
        if c == '#' {
            for j in i ..< n do colors[j] = theme.comment
            break
        }

        // Strings "..." or '...'
        if c == '"' || c == '\'' {
            quote := c
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == quote {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            continue
        }

        if c == '=' {
            colors[i] = theme.operator
            has_seen_eq = true
            i += 1
            continue
        }

        // Numbers & Dates
        if has_seen_eq && (c >= '0' && c <= '9' || c == '-' || c == '+') {
            start := i
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         line[i] == '.' || line[i] == '-' || line[i] == ':' || line[i] == 'T' || line[i] == 'Z' ||
                         line[i] == 'x' || line[i] == 'o' || line[i] == 'b' ||
                         (line[i] >= 'a' && line[i] <= 'f') || (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            continue
        }

        // Identifiers
        if is_ident_char_start(c) {
            start := i
            for i < n && (is_ident_char_continue(line[i]) || line[i] == '-') do i += 1
            word := line[start : i]

            color := theme.fg
            if !has_seen_eq {
                color = theme.keyword
            } else {
                if word == "true" || word == "false" {
                    color = theme.constant
                }
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        i += 1
    }
}

// ============================================================================
// KDL
// ============================================================================

syntax_highlight_kdl_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    first_ident := true
    for i < n {
        c := line[i]

        // Comments //, /* */, /-
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' || line[i + 1] == '-' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                j := i + 2
                closed := false
                for j + 1 < n {
                    if line[j] == '*' && line[j + 1] == '/' {
                        j += 2
                        closed = true
                        break
                    }
                    j += 1
                }
                if !closed do j = n
                for k in i ..< j do colors[k] = theme.comment
                i = j
                continue
            }
        }

        // Type annotations (type)
        if c == '(' {
            start := i
            i += 1
            for i < n && line[i] != ')' do i += 1
            if i < n && line[i] == ')' do i += 1
            for k in start ..< i do colors[k] = theme.type_name
            continue
        }

        // Strings "..."
        if c == '"' {
            start := i
            i += 1
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            first_ident = false
            continue
        }

        // Numbers
        if c >= '0' && c <= '9' || (c == '-' && i + 1 < n && line[i + 1] >= '0' && line[i + 1] <= '9') {
            start := i
            for i < n && ((line[i] >= '0' && line[i] <= '9') ||
                         line[i] == '.' || line[i] == 'x' || line[i] == 'o' || line[i] == 'b' ||
                         (line[i] >= 'a' && line[i] <= 'f') || (line[i] >= 'A' && line[i] <= 'F') ||
                         line[i] == '_') {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.number_lit
            first_ident = false
            continue
        }

        // Identifiers / property keys
        if is_ident_char_start(c) {
            start := i
            for i < n && (is_ident_char_continue(line[i]) || line[i] == '-') do i += 1
            word := line[start : i]

            color := theme.fg
            if first_ident {
                color = theme.fn_name
                first_ident = false
            } else if i < n && line[i] == '=' {
                color = theme.keyword
            } else if word == "true" || word == "false" || word == "null" {
                color = theme.constant
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        if c == '=' {
            colors[i] = theme.operator
        } else if c == '{' || c == '}' || c == ';' {
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

// ============================================================================
// MAKEFILE
// ============================================================================

is_makefile_directive :: proc(word: string) -> bool {
    switch word {
    case "include", "-include", "sinclude", "define", "endef", "ifeq", "ifneq",
         "ifdef", "ifndef", "else", "endif", "export", "unexport", "override",
         "vpath", ".PHONY", ".DEFAULT", ".PRECIOUS":
        return true
    }
    return false
}

syntax_highlight_makefile_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    i := 0
    // Skip leading whitespace or tab
    for i < n && (line[i] == ' ' || line[i] == '\t') do i += 1

    for i < n {
        c := line[i]

        // Comments #
        if c == '#' {
            for j in i ..< n do colors[j] = theme.comment
            break
        }

        // Variables $(...) or ${...} or $@, $<, etc.
        if c == '$' {
            start := i
            i += 1
            if i < n && (line[i] == '(' || line[i] == '{') {
                close_char := line[i] == '(' ? u8(')') : u8('}')
                i += 1
                for i < n && line[i] != close_char do i += 1
                if i < n && line[i] == close_char do i += 1
            } else if i < n {
                i += 1
            }
            for k in start ..< i do colors[k] = theme.type_name
            continue
        }

        // Assignment operators :=, ?=, +=, !=, =
        if c == ':' && i + 1 < n && line[i + 1] == '=' {
            colors[i] = theme.operator
            colors[i + 1] = theme.operator
            i += 2
            continue
        } else if (c == '?' || c == '+' || c == '!') && i + 1 < n && line[i + 1] == '=' {
            colors[i] = theme.operator
            colors[i + 1] = theme.operator
            i += 2
            continue
        } else if c == '=' {
            colors[i] = theme.operator
            i += 1
            continue
        }

        // Target detection: text followed by ':' (and not an assignment)
        if c == ':' && (i + 1 >= n || line[i + 1] != '=') {
            colors[i] = theme.operator
            i += 1
            continue
        }

        // Identifiers / directives / targets
        if is_ident_char_start(c) || c == '.' {
            start := i
            for i < n && (is_ident_char_continue(line[i]) || line[i] == '-' || line[i] == '.') do i += 1
            word := line[start : i]

            color := theme.fg
            if is_makefile_directive(word) {
                color = theme.directive
            } else {
                // Peek ahead to see if followed by ':' (target) or '=' / ':=' (variable)
                peek := i
                for peek < n && (line[peek] == ' ' || line[peek] == '\t') do peek += 1
                if peek < n {
                    if line[peek] == ':' && (peek + 1 >= n || line[peek + 1] != '=') {
                        color = theme.fn_name
                    } else if line[peek] == '=' || (peek + 1 < n && line[peek + 1] == '=') {
                        color = theme.keyword
                    }
                }
            }

            for k in start ..< i do colors[k] = color
            continue
        }

        i += 1
    }
}

// ============================================================================
// MAIN DISPATCHER
// ============================================================================

syntax_highlight_line :: proc(file_path: string, line: string, theme: ^Theme, colors: []sdl.FColor) {
    n := len(line)
    if n == 0 do return

    // Default to plain foreground text
    for i in 0 ..< n {
        colors[i] = theme.fg
    }

    lang := language_from_file_path(file_path)
    switch lang {
    case .Odin:     syntax_highlight_odin_line(line, theme, colors)
    case .Zig:      syntax_highlight_zig_line(line, theme, colors)
    case .C, .Cpp:  syntax_highlight_c_line(line, theme, colors)
    case .Rust:     syntax_highlight_rust_line(line, theme, colors)
    case .Go:       syntax_highlight_go_line(line, theme, colors)
    case .C3:       syntax_highlight_c3_line(line, theme, colors)
    case .Hare:     syntax_highlight_hare_line(line, theme, colors)
    case .Rela:     syntax_highlight_rela_line(line, theme, colors)
    case .Bash:     syntax_highlight_bash_line(line, theme, colors)
    case .Lua:      syntax_highlight_lua_line(line, theme, colors)
    case .Toml:     syntax_highlight_toml_line(line, theme, colors)
    case .Kdl:      syntax_highlight_kdl_line(line, theme, colors)
    case .Makefile: syntax_highlight_makefile_line(line, theme, colors)
    case .Plaintext: // default fg already assigned
    }
}
