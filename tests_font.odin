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

    expect_close(t, font_natural_height(m), 40.0, "natural height")

    // 100% zoom, default spacing: line height equals the font's own metrics.
    // At BASE_FONT_SIZE=20 this is exactly 20 logical pixels (Ghostty parity).
    expect_close(t, font_scale_for(m, .HALF, 1.0), 0.5, "HALF scale")
    expect_close(t, font_scale_for(m, .QUAT, 1.0), 0.25, "QUAT scale")
    expect_close(t, font_line_height_for(m, .HALF, 1.0, 1.0), 20.0, "line height @1.0")
    expect_close(t, font_baseline_for(m, .HALF, 1.0, 1.0), 15.9665, "baseline @1.0")

    // Extra leading is split evenly above and below the glyph box.
    expect_close(t, font_line_height_for(m, .HALF, 1.0, 1.25), 25.0, "line height @1.25")
    expect_close(t, font_baseline_for(m, .HALF, 1.0, 1.25), 18.4665, "baseline @1.25")

    // Native-size bake: when the atlas equals BASE_FONT_SIZE (density 1,
    // zoom 1) the scale factor is exactly 1.0, so glyphs map 1:1 to pixels.
    native := Font_Metrics{bake_px = 20.0, ascent = 16.0, descent = 3.0, line_gap = 1.0, cell_width = 10.0}
    expect_close(t, font_scale_for(native, .HALF, 1.0), 1.0, "native scale")
    expect_close(t, font_line_height_for(native, .HALF, 1.0, 1.0), 20.0, "native line height")

    // At 2x density the atlas doubles while the logical zoom stays 1x.
    hidpi_native := Font_Metrics{bake_px = 40.0, ascent = 32.0, descent = 7.0, line_gap = 1.0, cell_width = 20.0}
    expect_close(t, font_scale_for(hidpi_native, .HALF, 1.0), 0.5, "2x density scale")
    expect_close(t, font_line_height_for(hidpi_native, .HALF, 1.0, 1.0), 20.0, "2x density line height")

    // UI zoom scales layout linearly.
    expect_close(t, font_line_height_for(m, .HALF, 2.0, 1.0), 40.0, "line height @200% zoom")
    expect_close(t, font_baseline_for(m, .HALF, 2.0, 1.0), 31.933, "baseline @200% zoom")
    expect_close(t, font_line_height_for(m, .QUAT, 1.0, 1.0), 10.0, "QUAT line height")

    // Baking at a different resolution (HiDPI) must not change logical layout:
    // both the metrics and the bake size scale together.
    hidpi := m
    hidpi.bake_px = 80.0
    hidpi.ascent *= 2.0
    hidpi.descent *= 2.0
    hidpi.cell_width *= 2.0
    expect_close(t, font_line_height_for(hidpi, .HALF, 1.0, 1.0), 20.0, "HiDPI line height")
    expect_close(t, font_baseline_for(hidpi, .HALF, 1.0, 1.0), 15.9665, "HiDPI baseline")
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
