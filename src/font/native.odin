package font

import c "core:c"

FcConfig :: struct {}
FcPattern :: struct {}
FcResult :: enum c.int { Match, No_Match, Type_Mismatch, No_Id, Out_Of_Memory }
FcMatchKind :: enum c.int { Pattern, Font, Scan }

foreign import fontconfig "system:fontconfig"

@(default_calling_convention = "c")
foreign fontconfig {
	FcInitLoadConfigAndFonts :: proc() -> ^FcConfig ---
	FcConfigDestroy :: proc(config: ^FcConfig) ---
	FcNameParse :: proc(name: [^]u8) -> ^FcPattern ---
	FcPatternDestroy :: proc(pattern: ^FcPattern) ---
	FcConfigSubstitute :: proc(config: ^FcConfig, pattern: ^FcPattern, kind: FcMatchKind) -> c.int ---
	FcDefaultSubstitute :: proc(pattern: ^FcPattern) ---
	FcFontMatch :: proc(config: ^FcConfig, pattern: ^FcPattern, result: ^FcResult) -> ^FcPattern ---
	FcPatternGetString :: proc(pattern: ^FcPattern, object: cstring, index: c.int, value: ^[^]u8) -> FcResult ---
	FcPatternGetInteger :: proc(pattern: ^FcPattern, object: cstring, index: c.int, value: ^c.int) -> FcResult ---
}

FT_LibraryRec :: struct {}
FT_Library :: ^FT_LibraryRec
FT_Face :: ^FT_FaceRec
FT_GlyphSlot :: ^FT_GlyphSlotRec
FT_Size :: ^FT_SizeRec

FT_Generic :: struct {
	data: rawptr,
	finalizer: rawptr,
}

FT_Vector :: struct { x, y: c.long }
FT_BBox :: struct { x_min, y_min, x_max, y_max: c.long }
FT_Bitmap_Size :: struct {
	height, width: i16,
	size, x_ppem, y_ppem: c.long,
}

FT_Glyph_Metrics :: struct {
	width, height: c.long,
	hori_bearing_x, hori_bearing_y, hori_advance: c.long,
	vert_bearing_x, vert_bearing_y, vert_advance: c.long,
}

FT_Bitmap :: struct {
	rows: c.uint,
	width: c.uint,
	pitch: c.int,
	buffer: [^]u8,
	num_grays: u16,
	pixel_mode: u8,
	palette_mode: u8,
	palette: rawptr,
}

FT_Size_Metrics :: struct {
	x_ppem, y_ppem: u16,
	x_scale, y_scale: c.long,
	ascender, descender, height, max_advance: c.long,
}

FT_SizeRec :: struct {
	face: FT_Face,
	generic: FT_Generic,
	metrics: FT_Size_Metrics,
	internal: rawptr,
}

FT_FaceRec :: struct {
	num_faces, face_index, face_flags, style_flags, num_glyphs: c.long,
	family_name, style_name: cstring,
	num_fixed_sizes: c.int,
	available_sizes: ^FT_Bitmap_Size,
	num_charmaps: c.int,
	charmaps: rawptr,
	generic: FT_Generic,
	bbox: FT_BBox,
	units_per_em: u16,
	ascender, descender, height: i16,
	max_advance_width, max_advance_height: i16,
	underline_position, underline_thickness: i16,
	glyph: FT_GlyphSlot,
	size: FT_Size,
	charmap: rawptr,
}

FT_GlyphSlotRec :: struct {
	library: FT_Library,
	face: FT_Face,
	next: FT_GlyphSlot,
	glyph_index: c.uint,
	generic: FT_Generic,
	metrics: FT_Glyph_Metrics,
	linear_hori_advance, linear_vert_advance: c.long,
	advance: FT_Vector,
	format: u32,
	bitmap: FT_Bitmap,
	bitmap_left, bitmap_top: c.int,
}

FT_LOAD_RENDER :: c.int(1 << 2)
FT_LOAD_COLOR :: c.int(1 << 20)
FT_PIXEL_MODE_MONO :: u8(1)
FT_PIXEL_MODE_GRAY :: u8(2)
FT_PIXEL_MODE_BGRA :: u8(7)

foreign import freetype "system:freetype"

@(default_calling_convention = "c")
foreign freetype {
	FT_Init_FreeType :: proc(library: ^FT_Library) -> c.int ---
	FT_Done_FreeType :: proc(library: FT_Library) -> c.int ---
	FT_New_Face :: proc(library: FT_Library, path: cstring, face_index: c.long, face: ^FT_Face) -> c.int ---
	FT_Done_Face :: proc(face: FT_Face) -> c.int ---
	FT_Set_Pixel_Sizes :: proc(face: FT_Face, width, height: c.uint) -> c.int ---
	FT_Get_Char_Index :: proc(face: FT_Face, codepoint: c.ulong) -> c.uint ---
	FT_Load_Glyph :: proc(face: FT_Face, glyph_index: c.uint, flags: c.int) -> c.int ---
}

HB_Font :: struct {}
HB_Buffer :: struct {}
HB_Var_Int :: struct { bytes: [4]u8 }

HB_Glyph_Info :: struct {
	codepoint: u32,
	mask: u32,
	cluster: u32,
	var1, var2: HB_Var_Int,
}

HB_Glyph_Position :: struct {
	x_advance, y_advance, x_offset, y_offset: i32,
	var: HB_Var_Int,
}

HB_Feature :: struct {
	tag: u32,
	value, start, end: u32,
}

foreign import harfbuzz "system:harfbuzz"

@(default_calling_convention = "c")
foreign harfbuzz {
	hb_ft_font_create_referenced :: proc(face: FT_Face) -> ^HB_Font ---
	hb_font_destroy :: proc(font: ^HB_Font) ---
	hb_buffer_create :: proc() -> ^HB_Buffer ---
	hb_buffer_destroy :: proc(buffer: ^HB_Buffer) ---
	hb_buffer_reset :: proc(buffer: ^HB_Buffer) ---
	hb_buffer_add_utf32 :: proc(buffer: ^HB_Buffer, text: [^]u32, text_length: c.int, offset: c.uint, item_length: c.int) ---
	hb_buffer_guess_segment_properties :: proc(buffer: ^HB_Buffer) ---
	hb_buffer_get_glyph_infos :: proc(buffer: ^HB_Buffer, length: ^c.uint) -> [^]HB_Glyph_Info ---
	hb_buffer_get_glyph_positions :: proc(buffer: ^HB_Buffer, length: ^c.uint) -> [^]HB_Glyph_Position ---
	hb_shape :: proc(font: ^HB_Font, buffer: ^HB_Buffer, features: [^]HB_Feature, feature_count: c.uint) ---
}
