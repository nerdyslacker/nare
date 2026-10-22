package render

import fonts "../font"
import selection "../selection"
import vt "../vt"
import x11 "../x11"

Command_Kind :: enum { Rectangle, Glyph }

Command :: struct {
	kind: Command_Kind,
	x, y, width, height: int,
	color: u32,
	face_id: int,
	glyph_index: u32,
	glyph_kind: fonts.Bitmap_Kind,
	clip_left, clip_right: int,
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
) {
	clear(output)
	y := row * window.cell_h
	for column in 0..<screen.columns {
		cell := vt.cell_at(screen, row, column)
		foreground, background := display_colors(
			cell,
			selection.contains(selection_state, screen, row, column),
			block_cursor(terminal, screen, row, column),
		)
		append_rectangle(output, column*window.cell_w, y, window.cell_w, window.cell_h, background)
		if cell.attributes.underline {
			append_rectangle(output, column*window.cell_w, y+window.cell_h-1, window.cell_w, 1, foreground)
			if cell.attributes.double_underline {
				append_rectangle(output, column*window.cell_w, y+window.cell_h-3, window.cell_w, 1, foreground)
			}
		}
		if cell.attributes.strikethrough {
			append_rectangle(output, column*window.cell_w, y+window.cell_h/2, window.cell_w, 1, foreground)
		}
	}

	column := 0
	for column < screen.columns {
		cell := vt.cell_at(screen, row, column)
		if cell.continuation {
			column += 1
			continue
		}
		run_start := column
		attributes := cell.attributes
		text: [dynamic]rune
		clusters: [dynamic]int
		for column < screen.columns {
			current := vt.cell_at(screen, row, column)
			if current.continuation {
				column += 1
				continue
			}
			if current.attributes != attributes && len(text) > 0 do break
			append(&text, current.codepoint)
			append(&clusters, column)
			for index in 0..<int(current.combining_count) {
				append(&text, current.combining[index])
				append(&clusters, column)
			}
			column += max(1, int(current.width))
		}
		shaped: [dynamic]fonts.Shaped_Glyph
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
		delete(shaped)
		delete(clusters)
		delete(text)
	}
	append_cursor_commands(output, window, terminal, screen, row)
}

display_colors :: proc(cell: ^vt.Cell, selected, cursor: bool) -> (foreground, background: u32) {
	foreground, background = cell_colors(cell)
	if selected do foreground, background = background, foreground
	if cursor do foreground, background = background, foreground
	return
}

append_rectangle :: proc(output: ^[dynamic]Command, x, y, width, height: int, color: u32) {
	append(output, Command{kind = .Rectangle, x = x, y = y, width = width, height = height, color = color})
}

append_cursor_commands :: proc(output: ^[dynamic]Command, window: ^x11.Window, terminal: ^vt.Terminal, screen: ^vt.Screen, row: int) {
	if !terminal.modes.cursor_visible || row != screen.cursor.row do return
	style := terminal.modes.cursor_style
	if style == .Blinking_Block || style == .Steady_Block do return
	x := screen.cursor.column*window.cell_w
	color, _ := cell_colors(vt.cell_at(screen, row, screen.cursor.column))
	if style == .Blinking_Underline || style == .Steady_Underline {
		append_rectangle(output, x, row*window.cell_h+window.cell_h-2, window.cell_w, 2, color)
	} else {
		append_rectangle(output, x, row*window.cell_h, 2, window.cell_h, color)
	}
}
