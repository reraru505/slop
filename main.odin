package main

import "core:os"
import "core:time"
import sdl "vendor:sdl3"

TARGET :: 16_660 * time.Microsecond

AppView :: enum {
    Editor,
    Dired,
}

App :: struct {
    window   : ^sdl.Window,
    renderer : ^sdl.Renderer,
    font     : Font,
    editor   : Editor,
    dired    : Dired,
    view     : AppView,
    running  : bool,
}

app_open_file :: proc(app: ^App, file_path: string) {
    data, err := os.read_entire_file(file_path, context.allocator)
    initial_text := ""
    if err == nil {
        initial_text = string(data)
    }

    editor_destroy(&app.editor)
    editor_init(&app.editor, &app.font, initial_text, file_path)

    if err == nil {
        delete(data)
    }

    app.view = .Editor
}

app_open_dired :: proc(app: ^App, dir_path: string) {
    if dired_load_path(&app.dired, dir_path) {
        app.view = .Dired
    }
}

load :: proc(app: ^App) {
    sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "wayland")

    if !sdl.CreateWindowAndRenderer("Odin Text Editor", 1024, 768, sdl.WINDOW_RESIZABLE, &app.window, &app.renderer) {
        panic("Failed to create SDL window and renderer")
    }

    app.font = load_font(app.renderer)
    dired_init(&app.dired)
    editor_init(&app.editor, &app.font, "", "")

    target_path := "."
    if len(os.args) > 1 {
        target_path = os.args[1]
    }

    if os.is_dir(target_path) {
        app_open_dired(app, target_path)
    } else {
        app_open_file(app, target_path)
    }

    app.running = true
}

update :: proc(app: ^App) {
    event: sdl.Event
    for sdl.PollEvent(&event) {
        if event.type == .QUIT {
            app.running = false
            break
        }

        switch app.view {
        case .Dired:
            dired_handle_event(&app.dired, &event, app)
        case .Editor:
            editor_handle_event(&app.editor, &event, app.window, app)
        }
    }
}

draw :: proc(app: ^App) {
    w, h: i32
    sdl.GetWindowSize(app.window, &w, &h)

    switch app.view {
    case .Dired:
        dired_render(&app.dired, app.renderer, &app.font, w, h)
    case .Editor:
        editor_render(&app.editor, app.renderer, &app.font, w, h)
    }

    sdl.RenderPresent(app.renderer)
}

cleanup :: proc(app: ^App) {
    editor_destroy(&app.editor)
    dired_destroy(&app.dired)
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
