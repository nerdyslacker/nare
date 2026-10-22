package x11

import vt "../vt"
import xlib "vendor:x11/xlib"

redraw :: proc(window: ^Window, terminal: ^vt.Terminal) {
	if window.gc == nil do return
	screen := vt.terminal_screen(terminal)
	set_color(window, window.black)
	xlib.FillRectangle(window.display, xlib.Drawable(window.id), window.gc, 0, 0, u32(window.width), u32(window.height))
	for row in 0..<screen.rows {
		for column in 0..<screen.columns {
			cell := vt.cell_at(screen, row, column)
			if cell.continuation do continue
			draw_cell(window, cell, row, column, false)
		}
	}
	if terminal.modes.cursor_visible {
		cell := vt.cell_at(screen, screen.cursor.row, screen.cursor.column)
		if cell.continuation && screen.cursor.column > 0 do cell = vt.cell_at(screen, screen.cursor.row, screen.cursor.column-1)
		draw_cell(window, cell, screen.cursor.row, screen.cursor.column, true)
	}
	_ = xlib.Flush(window.display)
}

draw_cell :: proc(window: ^Window, cell: ^vt.Cell, row, column: int, cursor: bool) {
	foreground, background := cell_colors(window, cell)
	if cursor do foreground, background = background, foreground
	x := column * window.cell_w
	y := row * window.cell_h
	width := window.cell_w * max(1, int(cell.width))
	if background != window.black || cursor {
		set_color(window, background)
		xlib.FillRectangle(
			window.display,
			xlib.Drawable(window.id),
			window.gc,
			i32(x),
			i32(y),
			u32(width),
			u32(window.cell_h),
		)
	}
	if cell.codepoint != ' ' && !cell.attributes.hidden {
		glyph := byte('?')
		if cell.codepoint >= 0x20 && cell.codepoint <= 0x7e do glyph = byte(cell.codepoint)
		set_color(window, foreground)
		xlib.DrawString(
			window.display,
			xlib.Drawable(window.id),
			window.gc,
			i32(x),
			i32(y)+window.font.ascent,
			&glyph,
			1,
		)
	}
	if cell.attributes.underline {
		set_color(window, foreground)
		xlib.FillRectangle(
			window.display,
			xlib.Drawable(window.id),
			window.gc,
			i32(x),
			i32(y+window.cell_h-1),
			u32(width),
			1,
		)
	}
}

cell_colors :: proc(window: ^Window, cell: ^vt.Cell) -> (foreground, background: uint) {
	foreground = terminal_color(window, cell.attributes.foreground, true)
	background = terminal_color(window, cell.attributes.background, false)
	if cell.attributes.bold && cell.attributes.foreground.kind == .Indexed && cell.attributes.foreground.value < 8 {
		foreground = color_pixel(window, ansi_color(int(cell.attributes.foreground.value)+8))
	}
	if cell.attributes.inverse do foreground, background = background, foreground
	if cell.attributes.hidden do foreground = background
	return
}

terminal_color :: proc(window: ^Window, color: vt.Color, foreground: bool) -> uint {
	switch color.kind {
	case .Default:
		return window.white if foreground else window.black
	case .Indexed:
		index := int(color.value)
		if index < 16 do return color_pixel(window, ansi_color(index))
		if index < 232 {
			index -= 16
			red := color_cube_component(index / 36)
			green := color_cube_component(index / 6 % 6)
			blue := color_cube_component(index % 6)
			return color_pixel(window, u32(red<<16 | green<<8 | blue))
		}
		gray := 8 + (index-232) * 10
		return color_pixel(window, u32(gray<<16 | gray<<8 | gray))
	case .RGB:
		return color_pixel(window, color.value)
	}
	return window.white if foreground else window.black
}

ansi_color :: proc(index: int) -> u32 {
	palette := [16]u32{
		0x000000, 0xcd3131, 0x0dbc79, 0xe5e510,
		0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
		0x666666, 0xf14c4c, 0x23d18b, 0xf5f543,
		0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff,
	}
	return palette[clamp(index, 0, len(palette)-1)]
}

color_cube_component :: proc(value: int) -> int {
	return 0 if value == 0 else 55 + value*40
}

color_pixel :: proc(window: ^Window, rgb: u32) -> uint {
	red := uint((rgb >> 16) & 0xff)
	green := uint((rgb >> 8) & 0xff)
	blue := uint(rgb & 0xff)
	return component_pixel(red, window.visual.red_mask) |
	       component_pixel(green, window.visual.green_mask) |
	       component_pixel(blue, window.visual.blue_mask)
}

component_pixel :: proc(value, mask: uint) -> uint {
	if mask == 0 do return 0
	shift: uint
	field := mask
	for field & 1 == 0 {
		field >>= 1
		shift += 1
	}
	return (value*field/255 << shift) & mask
}

set_color :: proc(window: ^Window, pixel: uint) {
	xlib.SetForeground(window.display, window.gc, pixel)
}
