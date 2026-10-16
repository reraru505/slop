package main;

import sdl "vendor:sdl3";
import ttf "vendor:stb/truetype";

FONT_FILE    :: #load("CaskaydiaCoveNerdFont-Regular.ttf");
ATLAS_WIDTH  :: 2048 ;
ATLAS_HEIGHT :: 2048 ;
FONT_SIZE    :: 40   ;
FONT_START   :: 32   ;
FONT_COUNT   :: 96   ;
LINE_HEIGHT  :: 28.0 ;
FONT_SEP     :: 10   ;
 
FONT_SCALE :: enum{
   HALF ,
   QUAT ,
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
  
Font :: struct {
   texture     : ^sdl.Texture , 
   char_coords : [96]ttf.bakedchar,
   batcher     : TextBatcher ,

};

load_font :: proc(renderer : ^sdl.Renderer) -> Font {

   pixels := make([]u8 , ATLAS_WIDTH * ATLAS_HEIGHT);
   defer delete(pixels);

   char_coordinates : [96]ttf.bakedchar;

   result := ttf.BakeFontBitmap(
              raw_data(FONT_FILE ),
              0, FONT_SIZE , raw_data(pixels) , 
              ATLAS_WIDTH , ATLAS_HEIGHT , 
              FONT_START  , FONT_COUNT , 
              raw_data(&char_coordinates) ,
              );

   if result <= 0 {
      panic("Failed to load font atlas");
   }

   rgba := make([]u8, ATLAS_WIDTH * ATLAS_HEIGHT * 4);
   defer delete(rgba);

   for i in 0 ..< (ATLAS_WIDTH * ATLAS_HEIGHT) {
      alpha := pixels[i]      ;
      rgba[i * 4 + 0] = 255   ;   
      rgba[i * 4 + 1] = 255   ;   
      rgba[i * 4 + 2] = 255   ;   
      rgba[i * 4 + 3] = alpha ; 
   }

   texture := sdl.CreateTexture(renderer , .RGBA32 , .STATIC , ATLAS_WIDTH , ATLAS_HEIGHT);
   sdl.SetTextureBlendMode(texture , sdl.BLENDMODE_BLEND);
   sdl.SetTextureScaleMode(texture , .PIXELART);

   sdl.UpdateTexture(texture , nil , raw_data(rgba) , ATLAS_WIDTH * 4);

   batcher := init_text_batcher();

   return Font {
      texture = texture , 
      char_coords = char_coordinates ,
      batcher = batcher,
   };
}


push_text :: proc(
   font:     ^Font,       
   text:     string,
   pos :     Vec2 ,
   color:    sdl.FColor, 
   font_scale :   FONT_SCALE,
   left_margin : f32 ,
   atlas_w:  f32 = 2048.0,
   atlas_h:  f32 = 2048.0,
) {

   scale : f32 = 1.0

   switch font_scale {
   case .HALF : scale = 0.5 ;
   case .QUAT : scale = 0.25 ;
   }

   height : f32 = scale * FONT_SIZE + scale * FONT_SEP

   x := pos.x + left_margin * scale 
   y := pos.y + FONT_SIZE * scale

   for ch in text {
      
      // Handle newlines
      if ch == '\n' {
         x = pos.x + left_margin * scale
         y += height
         continue
      }

      // Only draw printable ASCII
      if ch < 32 || ch > 126 {
         continue
      }

      b := font.char_coords[ch - 32]

      // Screen quad positions
      x0 := x + b.xoff * scale
      y0 := y + b.yoff * scale 
      x1 := x0 + f32(b.x1 - b.x0) * scale
      y1 := y0 + f32(b.y1 - b.y0) * scale

      // Atlas UVs (normalized 0.0 to 1.0)
      u0 := f32(b.x0) / atlas_w
      v0 := f32(b.y0) / atlas_h
      u1 := f32(b.x1) / atlas_w
      v1 := f32(b.y1) / atlas_h

      base := i32(len(font.batcher.vertices))

      // Append 4 vertices aka 2 triangles
      append(&font.batcher.vertices,
         sdl.Vertex{ position = {x0, y0}, tex_coord = {u0, v0}, color = color }, // Top-Left
         sdl.Vertex{ position = {x1, y0}, tex_coord = {u1, v0}, color = color }, // Top-Right
         sdl.Vertex{ position = {x1, y1}, tex_coord = {u1, v1}, color = color }, // Bot-Right
         sdl.Vertex{ position = {x0, y1}, tex_coord = {u0, v1}, color = color }, // Bot-Left
      )

      // make index buffer
      append(&font.batcher.indices,
         base + 0, base + 1, base + 2,
         base + 0, base + 2, base + 3,
      )

      x += b.xadvance * scale
   }
}

get_font_scale_multiplier :: proc(font_scale: FONT_SCALE) -> f32 {
   switch font_scale {
   case .HALF: return 0.5
   case .QUAT: return 0.25
   }
   return 1.0
}

get_line_height :: proc(font_scale: FONT_SCALE) -> f32 {
   scale := get_font_scale_multiplier(font_scale)
   return scale * FONT_SIZE + scale * FONT_SEP
}

push_line :: proc(
   font:       ^Font,
   text:       string,
   pos:        Vec2,
   color:      sdl.FColor,
   font_scale: FONT_SCALE,
   atlas_w:    f32 = 2048.0,
   atlas_h:    f32 = 2048.0,
) -> f32 {
   scale := get_font_scale_multiplier(font_scale)
   x := pos.x
   y := pos.y + FONT_SIZE * scale

   for ch in text {
      if ch == '\t' {
         space_b := font.char_coords[' ' - 32]
         x += space_b.xadvance * scale * 4
         continue
      }

      if ch < 32 || ch > 126 {
         continue
      }

      b := font.char_coords[ch - 32]

      x0 := x + b.xoff * scale
      y0 := y + b.yoff * scale
      x1 := x0 + f32(b.x1 - b.x0) * scale
      y1 := y0 + f32(b.y1 - b.y0) * scale

      u0 := f32(b.x0) / atlas_w
      v0 := f32(b.y0) / atlas_h
      u1 := f32(b.x1) / atlas_w
      v1 := f32(b.y1) / atlas_h

      base := i32(len(font.batcher.vertices))

      append(&font.batcher.vertices,
         sdl.Vertex{ position = {x0, y0}, tex_coord = {u0, v0}, color = color },
         sdl.Vertex{ position = {x1, y0}, tex_coord = {u1, v0}, color = color },
         sdl.Vertex{ position = {x1, y1}, tex_coord = {u1, v1}, color = color },
         sdl.Vertex{ position = {x0, y1}, tex_coord = {u0, v1}, color = color },
      )

      append(&font.batcher.indices,
         base + 0, base + 1, base + 2,
         base + 0, base + 2, base + 3,
      )

      x += b.xadvance * scale
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
   atlas_w:         f32 = 2048.0,
   atlas_h:         f32 = 2048.0,
) -> f32 {
   scale := get_font_scale_multiplier(font_scale)
   x := pos.x
   y := pos.y + FONT_SIZE * scale

   col_idx := 0
   for ch in text {
      char_color := highlight_color if col_idx == highlight_col else color

      if ch == '\t' {
         space_b := font.char_coords[' ' - 32]
         x += space_b.xadvance * scale * 4
         col_idx += 1
         continue
      }

      if ch < 32 || ch > 126 {
         col_idx += 1
         continue
      }

      b := font.char_coords[ch - 32]

      x0 := x + b.xoff * scale
      y0 := y + b.yoff * scale
      x1 := x0 + f32(b.x1 - b.x0) * scale
      y1 := y0 + f32(b.y1 - b.y0) * scale

      u0 := f32(b.x0) / atlas_w
      v0 := f32(b.y0) / atlas_h
      u1 := f32(b.x1) / atlas_w
      v1 := f32(b.y1) / atlas_h

      base := i32(len(font.batcher.vertices))

      append(&font.batcher.vertices,
         sdl.Vertex{ position = {x0, y0}, tex_coord = {u0, v0}, color = char_color },
         sdl.Vertex{ position = {x1, y0}, tex_coord = {u1, v0}, color = char_color },
         sdl.Vertex{ position = {x1, y1}, tex_coord = {u1, v1}, color = char_color },
         sdl.Vertex{ position = {x0, y1}, tex_coord = {u0, v1}, color = char_color },
      )

      append(&font.batcher.indices,
         base + 0, base + 1, base + 2,
         base + 0, base + 2, base + 3,
      )

      x += b.xadvance * scale
      col_idx += 1
   }

   return x
}

find_biggest_advance :: proc (font : ^Font ) -> f32  {
   biggest : f32 = 0;
   
   for ch in 32 ..= 126 {
      b := font.char_coords[ch - 32]
      
      if biggest < b.xadvance  {
         biggest = b.xadvance
      }
   }

   return biggest
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


