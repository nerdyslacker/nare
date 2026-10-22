package font

import c "core:c"
import "core:fmt"
import "core:strings"

DEFAULT_FAMILY :: "monospace"
DEFAULT_PIXEL_SIZE :: 16
MAX_GLYPH_COUNT :: 2048
MAX_GLYPH_BYTES :: 16 * 1024 * 1024
MAX_FALLBACK_FACES :: 8

Error :: enum {
	None,
	Fontconfig,
	No_Match,
	FreeType,
	Face,
	Size,
	HarfBuzz,
}

Bitmap_Kind :: enum { Coverage, BGRA }

Glyph :: struct {
	face_id: int,
	index: u32,
	width, height: int,
	left, top: int,
	advance: int,
	kind: Bitmap_Kind,
	pixels: []u8,
	last_use: u64,
}

Fallback_Face :: struct {
	face: FT_Face,
	hb_font: ^HB_Font,
}

Shaped_Glyph :: struct {
	index: u32,
	cluster: int,
	x_advance, y_advance: int,
	x_offset, y_offset: int,
}

Manager :: struct {
	config: ^FcConfig,
	library: FT_Library,
	face: FT_Face,
	hb_font: ^HB_Font,
	hb_buffer: ^HB_Buffer,
	fallbacks: [dynamic]Fallback_Face,
	glyphs: [dynamic]Glyph,
	glyph_bytes: int,
	clock: u64,
	pixel_size: int,
	cell_width, cell_height: int,
	ascent, descent: int,
	family: string,
}

init :: proc(manager: ^Manager, family: string = DEFAULT_FAMILY, pixel_size: int = DEFAULT_PIXEL_SIZE) -> Error {
	if pixel_size <= 0 do return .Size
	manager.config = FcInitLoadConfigAndFonts()
	if manager.config == nil do return .Fontconfig
	manager.pixel_size = pixel_size
	manager.family = strings.clone(family)
	name := strings.clone_to_cstring(family)
	defer delete(name)
	pattern := FcNameParse(([^]u8)(name))
	if pattern == nil {
		destroy(manager)
		return .Fontconfig
	}
	defer FcPatternDestroy(pattern)
	_ = FcConfigSubstitute(manager.config, pattern, .Pattern)
	FcDefaultSubstitute(pattern)
	match_result: FcResult
	match := FcFontMatch(manager.config, pattern, &match_result)
	if match == nil || match_result != .Match {
		destroy(manager)
		return .No_Match
	}
	defer FcPatternDestroy(match)
	path: [^]u8
	if FcPatternGetString(match, "file", 0, &path) != .Match {
		destroy(manager)
		return .No_Match
	}
	face_index: c.int
	_ = FcPatternGetInteger(match, "index", 0, &face_index)
	if FT_Init_FreeType(&manager.library) != 0 {
		destroy(manager)
		return .FreeType
	}
	if FT_New_Face(manager.library, cstring(path), c.long(face_index), &manager.face) != 0 {
		destroy(manager)
		return .Face
	}
	if FT_Set_Pixel_Sizes(manager.face, 0, c.uint(pixel_size)) != 0 {
		destroy(manager)
		return .Size
	}
	manager.hb_font = hb_ft_font_create_referenced(manager.face)
	manager.hb_buffer = hb_buffer_create()
	if manager.hb_font == nil || manager.hb_buffer == nil {
		destroy(manager)
		return .HarfBuzz
	}
	metrics := manager.face.size.metrics
	manager.ascent = max(1, int((metrics.ascender+63)/64))
	manager.descent = max(0, int((-metrics.descender+63)/64))
	manager.cell_height = max(manager.ascent+manager.descent, int((metrics.height+63)/64))
	manager.cell_width = max(1, int((metrics.max_advance+63)/64))
	return .None
}

destroy :: proc(manager: ^Manager) {
	for &glyph in manager.glyphs do delete(glyph.pixels)
	delete(manager.glyphs)
	if manager.hb_buffer != nil do hb_buffer_destroy(manager.hb_buffer)
	for &fallback in manager.fallbacks {
		if fallback.hb_font != nil do hb_font_destroy(fallback.hb_font)
		if fallback.face != nil do _ = FT_Done_Face(fallback.face)
	}
	delete(manager.fallbacks)
	if manager.hb_font != nil do hb_font_destroy(manager.hb_font)
	if manager.face != nil do _ = FT_Done_Face(manager.face)
	if manager.library != nil do _ = FT_Done_FreeType(manager.library)
	if manager.config != nil do FcConfigDestroy(manager.config)
	delete(manager.family)
	manager^ = {}
}

glyph_index :: proc(manager: ^Manager, codepoint: rune) -> u32 {
	return u32(FT_Get_Char_Index(manager.face, c.ulong(codepoint)))
}

glyph :: proc(manager: ^Manager, index: u32) -> ^Glyph {
	return face_glyph(manager, 0, index)
}

glyph_for_codepoint :: proc(manager: ^Manager, codepoint: rune) -> ^Glyph {
	index := u32(FT_Get_Char_Index(manager.face, c.ulong(codepoint)))
	if index != 0 do return face_glyph(manager, 0, index)
	for &fallback, fallback_index in manager.fallbacks {
		index = u32(FT_Get_Char_Index(fallback.face, c.ulong(codepoint)))
		if index != 0 do return face_glyph(manager, fallback_index+1, index)
	}
	if len(manager.fallbacks) >= MAX_FALLBACK_FACES || !load_fallback(manager, codepoint) do return nil
	face_id := len(manager.fallbacks)
	index = u32(FT_Get_Char_Index(manager.fallbacks[face_id-1].face, c.ulong(codepoint)))
	if index == 0 do return nil
	return face_glyph(manager, face_id, index)
}

face_glyph :: proc(manager: ^Manager, face_id: int, index: u32) -> ^Glyph {
	manager.clock += 1
	for &entry in manager.glyphs {
		if entry.face_id == face_id && entry.index == index {
			entry.last_use = manager.clock
			return &entry
		}
	}
	if !cache_glyph(manager, face_id, index) do return nil
	return &manager.glyphs[len(manager.glyphs)-1]
}

cache_glyph :: proc(manager: ^Manager, face_id: int, index: u32) -> bool {
	face := manager.face if face_id == 0 else manager.fallbacks[face_id-1].face
	if FT_Load_Glyph(face, c.uint(index), FT_LOAD_RENDER | FT_LOAD_COLOR) != 0 do return false
	slot := face.glyph
	bitmap := &slot.bitmap
	channels := 4 if bitmap.pixel_mode == FT_PIXEL_MODE_BGRA else 1
	size := int(bitmap.width) * int(bitmap.rows) * channels
	if size > MAX_GLYPH_BYTES do return false
	for len(manager.glyphs) >= MAX_GLYPH_COUNT || manager.glyph_bytes+size > MAX_GLYPH_BYTES {
		if len(manager.glyphs) == 0 do return false
		evict_oldest(manager)
	}
	entry := Glyph{
		face_id = face_id,
		index = index,
		width = int(bitmap.width),
		height = int(bitmap.rows),
		left = int(slot.bitmap_left),
		top = int(slot.bitmap_top),
		advance = int((slot.advance.x+32)/64),
		kind = .BGRA if channels == 4 else .Coverage,
		pixels = make([]u8, size),
		last_use = manager.clock,
	}
	if bitmap.buffer != nil {
		pitch := int(bitmap.pitch)
		for row in 0..<entry.height {
			source_row := row if pitch >= 0 else entry.height-row-1
			source := bitmap.buffer[source_row*abs(pitch):]
			if bitmap.pixel_mode == FT_PIXEL_MODE_MONO {
				for column in 0..<entry.width {
					bit := u8(0x80 >> u32(column & 7))
					entry.pixels[row*entry.width+column] = 255 if source[column/8] & bit != 0 else 0
				}
			} else {
				row_bytes := entry.width * channels
				copy(entry.pixels[row*row_bytes:(row+1)*row_bytes], source[:row_bytes])
			}
		}
	}
	manager.glyph_bytes += size
	append(&manager.glyphs, entry)
	return true
}

load_fallback :: proc(manager: ^Manager, codepoint: rune) -> bool {
	query := fmt.aprintf(":charset=%x", codepoint)
	defer delete(query)
	name := strings.clone_to_cstring(query)
	defer delete(name)
	pattern := FcNameParse(([^]u8)(name))
	if pattern == nil do return false
	defer FcPatternDestroy(pattern)
	_ = FcConfigSubstitute(manager.config, pattern, .Pattern)
	FcDefaultSubstitute(pattern)
	match_result: FcResult
	match := FcFontMatch(manager.config, pattern, &match_result)
	if match == nil || match_result != .Match do return false
	defer FcPatternDestroy(match)
	path: [^]u8
	if FcPatternGetString(match, "file", 0, &path) != .Match do return false
	face_index: c.int
	_ = FcPatternGetInteger(match, "index", 0, &face_index)
	face: FT_Face
	if FT_New_Face(manager.library, cstring(path), c.long(face_index), &face) != 0 do return false
	if FT_Set_Pixel_Sizes(face, 0, c.uint(manager.pixel_size)) != 0 {
		_ = FT_Done_Face(face)
		return false
	}
	hb_font := hb_ft_font_create_referenced(face)
	if hb_font == nil {
		_ = FT_Done_Face(face)
		return false
	}
	append(&manager.fallbacks, Fallback_Face{face = face, hb_font = hb_font})
	return true
}

evict_oldest :: proc(manager: ^Manager) {
	oldest := 0
	for index in 1..<len(manager.glyphs) {
		if manager.glyphs[index].last_use < manager.glyphs[oldest].last_use do oldest = index
	}
	manager.glyph_bytes -= len(manager.glyphs[oldest].pixels)
	delete(manager.glyphs[oldest].pixels)
	unordered_remove(&manager.glyphs, oldest)
}

shape :: proc(manager: ^Manager, text: []rune, ligatures: bool, output: ^[dynamic]Shaped_Glyph) -> bool {
	clear(output)
	if len(text) == 0 do return true
	codepoints := make([]u32, len(text), context.temp_allocator)
	for value, index in text do codepoints[index] = u32(value)
	hb_buffer_reset(manager.hb_buffer)
	hb_buffer_add_utf32(manager.hb_buffer, raw_data(codepoints), c.int(len(codepoints)), 0, c.int(len(codepoints)))
	hb_buffer_guess_segment_properties(manager.hb_buffer)
	features := [2]HB_Feature{
		{tag = tag('l', 'i', 'g', 'a'), value = 1 if ligatures else 0, end = max(u32)},
		{tag = tag('c', 'a', 'l', 't'), value = 1 if ligatures else 0, end = max(u32)},
	}
	hb_shape(manager.hb_font, manager.hb_buffer, &features[0], len(features))
	count: c.uint
	infos := hb_buffer_get_glyph_infos(manager.hb_buffer, &count)
	positions := hb_buffer_get_glyph_positions(manager.hb_buffer, &count)
	if infos == nil || positions == nil do return false
	for index in 0..<int(count) {
		append(output, Shaped_Glyph{
			index = infos[index].codepoint,
			cluster = int(infos[index].cluster),
			x_advance = int(positions[index].x_advance),
			y_advance = int(positions[index].y_advance),
			x_offset = int(positions[index].x_offset),
			y_offset = int(positions[index].y_offset),
		})
	}
	return true
}

tag :: proc(a, b, c, d: u8) -> u32 {
	return u32(a)<<24 | u32(b)<<16 | u32(c)<<8 | u32(d)
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None: return "none"
	case .Fontconfig: return "could not initialize Fontconfig"
	case .No_Match: return "could not match a terminal font"
	case .FreeType: return "could not initialize FreeType"
	case .Face: return "could not load the matched font"
	case .Size: return "could not set the font size"
	case .HarfBuzz: return "could not initialize HarfBuzz"
	}
	return "unknown font error"
}
