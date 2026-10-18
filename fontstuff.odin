package main

import "core:c"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// 96 ASCII glyphs, ligature tiles, and lazily rasterized Unicode glyphs share
// one atlas. 4096x4096 covers several thousand fallback glyphs at 4K density.
ATLAS_WIDTH  :: 4096 ;
ATLAS_HEIGHT :: 4096 ;
FONT_START   :: 32   ;
FONT_COUNT   :: 96   ;
// Transparent border around each glyph so linear filtering cannot sample a
// neighbouring glyph (Ghostty uses the same trick).
ATLAS_PADDING :: 1 ;

// Multiplier on the font's natural cell height (ascent + descent + line gap).
// 1.0 is the font/terminal-emulator default (Ghostty parity); raise it for
// extra breathing room. Adjustable at runtime with :linespace.
line_spacing : f32 = DEFAULT_LINE_SPACING ;

// Dynamic global zoom scale (1.0 = 100%)
global_ui_scale : f32 = DEFAULT_UI_SCALE ;

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
// ascent is the font-specific baseline offset used to place fallback glyphs.
Glyph :: struct {
   u0, v0, u1, v1: f32,
   w, h:          int,
   ascent:        f32,
}

// A shaped sequence such as "->" or "=>" drawn as a single tile. Ligatures are
// ordered longest-first so the longest match wins.
Ligature :: struct {
   text:  string,
   glyph: Glyph,
}

// Common Cascadia Code ligatures. Keep each span short; they occupy the same
// number of cells as their characters so cursor/selection columns are unchanged.
LIGATURE_SEQUENCES :: []string{
   // 4 cells
   ">>>=", "<<<=",
   // 3 cells
   "<=>", "<->", "===", "!==", "=/=", ">>>", "<<<", "-->", "<--", "=>>",
   "=<<", "..<", "...", ":::", "///", "/**", "~~>", "??=",
   // 2 cells
   "->", "<-", "=>", "<=", ">=", "==", "!=", "|>", "<|", "||", "&&", "?.",
   "//", "/*", "*/", "..", "~~", "><", "|]", "[|", "?:", "??",
}

Font :: struct {
   texture        : ^sdl.Texture ,
   glyphs         : [FONT_COUNT]Glyph ,
   extra_glyphs   : map[rune]Glyph ,
   ligatures      : [dynamic]Ligature ,
   batcher        : TextBatcher ,
   metrics        : Font_Metrics ,
   // Kept alive for lazy rasterization of non-ASCII runes.
   face           : ^ttf.Font ,
   fallback_faces : [dynamic]^ttf.Font ,
   atlas          : []u8 ,
   pack_x         : int ,
   pack_y         : int ,
   row_h          : int ,
}

// SDL_ttf is initialized once and kept alive while the font face is open.
g_ttf_initialized := false

// Rasterize the embedded font with FreeType (through SDL_ttf) at the native
// physical size, with light hinting. This mirrors Ghostty's defaults: hinted
// grayscale glyphs at exact pixel size, integer cell metrics, no downscaling.
load_font :: proc(renderer : ^sdl.Renderer, window : ^sdl.Window = nil) -> Font {

   density : f32 = 1.0
   if window != nil {
      density = max(1.0, sdl.GetWindowPixelDensity(window))
   }
   target_px := max(1.0, f32(BASE_FONT_SIZE) * density * global_ui_scale)

   if !g_ttf_initialized {
      if !ttf.Init() {
         panic("Failed to initialize SDL_ttf")
      }
      g_ttf_initialized = true
   }

   io := sdl.IOFromConstMem(raw_data(FONT_FILE), uint(len(FONT_FILE)))
   if io == nil {
      panic("Failed to open embedded font")
   }
   face := ttf.OpenFontIO(io, true, target_px)
   if face == nil {
      panic("Failed to load embedded font")
   }

   fallback_faces: [dynamic]^ttf.Font
   for path in FALLBACK_FONT_PATHS {
      cpath := strings.clone_to_cstring(path, context.temp_allocator)
      if fb := ttf.OpenFont(cpath, target_px); fb != nil {
         ttf.SetFontHinting(fb, .LIGHT)
         append(&fallback_faces, fb)
      }
   }

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
         ascent = ascent,
      }

      pack_x += gw + ATLAS_PADDING * 2
      row_h = max(row_h, gh)
   }

   // Shaped ligature tiles. SDL_ttf runs HarfBuzz shaping, so rendering the
   // whole sequence produces Cascadia's contextual alternates. Each tile is
   // still drawn in exactly len(sequence) cells, preserving cursor columns.
   ligatures: [dynamic]Ligature
   for seq in LIGATURE_SEQUENCES {
      raw := ttf.RenderText_Blended(face, raw_data(seq), c.size_t(len(seq)), white)
      if raw == nil do continue
      surface := sdl.ConvertSurface(raw, .RGBA32)
      sdl.DestroySurface(raw)
      if surface == nil do continue

      gw := int(surface.w)
      gh := int(surface.h)
      expected := f32(len(seq)) * cell_width
      if gw <= 0 || gh <= 0 || abs(f32(gw) - expected) > 2.0 {
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

      append(&ligatures, Ligature{
         text = strings.clone(seq),
         glyph = Glyph{
            u0 = f32(gx) / f32(ATLAS_WIDTH),
            v0 = f32(gy) / f32(ATLAS_HEIGHT),
            u1 = f32(gx + gw) / f32(ATLAS_WIDTH),
            v1 = f32(gy + gh) / f32(ATLAS_HEIGHT),
            w  = gw,
            h  = gh,
            ascent = ascent,
         },
      })

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
      texture        = texture,
      glyphs         = glyphs,
      extra_glyphs   = make(map[rune]Glyph),
      ligatures      = ligatures,
      batcher        = init_text_batcher(),
      metrics        = metrics,
      face           = face,
      fallback_faces = fallback_faces,
      atlas          = atlas,
      pack_x         = pack_x,
      pack_y         = pack_y,
      row_h          = row_h,
   }
}

// font_free_contents releases everything owned by a loaded font. TTF itself
// stays initialized while the editor lives; font_destroy quits it.
font_free_contents :: proc(font: ^Font, quit_ttf := false) {
   if font == nil do return
   if font.texture != nil {
      sdl.DestroyTexture(font.texture)
      font.texture = nil
   }
   for l in font.ligatures do delete(l.text)
   delete(font.ligatures)
   font.ligatures = nil
   delete(font.batcher.vertices)
   delete(font.batcher.indices)
   font.batcher.vertices = nil
   font.batcher.indices = nil
   delete(font.extra_glyphs)
   font.extra_glyphs = nil
   if font.face != nil {
      ttf.CloseFont(font.face)
      font.face = nil
   }
   for fb in font.fallback_faces {
      ttf.CloseFont(fb)
   }
   delete(font.fallback_faces)
   font.fallback_faces = nil
   delete(font.atlas)
   font.atlas = nil
   if quit_ttf && g_ttf_initialized {
      ttf.Quit()
      g_ttf_initialized = false
   }
}

font_destroy :: proc(font: ^Font) {
   font_free_contents(font, quit_ttf = true)
}

// Re-bake the atlas at the current UI scale. Glyphs are rasterized natively,
// so this is what keeps them sharp when the zoom level changes.
font_reload :: proc(font: ^Font, renderer: ^sdl.Renderer, window: ^sdl.Window = nil) {
   if font == nil || renderer == nil do return
   fresh := load_font(renderer, window)
   font_free_contents(font)
   font^ = fresh
}

// Pack one rasterized surface into the atlas and upload only its rectangle.
// Returns false when the atlas is full or the surface is unusable.
font_pack_surface :: proc(font: ^Font, surface: ^sdl.Surface, ascent: f32) -> (Glyph, bool) {
   gw := int(surface.w)
   gh := int(surface.h)
   if gw <= 0 || gh <= 0 do return {}, false

   if font.pack_x + gw + ATLAS_PADDING > ATLAS_WIDTH {
      font.pack_x = ATLAS_PADDING
      font.pack_y += font.row_h + ATLAS_PADDING * 2
      font.row_h = 0
   }
   if font.pack_y + gh + ATLAS_PADDING > ATLAS_HEIGHT do return {}, false

   gx := font.pack_x
   gy := font.pack_y

   _ = sdl.LockSurface(surface)
   pixels := ([^]u8)(surface.pixels)
   pitch := int(surface.pitch)
   for yy in 0 ..< gh {
      for xx in 0 ..< gw {
         alpha := pixels[yy * pitch + xx * 4 + 3]
         di := ((gy + yy) * ATLAS_WIDTH + (gx + xx)) * 4
         font.atlas[di + 0] = 255
         font.atlas[di + 1] = 255
         font.atlas[di + 2] = 255
         font.atlas[di + 3] = alpha
      }
   }
   sdl.UnlockSurface(surface)

   rect := sdl.Rect{i32(gx), i32(gy), i32(gw), i32(gh)}
   src := rawptr(&font.atlas[(gy * ATLAS_WIDTH + gx) * 4])
   _ = sdl.UpdateTexture(font.texture, &rect, src, ATLAS_WIDTH * 4)

   font.pack_x += gw + ATLAS_PADDING * 2
   font.row_h = max(font.row_h, gh)

   return Glyph{
      u0 = f32(gx) / f32(ATLAS_WIDTH),
      v0 = f32(gy) / f32(ATLAS_HEIGHT),
      u1 = f32(gx + gw) / f32(ATLAS_WIDTH),
      v1 = f32(gy + gh) / f32(ATLAS_HEIGHT),
      w  = gw,
      h  = gh,
      ascent = ascent,
   }, true
}

// Lazily rasterize a non-ASCII rune, trying fallback faces when the primary
// font has no glyph. The result is cached in extra_glyphs (including the
// replacement glyph for characters no configured font covers).
font_ensure_glyph :: proc(font: ^Font, r: rune) -> (Glyph, bool) {
   if font == nil do return {}, false
   if g, ok := font.extra_glyphs[r]; ok do return g, true
   if font.texture == nil do return {}, false

   white := sdl.Color{255, 255, 255, 255}
   faces: [16]^ttf.Font
   face_count := 0
   if font.face != nil {
      faces[face_count] = font.face
      face_count += 1
   }
   for fb in font.fallback_faces {
      if face_count >= len(faces) do break
      faces[face_count] = fb
      face_count += 1
   }

   chosen: ^ttf.Font = nil
   for i in 0 ..< face_count {
      if ttf.FontHasGlyph(faces[i], u32(r)) {
         chosen = faces[i]
         break
      }
   }

   // Unknown rune: try U+FFFD, then fall back to '?' so text still reads.
   render_rune := r
   if chosen == nil {
      render_rune = 0xFFFD
      for i in 0 ..< face_count {
         if ttf.FontHasGlyph(faces[i], u32(render_rune)) {
            chosen = faces[i]
            break
         }
      }
   }
   if chosen == nil {
      render_rune = '?'
      for i in 0 ..< face_count {
         if ttf.FontHasGlyph(faces[i], u32(render_rune)) {
            chosen = faces[i]
            break
         }
      }
   }
   if chosen == nil do return {}, false

   raw := ttf.RenderGlyph_Blended(chosen, u32(render_rune), white)
   if raw == nil do return {}, false
   surface := sdl.ConvertSurface(raw, .RGBA32)
   sdl.DestroySurface(raw)
   if surface == nil do return {}, false
   defer sdl.DestroySurface(surface)

   glyph, ok := font_pack_surface(font, surface, f32(ttf.GetFontAscent(chosen)))
   if !ok do return {}, false
   font.extra_glyphs[r] = glyph
   return glyph, true
}

// Look up a rune, rasterizing non-ASCII glyphs on first use.
font_lookup_glyph :: proc(font: ^Font, r: rune) -> (Glyph, bool) {
   if font == nil do return {}, false
   if r >= FONT_START && r < FONT_START + FONT_COUNT {
      g := font.glyphs[r - FONT_START]
      return g, g.w > 0 && g.h > 0
   }
   return font_ensure_glyph(font, r)
}

// Append one atlas tile as a quad.
push_glyph :: proc(font: ^Font, g: Glyph, x, y, w, h: f32, color: sdl.FColor) {
   if g.w <= 0 || g.h <= 0 || w <= 0 || h <= 0 do return
   base := i32(len(font.batcher.vertices))
   append(&font.batcher.vertices,
      sdl.Vertex{ position = {x, y},     tex_coord = {g.u0, g.v0}, color = color },
      sdl.Vertex{ position = {x + w, y}, tex_coord = {g.u1, g.v0}, color = color },
      sdl.Vertex{ position = {x + w, y + h}, tex_coord = {g.u1, g.v1}, color = color },
      sdl.Vertex{ position = {x, y + h}, tex_coord = {g.u0, g.v1}, color = color },
   )
   append(&font.batcher.indices,
      base + 0, base + 1, base + 2,
      base + 0, base + 2, base + 3,
   )
}

// Find the longest ligature starting at pos. Ligatures are skipped when the
// span crosses a syntax-color boundary, and the caller may veto a match when
// the cursor highlight falls inside it.
is_ligature_start :: proc(b: byte) -> bool {
   switch b {
   case '-', '=', '!', '<', '>', '|', '/', '.', ':', '?', '~', '#', '&', '[', '*':
      return true
   }
   return false
}

find_ligature :: proc(font: ^Font, text: string, pos: int, colors: []sdl.FColor) -> (Glyph, int, bool) {
   if pos >= len(text) do return {}, 0, false
   if !is_ligature_start(text[pos]) do return {}, 0, false

   color := sdl.FColor{}
   if colors != nil && pos < len(colors) do color = colors[pos]

   for lig in font.ligatures {
      n := len(lig.text)
      if pos + n > len(text) do continue
      if text[pos:pos + n] != lig.text do continue
      if colors != nil {
         uniform := true
         for k in 0 ..< n {
            if pos + k >= len(colors) || colors[pos + k] != color {
               uniform = false
               break
            }
         }
         if !uniform do continue
      }
      return lig.glyph, n, true
   }
   return {}, 0, false
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

   i := 0
   for i < len(text) {
      r, size := utf8.decode_rune_in_string(text[i:])
      if size <= 0 {
         r = utf8.RUNE_ERROR
         size = 1
      }
      if r == '\n' {
         x = pos.x + left_margin * scale
         baseline += line_h
         top += line_h
         i += size
         continue
      }
      if r == '\t' {
         x += cell_w * 4
         i += size
         continue
      }

      if r >= 32 && r <= 126 {
         if lig, n, ok := find_ligature(font, text, i, nil); ok {
            push_glyph(font, lig, x, top, f32(n) * cell_w, f32(lig.h) * scale, color)
            x += f32(n) * cell_w
            i += n
            continue
         }
      }

      if g, ok := font_lookup_glyph(font, r); ok {
         glyph_top := baseline - g.ascent * scale
         push_glyph(font, g, x, glyph_top, f32(g.w) * scale, f32(g.h) * scale, color)
      }
      x += f32(rune_display_width(r)) * cell_w
      i += size
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

   i := 0
   for i < len(text) {
      r, size := utf8.decode_rune_in_string(text[i:])
      if size <= 0 {
         r = utf8.RUNE_ERROR
         size = 1
      }
      if r == '\t' {
         x += cell_w * 4
         i += size
         continue
      }

      if r >= 32 && r <= 126 {
         if lig, n, ok := find_ligature(font, text, i, nil); ok {
            push_glyph(font, lig, x, top, f32(n) * cell_w, f32(lig.h) * scale, color)
            x += f32(n) * cell_w
            i += n
            continue
         }
      }

      if g, ok := font_lookup_glyph(font, r); ok {
         glyph_top := top + (font.metrics.ascent - g.ascent) * scale
         push_glyph(font, g, x, glyph_top, f32(g.w) * scale, f32(g.h) * scale, color)
      }
      x += f32(rune_display_width(r)) * cell_w
      i += size
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

   i := 0
   for i < len(text) {
      r, size := utf8.decode_rune_in_string(text[i:])
      if size <= 0 {
         r = utf8.RUNE_ERROR
         size = 1
      }
      base_color := char_colors[i] if (char_colors != nil && i < len(char_colors)) else color
      char_color := highlight_color if (highlight_col >= i && highlight_col < i + size) else base_color

      if r == '\t' {
         x += cell_w * 4
         i += size
         continue
      }

      if r >= 32 && r <= 126 {
         if lig, n, ok := find_ligature(font, text, i, char_colors); ok {
            // Keep the cursor-highlighted character visible rather than hiding
            // it inside a ligature tile.
            if !(highlight_col >= i && highlight_col < i + n) {
               push_glyph(font, lig, x, top, f32(n) * cell_w, f32(lig.h) * scale, char_color)
               x += f32(n) * cell_w
               i += n
               continue
            }
         }
      }

      if g, ok := font_lookup_glyph(font, r); ok {
         glyph_top := top + (font.metrics.ascent - g.ascent) * scale
         push_glyph(font, g, x, glyph_top, f32(g.w) * scale, f32(g.h) * scale, char_color)
      }
      x += f32(rune_display_width(r)) * cell_w
      i += size
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
