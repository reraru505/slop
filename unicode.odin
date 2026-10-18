package main

import "core:unicode"
import "core:unicode/utf8"

// The editor stores cursor columns as UTF-8 byte offsets (the piece table and
// the LSP utf-8 position encoding are byte-based). These helpers keep motion
// and selection on rune boundaries without changing that representation.

// Previous rune boundary at or before `byte_col`.
utf8_prev_boundary :: proc(text: string, byte_col: int) -> int {
    i := clamp(byte_col, 0, len(text))
    if i == 0 do return 0
    i -= 1
    for i > 0 && !utf8.rune_start(text[i]) {
        i -= 1
    }
    return i
}

// Next rune boundary strictly after `byte_col`.
utf8_next_boundary :: proc(text: string, byte_col: int) -> int {
    if byte_col >= len(text) do return len(text)
    col := max(0, byte_col)
    _, size := utf8.decode_rune_in_string(text[col:])
    if size <= 0 do size = 1
    return min(len(text), col + size)
}

// Floor a byte column to a rune start.
utf8_clamp_boundary :: proc(text: string, byte_col: int) -> int {
    i := clamp(byte_col, 0, len(text))
    for i > 0 && i < len(text) && !utf8.rune_start(text[i]) {
        i -= 1
    }
    return i
}

// Terminal-style cell width: combining marks take no cell, East-Asian wide
// runes take two, everything else one.
rune_display_width :: proc(r: rune) -> int {
    if r == utf8.RUNE_ERROR do return 1
    if unicode.is_combining(r) do return 0
    width := unicode.normalized_east_asian_width(r)
    return 2 if width == 2 else 1
}

is_word_rune :: proc(r: rune) -> bool {
    return r == '_' || unicode.is_letter(r) || unicode.is_digit(r)
}

is_space_rune :: proc(r: rune) -> bool {
    return r == ' ' || r == '\t' || unicode.is_space(r)
}

// --- Editor-line variants ---------------------------------------------------

editor_rune_at :: proc(e: ^Editor, row, byte_col: int) -> (r: rune, size: int) {
    if e == nil do return utf8.RUNE_ERROR, 0
    line_len := editor_get_line_len(e, row)
    col := clamp(byte_col, 0, line_len)
    if col >= line_len do return utf8.RUNE_ERROR, 0

    start := pt_line_to_offset(&e.table, row)
    buf: [4]u8
    n := min(len(buf), line_len - col)
    for i in 0 ..< n {
        buf[i] = pt_byte_at(&e.table, start + col + i)
    }
    r, size = utf8.decode_rune(buf[:n])
    if size <= 0 do size = 1
    return r, size
}

editor_prev_rune_start :: proc(e: ^Editor, row, byte_col: int) -> int {
    line_len := editor_get_line_len(e, row)
    i := clamp(byte_col, 0, line_len)
    if i == 0 do return 0
    i -= 1
    start := pt_line_to_offset(&e.table, row)
    for i > 0 && !utf8.rune_start(pt_byte_at(&e.table, start + i)) {
        i -= 1
    }
    return i
}

editor_next_rune_end :: proc(e: ^Editor, row, byte_col: int) -> int {
    line_len := editor_get_line_len(e, row)
    i := clamp(byte_col, 0, line_len)
    if i >= line_len do return line_len
    _, size := editor_rune_at(e, row, i)
    if size <= 0 do size = 1
    return min(line_len, i + size)
}

editor_clamp_col_to_rune :: proc(e: ^Editor, row, byte_col: int) -> int {
    line_len := editor_get_line_len(e, row)
    col := clamp(byte_col, 0, line_len)
    start := pt_line_to_offset(&e.table, row)
    for col > 0 && col < line_len && !utf8.rune_start(pt_byte_at(&e.table, start + col)) {
        col -= 1
    }
    return col
}
