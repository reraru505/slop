package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

// Name used for the scratch buffer opened by :help.
HELP_FILE_PATH :: "*help*"

// Embedded at compile time, so the binary runs without the assets directory.
// `{token}` placeholders are filled from config.odin by help_render.
HELP_TEMPLATE :: #load("assets/help.txt", string)

Help_Label_Style :: enum {
    Plain,          // h, Ctrl+L, Alt+J, Shift+H
    Upper,          // H, L, D, C, Y (documentation capitals)
    Shift_Letter,   // I, O, G, K; falls back to Shift+<name>
    Shift_Symbol,   // $, _ and other US-layout shifted symbols
    Shift_Explicit, // Shift+H, Shift+L
}

// Human-readable base name for a key, without modifiers.
key_base_name :: proc(key: sdl.Keycode) -> string {
    switch key {
    case sdl.K_ESCAPE:
        return "Esc"
    case sdl.K_RETURN, sdl.K_KP_ENTER, sdl.K_RETURN2:
        return "Enter"
    case sdl.K_SPACE:
        return "Space"
    case sdl.K_TAB:
        return "Tab"
    case sdl.K_BACKSPACE:
        return "Backspace"
    case sdl.K_DELETE:
        return "Delete"
    case sdl.K_LEFT:
        return "Left"
    case sdl.K_RIGHT:
        return "Right"
    case sdl.K_UP:
        return "Up"
    case sdl.K_DOWN:
        return "Down"
    case sdl.K_KP_PLUS:
        return "Keypad+"
    case sdl.K_KP_MINUS:
        return "Keypad-"
    case sdl.K_KP_0:
        return "Keypad0"
    }

    code := u32(key)
    if code >= 0x20 && code < 0x7f {
        return fmt.aprintf("%c", rune(code), allocator = context.temp_allocator)
    }

    if name := sdl.GetKeyName(key); name != nil {
        if cloned, err := strings.clone_from_cstring(name, context.temp_allocator); err == nil && cloned != "" {
            return cloned
        }
    }
    return fmt.aprintf("Key%#x", code, allocator = context.temp_allocator)
}

is_letter_key :: proc(key: sdl.Keycode) -> bool {
    code := u32(key)
    return code >= 'a' && code <= 'z'
}

upper_letter :: proc(key: sdl.Keycode) -> string {
    return fmt.aprintf("%c", rune(u32(key) - ('a' - 'A')), allocator = context.temp_allocator)
}

shift_symbol :: proc(key: sdl.Keycode) -> (string, bool) {
    switch key {
    case sdl.K_1: return "!", true
    case sdl.K_2: return "@", true
    case sdl.K_3: return "#", true
    case sdl.K_4: return "$", true
    case sdl.K_5: return "%", true
    case sdl.K_6: return "^", true
    case sdl.K_7: return "&", true
    case sdl.K_8: return "*", true
    case sdl.K_9: return "(", true
    case sdl.K_0: return ")", true
    case sdl.K_MINUS: return "_", true
    case sdl.K_EQUALS: return "+", true
    case sdl.K_LEFTBRACKET: return "{", true
    case sdl.K_RIGHTBRACKET: return "}", true
    case sdl.K_BACKSLASH: return "|", true
    case sdl.K_SEMICOLON: return ":", true
    case sdl.K_APOSTROPHE: return "\"", true
    case sdl.K_GRAVE: return "~", true
    case sdl.K_COMMA: return "<", true
    case sdl.K_PERIOD: return ">", true
    case sdl.K_SLASH: return "?", true
    }
    return "", false
}

// Render a key with a fixed modifier set in a documentation style.
key_label :: proc(key: sdl.Keycode, mods: sdl.Keymod, style: Help_Label_Style) -> string {
    base := key_base_name(key)

    switch style {
    case .Plain:
        if mods & (sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_SHIFT) == {} {
            return base
        }
        prefix := ""
        if mods & sdl.KMOD_CTRL != {} do prefix = "Ctrl+"
        if mods & sdl.KMOD_ALT != {} do prefix = fmt.aprintf("%sAlt+", prefix, allocator = context.temp_allocator)
        if mods & sdl.KMOD_SHIFT != {} do prefix = fmt.aprintf("%sShift+", prefix, allocator = context.temp_allocator)
        name := base
        if is_letter_key(key) do name = upper_letter(key)
        return fmt.aprintf("%s%s", prefix, name, allocator = context.temp_allocator)

    case .Upper:
        return upper_letter(key) if is_letter_key(key) else base

    case .Shift_Letter:
        return upper_letter(key) if is_letter_key(key) else fmt.aprintf("Shift+%s", base, allocator = context.temp_allocator)

    case .Shift_Symbol:
        if shifted, ok := shift_symbol(key); ok do return shifted
        return fmt.aprintf("Shift+%s", base, allocator = context.temp_allocator)

    case .Shift_Explicit:
        name := base
        if is_letter_key(key) do name = upper_letter(key)
        return fmt.aprintf("Shift+%s", name, allocator = context.temp_allocator)
    }

    return base
}

help_sequence2 :: proc(first, second: sdl.Keycode) -> string {
    return fmt.aprintf("%s%s", key_base_name(first), key_base_name(second), allocator = context.temp_allocator)
}

help_chord :: proc(prefix: sdl.Keycode, prefix_mods: sdl.Keymod, suffix: sdl.Keycode) -> string {
    return fmt.aprintf(
        "%s %s",
        key_label(prefix, prefix_mods, .Plain),
        key_label(suffix, {}, .Plain),
        allocator = context.temp_allocator,
    )
}

help_line_spacing_label :: proc() -> string {
    label := fmt.aprintf("%.2f", f32(DEFAULT_LINE_SPACING), allocator = context.temp_allocator)
    if strings.has_suffix(label, "0") {
        label = label[:len(label) - 1]
    }
    return label
}

// Value for a help-template token. Returns false for unknown tokens.
help_token_value :: proc(name: string) -> (string, bool) {
    ctrl := sdl.KMOD_CTRL
    alt := sdl.KMOD_ALT
    shift := sdl.KMOD_SHIFT

    switch name {
    case "editor_name":           return EDITOR_NAME, true
    case "help_underline":
        return strings.repeat("=", len(EDITOR_NAME) + len(" - Help"), context.temp_allocator), true
    case "cmd_prompt":            return key_label(KEY_CMD_PROMPT, {}, .Plain), true
    case "insert":                return key_label(KEY_INSERT_BEFORE, {}, .Plain), true
    case "insert_line_start":     return key_label(KEY_INSERT_LINE_START, {}, .Shift_Letter), true
    case "append":                return key_label(KEY_APPEND, {}, .Plain), true
    case "append_line_end":       return key_label(KEY_APPEND_LINE_END, {}, .Shift_Letter), true
    case "open_below":            return key_label(KEY_OPEN_BELOW, {}, .Plain), true
    case "open_above":            return key_label(KEY_OPEN_ABOVE, {}, .Shift_Letter), true
    case "visual_toggle":         return key_label(KEY_VISUAL_TOGGLE, ctrl, .Plain), true
    case "select_line":           return key_label(KEY_SELECT_LINE, {}, .Upper), true
    case "left":                  return key_label(KEY_MOVE_LEFT, {}, .Plain), true
    case "down":                  return key_label(KEY_MOVE_DOWN, {}, .Plain), true
    case "up":                    return key_label(KEY_MOVE_UP, {}, .Plain), true
    case "right":                 return key_label(KEY_MOVE_RIGHT, {}, .Plain), true
    case "left_upper":            return key_label(KEY_MOVE_LEFT, {}, .Upper), true
    case "right_upper":           return key_label(KEY_MOVE_RIGHT, {}, .Upper), true
    case "line_start":            return key_label(KEY_LINE_START, shift, .Shift_Explicit), true
    case "line_end":              return key_label(KEY_LINE_END, shift, .Shift_Explicit), true
    case "zero":                  return key_label(KEY_LINE_START_ZERO, {}, .Plain), true
    case "dollar":                return key_label(KEY_LINE_END_DOLLAR, shift, .Shift_Symbol), true
    case "gg":                    return help_sequence2(KEY_GOTO, KEY_GOTO), true
    case "G":                     return key_label(KEY_FILE_END, shift, .Shift_Letter), true
    case "gd":                    return help_sequence2(KEY_GOTO, KEY_GOTO_DEFINITION), true
    case "word_forward":          return key_label(KEY_WORD_FORWARD, ctrl, .Plain), true
    case "word_backward":         return key_label(KEY_WORD_BACKWARD, ctrl, .Plain), true
    case "scope_down":            return key_label(KEY_SCOPE_DOWN, ctrl, .Plain), true
    case "scope_up":              return key_label(KEY_SCOPE_UP, ctrl, .Plain), true
    case "hover":                 return key_label(KEY_HOVER, shift, .Shift_Letter), true
    case "format_line":           return help_sequence2(KEY_FORMAT_LINE, KEY_FORMAT_LINE), true
    case "format_selection":      return key_label(KEY_FORMAT_SELECTION, {}, .Plain), true
    case "delete_char":           return key_label(KEY_DELETE_CHAR, {}, .Plain), true
    case "delete_selection":      return key_label(KEY_DELETE_SELECTION, {}, .Upper), true
    case "change_selection":      return key_label(KEY_CHANGE_SELECTION, {}, .Upper), true
    case "yank_selection":        return key_label(KEY_YANK_SELECTION, {}, .Upper), true
    case "yank_alt":              return key_label(KEY_YANK_ALT, alt, .Plain), true
    case "paste":                 return key_label(KEY_PASTE_CLIPBOARD, ctrl, .Plain), true
    case "paste_normal":          return key_label(KEY_PASTE_NORMAL, {}, .Plain), true
    case "save":                  return key_label(KEY_SAVE, ctrl, .Plain), true
    case "undo":                  return key_label(KEY_UNDO, {}, .Plain), true
    case "undo_alt":              return key_label(KEY_UNDO_ALT, ctrl, .Plain), true
    case "redo":                  return key_label(KEY_REDO, ctrl, .Plain), true
    case "move_line_down":        return key_label(KEY_MOVE_LINE_DOWN, alt, .Plain), true
    case "move_line_up":          return key_label(KEY_MOVE_LINE_UP, alt, .Plain), true
    case "completion_trigger":    return key_label(KEY_COMPLETION_TRIGGER, ctrl, .Plain), true
    case "zoom_in":               return key_label(KEY_ZOOM_IN, ctrl, .Plain), true
    case "zoom_out":              return key_label(KEY_ZOOM_OUT, ctrl, .Plain), true
    case "zoom_reset":            return key_label(KEY_ZOOM_RESET, ctrl, .Plain), true
    case "line_spacing_default":  return help_line_spacing_label(), true
    case "leader":                return key_label(KEY_LEADER, {}, .Plain), true
    case "files":                 return key_label(KEY_LEADER_FILES, {}, .Plain), true
    case "window_prefix":         return key_label(KEY_WINDOW_PREFIX, ctrl, .Plain), true
    case "pane_left":             return key_label(KEY_WINDOW_LEFT, {}, .Plain), true
    case "pane_down":             return key_label(KEY_WINDOW_DOWN, {}, .Plain), true
    case "pane_up":               return key_label(KEY_WINDOW_UP, {}, .Plain), true
    case "pane_right":            return key_label(KEY_WINDOW_RIGHT, {}, .Plain), true
    case "split_h":               return help_chord(KEY_WINDOW_PREFIX, ctrl, KEY_WINDOW_SPLIT_H), true
    case "split_v":               return help_chord(KEY_WINDOW_PREFIX, ctrl, KEY_WINDOW_SPLIT_V), true
    case "split_v_key":           return key_base_name(KEY_WINDOW_SPLIT_V), true
    case "pane_cycle":            return help_chord(KEY_WINDOW_PREFIX, ctrl, KEY_WINDOW_CYCLE), true
    case "pane_close":            return help_chord(KEY_WINDOW_PREFIX, ctrl, KEY_WINDOW_CLOSE), true
    case "pane_close_alt":        return help_chord(KEY_WINDOW_PREFIX, ctrl, KEY_WINDOW_CLOSE_ALT), true
    case "pane_close_alt_key":    return key_base_name(KEY_WINDOW_CLOSE_ALT), true
    case "dired_down":            return key_label(KEY_DIRED_DOWN, {}, .Plain), true
    case "dired_up":              return key_label(KEY_DIRED_UP, {}, .Plain), true
    case "dired_pages":
        down := key_label(KEY_DIRED_PAGE_DOWN, ctrl, .Plain)
        // Share the Ctrl+ prefix only when both suffixes are simple letters;
        // otherwise show the full chord so the modifier is not lost.
        if is_letter_key(KEY_DIRED_PAGE_DOWN) && is_letter_key(KEY_DIRED_PAGE_UP) {
            up := upper_letter(KEY_DIRED_PAGE_UP)
            return fmt.aprintf("%s/%s", down, up, allocator = context.temp_allocator), true
        }
        return fmt.aprintf(
            "%s/%s",
            down,
            key_label(KEY_DIRED_PAGE_UP, ctrl, .Plain),
            allocator = context.temp_allocator,
        ), true
    case "dired_open":            return key_label(KEY_DIRED_OPEN, {}, .Upper), true
    case "dired_parent":          return key_label(KEY_DIRED_PARENT, {}, .Plain), true
    case "dired_parent_alt":      return key_label(KEY_DIRED_PARENT_ALT, {}, .Plain), true
    case "dired_edit":            return key_label(KEY_DIRED_EDIT, {}, .Plain), true
    case "dired_sort":            return key_label(KEY_DIRED_SORT, {}, .Plain), true
    case "dired_sort_reverse":    return key_label(KEY_DIRED_SORT_REVERSE, shift, .Shift_Letter), true
    case "dired_quit":            return key_label(KEY_DIRED_QUIT, {}, .Plain), true
    case "compile_down":          return key_label(KEY_COMPILE_DOWN, {}, .Plain), true
    case "compile_up":            return key_label(KEY_COMPILE_UP, {}, .Plain), true
    case "compile_next_error":    return key_label(KEY_COMPILE_NEXT_ERROR, {}, .Plain), true
    case "compile_prev_error":    return key_label(KEY_COMPILE_PREV_ERROR, {}, .Plain), true
    case "compile_jump":          return key_label(KEY_COMPILE_JUMP, {}, .Upper), true
    case "compile_recompile":     return key_label(KEY_COMPILE_RECOMPILE, {}, .Plain), true
    case "compile_recompile_alt": return key_label(KEY_COMPILE_RECOMPILE_ALT, {}, .Plain), true
    case "compile_yank":          return key_label(KEY_COMPILE_YANK, {}, .Plain), true
    case "compile_yank_alt":      return key_label(KEY_COMPILE_YANK_ALT, alt, .Plain), true
    case "compile_yank_all":      return key_label(KEY_COMPILE_YANK_ALL, shift, .Shift_Letter), true
    case "compile_visual":        return key_label(KEY_COMPILE_VISUAL, {}, .Plain), true
    case "compile_quit":          return key_label(KEY_COMPILE_QUIT, {}, .Plain), true
    }
    return "", false
}

is_help_token_char :: proc(ch: byte) -> bool {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
}

// Dot-leader alignment target (0-based description column). Long labels fall
// back to a single separating space instead of shifting the whole line.
HELP_DESC_COLUMN :: 34

// Align one already-rendered help line. Lines without a ` .... ` leader are
// returned unchanged (cloned with the requested allocator).
help_align_line :: proc(line: string, allocator := context.allocator) -> string {
    dot_start := -1
    dot_end := -1
    for i := 1; i + 1 < len(line); i += 1 {
        if line[i] != '.' || line[i - 1] != ' ' do continue
        j := i
        for j < len(line) && line[j] == '.' do j += 1
        if j - i >= 2 && j < len(line) && line[j] == ' ' {
            dot_start = i
            dot_end = j
            break
        }
    }
    if dot_start < 0 do return strings.clone(line, allocator)

    left := strings.trim_right(line[:dot_start], " \t")
    desc := strings.trim_left(line[dot_end:], " \t")
    if desc == "" do return strings.clone(line, allocator)

    b: strings.Builder
    strings.builder_init(&b, 0, len(line) + 8, allocator)
    strings.write_string(&b, left)
    pad := HELP_DESC_COLUMN - len(left)
    if pad >= 3 {
        strings.write_byte(&b, ' ')
        for _ in 0 ..< pad - 2 do strings.write_byte(&b, '.')
        strings.write_byte(&b, ' ')
    } else {
        strings.write_byte(&b, ' ')
    }
    strings.write_string(&b, desc)
    return strings.to_string(b)
}

// Render the embedded help template, substituting {tokens} from config.odin.
// Unknown tokens, empty `{}`, and lone `{` are left untouched. Caller owns the
// returned string.
help_render :: proc(allocator := context.allocator) -> string {
    template := HELP_TEMPLATE
    b: strings.Builder
    strings.builder_init(&b, 0, len(template) * 2, allocator)

    i := 0
    for i < len(template) {
        if template[i] != '{' {
            strings.write_byte(&b, template[i])
            i += 1
            continue
        }

        j := i + 1
        for j < len(template) && is_help_token_char(template[j]) {
            j += 1
        }

        if j > i + 1 && j < len(template) && template[j] == '}' {
            if value, known := help_token_value(template[i + 1:j]); known {
                strings.write_string(&b, value)
                i = j + 1
                continue
            }
        }

        strings.write_byte(&b, '{')
        i += 1
    }

    raw := strings.to_string(b)
    lines := strings.split(raw, "\n", context.temp_allocator)
    aligned: strings.Builder
    strings.builder_init(&aligned, 0, len(raw) + 64, allocator)
    for line, idx in lines {
        strings.write_string(&aligned, help_align_line(line, context.temp_allocator))
        if idx + 1 < len(lines) do strings.write_byte(&aligned, '\n')
    }
    delete(raw, allocator)
    return strings.to_string(aligned)
}
