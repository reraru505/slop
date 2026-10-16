package main

import "core:os"
import "core:time"
import sdl "vendor:sdl3"

TARGET :: 16_660 * time.Microsecond
CODE_SAMPLE :: #load("main.odin", string)

App :: struct {
    window   : ^sdl.Window,
    renderer : ^sdl.Renderer,
    font     : Font,
    editor   : Editor,
    running  : bool,
}

load :: proc(app: ^App) {
    sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "wayland")

    if !sdl.CreateWindowAndRenderer("Odin Text Editor", 1024, 768, sdl.WINDOW_RESIZABLE, &app.window, &app.renderer) {
        panic("Failed to create SDL window and renderer")
    }

    app.font = load_font(app.renderer)

    initial_text := CODE_SAMPLE
    file_path := "main.odin"

    if len(os.args) > 1 {
        file_path = os.args[1]
        data, err := os.read_entire_file(file_path, context.allocator)
        if err == nil {
            initial_text = string(data)
        } else {
            initial_text = ""
        }
    }

    editor_init(&app.editor, &app.font, initial_text, file_path)
    app.running = true
}

update :: proc(app: ^App) {
    event: sdl.Event
    for sdl.PollEvent(&event) {
        if event.type == .QUIT {
            app.running = false
            break
        }

        editor_handle_event(&app.editor, &event, app.window)
    }
}

draw :: proc(app: ^App) {
    w, h: i32
    sdl.GetWindowSize(app.window, &w, &h)

    editor_render(&app.editor, app.renderer, &app.font, w, h)
    sdl.RenderPresent(app.renderer)
}

cleanup :: proc(app: ^App) {
    editor_destroy(&app.editor)
    sdl.DestroyRenderer(app.renderer)
    sdl.DestroyWindow(app.window)
    sdl.Quit()
}

main :: proc() {
    app: App
    load(&app)
    defer cleanup(&app)

    for app.running {
        frame_start := time.now()

        update(&app)
        draw(&app)

        elapsed := time.since(frame_start)
        remaining := TARGET - elapsed
        if remaining > 0 {
            time.sleep(remaining)
        }
    }
}
