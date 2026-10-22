package render

import c "core:c"
import libc "core:c/libc"
import fonts "../font"
import vt "../vt"
import x11 "../x11"
import xlib "vendor:x11/xlib"

MAX_SURFACE_BYTES :: 256 * 1024 * 1024

CPU :: struct {
	image: ^xlib.XImage,
	pixels: []u32,
	width, height: int,
	previous: []vt.Cell,
	previous_cursor: vt.Cursor,
	previous_cursor_visible: bool,
	previous_alternate: bool,
}

cpu_resize :: proc(cpu: ^CPU, window: ^x11.Window) -> bool {
	if window.width <= 0 || window.height <= 0 do return false
	byte_count := window.width * window.height * size_of(u32)
	if byte_count <= 0 || byte_count > MAX_SURFACE_BYTES do return false
	if cpu.image != nil do xlib.DestroyImage(cpu.image)
	cpu.image = nil
	cpu.pixels = nil
	data := libc.malloc(c.size_t(byte_count))
	if data == nil do return false
	image := xlib.CreateImage(
		window.display,
		window.visual,
		u32(window.depth),
		.ZPixmap,
		0,
		data,
		u32(window.width),
		u32(window.height),
		32,
		i32(window.width*size_of(u32)),
	)
	if image == nil || image.bits_per_pixel != 32 {
		if image != nil {
			xlib.DestroyImage(image)
		} else {
			libc.free(data)
		}
		return false
	}
	cpu.image = image
	cpu.pixels = (([^]u32)(data))[:window.width*window.height]
	cpu.width = window.width
	cpu.height = window.height
	delete(cpu.previous)
	cpu.previous = nil
	return true
}

cpu_destroy :: proc(cpu: ^CPU) {
	if cpu.image != nil do xlib.DestroyImage(cpu.image)
	delete(cpu.previous)
	cpu^ = {}
}

cpu_draw :: proc(
	cpu: ^CPU,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	ligatures: bool,
	force: bool,
) {
	if cpu.image == nil do return
	screen := vt.terminal_screen(terminal)
	full_redraw := force
	if len(cpu.previous) != len(screen.cells) {
		delete(cpu.previous)
		cpu.previous = make([]vt.Cell, len(screen.cells))
		full_redraw = true
	}
	if cpu.previous_alternate != terminal.using_alternate do full_redraw = true
	for row in 0..<screen.rows {
		dirty := full_redraw || row == screen.cursor.row || row == cpu.previous_cursor.row
		if !dirty {
			for column in 0..<screen.columns {
				index := row*screen.columns+column
				if cpu.previous[index] != screen.cells[index] {
					dirty = true
					break
				}
			}
		}
		if !dirty do continue
		render_row(cpu, font, window, terminal, screen, row, ligatures)
		copy(
			cpu.previous[row*screen.columns:(row+1)*screen.columns],
			screen.cells[row*screen.columns:(row+1)*screen.columns],
		)
		y := row * window.cell_h
		if y >= cpu.height do continue
		height := min(window.cell_h, cpu.height-y)
		xlib.PutImage(
			window.display,
			xlib.Drawable(window.id),
			window.gc,
			cpu.image,
			0,
			i32(y),
			0,
			i32(y),
			u32(min(cpu.width, screen.columns*window.cell_w)),
			u32(height),
		)
	}
	cpu.previous_cursor = screen.cursor
	cpu.previous_cursor_visible = terminal.modes.cursor_visible
	cpu.previous_alternate = terminal.using_alternate
	_ = xlib.Flush(window.display)
}

render_row :: proc(
	cpu: ^CPU,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	screen: ^vt.Screen,
	row: int,
	ligatures: bool,
) {
	y := row * window.cell_h
	if y >= cpu.height do return
	for column in 0..<screen.columns {
		cell := vt.cell_at(screen, row, column)
		foreground, background := cell_colors(cell)
		if block_cursor(terminal, screen, row, column) do foreground, background = background, foreground
		fill_rect(cpu, window, column*window.cell_w, y, window.cell_w, window.cell_h, background)
		if cell.attributes.underline {
			fill_rect(cpu, window, column*window.cell_w, y+window.cell_h-1, window.cell_w, 1, foreground)
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
		defer delete(text)
		defer delete(clusters)
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
		if fonts.shape(font, text[:], ligatures, &shaped) {
			foreground, _ := cell_colors(vt.cell_at(screen, row, run_start))
			for shaped_glyph in shaped {
				if shaped_glyph.cluster < 0 || shaped_glyph.cluster >= len(clusters) do continue
				cached := fonts.glyph(font, shaped_glyph.index)
				if shaped_glyph.index == 0 do cached = fonts.glyph_for_codepoint(font, text[shaped_glyph.cluster])
				if cached == nil do continue
				origin_column := clusters[shaped_glyph.cluster]
				if block_cursor(terminal, screen, row, origin_column) {
					_, foreground = cell_colors(vt.cell_at(screen, row, origin_column))
				}
				draw_glyph(
					cpu,
					window,
					cached,
					origin_column*window.cell_w+cached.left+shaped_glyph.x_offset/64,
					y+font.ascent-cached.top-shaped_glyph.y_offset/64,
					foreground,
					run_start*window.cell_w,
					min(cpu.width, column*window.cell_w),
				)
			}
		}
		delete(shaped)
	}
	draw_cursor_accent(cpu, window, terminal, screen, row)
}

draw_glyph :: proc(cpu: ^CPU, window: ^x11.Window, glyph: ^fonts.Glyph, x, y: int, color: u32, clip_left, clip_right: int) {
	for bitmap_y in 0..<glyph.height {
		destination_y := y + bitmap_y
		if destination_y < 0 || destination_y >= cpu.height do continue
		for bitmap_x in 0..<glyph.width {
			destination_x := x + bitmap_x
			if destination_x < clip_left || destination_x >= clip_right || destination_x < 0 || destination_x >= cpu.width do continue
			pixel := &cpu.pixels[destination_y*cpu.width+destination_x]
			if glyph.kind == .Coverage {
				alpha := glyph.pixels[bitmap_y*glyph.width+bitmap_x]
				pixel^ = blend(window, pixel^, color, alpha)
			} else {
				index := (bitmap_y*glyph.width+bitmap_x)*4
				blue := u32(glyph.pixels[index])
				green := u32(glyph.pixels[index+1])
				red := u32(glyph.pixels[index+2])
				alpha := glyph.pixels[index+3]
				pixel^ = blend_premultiplied(window, pixel^, red, green, blue, alpha)
			}
		}
	}
}

fill_rect :: proc(cpu: ^CPU, window: ^x11.Window, x, y, width, height: int, color: u32) {
	pixel := rgb_to_pixel(window, color)
	left, top := max(0, x), max(0, y)
	right, bottom := min(cpu.width, x+width), min(cpu.height, y+height)
	for destination_y in top..<bottom {
		for destination_x in left..<right do cpu.pixels[destination_y*cpu.width+destination_x] = pixel
	}
}

blend :: proc(window: ^x11.Window, background: u32, foreground: u32, alpha: u8) -> u32 {
	background_rgb := pixel_to_rgb(window, background)
	inverse := 255-u32(alpha)
	red := (((foreground>>16)&0xff)*u32(alpha) + ((background_rgb>>16)&0xff)*inverse) / 255
	green := (((foreground>>8)&0xff)*u32(alpha) + ((background_rgb>>8)&0xff)*inverse) / 255
	blue := ((foreground&0xff)*u32(alpha) + (background_rgb&0xff)*inverse) / 255
	return rgb_to_pixel(window, red<<16|green<<8|blue)
}

blend_premultiplied :: proc(window: ^x11.Window, background: u32, red, green, blue: u32, alpha: u8) -> u32 {
	background_rgb := pixel_to_rgb(window, background)
	inverse := 255-u32(alpha)
	result_red := red+((background_rgb>>16)&0xff)*inverse/255
	result_green := green+((background_rgb>>8)&0xff)*inverse/255
	result_blue := blue+(background_rgb&0xff)*inverse/255
	return rgb_to_pixel(window, min(result_red, 255)<<16|min(result_green, 255)<<8|min(result_blue, 255))
}

cell_colors :: proc(cell: ^vt.Cell) -> (foreground, background: u32) {
	foreground = terminal_color(cell.attributes.foreground, true)
	background = terminal_color(cell.attributes.background, false)
	if cell.attributes.bold && cell.attributes.foreground.kind == .Indexed && cell.attributes.foreground.value < 8 {
		foreground = ansi_color(int(cell.attributes.foreground.value)+8)
	}
	if cell.attributes.inverse do foreground, background = background, foreground
	if cell.attributes.hidden do foreground = background
	return
}

terminal_color :: proc(color: vt.Color, foreground: bool) -> u32 {
	switch color.kind {
	case .Default: return 0xe5e5e5 if foreground else 0x000000
	case .Indexed:
		index := int(color.value)
		if index < 16 do return ansi_color(index)
		if index < 232 {
			index -= 16
			red := color_cube_component(index/36)
			green := color_cube_component(index/6%6)
			blue := color_cube_component(index%6)
			return u32(red<<16|green<<8|blue)
		}
		gray := 8+(index-232)*10
		return u32(gray<<16|gray<<8|gray)
	case .RGB: return color.value
	}
	return 0
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
	return 0 if value == 0 else 55+value*40
}

rgb_to_pixel :: proc(window: ^x11.Window, rgb: u32) -> u32 {
	red := uint((rgb>>16)&0xff)
	green := uint((rgb>>8)&0xff)
	blue := uint(rgb&0xff)
	return u32(component_to_mask(red, window.visual.red_mask) |
	           component_to_mask(green, window.visual.green_mask) |
	           component_to_mask(blue, window.visual.blue_mask))
}

pixel_to_rgb :: proc(window: ^x11.Window, pixel: u32) -> u32 {
	red := component_from_mask(uint(pixel), window.visual.red_mask)
	green := component_from_mask(uint(pixel), window.visual.green_mask)
	blue := component_from_mask(uint(pixel), window.visual.blue_mask)
	return u32(red<<16|green<<8|blue)
}

component_to_mask :: proc(value, mask: uint) -> uint {
	if mask == 0 do return 0
	shift, field := mask_field(mask)
	return (value*field/255<<shift)&mask
}

component_from_mask :: proc(pixel, mask: uint) -> uint {
	if mask == 0 do return 0
	shift, field := mask_field(mask)
	return ((pixel&mask)>>shift)*255/field
}

mask_field :: proc(mask: uint) -> (shift, field: uint) {
	field = mask
	for field&1 == 0 {
		field >>= 1
		shift += 1
	}
	return
}

block_cursor :: proc(terminal: ^vt.Terminal, screen: ^vt.Screen, row, column: int) -> bool {
	if !terminal.modes.cursor_visible || row != screen.cursor.row || column != screen.cursor.column do return false
	return terminal.modes.cursor_style == .Blinking_Block || terminal.modes.cursor_style == .Steady_Block
}

draw_cursor_accent :: proc(cpu: ^CPU, window: ^x11.Window, terminal: ^vt.Terminal, screen: ^vt.Screen, row: int) {
	if !terminal.modes.cursor_visible || row != screen.cursor.row do return
	style := terminal.modes.cursor_style
	if style == .Blinking_Block || style == .Steady_Block do return
	x := screen.cursor.column*window.cell_w
	color, _ := cell_colors(vt.cell_at(screen, row, screen.cursor.column))
	if style == .Blinking_Underline || style == .Steady_Underline {
		fill_rect(cpu, window, x, row*window.cell_h+window.cell_h-2, window.cell_w, 2, color)
	} else {
		fill_rect(cpu, window, x, row*window.cell_h, 2, window.cell_h, color)
	}
}
