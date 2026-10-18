package main

import "core:fmt"
import "core:math"
import "core:testing"
import sdl "vendor:sdl3"

expect_color_close :: proc(t: ^testing.T, got, want: f32) {
    testing.expectf(t, math.abs(got - want) < 1e-6, "expected %v, got %v", want, got)
}

@(test)
test_theme_hex_to_fcolor :: proc(t: ^testing.T) {
    c := hex_to_fcolor(0x336699)
    expect_color_close(t, c.r, 0.2)
    expect_color_close(t, c.g, 0.4)
    expect_color_close(t, c.b, 0.6)
    expect_color_close(t, c.a, 1.0)

    black := hex_to_fcolor(0x000000)
    expect_color_close(t, black.r, 0.0)
    expect_color_close(t, black.g, 0.0)
    expect_color_close(t, black.b, 0.0)
    expect_color_close(t, black.a, 1.0)

    white := hex_to_fcolor(0xFFFFFF)
    expect_color_close(t, white.r, 1.0)
    expect_color_close(t, white.g, 1.0)
    expect_color_close(t, white.b, 1.0)

    // Alpha is always opaque
    expect_color_close(t, white.a, 1.0)
    fmt.println("  ✓ [Theme] hex color decoding and opaque alpha verified")
}

theme_colors_valid :: proc(th: Theme) -> bool {
    colors := []sdl.FColor{
        th.bg, th.fg, th.gutter_bg, th.gutter_fg, th.gutter_active_fg,
        th.cursor_line_bg, th.selection_bg, th.status_bg, th.status_fg,
        th.status_inactive_bg, th.status_inactive_fg, th.cmd_bar_bg,
        th.border, th.cursor, th.keyword, th.type_name, th.fn_name,
        th.string_lit, th.number_lit, th.comment, th.directive, th.operator,
        th.punctuation, th.constant,
    }
    for c in colors {
        if c.r < 0 || c.r > 1 || c.g < 0 || c.g > 1 || c.b < 0 || c.b > 1 {
            return false
        }
        if math.abs(c.a - 1.0) > 1e-6 do return false
    }
    return true
}

@(test)
test_theme_all_variants :: proc(t: ^testing.T) {
    names: [dynamic]string
    defer delete(names)

    for id in ThemeId {
        th := theme_get(id)
        testing.expect_value(t, th.id, id)
        testing.expectf(t, th.name != "", "theme %v has an empty name", id)
        testing.expectf(t, theme_colors_valid(th), "theme %s has out-of-range colors", th.name)

        for existing in names {
            testing.expectf(t, existing != th.name, "duplicate theme name: %s", th.name)
        }
        append(&names, th.name)
    }

    testing.expect_value(t, len(names), 4)
    testing.expect_value(t, names[0], "gruber-darker")
    testing.expect_value(t, names[1], "naysayer")
    testing.expect_value(t, names[2], "kanagawa")
    testing.expect_value(t, names[3], "hemisu")

    // Spot-check that individual themes pick distinct backgrounds
    a := theme_get(.GruberDarker)
    b := theme_get(.Naysayer)
    testing.expect(t, a.bg != b.bg)
    fmt.println("  ✓ [Theme] all 4 themes have valid, distinct color tables")
}

@(test)
test_theme_from_name :: proc(t: ^testing.T) {
    id, ok := theme_from_name("gruber-darker")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.GruberDarker)

    id, ok = theme_from_name("gruber")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.GruberDarker)

    id, ok = theme_from_name("gruberdarker")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.GruberDarker)

    id, ok = theme_from_name("  GRUBER-DARKER  ")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.GruberDarker)

    id, ok = theme_from_name("Naysayer")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.Naysayer)

    id, ok = theme_from_name("KANAGAWA")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.Kanagawa)

    id, ok = theme_from_name("hemisu")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, id, ThemeId.Hemisu)

    // Unknown names fall back to the configured default theme but report failure
    id, ok = theme_from_name("solarized")
    testing.expect_value(t, ok, false)
    testing.expect_value(t, id, DEFAULT_THEME)

    id, ok = theme_from_name("")
    testing.expect_value(t, ok, false)
    testing.expect_value(t, id, DEFAULT_THEME)
    fmt.println("  ✓ [Theme] case-insensitive name lookup and fallback verified")
}
