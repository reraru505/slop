package main

import sdl "vendor:sdl3"
import "core:strings"

ThemeId :: enum {
    GruberDarker,
    Naysayer,
    Kanagawa,
    Hemisu,
}

// Keep this in sync with ThemeId; used for cycling and completion.
THEME_IDS :: [?]ThemeId{.GruberDarker, .Naysayer, .Kanagawa, .Hemisu}
THEME_NAMES :: [?]string{"gruber-darker", "naysayer", "kanagawa", "hemisu"}
THEME_COUNT :: len(THEME_IDS)

// Compile-time default theme

Theme :: struct {
    name               : string,
    id                 : ThemeId,
    // UI Colors
    bg                 : sdl.FColor,
    fg                 : sdl.FColor,
    gutter_bg          : sdl.FColor,
    gutter_fg          : sdl.FColor,
    gutter_active_fg   : sdl.FColor,
    cursor_line_bg     : sdl.FColor,
    selection_bg       : sdl.FColor,
    status_bg          : sdl.FColor,
    status_fg          : sdl.FColor,
    status_inactive_bg : sdl.FColor,
    status_inactive_fg : sdl.FColor,
    cmd_bar_bg         : sdl.FColor,
    border             : sdl.FColor,
    cursor             : sdl.FColor,
    // Syntax Token Colors
    keyword            : sdl.FColor,
    type_name          : sdl.FColor,
    fn_name            : sdl.FColor,
    string_lit         : sdl.FColor,
    number_lit         : sdl.FColor,
    comment            : sdl.FColor,
    directive          : sdl.FColor,
    operator           : sdl.FColor,
    punctuation        : sdl.FColor,
    constant           : sdl.FColor,
}

hex_to_fcolor :: proc(hex: u32) -> sdl.FColor {
    r := f32((hex >> 16) & 0xFF) / 255.0
    g := f32((hex >> 8) & 0xFF) / 255.0
    b := f32(hex & 0xFF) / 255.0
    return sdl.FColor{r, g, b, 1.0}
}

theme_get :: proc(id: ThemeId) -> Theme {
    switch id {
    case .GruberDarker:
        return Theme{
            name               = "gruber-darker",
            id                 = .GruberDarker,
            bg                 = hex_to_fcolor(0x181818),
            fg                 = hex_to_fcolor(0xe4e4ef),
            gutter_bg          = hex_to_fcolor(0x181818),
            gutter_fg          = hex_to_fcolor(0x52494e),
            gutter_active_fg   = hex_to_fcolor(0xffdd33),
            cursor_line_bg     = hex_to_fcolor(0x282828),
            selection_bg       = hex_to_fcolor(0x453d41),
            status_bg          = hex_to_fcolor(0x282828),
            status_fg          = hex_to_fcolor(0xe4e4ef),
            status_inactive_bg = hex_to_fcolor(0x202020),
            status_inactive_fg = hex_to_fcolor(0xa89984),
            cmd_bar_bg         = hex_to_fcolor(0x181818),
            border             = hex_to_fcolor(0x3a3a3a),
            cursor             = hex_to_fcolor(0xffdd33),
            keyword            = hex_to_fcolor(0xffdd33),
            type_name          = hex_to_fcolor(0x95a99f),
            fn_name            = hex_to_fcolor(0x96a6c8),
            string_lit         = hex_to_fcolor(0x73c936),
            number_lit         = hex_to_fcolor(0x9e95c7),
            comment            = hex_to_fcolor(0xcc8c3c),
            directive          = hex_to_fcolor(0x95a99f),
            operator           = hex_to_fcolor(0xe4e4ef),
            punctuation        = hex_to_fcolor(0xe4e4ef),
            constant           = hex_to_fcolor(0xffdd33),
        }

    case .Naysayer:
        return Theme{
            name               = "naysayer",
            id                 = .Naysayer,
            bg                 = hex_to_fcolor(0x062329),
            fg                 = hex_to_fcolor(0xd1b897),
            gutter_bg          = hex_to_fcolor(0x062329),
            gutter_fg          = hex_to_fcolor(0x126367),
            gutter_active_fg   = hex_to_fcolor(0xffffff),
            cursor_line_bg     = hex_to_fcolor(0x0b3335),
            selection_bg       = hex_to_fcolor(0x0000aa),
            status_bg          = hex_to_fcolor(0x0b3335),
            status_fg          = hex_to_fcolor(0xd1b897),
            status_inactive_bg = hex_to_fcolor(0x04191d),
            status_inactive_fg = hex_to_fcolor(0x126367),
            cmd_bar_bg         = hex_to_fcolor(0x062329),
            border             = hex_to_fcolor(0x126367),
            cursor             = hex_to_fcolor(0xffffff),
            keyword            = hex_to_fcolor(0xffffff),
            type_name          = hex_to_fcolor(0xd1b897),
            fn_name            = hex_to_fcolor(0xffffff),
            string_lit         = hex_to_fcolor(0x2ec90c),
            number_lit         = hex_to_fcolor(0x7ad0c6),
            comment            = hex_to_fcolor(0x44b340),
            directive          = hex_to_fcolor(0x8cde94),
            operator           = hex_to_fcolor(0x8cde94),
            punctuation        = hex_to_fcolor(0x8cde94),
            constant           = hex_to_fcolor(0x7ad0c6),
        }

    case .Kanagawa:
        return Theme{
            name               = "kanagawa",
            id                 = .Kanagawa,
            bg                 = hex_to_fcolor(0x1F1F28),
            fg                 = hex_to_fcolor(0xDCD7BA),
            gutter_bg          = hex_to_fcolor(0x1F1F28),
            gutter_fg          = hex_to_fcolor(0x727169),
            gutter_active_fg   = hex_to_fcolor(0xC8C093),
            cursor_line_bg     = hex_to_fcolor(0x2A2A37),
            selection_bg       = hex_to_fcolor(0x2D4F67),
            status_bg          = hex_to_fcolor(0x16161D),
            status_fg          = hex_to_fcolor(0xC8C093),
            status_inactive_bg = hex_to_fcolor(0x181820),
            status_inactive_fg = hex_to_fcolor(0x727169),
            cmd_bar_bg         = hex_to_fcolor(0x16161D),
            border             = hex_to_fcolor(0x363646),
            cursor             = hex_to_fcolor(0xC8C093),
            keyword            = hex_to_fcolor(0x957FB8),
            type_name          = hex_to_fcolor(0x7AA89F),
            fn_name            = hex_to_fcolor(0x7E9CD8),
            string_lit         = hex_to_fcolor(0x98BB6C),
            number_lit         = hex_to_fcolor(0xD27E99),
            comment            = hex_to_fcolor(0x727169),
            directive          = hex_to_fcolor(0xE46876),
            operator           = hex_to_fcolor(0xC0A36E),
            punctuation        = hex_to_fcolor(0x9CABCA),
            constant           = hex_to_fcolor(0xFFA066),
        }

    case .Hemisu:
        return Theme{
            name               = "hemisu",
            id                 = .Hemisu,
            bg                 = hex_to_fcolor(0x000000),
            fg                 = hex_to_fcolor(0xEEEEEE),
            gutter_bg          = hex_to_fcolor(0x000000),
            gutter_fg          = hex_to_fcolor(0x444444),
            gutter_active_fg   = hex_to_fcolor(0xEEEEEE),
            cursor_line_bg     = hex_to_fcolor(0x111111),
            selection_bg       = hex_to_fcolor(0x222222),
            status_bg          = hex_to_fcolor(0x111111),
            status_fg          = hex_to_fcolor(0xEEEEEE),
            status_inactive_bg = hex_to_fcolor(0x000000),
            status_inactive_fg = hex_to_fcolor(0x777777),
            cmd_bar_bg         = hex_to_fcolor(0x000000),
            border             = hex_to_fcolor(0x333333),
            cursor             = hex_to_fcolor(0xEEEEEE),
            keyword            = hex_to_fcolor(0x9FD3E6),
            type_name          = hex_to_fcolor(0xECE1C8),
            fn_name            = hex_to_fcolor(0x9FD3E6),
            string_lit         = hex_to_fcolor(0xB1D631),
            number_lit         = hex_to_fcolor(0xD65E76),
            comment            = hex_to_fcolor(0x777777),
            directive          = hex_to_fcolor(0x538192),
            operator           = hex_to_fcolor(0xBBBBBB),
            punctuation        = hex_to_fcolor(0x999999),
            constant           = hex_to_fcolor(0xD65E76),
        }
    }
    return theme_get(DEFAULT_THEME)
}

theme_from_name :: proc(name: string) -> (ThemeId, bool) {
    lower := strings.to_lower(strings.trim_space(name), context.temp_allocator)
    switch lower {
    case "gruber", "gruber-darker", "gruberdarker":
        return .GruberDarker, true
    case "naysayer":
        return .Naysayer, true
    case "kanagawa":
        return .Kanagawa, true
    case "hemisu":
        return .Hemisu, true
    }
    return DEFAULT_THEME, false
}
