package main

import sdl "vendor:sdl3"
import "core:path/filepath"
import "core:strings"

is_odin_ident_start :: proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b == '_'
}

is_odin_ident_continue :: proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

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

    // Default everything to foreground text color
    for i in 0 ..< n {
        colors[i] = theme.fg
    }

    i := 0
    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                // Line comment // ...
                for j in i ..< n {
                    colors[j] = theme.comment
                }
                break
            } else if line[i + 1] == '*' {
                // Block comment start /* ... */
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
                for k in i ..< j {
                    colors[k] = theme.comment
                }
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
            for k in start ..< i {
                colors[k] = theme.string_lit
            }
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
            for k in start ..< i {
                colors[k] = theme.string_lit
            }
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
            for k in start ..< i {
                colors[k] = theme.string_lit
            }
            continue
        }

        // 5. Directives & Attributes (#... or @...)
        if c == '#' || c == '@' {
            start := i
            i += 1
            for i < n && is_odin_ident_continue(line[i]) {
                i += 1
            }
            for k in start ..< i {
                colors[k] = theme.directive
            }
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
            for k in start ..< i {
                colors[k] = theme.number_lit
            }
            continue
        }

        // 7. Identifiers / Keywords / Types / Function calls
        if is_odin_ident_start(c) {
            start := i
            for i < n && is_odin_ident_continue(line[i]) {
                i += 1
            }
            word := line[start : i]

            // Check if followed by '(' (function call) or ':: proc'
            is_func := false
            peek := i
            for peek < n && (line[peek] == ' ' || line[peek] == '\t') {
                peek += 1
            }
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
                // Capitalized identifiers in Odin are typically types/enums/structs
                color = theme.type_name
            }

            for k in start ..< i {
                colors[k] = color
            }
            continue
        }

        // 8. Operators
        switch c {
        case ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '~', '^', '?':
            colors[i] = theme.operator
        case '(', ')', '[', ']', '{', '}', ';', ',', '.':
            colors[i] = theme.punctuation
        }

        i += 1
    }
}

syntax_highlight_line :: proc(file_path: string, line: string, theme: ^Theme, colors: []sdl.FColor) {
    ext := filepath.ext(file_path)
    if ext == ".odin" || strings.has_suffix(file_path, ".odin") {
        syntax_highlight_odin_line(line, theme, colors)
        return
    }

    // Default to plain foreground text
    for i in 0 ..< len(line) {
        colors[i] = theme.fg
    }
}
