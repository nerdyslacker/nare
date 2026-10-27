package font

import c "core:c"
import "core:fmt"
import "core:strings"
import "core:unicode"

DEFAULT_FAMILY :: "monospace"
DEFAULT_POINT_SIZE :: 16
DEFAULT_DPI :: 96.0
MAX_GLYPH_COUNT :: 2048
MAX_GLYPH_BYTES :: 16 * 1024 * 1024
MAX_FALLBACK_FACES :: 8
PRIMARY_FACE_COUNT :: 4

Error :: enum { None, Fontconfig, No_Match, FreeType, Face, Size, HarfBuzz }
Style :: enum { Regular, Bold, Italic, Bold_Italic }
Bitmap_Kind :: enum { Coverage, BGRA }

Font_Face :: struct {
	face: FT_Face,
	hb_font: ^HB_Font,
}

Fallback_Face :: struct { font: Font_Face }

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

Shaped_Glyph :: struct {
	face_id: int,
	index: u32,
	cluster: int,
	x_advance, y_advance: int,
	x_offset, y_offset: int,
}

Manager :: struct {
	config: ^FcConfig,
	library: FT_Library,
	faces: [PRIMARY_FACE_COUNT]Font_Face,
	hb_buffer: ^HB_Buffer,
	fallbacks: [dynamic]Fallback_Face,
	glyphs: [dynamic]Glyph,
	glyph_bytes: int,
	clock: u64,
	point_size: int,
	dpi: f32,
	face_height: int,
	cell_width, cell_height: int,
	ascent, descent: int,
	family: string,
}

init :: proc(
	manager: ^Manager,
	family: string = DEFAULT_FAMILY,
	point_size: int = DEFAULT_POINT_SIZE,
	bold_family: string = "auto",
	italic_family: string = "auto",
	bold_italic_family: string = "auto",
	cell_width_percent: int = 100,
	cell_height_percent: int = 100,
	dpi: f32 = DEFAULT_DPI,
) -> Error {
	if point_size <= 0 || dpi <= 0 do return .Size
	manager.config = FcInitLoadConfigAndFonts()
	if manager.config == nil do return .Fontconfig
	manager.point_size = point_size
	manager.dpi = dpi
	manager.family = strings.clone(family)
	if FT_Init_FreeType(&manager.library) != 0 {
		destroy(manager)
		return .FreeType
	}
	regular, ok := load_face(manager, family)
	if !ok {
		destroy(manager)
		return .Face
	}
	manager.faces[int(Style.Regular)] = regular
	style_names := [3]string{"Bold", "Italic", "Bold Italic"}
	style_families := [3]string{bold_family, italic_family, bold_italic_family}
	for style_name, index in style_names {
		query := fmt.aprintf("%s:style=%s", family, style_name)
		if style_families[index] != "" && style_families[index] != "auto" {
			delete(query)
			query = strings.clone(style_families[index])
		}
		face, loaded := load_face(manager, query)
		delete(query)
		if loaded do manager.faces[index+1] = face
	}
	manager.hb_buffer = hb_buffer_create()
	if manager.hb_buffer == nil {
		destroy(manager)
		return .HarfBuzz
	}
	metrics := regular.face.size.metrics
	manager.ascent = max(1, int((metrics.ascender+63)/64))
	manager.descent = max(0, int((-metrics.descender+63)/64))
	manager.cell_height = max(manager.ascent+manager.descent, int((metrics.height+63)/64))
	manager.cell_width = max(1, int((metrics.max_advance+63)/64))
	reference_index := FT_Get_Char_Index(regular.face, c.ulong('M'))
	if reference_index != 0 && FT_Load_Glyph(regular.face, reference_index, 0) == 0 {
		manager.cell_width = max(1, int((regular.face.glyph.advance.x+32)/64))
	}
	base_height := manager.cell_height
	manager.face_height = base_height
	manager.cell_width = max(1, (manager.cell_width*clamp(cell_width_percent, 50, 300)+50)/100)
	manager.cell_height = max(1, (manager.cell_height*clamp(cell_height_percent, 50, 300)+50)/100)
	manager.ascent += (manager.cell_height-base_height)/2
	return .None
}

destroy :: proc(manager: ^Manager) {
	for &glyph in manager.glyphs do delete(glyph.pixels)
	delete(manager.glyphs)
	if manager.hb_buffer != nil do hb_buffer_destroy(manager.hb_buffer)
	for &fallback in manager.fallbacks do destroy_face(&fallback.font)
	delete(manager.fallbacks)
	for &face in manager.faces do destroy_face(&face)
	if manager.library != nil do _ = FT_Done_FreeType(manager.library)
	if manager.config != nil do FcConfigDestroy(manager.config)
	delete(manager.family)
	manager^ = {}
}

destroy_face :: proc(face: ^Font_Face) {
	if face.hb_font != nil do hb_font_destroy(face.hb_font)
	if face.face != nil do _ = FT_Done_Face(face.face)
	face^ = {}
}

load_face :: proc(manager: ^Manager, query: string) -> (result: Font_Face, ok: bool) {
	name := strings.clone_to_cstring(query)
	defer delete(name)
	pattern := FcNameParse(([^]u8)(name))
	if pattern == nil do return
	defer FcPatternDestroy(pattern)
	_ = FcConfigSubstitute(manager.config, pattern, .Pattern)
	FcDefaultSubstitute(pattern)
	match_result: FcResult
	match := FcFontMatch(manager.config, pattern, &match_result)
	if match == nil || match_result != .Match do return
	defer FcPatternDestroy(match)
	path: [^]u8
	if FcPatternGetString(match, "file", 0, &path) != .Match do return
	face_index: c.int
	_ = FcPatternGetInteger(match, "index", 0, &face_index)
	if FT_New_Face(manager.library, cstring(path), c.long(face_index), &result.face) != 0 do return
	// Configuration uses typographic points, like Kitty and other desktop apps.
	// FreeType expects the point size in 26.6 units and resolves it at the
	// display DPI (13 pt at 96 DPI is about 17 physical pixels).
	point_height := c.long(manager.point_size*64)
	face_dpi := c.uint(clamp(int(manager.dpi+0.5), 1, 1000))
	if FT_Set_Char_Size(result.face, 0, point_height, face_dpi, face_dpi) != 0 {
		_ = FT_Done_Face(result.face)
		result.face = nil
		return
	}
	result.hb_font = hb_ft_font_create_referenced(result.face)
	if result.hb_font == nil {
		_ = FT_Done_Face(result.face)
		result.face = nil
		return
	}
	return result, true
}

style_for_attributes :: proc(bold, italic: bool) -> Style {
	if bold && italic do return .Bold_Italic
	if bold do return .Bold
	if italic do return .Italic
	return .Regular
}

primary_face_id :: proc(manager: ^Manager, style: Style) -> int {
	id := int(style)
	return id if manager.faces[id].face != nil else int(Style.Regular)
}

face_for_id :: proc(manager: ^Manager, face_id: int) -> ^Font_Face {
	if face_id < PRIMARY_FACE_COUNT do return &manager.faces[face_id]
	index := face_id-PRIMARY_FACE_COUNT
	if index < 0 || index >= len(manager.fallbacks) do return nil
	return &manager.fallbacks[index].font
}

glyph_index :: proc(manager: ^Manager, codepoint: rune, style: Style = .Regular) -> u32 {
	face := face_for_id(manager, primary_face_id(manager, style))
	return u32(FT_Get_Char_Index(face.face, c.ulong(codepoint)))
}

glyph :: proc(manager: ^Manager, index: u32, style: Style = .Regular) -> ^Glyph {
	return face_glyph(manager, primary_face_id(manager, style), index)
}

glyph_for_codepoint :: proc(manager: ^Manager, codepoint: rune, style: Style = .Regular) -> ^Glyph {
	face_id := resolve_face(manager, codepoint, style)
	face := face_for_id(manager, face_id)
	if face == nil do return nil
	index := u32(FT_Get_Char_Index(face.face, c.ulong(codepoint)))
	if index == 0 do return nil
	return face_glyph(manager, face_id, index)
}

resolve_face :: proc(manager: ^Manager, codepoint: rune, style: Style) -> int {
	face_id := primary_face_id(manager, style)
	face := face_for_id(manager, face_id)
	if FT_Get_Char_Index(face.face, c.ulong(codepoint)) != 0 do return face_id
	for &fallback, index in manager.fallbacks {
		if FT_Get_Char_Index(fallback.font.face, c.ulong(codepoint)) != 0 do return PRIMARY_FACE_COUNT+index
	}
	if len(manager.fallbacks) < MAX_FALLBACK_FACES && load_fallback(manager, codepoint) {
		return PRIMARY_FACE_COUNT+len(manager.fallbacks)-1
	}
	return face_id
}

load_fallback :: proc(manager: ^Manager, codepoint: rune) -> bool {
	query := fmt.aprintf(":charset=%x", codepoint)
	defer delete(query)
	face, ok := load_face(manager, query)
	if !ok do return false
	if !fit_fallback_face(manager, &face) {
		destroy_face(&face)
		return false
	}
	append(&manager.fallbacks, Fallback_Face{font = face})
	return true
}

fit_fallback_face :: proc(manager: ^Manager, face: ^Font_Face) -> bool {
	if face == nil || face.face == nil || manager.face_height <= 0 do return false
	current_height := max(1, int((face.face.size.metrics.height+63)/64))
	if abs(current_height-manager.face_height) <= 1 do return true
	char_height := manager.point_size*64
	for _ in 0..<3 {
		char_height = max(64, (char_height*manager.face_height+current_height/2)/current_height)
		face_dpi := c.uint(clamp(int(manager.dpi+0.5), 1, 1000))
		if FT_Set_Char_Size(face.face, 0, c.long(char_height), face_dpi, face_dpi) != 0 do return false
		current_height = max(1, int((face.face.size.metrics.height+63)/64))
		if abs(current_height-manager.face_height) <= 1 do break
	}
	// HarfBuzz snapshots the FreeType scale when its font is created.
	if face.hb_font != nil do hb_font_destroy(face.hb_font)
	face.hb_font = hb_ft_font_create_referenced(face.face)
	return face.hb_font != nil
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
	font_face := face_for_id(manager, face_id)
	if font_face == nil || FT_Load_Glyph(font_face.face, c.uint(index), FT_LOAD_RENDER | FT_LOAD_COLOR) != 0 do return false
	slot := font_face.face.glyph
	bitmap := &slot.bitmap
	channels := 4 if bitmap.pixel_mode == FT_PIXEL_MODE_BGRA else 1
	size := int(bitmap.width)*int(bitmap.rows)*channels
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
					bit := u8(0x80 >> u32(column&7))
					entry.pixels[row*entry.width+column] = 255 if source[column/8]&bit != 0 else 0
				}
			} else {
				row_bytes := entry.width*channels
				copy(entry.pixels[row*row_bytes:(row+1)*row_bytes], source[:row_bytes])
			}
		}
	}
	manager.glyph_bytes += size
	append(&manager.glyphs, entry)
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

shape :: proc(
	manager: ^Manager,
	text: []rune,
	ligatures: bool,
	output: ^[dynamic]Shaped_Glyph,
	style: Style = .Regular,
) -> bool {
	clear(output)
	if len(text) == 0 do return true
	run_start := 0
	for run_start < len(text) {
		face_id := resolve_face(manager, text[run_start], style)
		face := face_for_id(manager, face_id)
		run_end := run_start+1
		for run_end < len(text) {
			if unicode.is_combining(text[run_end]) && FT_Get_Char_Index(face.face, c.ulong(text[run_end])) != 0 {
				run_end += 1
				continue
			}
			if resolve_face(manager, text[run_end], style) != face_id do break
			run_end += 1
		}
		if !shape_segment(manager, face_id, text[run_start:run_end], ligatures, run_start, output) do return false
		run_start = run_end
	}
	return true
}

shape_segment :: proc(
	manager: ^Manager,
	face_id: int,
	text: []rune,
	ligatures: bool,
	cluster_offset: int,
	output: ^[dynamic]Shaped_Glyph,
) -> bool {
	face := face_for_id(manager, face_id)
	if face == nil do return false
	codepoints := make([]u32, len(text), context.temp_allocator)
	for value, index in text do codepoints[index] = u32(value)
	hb_buffer_reset(manager.hb_buffer)
	hb_buffer_add_utf32(manager.hb_buffer, raw_data(codepoints), c.int(len(codepoints)), 0, c.int(len(codepoints)))
	hb_buffer_guess_segment_properties(manager.hb_buffer)
	features := [2]HB_Feature{
		{tag = tag('l', 'i', 'g', 'a'), value = 1 if ligatures else 0, end = max(u32)},
		{tag = tag('c', 'a', 'l', 't'), value = 1 if ligatures else 0, end = max(u32)},
	}
	hb_shape(face.hb_font, manager.hb_buffer, &features[0], len(features))
	count: c.uint
	infos := hb_buffer_get_glyph_infos(manager.hb_buffer, &count)
	positions := hb_buffer_get_glyph_positions(manager.hb_buffer, &count)
	if infos == nil || positions == nil do return false
	for index in 0..<int(count) {
		append(output, Shaped_Glyph{
			face_id = face_id,
			index = infos[index].codepoint,
			cluster = cluster_offset+int(infos[index].cluster),
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
