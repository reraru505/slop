package main

import sdl "vendor:sdl3"
import time "core:time"

CursorShape :: enum {
    Bar,
    Block,
}

Cursor :: struct {
    col   : int,
    row   : int,
    shape : CursorShape,
    color : sdl.FColor,
}

cursor_is_visible :: proc(cursor: ^Cursor, start_time: time.Time) -> bool {
    return true
}

render_cursor :: proc(
    cursor     : ^Cursor,
    renderer   : ^sdl.Renderer,
    cx, cy     : f32,
    char_w     : f32,
    line_h     : f32,
    start_time : time.Time,
) {
    if !cursor_is_visible(cursor, start_time) do return

    cw: f32 = 2.0
    if cursor.shape == .Block {
        cw = char_w
    }

    rect := sdl.FRect{
        x = cx,
        y = cy,
        w = cw,
        h = line_h,
    }

    sdl.SetRenderDrawColorFloat(renderer, cursor.color.r, cursor.color.g, cursor.color.b, cursor.color.a)
    sdl.RenderFillRect(renderer, &rect)
}
