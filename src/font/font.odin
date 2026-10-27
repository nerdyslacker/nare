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

Fallback_Face :: struct {
	font: Font_Face,
	emoji: bool,
}

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
		if !select_nearest_fixed_size(result.face, manager.point_size, manager.dpi) {
			_ = FT_Done_Face(result.face)
			result.face = nil
			return
		}
	}
	result.hb_font = hb_ft_font_create_referenced(result.face)
	if result.hb_font == nil {
		_ = FT_Done_Face(result.face)
		result.face = nil
		return
	}
	return result, true
}

select_nearest_fixed_size :: proc(face: FT_Face, point_size: int, dpi: f32) -> bool {
	if face == nil || face.num_fixed_sizes <= 0 || face.available_sizes == nil do return false
	target := max(1, int(f32(point_size)*dpi/72+0.5))
	best := 0
	best_distance := max(int)
	for index in 0..<int(face.num_fixed_sizes) {
		size := ([^]FT_Bitmap_Size)(face.available_sizes)[index]
		pixels := int((size.y_ppem+32)/64)
		if pixels <= 0 do pixels = int(size.height)
		distance := abs(pixels-target)
		if distance < best_distance do best, best_distance = index, distance
	}
	return FT_Select_Size(face, c.int(best)) == 0
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
	if emoji_default_presentation(codepoint) do return resolve_emoji_face(manager, codepoint, style)
	return resolve_text_face(manager, codepoint, style)
}

resolve_text_face :: proc(manager: ^Manager, codepoint: rune, style: Style) -> int {
	face_id := primary_face_id(manager, style)
	face := face_for_id(manager, face_id)
	if FT_Get_Char_Index(face.face, c.ulong(codepoint)) != 0 do return face_id
	for &fallback, index in manager.fallbacks {
		if FT_Get_Char_Index(fallback.font.face, c.ulong(codepoint)) != 0 do return PRIMARY_FACE_COUNT+index
	}
	if len(manager.fallbacks) < MAX_FALLBACK_FACES && load_fallback(manager, codepoint, false) {
		return PRIMARY_FACE_COUNT+len(manager.fallbacks)-1
	}
	return face_id
}

resolve_emoji_face :: proc(manager: ^Manager, codepoint: rune, style: Style) -> int {
	for &fallback, index in manager.fallbacks {
		if fallback.emoji && FT_Get_Char_Index(fallback.font.face, c.ulong(codepoint)) != 0 {
			return PRIMARY_FACE_COUNT+index
		}
	}
	if len(manager.fallbacks) < MAX_FALLBACK_FACES && load_fallback(manager, codepoint, true) {
		return PRIMARY_FACE_COUNT+len(manager.fallbacks)-1
	}
	return resolve_text_face(manager, codepoint, style)
}

load_fallback :: proc(manager: ^Manager, codepoint: rune, emoji: bool) -> bool {
	query := fmt.aprintf("emoji:charset=%x", codepoint) if emoji else fmt.aprintf("monospace:charset=%x", codepoint)
	defer delete(query)
	face, ok := load_face(manager, query)
	if !ok do return false
	// Color emoji fonts commonly expose a large bitmap strike. Keep its
	// native face size for shaping and scale the rendered BGRA bitmap into
	// the terminal's two-cell box when it enters the glyph cache.
	if !emoji && !fit_fallback_face(manager, &face) {
		destroy_face(&face)
		return false
	}
	append(&manager.fallbacks, Fallback_Face{font = face, emoji = emoji})
	return true
}

emoji_default_presentation :: proc(codepoint: rune) -> bool {
	return codepoint >= 0x1f000 && codepoint <= 0x1faff ||
	       codepoint >= 0x1f1e6 && codepoint <= 0x1f1ff ||
	       codepoint == 0x231a || codepoint == 0x231b ||
	       codepoint >= 0x23e9 && codepoint <= 0x23ec ||
	       codepoint == 0x23f0 || codepoint == 0x23f3 ||
	       codepoint >= 0x25fd && codepoint <= 0x25fe ||
	       codepoint >= 0x2614 && codepoint <= 0x2615 ||
	       codepoint >= 0x2648 && codepoint <= 0x2653 ||
	       codepoint == 0x267f || codepoint == 0x2693 || codepoint == 0x26a1 ||
	       codepoint >= 0x26aa && codepoint <= 0x26ab ||
	       codepoint >= 0x26bd && codepoint <= 0x26be ||
	       codepoint >= 0x26c4 && codepoint <= 0x26c5 || codepoint == 0x26ce ||
	       codepoint == 0x26d4 || codepoint == 0x26ea ||
	       codepoint >= 0x26f2 && codepoint <= 0x26f3 || codepoint == 0x26f5 ||
	       codepoint == 0x26fa || codepoint == 0x26fd || codepoint == 0x2705 ||
	       codepoint >= 0x270a && codepoint <= 0x270b || codepoint == 0x2728 ||
	       codepoint == 0x274c || codepoint == 0x274e ||
	       codepoint >= 0x2753 && codepoint <= 0x2755 || codepoint == 0x2757 ||
	       codepoint >= 0x2795 && codepoint <= 0x2797 || codepoint == 0x27b0 || codepoint == 0x27bf
}

emoji_sequence_component :: proc(codepoint: rune) -> bool {
	return codepoint == 0x200d || codepoint == 0xfe0e || codepoint == 0xfe0f || codepoint == 0x20e3 ||
	       codepoint >= 0x1f3fb && codepoint <= 0x1f3ff ||
	       codepoint >= 0xe0020 && codepoint <= 0xe007f
}

emoji_presentation_at :: proc(text: []rune, index: int) -> bool {
	if index < 0 || index >= len(text) do return false
	if emoji_default_presentation(text[index]) do return true
	return index+1 < len(text) && text[index+1] == 0xfe0f
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
	source_width := int(bitmap.width)
	source_height := int(bitmap.rows)
	width, height := source_width, source_height
	if channels == 4 && source_width > 0 && source_height > 0 {
		max_width := max(1, manager.cell_width*2)
		max_height := max(1, manager.cell_height)
		if source_width*max_height > source_height*max_width {
			width = min(source_width, max_width)
			height = max(1, source_height*width/source_width)
		} else {
			height = min(source_height, max_height)
			width = max(1, source_width*height/source_height)
		}
	}
	size := width*height*channels
	if size > MAX_GLYPH_BYTES do return false
	for len(manager.glyphs) >= MAX_GLYPH_COUNT || manager.glyph_bytes+size > MAX_GLYPH_BYTES {
		if len(manager.glyphs) == 0 do return false
		evict_oldest(manager)
	}
	entry := Glyph{
		face_id = face_id,
		index = index,
		width = width,
		height = height,
		left = int(slot.bitmap_left),
		top = int(slot.bitmap_top),
		advance = int((slot.advance.x+32)/64),
		kind = .BGRA if channels == 4 else .Coverage,
		pixels = make([]u8, size),
		last_use = manager.clock,
	}
	if channels == 4 {
		entry.left = max(0, (manager.cell_width*2-entry.width)/2)
		entry.top = manager.ascent-(manager.cell_height-entry.height)/2
	}
	if bitmap.buffer != nil {
		pitch := int(bitmap.pitch)
		if channels == 4 && (entry.width != source_width || entry.height != source_height) {
			resample_bgra(entry.pixels, entry.width, entry.height, bitmap.buffer, source_width, source_height, pitch)
		} else {
			for row in 0..<entry.height {
				source_row := row if pitch >= 0 else source_height-row-1
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
	}
	manager.glyph_bytes += size
	append(&manager.glyphs, entry)
	return true
}

resample_bgra :: proc(
	destination: []u8,
	width, height: int,
	source: [^]u8,
	source_width, source_height, source_pitch: int,
) {
	if len(destination) < width*height*4 || source == nil || source_width <= 0 || source_height <= 0 do return
	pitch := abs(source_pitch)
	for y in 0..<height {
		source_y_fixed := clamp(((2*y+1)*source_height*256)/(2*height)-128, 0, (source_height-1)*256)
		y0 := source_y_fixed/256
		y1 := min(source_height-1, y0+1)
		fy := source_y_fixed&255
		row0 := y0 if source_pitch >= 0 else source_height-y0-1
		row1 := y1 if source_pitch >= 0 else source_height-y1-1
		for x in 0..<width {
			source_x_fixed := clamp(((2*x+1)*source_width*256)/(2*width)-128, 0, (source_width-1)*256)
			x0 := source_x_fixed/256
			x1 := min(source_width-1, x0+1)
			fx := source_x_fixed&255
			for channel in 0..<4 {
				top := (int(source[row0*pitch+x0*4+channel])*(256-fx)+int(source[row0*pitch+x1*4+channel])*fx+128)/256
				bottom := (int(source[row1*pitch+x0*4+channel])*(256-fx)+int(source[row1*pitch+x1*4+channel])*fx+128)/256
				destination[(y*width+x)*4+channel] = u8((top*(256-fy)+bottom*fy+128)/256)
			}
		}
	}
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
		emoji_run := emoji_presentation_at(text, run_start)
		face_id := resolve_emoji_face(manager, text[run_start], style) if emoji_run else resolve_face(manager, text[run_start], style)
		face := face_for_id(manager, face_id)
		run_end := run_start+1
		for run_end < len(text) {
			if emoji_run {
				if emoji_sequence_component(text[run_end]) || emoji_default_presentation(text[run_end]) ||
				   text[run_end-1] == 0x200d {
					run_end += 1
					continue
				}
				break
			}
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
	features := [4]HB_Feature{
		{tag = tag('l', 'i', 'g', 'a'), value = 1 if ligatures else 0, end = max(u32)},
		{tag = tag('c', 'a', 'l', 't'), value = 1 if ligatures else 0, end = max(u32)},
		// Emoji ZWJ and presentation sequences rely on required ligatures and
		// canonical composition independently of the user's text-ligature
		// preference.
		{tag = tag('r', 'l', 'i', 'g'), value = 1, end = max(u32)},
		{tag = tag('c', 'c', 'm', 'p'), value = 1, end = max(u32)},
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
