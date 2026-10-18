package main

import "core:strings"
import sdl "vendor:sdl3"

// Lexer state carried from one line to the next. `Normal` is the zero value.
Syntax_State_Kind :: enum u8 {
    Normal,
    Block_Comment,
    Raw_String,
    Quoted_String,
    Long_String,
    Here_Doc,
}

Syntax_State :: struct {
    kind:             Syntax_State_Kind,
    depth:            int,  // nested block-comment depth
    hashes:           int,  // Rust raw-string '#' count
    bracket_level:    int,  // Lua long-bracket '=' count
    quote:            u8,   // active quote character
    heredoc_tag:      u64,  // hash of the Bash heredoc terminator
    heredoc_strip_tabs: bool,
}

syntax_state_hash :: proc(state: Syntax_State) -> u64 {
    h: u64 = 1469598103934665603
    h = (h ~ u64(state.kind)) * 1099511628211
    h = (h ~ u64(state.depth + 1)) * 1099511628211
    h = (h ~ u64(state.hashes + 1)) * 1099511628211
    h = (h ~ u64(state.bracket_level + 1)) * 1099511628211
    h = (h ~ u64(state.quote)) * 1099511628211
    h = (h ~ state.heredoc_tag) * 1099511628211
    h = (h ~ u64(1 if state.heredoc_strip_tabs else 0)) * 1099511628211
    return h
}

string_hash :: proc(s: string) -> u64 {
    h: u64 = 1469598103934665603
    for b in s do h = (h ~ u64(b)) * 1099511628211
    return h
}

syntax_color_range :: proc(colors: []sdl.FColor, start, end: int, color: sdl.FColor) {
    lo := clamp(start, 0, len(colors))
    hi := clamp(end, lo, len(colors))
    for i in lo ..< hi do colors[i] = color
}

// Lua long bracket: `[`, zero or more `=`, then `[`.
syntax_lua_long_open :: proc(line: string, pos: int) -> (level: int, after: int, ok: bool) {
    if pos >= len(line) || line[pos] != '[' do return 0, pos, false
    j := pos + 1
    for j < len(line) && line[j] == '=' do j += 1
    if j < len(line) && line[j] == '[' do return j - pos - 1, j + 1, true
    return 0, pos, false
}

syntax_lua_long_close :: proc(line: string, start: int, level: int) -> (end: int, closed: bool) {
    j := start
    for j < len(line) {
        if line[j] == ']' {
            match := true
            for k in 0 ..< level {
                if j + 1 + k >= len(line) || line[j + 1 + k] != '=' {
                    match = false
                    break
                }
            }
            if match && j + 1 + level < len(line) && line[j + 1 + level] == ']' {
                return j + 2 + level, true
            }
        }
        j += 1
    }
    return len(line), false
}

// Consume a block comment starting at `start`. `depth` is the incoming depth
// (1 for a fresh comment). Returns the byte after the closing delimiter, the
// remaining depth, and whether it closed on this line.
syntax_scan_block_comment :: proc(
    line: string,
    start: int,
    open: string,
    close: string,
    depth: int,
    nested: bool,
) -> (end: int, remaining: int, closed: bool) {
    remaining = max(1, depth)
    j := start
    for j < len(line) {
        if nested && j + len(open) <= len(line) && line[j:j + len(open)] == open {
            remaining += 1
            j += len(open)
            continue
        }
        if j + len(close) <= len(line) && line[j:j + len(close)] == close {
            remaining -= 1
            j += len(close)
            if remaining == 0 do return j, 0, true
            continue
        }
        j += 1
    }
    return len(line), remaining, false
}

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

syntax_highlight_odin_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, true)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    } else if state.kind == .Raw_String {
        j := 0
        closed := false
        for j < n {
            if line[j] == '`' {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, true)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
            closed := false
            for i < n {
                if line[i] == '`' {
                    i += 1
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed do return Syntax_State{kind = .Raw_String}
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
    return state
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

syntax_highlight_zig_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    state := state_in
    n := len(line)
    if n == 0 do return state

    // Multiline string literal \\...
    trimmed := strings.trim_left_space(line)
    if strings.has_prefix(trimmed, "\\\\") {
        idx := strings.index(line, "\\\\")
        if idx >= 0 {
            for j in idx ..< n do colors[j] = theme.string_lit
            return state
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
    return state
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

syntax_highlight_c_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, false)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    } else if state.kind == .Quoted_String {
        start := 0
        j := 0
        closed := false
        for j < n {
            if line[j] == '\\' && j + 1 < n {
                j += 2
                continue
            }
            if line[j] == '"' {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, start, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, false)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
            closed := false
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            // A trailing backslash escapes the newline; carry the string.
            if !closed && i > start && line[i - 1] == '\\' {
                return Syntax_State{kind = .Quoted_String, quote = '"'}
            }
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
    return state
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

syntax_highlight_rust_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, true)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    } else if state.kind == .Raw_String {
        j := 0
        closed := false
        for j < n {
            if line[j] == '"' {
                match := true
                for h in 0 ..< state.hashes {
                    if j + 1 + h >= n || line[j + 1 + h] != '#' {
                        match = false
                        break
                    }
                }
                if match {
                    j += 1 + state.hashes
                    closed = true
                    break
                }
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    } else if state.kind == .Quoted_String {
        j := 0
        closed := false
        for j < n {
            if line[j] == '\\' && j + 1 < n {
                j += 2
                continue
            }
            if line[j] == '"' {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

    for i < n {
        c := line[i]

        // 1. Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, true)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
                closed := false
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
                            closed = true
                            break
                        }
                    }
                    i += 1
                }
                for k in start ..< i do colors[k] = theme.string_lit
                if !closed do return Syntax_State{kind = .Raw_String, hashes = hashes}
                continue
            }
            i = start
        }

        // 4. Strings
        if c == '"' {
            start := i
            i += 1
            closed := false
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == '"' {
                    i += 1
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed do return Syntax_State{kind = .Quoted_String, quote = '"'}
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
    return state
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

syntax_highlight_go_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, false)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    } else if state.kind == .Raw_String {
        j := 0
        closed := false
        for j < n {
            if line[j] == '`' {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

    for i < n {
        c := line[i]

        // Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, false)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
            closed := false
            for i < n {
                if line[i] == '`' {
                    i += 1
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed do return Syntax_State{kind = .Raw_String}
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
    return state
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

syntax_highlight_c3_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, true)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    }

    for i < n {
        c := line[i]

        // Comments
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, true)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
    return state
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

syntax_highlight_hare_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Raw_String {
        j := 0
        closed := false
        for j < n {
            if line[j] == '`' {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

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
            closed := false
            for i < n {
                if line[i] == '`' {
                    i += 1
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed do return Syntax_State{kind = .Raw_String}
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
    return state
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

syntax_highlight_rela_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, false)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    }

    for i < n {
        c := line[i]

        // Comments // and /* */
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, false)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
    return state
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

syntax_heredoc_line_matches :: proc(line: string, state: Syntax_State) -> bool {
    candidate := strings.trim_right(line, "\r")
    if state.heredoc_strip_tabs do candidate = strings.trim_left(candidate, "\t")
    return string_hash(candidate) == state.heredoc_tag
}

syntax_highlight_bash_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 {
        if state.kind == .Here_Doc {
            return state
        }
        return state
    }

    if state.kind == .Here_Doc {
        if syntax_heredoc_line_matches(line, state) {
            syntax_color_range(colors, 0, n, theme.string_lit)
            return Syntax_State{}
        }
        syntax_color_range(colors, 0, n, theme.string_lit)
        return state
    }

    // Shebang #!...
    if strings.has_prefix(line, "#!") {
        for j in 0 ..< n do colors[j] = theme.directive
        return state
    }

    i := 0
    if state.kind == .Quoted_String {
        quote := state.quote
        j := 0
        closed := false
        for j < n {
            if quote == '"' && line[j] == '\\' && j + 1 < n {
                j += 2
                continue
            }
            if line[j] == quote {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

    pending_heredoc: Syntax_State
    for i < n {
        c := line[i]

        // Heredoc operator: <<TAG or <<-TAG (body starts on the next line).
        if c == '<' && i + 1 < n && line[i + 1] == '<' {
            j := i + 2
            strip_tabs := false
            if j < n && line[j] == '-' {
                strip_tabs = true
                j += 1
            }
            for j < n && (line[j] == ' ' || line[j] == '\t') do j += 1
            delim := ""
            if j < n && (line[j] == '\'' || line[j] == '"') {
                quote := line[j]
                j += 1
                start := j
                for j < n && line[j] != quote do j += 1
                delim = line[start:j]
                if j < n do j += 1
            } else {
                start := j
                for j < n && (is_ident_char_continue(line[j]) || line[j] == '-' || line[j] == '.') do j += 1
                delim = line[start:j]
            }
            if delim != "" {
                pending_heredoc = Syntax_State{
                    kind = .Here_Doc,
                    heredoc_tag = string_hash(delim),
                    heredoc_strip_tabs = strip_tabs,
                }
            }
            i = j
            continue
        }

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
            closed := false
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
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed do return Syntax_State{kind = .Quoted_String, quote = '"'}
            continue
        }

        // Single quoted strings
        if c == '\'' {
            start := i
            i += 1
            closed := false
            for i < n && line[i] != '\'' do i += 1
            if i < n && line[i] == '\'' {
                i += 1
                closed = true
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed do return Syntax_State{kind = .Quoted_String, quote = '\''}
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
    // A heredoc block begins on the following line.
    if pending_heredoc.kind == .Here_Doc do state = pending_heredoc
    return state
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

syntax_highlight_lua_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, closed := syntax_lua_long_close(line, 0, state.bracket_level)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed do return state
        state = {}
        i = end
    } else if state.kind == .Long_String {
        end, closed := syntax_lua_long_close(line, 0, state.bracket_level)
        syntax_color_range(colors, 0, end, theme.string_lit)
        if !closed do return state
        state = {}
        i = end
    } else if state.kind == .Quoted_String {
        quote := state.quote
        j := 0
        closed := false
        for j < n {
            if line[j] == '\\' && j + 1 < n {
                j += 2
                continue
            }
            if line[j] == quote {
                j += 1
                closed = true
                break
            }
            j += 1
        }
        syntax_color_range(colors, 0, j, theme.string_lit)
        if !closed do return state
        state = {}
        i = j
    }

    for i < n {
        c := line[i]

        // Comments -- and --[=[ ... ]=]
        if c == '-' && i + 1 < n && line[i + 1] == '-' {
            if level, after, ok := syntax_lua_long_open(line, i + 2); ok {
                end, closed := syntax_lua_long_close(line, after, level)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, bracket_level = level}
                i = end
                continue
            } else {
                for j in i ..< n do colors[j] = theme.comment
                break
            }
        }

        // Multiline strings [[...]] and [=[...]=]
        if c == '[' {
            if level, after, ok := syntax_lua_long_open(line, i); ok {
                end, closed := syntax_lua_long_close(line, after, level)
                syntax_color_range(colors, i, end, theme.string_lit)
                if !closed do return Syntax_State{kind = .Long_String, bracket_level = level}
                i = end
                continue
            }
        }

        // Strings "..." and '...'
        if c == '"' || c == '\'' {
            quote := c
            start := i
            i += 1
            closed := false
            for i < n {
                if line[i] == '\\' && i + 1 < n {
                    i += 2
                    continue
                }
                if line[i] == quote {
                    i += 1
                    closed = true
                    break
                }
                i += 1
            }
            for k in start ..< i do colors[k] = theme.string_lit
            if !closed && i > start && line[i - 1] == '\\' {
                return Syntax_State{kind = .Quoted_String, quote = quote}
            }
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
    return state
}

// ============================================================================
// TOML
// ============================================================================

syntax_highlight_toml_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Quoted_String || state.kind == .Raw_String {
        quote := state.quote
        j := 0
        closed := false
        for j + 2 < n {
            if quote == '"' && line[j] == '\\' {
                j += 1
                if j < n do j += 1
                continue
            }
            if line[j] == quote && line[j + 1] == quote && line[j + 2] == quote {
                j += 3
                closed = true
                break
            }
            j += 1
        }
        if !closed {
            syntax_color_range(colors, 0, n, theme.string_lit)
            return state
        }
        // The closing run may be at the very end; color through it.
        end := min(n, j)
        syntax_color_range(colors, 0, end, theme.string_lit)
        state = {}
        i = end
    }

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
                return state
            }
        }
    }

    has_seen_eq := false
    for i < n {
        c := line[i]

        // Comments #
        if c == '#' {
            for j in i ..< n do colors[j] = theme.comment
            break
        }

        // Strings "...", '...', and triple-quoted multi-line strings.
        if c == '"' || c == '\'' {
            quote := c
            start := i
            if i + 2 < n && line[i + 1] == quote && line[i + 2] == quote {
                i += 3
                closed := false
                for i + 2 < n {
                    if quote == '"' && line[i] == '\\' {
                        i += 1
                        if i < n do i += 1
                        continue
                    }
                    if line[i] == quote && line[i + 1] == quote && line[i + 2] == quote {
                        i += 3
                        closed = true
                        break
                    }
                    i += 1
                }
                for k in start ..< i do colors[k] = theme.string_lit
                if !closed {
                    state.kind = .Quoted_String if quote == '"' else .Raw_String
                    state.quote = quote
                    return state
                }
                continue
            }
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
    return state
}

// ============================================================================
// KDL
// ============================================================================

syntax_highlight_kdl_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    state := state_in
    if n == 0 do return state

    i := 0
    if state.kind == .Block_Comment {
        end, remaining, closed := syntax_scan_block_comment(line, 0, "/*", "*/", state.depth, false)
        syntax_color_range(colors, 0, end, theme.comment)
        if !closed {
            state.depth = remaining
            return state
        }
        state = {}
        i = end
    }
    first_ident := true
    for i < n {
        c := line[i]

        // Comments //, /* */, /-
        if c == '/' && i + 1 < n {
            if line[i + 1] == '/' || line[i + 1] == '-' {
                for j in i ..< n do colors[j] = theme.comment
                break
            } else if line[i + 1] == '*' {
                end, remaining, closed := syntax_scan_block_comment(line, i + 2, "/*", "*/", 1, false)
                syntax_color_range(colors, i, end, theme.comment)
                if !closed do return Syntax_State{kind = .Block_Comment, depth = remaining}
                i = end
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
    return state
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

syntax_highlight_makefile_line :: proc(line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    state := state_in
    n := len(line)
    if n == 0 do return state

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
    return state
}

// ============================================================================
// MAIN DISPATCHER
// ============================================================================

syntax_highlight_line_state :: proc(file_path: string, line: string, theme: ^Theme, colors: []sdl.FColor, state_in: Syntax_State) -> Syntax_State {
    n := len(line)
    if n == 0 do return state_in

    // Default to plain foreground text
    for i in 0 ..< n {
        colors[i] = theme.fg
    }

    lang := language_from_file_path(file_path)
    switch lang {
    case .Odin:     return syntax_highlight_odin_line(line, theme, colors, state_in)
    case .Zig:      return syntax_highlight_zig_line(line, theme, colors, state_in)
    case .C, .Cpp:  return syntax_highlight_c_line(line, theme, colors, state_in)
    case .Rust:     return syntax_highlight_rust_line(line, theme, colors, state_in)
    case .Go:       return syntax_highlight_go_line(line, theme, colors, state_in)
    case .C3:       return syntax_highlight_c3_line(line, theme, colors, state_in)
    case .Hare:     return syntax_highlight_hare_line(line, theme, colors, state_in)
    case .Rela:     return syntax_highlight_rela_line(line, theme, colors, state_in)
    case .Bash:     return syntax_highlight_bash_line(line, theme, colors, state_in)
    case .Lua:      return syntax_highlight_lua_line(line, theme, colors, state_in)
    case .Toml:     return syntax_highlight_toml_line(line, theme, colors, state_in)
    case .Kdl:      return syntax_highlight_kdl_line(line, theme, colors, state_in)
    case .Makefile: return syntax_highlight_makefile_line(line, theme, colors, state_in)
    case .Plaintext:
        return state_in
    }
    return state_in
}

// Backwards-compatible single-line entry point (state starts Normal).
syntax_highlight_line :: proc(file_path: string, line: string, theme: ^Theme, colors: []sdl.FColor) {
    _ = syntax_highlight_line_state(file_path, line, theme, colors, Syntax_State{})
}
