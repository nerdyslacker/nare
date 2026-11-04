package render

import fonts "../font"
import graphics "../graphics"
import selection "../selection"
import vt "../vt"
import x11 "../x11"

Command_Kind :: enum { Rectangle, Image, Glyph }
Image_Layer :: enum { Below_Background, Below_Text, Above_Text }

Command :: struct {
	kind: Command_Kind,
	x, y, width, height: int,
	color: u32,
	opacity: u8,
	face_id: int,
	glyph_index: u32,
	glyph_kind: fonts.Bitmap_Kind,
	clip_left, clip_right: int,
	clip_top, clip_bottom: int,
	image_id, placement_id: u64,
	source_x, source_y, source_width, source_height: int,
	z: i32,
}

Command_Scratch :: struct {
	text: [dynamic]rune,
	clusters: [dynamic]int,
	shaped: [dynamic]fonts.Shaped_Glyph,
}

command_scratch_destroy :: proc(scratch: ^Command_Scratch) {
	delete(scratch.text)
	delete(scratch.clusters)
	delete(scratch.shaped)
	scratch^ = {}
}

build_row_commands :: proc(
	output: ^[dynamic]Command,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	screen: ^vt.Screen,
	row: int,
	ligatures: bool,
	selection_state: ^selection.State = nil,
	scrollbar: Scrollbar = {},
	scratch_buffer: ^Command_Scratch = nil,
) {
	clear(output)
	local_scratch: Command_Scratch
	scratch := scratch_buffer
	if scratch == nil do scratch = &local_scratch
	text := scratch.text
	clusters := scratch.clusters
	shaped := scratch.shaped
	defer {
		scratch.text = text
		scratch.clusters = clusters
		scratch.shaped = shaped
		if scratch_buffer == nil do command_scratch_destroy(scratch)
	}
	y := row * window.cell_h
	append_rectangle(output, 0, y, window.width, window.cell_h, active_theme.background)
	append_image_commands(output, window, screen, row, .Below_Background)
	append_placeholder_commands(output, screen, row, .Below_Background, window.cell_w, window.cell_h)
	for column in 0..<screen.columns {
		cell := vt.cell_at(screen, row, column)
		_, background := display_colors(
			cell,
			selection.contains(selection_state, screen, row, column),
			block_cursor(terminal, screen, row, column),
		)
		if background != active_theme.background {
			append_rectangle(output, column*window.cell_w, y, window.cell_w, window.cell_h, background)
		}
	}
	append_image_commands(output, window, screen, row, .Below_Text)
	append_placeholder_commands(output, screen, row, .Below_Text, window.cell_w, window.cell_h)
	for column in 0..<screen.columns {
		cell := vt.cell_at(screen, row, column)
		if cell.continuation || cell.codepoint == PLACEHOLDER_CODEPOINT do continue
		foreground, background := display_colors(
			cell,
			selection.contains(selection_state, screen, row, column),
			block_cursor(terminal, screen, row, column),
		)
		if foreground == background do continue
		decoration_width := min(window.width-column*window.cell_w, max(1, int(cell.width))*window.cell_w)
		if cell.attributes.underline != .None {
			underline_color := foreground
			if cell.attributes.underline_color.kind != .Default do underline_color = terminal_color(cell.attributes.underline_color, true)
			append_underline(
				output,
				column*window.cell_w,
				y,
				decoration_width,
				window.cell_h,
				cell.attributes.underline,
				underline_color,
			)
		}
		if cell.attributes.strikethrough {
			append_rectangle(output, column*window.cell_w, y+window.cell_h/2, decoration_width, 1, foreground)
		}
	}

	column := 0
	for column < screen.columns {
		cell := vt.cell_at(screen, row, column)
		if cell.continuation {
			column += 1
			continue
		}
		if cell.codepoint == PLACEHOLDER_CODEPOINT {
			column += max(1, int(cell.width))
			continue
		}
		if cell.combining_count == 0 {
			foreground, background := display_colors(
				cell,
				selection.contains(selection_state, screen, row, column),
				block_cursor(terminal, screen, row, column),
			)
			if foreground == background {
				column += max(1, int(cell.width))
				continue
			}
			if append_cell_graphic(output, column*window.cell_w, y, window.cell_w, window.cell_h, cell.codepoint, foreground) {
				column += max(1, int(cell.width))
				continue
			}
		}
		run_start := column
		attributes := cell.attributes
		run_foreground: u32
		clear(&text)
		clear(&clusters)
		clear(&shaped)
		for column < screen.columns {
			current := vt.cell_at(screen, row, column)
			if current.continuation {
				column += 1
				continue
			}
			if current.codepoint == PLACEHOLDER_CODEPOINT do break
			if current.combining_count == 0 && is_cell_graphic(current.codepoint) && len(text) > 0 do break
			if current.attributes != attributes && len(text) > 0 do break
			current_foreground, _ := display_colors(
				current,
				selection.contains(selection_state, screen, row, column),
				block_cursor(terminal, screen, row, column),
			)
			if len(text) > 0 && current_foreground != run_foreground do break
			run_foreground = current_foreground
			append(&text, current.codepoint)
			append(&clusters, column)
			for index in 0..<int(current.combining_count) {
				append(&text, current.combining[index])
				append(&clusters, column)
			}
			column += max(1, int(current.width))
		}
		style := fonts.style_for_attributes(attributes.bold, attributes.italic)
		if fonts.shape(font, text[:], ligatures, &shaped, style) {
			for shaped_glyph in shaped {
				if shaped_glyph.cluster < 0 || shaped_glyph.cluster >= len(clusters) do continue
				glyph := fonts.face_glyph(font, shaped_glyph.face_id, shaped_glyph.index)
				if glyph == nil do continue
				origin_column := clusters[shaped_glyph.cluster]
				glyph_color, _ := display_colors(
					vt.cell_at(screen, row, origin_column),
					selection.contains(selection_state, screen, row, origin_column),
					block_cursor(terminal, screen, row, origin_column),
				)
				append(output, Command{
					kind = .Glyph,
					x = origin_column*window.cell_w+glyph.left+shaped_glyph.x_offset/64,
					y = y+font.ascent-glyph.top-shaped_glyph.y_offset/64,
					width = glyph.width,
					height = glyph.height,
					color = glyph_color,
					face_id = shaped_glyph.face_id,
					glyph_index = shaped_glyph.index,
					glyph_kind = glyph.kind,
					clip_left = run_start*window.cell_w,
					clip_right = min(window.width, column*window.cell_w),
				})
			}
		}
	}
	append_image_commands(output, window, screen, row, .Above_Text)
	append_placeholder_commands(output, screen, row, .Above_Text, window.cell_w, window.cell_h)
	append_cursor_commands(output, window, terminal, screen, row)
	append_scrollbar_commands(output, window, screen, row, scrollbar)
}

append_image_commands :: proc(
	output: ^[dynamic]Command,
	window: ^x11.Window,
	screen: ^vt.Screen,
	row: int,
	layer: Image_Layer,
) {
	if screen.image_registry == nil do return
	start := len(output^)
	row_top, row_bottom := row*window.cell_h, (row+1)*window.cell_h
	for placement in screen.image_registry.placements {
		if placement.virtual || placement.screen != screen.image_screen || image_placement_layer(screen.image_registry, placement) != layer do continue
		placement_row, placement_column, position_ok := placement_effective_position(screen, placement)
		if !position_ok do continue
		positioned := placement
		positioned.row = placement_row
		positioned.column = placement_column
		x, y, width, height := image_destination(
			positioned,
			window.cell_w,
			window.cell_h,
			screen.image_row_offset,
		)
		if x >= window.width || x+width <= 0 || y >= row_bottom || y+height <= row_top do continue
		append(output, Command{
			kind = .Image,
			x = x,
			y = y,
			width = width,
			height = height,
			clip_left = max(0, x),
			clip_right = min(window.width, x+width),
			clip_top = max(row_top, y),
			clip_bottom = min(row_bottom, y+height),
			image_id = placement.image_id,
			placement_id = placement.id,
			source_x = placement.source_x,
			source_y = placement.source_y,
			source_width = placement.source_width,
			source_height = placement.source_height,
			z = placement.z,
		})
	}
	sort_image_commands(output^, start)
}

placement_effective_position :: proc(screen: ^vt.Screen, placement: graphics.Placement) -> (row, column: int, ok: bool) {
	if placement.parent_placement_id == 0 do return placement.row, placement.column, true
	offset_row := placement.relative_row
	offset_column := placement.relative_column
	child := placement
	for _ in 0..<graphics.MAX_RELATIVE_DEPTH {
		parent := graphics.find_placement(screen.image_registry, child.parent_placement_id)
		if parent == nil do return 0, 0, false
		if parent.virtual {
			anchor_row, anchor_column, anchor_ok := find_placeholder_anchor(screen, parent)
			if !anchor_ok do return 0, 0, false
			return anchor_row+offset_row, anchor_column+offset_column, true
		}
		if parent.parent_placement_id == 0 {
			return parent.row+offset_row, parent.column+offset_column, true
		}
		offset_row += parent.relative_row
		offset_column += parent.relative_column
		child = parent^
	}
	return 0, 0, false
}

sort_image_commands :: proc(commands: [dynamic]Command, start: int) {
	for index := start+1; index < len(commands); index += 1 {
		current := commands[index]
		position := index
		for position > start && image_command_after(commands[position-1], current) {
			commands[position] = commands[position-1]
			position -= 1
		}
		commands[position] = current
	}
}

image_placement_layer :: proc(registry: ^graphics.Registry, placement: graphics.Placement) -> Image_Layer {
	resource := graphics.find_image(registry, placement.image_id)
	if resource != nil && resource.protocol == .Kitty && placement.z < graphics.KITTY_BACKGROUND_Z_THRESHOLD {
		return .Below_Background
	}
	if placement.z < 0 do return .Below_Text
	return .Above_Text
}

image_destination :: proc(
	placement: graphics.Placement,
	cell_width, cell_height: int,
	row_offset: int = 0,
) -> (x, y, width, height: int) {
	x = placement.column*cell_width+placement.pixel_offset_x
	y = (placement.row+row_offset)*cell_height+placement.pixel_offset_y
	width = placement.pixel_width if placement.pixel_width > 0 else placement.columns*cell_width
	height = placement.pixel_height if placement.pixel_height > 0 else placement.rows*cell_height
	if !placement.preserve_aspect || placement.source_width <= 0 || placement.source_height <= 0 do return
	if i64(width)*i64(placement.source_height) > i64(height)*i64(placement.source_width) {
		fitted := max(1, int(i64(height)*i64(placement.source_width)/i64(placement.source_height)))
		x += (width-fitted)/2
		width = fitted
	} else {
		fitted := max(1, int(i64(width)*i64(placement.source_height)/i64(placement.source_width)))
		y += (height-fitted)/2
		height = fitted
	}
	return
}

image_command_after :: proc(left, right: Command) -> bool {
	if left.z != right.z do return left.z > right.z
	if left.image_id != right.image_id do return left.image_id > right.image_id
	return left.placement_id > right.placement_id
}

display_colors :: proc(cell: ^vt.Cell, selected, cursor: bool) -> (foreground, background: u32) {
	foreground, background = cell_colors(cell)
	if selected {
		foreground = active_theme.selection_foreground
		background = active_theme.selection_background
	}
	if cursor {
		foreground = active_theme.cursor_text
		background = active_theme.cursor
	}
	return
}

append_rectangle :: proc(output: ^[dynamic]Command, x, y, width, height: int, color: u32) {
	append(output, Command{kind = .Rectangle, x = x, y = y, width = width, height = height, color = color})
}

append_translucent_rectangle :: proc(output: ^[dynamic]Command, x, y, width, height: int, color: u32, opacity: u8) {
	append(output, Command{kind = .Rectangle, x = x, y = y, width = width, height = height, color = color, opacity = opacity})
}

append_cursor_commands :: proc(output: ^[dynamic]Command, window: ^x11.Window, terminal: ^vt.Terminal, screen: ^vt.Screen, row: int) {
	if !cursor_visible(terminal) || row != screen.cursor.row do return
	style := terminal.modes.cursor_style
	if style == .Blinking_Block || style == .Steady_Block do return
	x := screen.cursor.column*window.cell_w
	color := active_theme.cursor
	if style == .Blinking_Underline || style == .Steady_Underline {
		height := clamp(terminal.cursor_underline_height, 1, window.cell_h)
		append_rectangle(output, x, row*window.cell_h+window.cell_h-height, window.cell_w, height, color)
	} else {
		append_rectangle(output, x, row*window.cell_h, clamp(terminal.cursor_beam_width, 1, window.cell_w), window.cell_h, color)
	}
}

cursor_visible :: proc(terminal: ^vt.Terminal) -> bool {
	if !terminal.modes.cursor_visible do return false
	style := terminal.modes.cursor_style
	if style == .Blinking_Block || style == .Blinking_Underline || style == .Blinking_Bar do return terminal.cursor_phase_visible
	return true
}
