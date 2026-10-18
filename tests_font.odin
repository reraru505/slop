package main

import "core:fmt"
import "core:math"
import "core:testing"
import "core:strings"
import sdl "vendor:sdl3"

font_metrics_fixture :: proc() -> Font_Metrics {
    // Values measured from the embedded Caskaydia Cove Nerd Font at a 40px bake.
    return Font_Metrics{
        bake_px    = 40.0,
        ascent     = 31.933,
        descent    = 8.067,
        line_gap   = 0.0,
        cell_width = 20.168,
    }
}

expect_close :: proc(t: ^testing.T, got, want: f32, what: string) {
    testing.expectf(t, math.abs(got - want) < 1e-3, "%s: expected %v, got %v", what, want, got)
}

@(test)
test_font_metrics_line_layout :: proc(t: ^testing.T) {
    m := font_metrics_fixture()
    base := f32(BASE_FONT_SIZE) / m.bake_px
    logical := f32(BASE_FONT_SIZE)

    expect_close(t, font_natural_height(m), 40.0, "natural height")

    // 100% zoom, default spacing: line height equals the font's own metrics.
    // The fixture's natural height matches its bake size, so this is exactly
    // BASE_FONT_SIZE logical pixels (Ghostty parity).
    expect_close(t, font_scale_for(m, .HALF, 1.0), base, "HALF scale")
    expect_close(t, font_scale_for(m, .QUAT, 1.0), base * 0.5, "QUAT scale")
    expect_close(t, font_line_height_for(m, .HALF, 1.0, 1.0), logical, "line height @1.0")
    expect_close(t, font_baseline_for(m, .HALF, 1.0, 1.0), 31.933 * base, "baseline @1.0")

    // Extra leading is split evenly above and below the glyph box.
    expect_close(t, font_line_height_for(m, .HALF, 1.0, 1.25), logical * 1.25, "line height @1.25")
    expect_close(t, font_baseline_for(m, .HALF, 1.0, 1.25), 36.933 * base, "baseline @1.25")

    // Native-size bake: the atlas matches BASE_FONT_SIZE at density 1 and
    // zoom 1, so glyphs map 1:1 to pixels.
    native := Font_Metrics{bake_px = 20.0, ascent = 16.0, descent = 3.0, line_gap = 1.0, cell_width = 10.0}
    expect_close(t, font_scale_for(native, .HALF, 1.0), f32(BASE_FONT_SIZE) / 20.0, "native scale")
    expect_close(t, font_line_height_for(native, .HALF, 1.0, 1.0), logical, "native line height")

    // At 2x density the atlas doubles while the logical zoom stays 1x.
    hidpi_native := Font_Metrics{bake_px = 40.0, ascent = 32.0, descent = 7.0, line_gap = 1.0, cell_width = 20.0}
    expect_close(t, font_scale_for(hidpi_native, .HALF, 1.0), base, "2x density scale")
    expect_close(t, font_line_height_for(hidpi_native, .HALF, 1.0, 1.0), logical, "2x density line height")

    // UI zoom scales layout linearly.
    expect_close(t, font_line_height_for(m, .HALF, 2.0, 1.0), logical * 2.0, "line height @200% zoom")
    expect_close(t, font_baseline_for(m, .HALF, 2.0, 1.0), 31.933 * base * 2.0, "baseline @200% zoom")
    expect_close(t, font_line_height_for(m, .QUAT, 1.0, 1.0), logical * 0.5, "QUAT line height")

    // Baking at a different resolution (HiDPI) must not change logical layout:
    // both the metrics and the bake size scale together.
    hidpi := m
    hidpi.bake_px = 80.0
    hidpi.ascent *= 2.0
    hidpi.descent *= 2.0
    hidpi.cell_width *= 2.0
    expect_close(t, font_line_height_for(hidpi, .HALF, 1.0, 1.0), logical, "HiDPI line height")
    expect_close(t, font_baseline_for(hidpi, .HALF, 1.0, 1.0), 63.866 * f32(BASE_FONT_SIZE) / 80.0, "HiDPI baseline")
    fmt.println("  ✓ [Font] line height and baseline derive from font metrics")
}

@(test)
test_font_ligature_sequences_sorted :: proc(t: ^testing.T) {
    seqs := LIGATURE_SEQUENCES
    for i in 1 ..< len(seqs) {
        testing.expectf(
            t,
            len(seqs[i - 1]) >= len(seqs[i]),
            "ligature list is not longest-first at %d",
            i,
        )
    }
    fmt.println("  ✓ [Font] ligature table is ordered longest-first")
}

@(test)
test_font_ligature_matching :: proc(t: ^testing.T) {
    f: Font
    append(&f.ligatures, Ligature{text = strings.clone("<=>"), glyph = Glyph{w = 3, h = 10}})
    append(&f.ligatures, Ligature{text = strings.clone("->"), glyph = Glyph{w = 2, h = 10}})
    defer {
        for l in f.ligatures do delete(l.text)
        delete(f.ligatures)
    }

    g, n, ok := find_ligature(&f, "a->b", 1, nil)
    testing.expect_value(t, ok, true)
    testing.expect_value(t, n, 2)
    testing.expect_value(t, g.w, 2)

    _, n2, ok2 := find_ligature(&f, "<=>", 0, nil)
    testing.expect_value(t, ok2, true)
    testing.expect_value(t, n2, 3)

    // A syntax-color boundary disables the ligature.
    split_colors := []sdl.FColor{
        {1.0, 0.0, 0.0, 1.0},
        {0.0, 1.0, 0.0, 1.0},
        {0.0, 1.0, 0.0, 1.0},
    }
    _, _, split_ok := find_ligature(&f, "->", 0, split_colors)
    testing.expect_value(t, split_ok, false)

    uniform_colors := []sdl.FColor{
        {1.0, 0.0, 0.0, 1.0},
        {1.0, 0.0, 0.0, 1.0},
    }
    _, n4, uniform_ok := find_ligature(&f, "->", 0, uniform_colors)
    testing.expect_value(t, uniform_ok, true)
    testing.expect_value(t, n4, 2)
    fmt.println("  ✓ [Font] ligature matching respects length order and color runs")
}

@(test)
test_font_cell_width :: proc(t: ^testing.T) {
    testing.expect_value(t, font_cell_width(nil), 10.0)

    empty: Font
    testing.expect_value(t, font_cell_width(&empty), 10.0) // zero atlas falls back

    f: Font
    f.metrics.cell_width = 20.168
    expect_close(t, font_cell_width(&f), 20.168, "cell width")
    fmt.println("  ✓ [Font] column width comes from the monospace advance")
}

@(test)
test_font_ligature_table_has_reachable_starts :: proc(t: ^testing.T) {
    for seq in LIGATURE_SEQUENCES {
        testing.expectf(t, len(seq) > 0, "empty ligature sequence")
        if len(seq) > 0 {
            testing.expectf(t, is_ligature_start(seq[0]), "unreachable ligature %q", seq)
        }
    }
    fmt.println("  ✓ [Font] every ligature sequence has a reachable start byte")
}

@(test)
test_font_rune_widths_and_glyph_lookup :: proc(t: ^testing.T) {
    testing.expect_value(t, rune_display_width('a'), 1)
    testing.expect_value(t, rune_display_width('é'), 1)
    testing.expect_value(t, rune_display_width('日'), 2)
    testing.expect_value(t, rune_display_width(0x0301), 0) // combining acute
    testing.expect_value(t, rune_display_width('😀'), 2)

    f: Font
    f.extra_glyphs = make(map[rune]Glyph)
    defer delete(f.extra_glyphs)
    f.glyphs['A' - FONT_START] = Glyph{w = 4, h = 6, ascent = 8, u1 = 0.1, v1 = 0.1}
    f.extra_glyphs['é'] = Glyph{w = 4, h = 6, ascent = 8, u1 = 0.2, v1 = 0.2}

    g, ok := font_lookup_glyph(&f, 'A')
    testing.expect_value(t, ok, true)
    testing.expect_value(t, g.w, 4)
    g2, ok2 := font_lookup_glyph(&f, 'é')
    testing.expect_value(t, ok2, true)
    testing.expect_value(t, g2.h, 6)
    _, ok3 := font_lookup_glyph(&f, '日')
    testing.expect_value(t, ok3, false) // no face/texture available in this fixture

    fmt.println("  ✓ [Font] rune cell widths and ASCII/lazy glyph lookup")
}

RUN_SDL_FONT_TESTS :: #config(ODIN_TEST_SDL_FONT, false)

when RUN_SDL_FONT_TESTS {
@(test)
test_font_lazy_glyph_rasterization :: proc(t: ^testing.T) {
    _ = sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "dummy")
    if !sdl.Init({.VIDEO}) do return
    defer sdl.Quit()

    window: ^sdl.Window
    renderer: ^sdl.Renderer
    if !sdl.CreateWindowAndRenderer("font-test", 320, 240, {.HIDDEN}, &window, &renderer) {
        fmt.println("SDL renderer unavailable, skipping font rasterization test")
        return
    }
    defer {
        sdl.DestroyRenderer(renderer)
        sdl.DestroyWindow(window)
    }

    f := load_font(renderer, window)
    defer font_destroy(&f)

    ascii, ascii_ok := font_lookup_glyph(&f, 'A')
    testing.expect_value(t, ascii_ok, true)
    testing.expect(t, ascii.w > 0)

    cjk, cjk_ok := font_lookup_glyph(&f, '日')
    testing.expect_value(t, cjk_ok, true)
    testing.expect(t, cjk.w > 0)
    _, cached_ok := f.extra_glyphs['日']
    testing.expect_value(t, cached_ok, true)

    emoji, emoji_ok := font_lookup_glyph(&f, '😀')
    testing.expect_value(t, emoji_ok, true) // replacement glyph when unavailable
    testing.expect(t, emoji.w > 0)

    // Wide cells advance two cells; combining marks advance zero.
    start_x: f32 = 100.0
    end_x := push_editor_line(&f, "é日", Vec2{start_x, 0}, sdl.FColor{1, 1, 1, 1}, .HALF)
    cell := font_cell_width(&f) * get_font_scale_multiplier(.HALF)
    testing.expect(t, abs(end_x - (start_x + 3 * cell)) < 0.1, "wide runes must advance two cells")
    combined_end := push_editor_line(&f, "é", Vec2{start_x, 0}, sdl.FColor{1, 1, 1, 1}, .HALF)
    testing.expect(t, abs(combined_end - (start_x + cell)) < 0.1, "combining marks must not advance")
    fmt.println("  ✓ [Font] lazy Unicode glyphs rasterize into the atlas")
}
}
