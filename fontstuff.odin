package main

import "core:c"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

FONT_FILE    :: #load("assets/CaskaydiaCoveNerdFont-Regular.ttf");
// 96 ASCII glyphs at even 2x-density/250%-zoom sizes fit comfortably in
// 1024x1024, keeping the per-rebake texture upload cheap.
ATLAS_WIDTH  :: 1024 ;
ATLAS_HEIGHT :: 1024 ;
FONT_START   :: 32   ;
FONT_COUNT   :: 96   ;
// Transparent border around each glyph so linear filtering cannot sample a
// neighbouring glyph (Ghostty uses the same trick).
ATLAS_PADDING :: 1 ;

// Logical pixels occupied by the font's ascent+descent at 100% UI scale.
// Layout is derived from the font's real metrics at this size.
BASE_FONT_SIZE :: 20.0 ;

// Multiplier on the font's natural cell height (ascent + descent + line gap).
// 1.0 is the font/terminal-emulator default (Ghostty parity); raise it for
// extra breathing room. Adjustable at runtime with :linespace.
line_spacing : f32 = 1.0 ;

// Dynamic global zoom scale (1.0 = 100%)
global_ui_scale : f32 = 1.0 ;

FONT_SCALE :: enum{
   HALF ,
   QUAT ,
}

// Vertical metrics in atlas (physical) pixels. Text layout is derived from
// these values rather than from hand-tuned constants.
Font_Metrics :: struct {
   bake_px:    f32, // physical ascent+descent+line gap the atlas was baked at
   ascent:     f32, // above the baseline
   descent:    f32, // below the baseline (positive)
   line_gap:   f32, // extra spacing recommended by the font
   cell_width: f32, // monospace advance (integer pixels from FreeType)
}

// Metrics for the single application font. load_font replaces these; the
// defaults keep layout helpers usable before (or without) a renderer.
g_font_metrics := Font_Metrics{
   bake_px    = 40.0,
   ascent     = 31.933,
   descent    = 8.067,
   line_gap   = 0.0,
   cell_width = 20.168,
};

font_natural_height :: proc(m: Font_Metrics) -> f32 {
   return m.ascent + m.descent + max(0.0, m.line_gap)
}

font_scale_for :: proc(m: Font_Metrics, font_scale: FONT_SCALE, ui_scale: f32) -> f32 {
   if m.bake_px <= 0 do return 0.0
   base := f32(BASE_FONT_SIZE) / m.bake_px
   switch font_scale {
   case .HALF: return base * ui_scale
   case .QUAT: return base * 0.5 * ui_scale
   }
   return base * ui_scale
}

font_line_height_for :: proc(m: Font_Metrics, font_scale: FONT_SCALE, ui_scale, spacing: f32) -> f32 {
   return font_natural_height(m) * spacing * font_scale_for(m, font_scale, ui_scale)
}

font_baseline_for :: proc(m: Font_Metrics, font_scale: FONT_SCALE, ui_scale, spacing: f32) -> f32 {
   natural := font_natural_height(m)
   extra := natural * (spacing - 1.0)
   // Center the font's natural line box inside the spaced cell so glyphs do not
   // sit low above the cursor/selection rectangle.
   return (extra * 0.5 + m.ascent) * font_scale_for(m, font_scale, ui_scale)
}

Vec2 :: struct {
   x , y : f32 ,
}

// batching the draw calls
TextBatcher :: struct {
   vertices: [dynamic]sdl.Vertex,
   indices:  [dynamic]i32,
}

init_text_batcher :: proc(initial_capacity := 4096) -> TextBatcher {
   return TextBatcher{
      vertices = make([dynamic]sdl.Vertex, 0, initial_capacity * 4),
      indices  = make([dynamic]i32,        0, initial_capacity * 6),
   }
}

// One atlas tile. w/h are physical pixels; UVs are normalized atlas coords.
Glyph :: struct {
   u0, v0, u1, v1: f32,
   w, h:          int,
}

Font :: struct {
   texture : ^sdl.Texture ,
   glyphs  : [FONT_COUNT]Glyph ,
   batcher : TextBatcher ,
   metrics : Font_Metrics ,
}

// Rasterize the embedded font with FreeType (through SDL_ttf) at the native
// physical size, with light hinting. This mirrors Ghostty's defaults: hinted
// grayscale glyphs at exact pixel size, integer cell metrics, no downscaling.
load_font :: proc(renderer : ^sdl.Renderer, window : ^sdl.Window = nil) -> Font {

   density : f32 = 1.0
   if window != nil {
      density = max(1.0, sdl.GetWindowPixelDensity(window))
   }
   target_px := max(1.0, f32(BASE_FONT_SIZE) * density * global_ui_scale)

   if !ttf.Init() {
      panic("Failed to initialize SDL_ttf")
   }
   defer ttf.Quit()

   io := sdl.IOFromConstMem(raw_data(FONT_FILE), uint(len(FONT_FILE)))
   if io == nil {
      panic("Failed to open embedded font")
   }
   face := ttf.OpenFontIO(io, true, target_px)
   if face == nil {
      panic("Failed to load embedded font")
   }
   defer ttf.CloseFont(face)

   // Match BASE_FONT_SIZE semantics: the font's line height (ascent+descent+
   // line gap) should equal target_px physical pixels.
   ttf.SetFontHinting(face, .LIGHT)
   initial_height := f32(ttf.GetFontHeight(face))
   if initial_height > 0 && abs(initial_height - target_px) > 0.001 {
      _ = ttf.SetFontSize(face, target_px * target_px / initial_height)
      ttf.SetFontHinting(face, .LIGHT)
   }

   ascent  := f32(ttf.GetFontAscent(face))
   descent := -f32(ttf.GetFontDescent(face)) // SDL_ttf reports a negative descent
   line_skip := f32(ttf.GetFontLineSkip(face))
   line_gap := max(0.0, line_skip - (ascent + descent))

   minx, maxx, miny, maxy, advance: c.int
   cell_width := target_px * 0.5
   if ttf.GetGlyphMetrics(face, ' ', &minx, &maxx, &miny, &maxy, &advance) && advance > 0 {
      cell_width = f32(advance)
   }

   atlas := make([]u8, ATLAS_WIDTH * ATLAS_HEIGHT * 4)
   defer delete(atlas)

   glyphs: [FONT_COUNT]Glyph
   white := sdl.Color{255, 255, 255, 255}
   pack_x, pack_y, row_h := ATLAS_PADDING, ATLAS_PADDING, 0

   for i in 0 ..< FONT_COUNT {
      codepoint := u32(FONT_START + i)
      raw_surface := ttf.RenderGlyph_Blended(face, codepoint, white)
      if raw_surface == nil do continue

      // Blended surfaces may be palettized; normalize to RGBA32 so the alpha
      // channel is directly readable.
      surface := sdl.ConvertSurface(raw_surface, .RGBA32)
      sdl.DestroySurface(raw_surface)
      if surface == nil do continue

      gw := int(surface.w)
      gh := int(surface.h)
      if gw <= 0 || gh <= 0 {
         sdl.DestroySurface(surface)
         continue
      }

      if pack_x + gw + ATLAS_PADDING > ATLAS_WIDTH {
         pack_x = ATLAS_PADDING
         pack_y += row_h + ATLAS_PADDING * 2
         row_h = 0
      }
      if pack_y + gh + ATLAS_PADDING > ATLAS_HEIGHT {
         panic("Font atlas is full")
      }

      gx := pack_x
      gy := pack_y

      _ = sdl.LockSurface(surface)
      pixels := ([^]u8)(surface.pixels)
      pitch := int(surface.pitch)
      for yy in 0 ..< gh {
         for xx in 0 ..< gw {
            alpha := pixels[yy * pitch + xx * 4 + 3]
            di := ((gy + yy) * ATLAS_WIDTH + (gx + xx)) * 4
            atlas[di + 0] = 255
            atlas[di + 1] = 255
            atlas[di + 2] = 255
            atlas[di + 3] = alpha
         }
      }
      sdl.UnlockSurface(surface)
      sdl.DestroySurface(surface)

      glyphs[i] = Glyph{
         u0 = f32(gx) / f32(ATLAS_WIDTH),
         v0 = f32(gy) / f32(ATLAS_HEIGHT),
         u1 = f32(gx + gw) / f32(ATLAS_WIDTH),
         v1 = f32(gy + gh) / f32(ATLAS_HEIGHT),
         w  = gw,
         h  = gh,
      }

      pack_x += gw + ATLAS_PADDING * 2
      row_h = max(row_h, gh)
   }

   texture := sdl.CreateTexture(renderer, .RGBA32, .STATIC, ATLAS_WIDTH, ATLAS_HEIGHT)
   sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
   // Glyphs are rasterized at native size, so linear filtering is effectively
   // 1:1 here; it only matters while zooming.
   sdl.SetTextureScaleMode(texture, .LINEAR)
   sdl.UpdateTexture(texture, nil, raw_data(atlas), ATLAS_WIDTH * 4)

   metrics := Font_Metrics{
      bake_px    = ascent + descent + line_gap,
      ascent     = ascent,
      descent    = descent,
      line_gap   = line_gap,
      cell_width = cell_width,
   }
   g_font_metrics = metrics

   return Font {
      texture = texture,
      glyphs  = glyphs,
      batcher = init_text_batcher(),
      metrics = metrics,
   }
}

// Re-bake the atlas at the current UI scale. Glyphs are rasterized natively,
// so this is what keeps them sharp when the zoom level changes.
font_reload :: proc(font: ^Font, renderer: ^sdl.Renderer, window: ^sdl.Window = nil) {
   if font == nil || renderer == nil do return
   fresh := load_font(renderer, window)
   if font.texture != nil do sdl.DestroyTexture(font.texture)
   delete(font.batcher.vertices)
   delete(font.batcher.indices)
   font^ = fresh
}

push_text :: proc(
   font:     ^Font,
   text:     string,
   pos :     Vec2 ,
   color:    sdl.FColor,
   font_scale :   FONT_SCALE,
   left_margin : f32 ,
) {
   scale := font_scale_for(font.metrics, font_scale, global_ui_scale)
   line_h := font_natural_height(font.metrics) * line_spacing * scale
   cell_w := font.metrics.cell_width * scale
   x := pos.x + left_margin * scale
   baseline := pos.y + font_baseline(font, font_scale)
   top := baseline - font.metrics.ascent * scale

   for ch in text {
      if ch == '\n' {
         x = pos.x + left_margin * scale
         baseline += line_h
         top += line_h
         continue
      }
      if ch == '\t' {
         x += cell_w * 4
         continue
      }
      if ch < 32 || ch > 126 {
         continue
      }

      g := font.glyphs[ch - 32]
      if g.w <= 0 || g.h <= 0 {
         x += cell_w
         continue
      }

      x0 := x
      y0 := top
      x1 := x0 + f32(g.w) * scale
      y1 := y0 + f32(g.h) * scale

      base := i32(len(font.batcher.vertices))
      append(&font.batcher.vertices,
         sdl.Vertex{ position = {x0, y0}, tex_coord = {g.u0, g.v0}, color = color },
         sdl.Vertex{ position = {x1, y0}, tex_coord = {g.u1, g.v0}, color = color },
         sdl.Vertex{ position = {x1, y1}, tex_coord = {g.u1, g.v1}, color = color },
         sdl.Vertex{ position = {x0, y1}, tex_coord = {g.u0, g.v1}, color = color },
      )
      append(&font.batcher.indices,
         base + 0, base + 1, base + 2,
         base + 0, base + 2, base + 3,
      )

      x += cell_w
   }
}

get_font_scale_multiplier :: proc(font_scale: FONT_SCALE) -> f32 {
   return font_scale_for(g_font_metrics, font_scale, global_ui_scale)
}

get_line_height :: proc(font_scale: FONT_SCALE) -> f32 {
   return font_line_height_for(g_font_metrics, font_scale, global_ui_scale, line_spacing)
}

// Distance from the top of a line cell to the text baseline, in screen pixels.
font_baseline :: proc(font: ^Font, font_scale: FONT_SCALE) -> f32 {
   m := g_font_metrics
   if font != nil do m = font.metrics
   return font_baseline_for(m, font_scale, global_ui_scale, line_spacing)
}

push_line :: proc(
   font:       ^Font,
   text:       string,
   pos:        Vec2,
   color:      sdl.FColor,
   font_scale: FONT_SCALE,
) -> f32 {
   scale := font_scale_for(font.metrics, font_scale, global_ui_scale)
   cell_w := font.metrics.cell_width * scale
   x := pos.x
   top := pos.y + font_baseline(font, font_scale) - font.metrics.ascent * scale

   for ch in text {
      if ch == '\t' {
         x += cell_w * 4
         continue
      }
      if ch < 32 || ch > 126 {
         continue
      }

      g := font.glyphs[ch - 32]
      if g.w <= 0 || g.h <= 0 {
         x += cell_w
         continue
      }

      x0 := x
      y0 := top
      x1 := x0 + f32(g.w) * scale
      y1 := y0 + f32(g.h) * scale

      base := i32(len(font.batcher.vertices))
      append(&font.batcher.vertices,
         sdl.Vertex{ position = {x0, y0}, tex_coord = {g.u0, g.v0}, color = color },
         sdl.Vertex{ position = {x1, y0}, tex_coord = {g.u1, g.v0}, color = color },
         sdl.Vertex{ position = {x1, y1}, tex_coord = {g.u1, g.v1}, color = color },
         sdl.Vertex{ position = {x0, y1}, tex_coord = {g.u0, g.v1}, color = color },
      )
      append(&font.batcher.indices,
         base + 0, base + 1, base + 2,
         base + 0, base + 2, base + 3,
      )

      x += cell_w
   }

   return x
}

push_editor_line :: proc(
   font:            ^Font,
   text:            string,
   pos:             Vec2,
   color:           sdl.FColor,
   font_scale:      FONT_SCALE,
   highlight_col:   int = -1,
   highlight_color: sdl.FColor = {},
   char_colors:     []sdl.FColor = nil,
) -> f32 {
   scale := font_scale_for(font.metrics, font_scale, global_ui_scale)
   cell_w := font.metrics.cell_width * scale
   x := pos.x
   top := pos.y + font_baseline(font, font_scale) - font.metrics.ascent * scale

   col_idx := 0
   for ch in text {
      base_color := char_colors[col_idx] if (char_colors != nil && col_idx < len(char_colors)) else color
      char_color := highlight_color if col_idx == highlight_col else base_color

      if ch == '\t' {
         x += cell_w * 4
         col_idx += 1
         continue
      }

      if ch < 32 || ch > 126 {
         col_idx += 1
         continue
      }

      g := font.glyphs[ch - 32]
      if g.w <= 0 || g.h <= 0 {
         x += cell_w
         col_idx += 1
         continue
      }

      x0 := x
      y0 := top
      x1 := x0 + f32(g.w) * scale
      y1 := y0 + f32(g.h) * scale

      base := i32(len(font.batcher.vertices))
      append(&font.batcher.vertices,
         sdl.Vertex{ position = {x0, y0}, tex_coord = {g.u0, g.v0}, color = char_color },
         sdl.Vertex{ position = {x1, y0}, tex_coord = {g.u1, g.v0}, color = char_color },
         sdl.Vertex{ position = {x1, y1}, tex_coord = {g.u1, g.v1}, color = char_color },
         sdl.Vertex{ position = {x0, y1}, tex_coord = {g.u0, g.v1}, color = char_color },
      )
      append(&font.batcher.indices,
         base + 0, base + 1, base + 2,
         base + 0, base + 2, base + 3,
      )

      x += cell_w
      col_idx += 1
   }

   return x
}

// Advance of the monospace cell in atlas pixels.
font_cell_width :: proc(font: ^Font) -> f32 {
   if font == nil do return 10.0
   return font.metrics.cell_width > 0 ? font.metrics.cell_width : 10.0
}

flush_text :: proc(
   font : ^Font ,
   renderer: ^sdl.Renderer,
) {
   if len(font.batcher.vertices) == 0 do return

      // ONE call to render the entire screen of code!
      sdl.RenderGeometry(
         renderer,
         font.texture,
         raw_data(font.batcher.vertices), i32(len(font.batcher.vertices)),
         raw_data(font.batcher.indices),  i32(len(font.batcher.indices)),
      )

      // Reset counts for the next frame (keeps memory allocated!)
      clear(&font.batcher.vertices)

      clear(&font.batcher.indices)
}
