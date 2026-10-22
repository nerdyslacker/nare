package render

ATLAS_WIDTH :: 2048
ATLAS_HEIGHT :: 2048
ATLAS_PADDING :: 1
MAX_ATLAS_GLYPHS :: 2048

Atlas_Entry :: struct {
	face_id: int,
	glyph_index: u32,
	x, y, width, height: int,
	generation: u32,
}

Atlas :: struct {
	entries: [dynamic]Atlas_Entry,
	next_x, next_y: int,
	row_height: int,
	generation: u32,
}

atlas_destroy :: proc(atlas: ^Atlas) {
	delete(atlas.entries)
	atlas^ = {}
}

atlas_find :: proc(atlas: ^Atlas, face_id: int, glyph_index: u32) -> ^Atlas_Entry {
	for &entry in atlas.entries {
		if entry.face_id == face_id && entry.glyph_index == glyph_index do return &entry
	}
	return nil
}

atlas_place :: proc(atlas: ^Atlas, face_id: int, glyph_index: u32, width, height: int) -> (entry: ^Atlas_Entry, reset: bool) {
	if existing := atlas_find(atlas, face_id, glyph_index); existing != nil do return existing, false
	if width <= 0 || height <= 0 || width+ATLAS_PADDING*2 > ATLAS_WIDTH || height+ATLAS_PADDING*2 > ATLAS_HEIGHT do return nil, false
	if atlas.next_x == 0 {
		atlas.next_x = ATLAS_PADDING
		atlas.next_y = ATLAS_PADDING
	}
	if len(atlas.entries) >= MAX_ATLAS_GLYPHS || !atlas_has_space(atlas, width, height) {
		atlas_reset(atlas)
		reset = true
	}
	if !atlas_has_space(atlas, width, height) do return nil, reset
	if atlas.next_x+width+ATLAS_PADDING > ATLAS_WIDTH {
		atlas.next_x = ATLAS_PADDING
		atlas.next_y += atlas.row_height+ATLAS_PADDING
		atlas.row_height = 0
	}
	append(&atlas.entries, Atlas_Entry{
		face_id = face_id,
		glyph_index = glyph_index,
		x = atlas.next_x,
		y = atlas.next_y,
		width = width,
		height = height,
		generation = atlas.generation,
	})
	atlas.next_x += width+ATLAS_PADDING
	atlas.row_height = max(atlas.row_height, height)
	return &atlas.entries[len(atlas.entries)-1], reset
}

atlas_has_space :: proc(atlas: ^Atlas, width, height: int) -> bool {
	if atlas.next_x+width+ATLAS_PADDING <= ATLAS_WIDTH {
		return atlas.next_y+height+ATLAS_PADDING <= ATLAS_HEIGHT
	}
	return atlas.next_y+atlas.row_height+height+ATLAS_PADDING*2 <= ATLAS_HEIGHT
}

atlas_reset :: proc(atlas: ^Atlas) {
	clear(&atlas.entries)
	atlas.next_x = ATLAS_PADDING
	atlas.next_y = ATLAS_PADDING
	atlas.row_height = 0
	atlas.generation += 1
}
