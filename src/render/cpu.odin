package render

import c "core:c"
import libc "core:c/libc"
import fonts "../font"
import graphics "../graphics"
import selection "../selection"
import vt "../vt"
import x11 "../x11"
import xlib "vendor:x11/xlib"

MAX_SURFACE_BYTES :: 256 * 1024 * 1024

CPU :: struct {
	image: ^xlib.XImage,
	pixels: []u32,
	width, height: int,
	previous: []vt.Cell,
	dirty_rows: []bool,
	commands: [dynamic]Command,
	previous_cursor: vt.Cursor,
	previous_cursor_visible: bool,
	previous_alternate: bool,
	previous_image_generation: u64,
	previous_image_row_offset: int,
	previous_selection: selection.State,
	previous_scrollbar: Scrollbar_Geometry,
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
	background := rgb_to_pixel(window, active_theme.background)
	for &pixel in cpu.pixels do pixel = background
	cpu.width = window.width
	cpu.height = window.height
	delete(cpu.previous)
	cpu.previous = nil
	delete(cpu.dirty_rows)
	cpu.dirty_rows = nil
	return true
}

cpu_destroy :: proc(cpu: ^CPU) {
	if cpu.image != nil do xlib.DestroyImage(cpu.image)
	delete(cpu.previous)
	delete(cpu.dirty_rows)
	delete(cpu.commands)
	cpu^ = {}
}

cpu_render :: proc(
	cpu: ^CPU,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	ligatures: bool,
	force: bool,
	selection_state: ^selection.State = nil,
	screen_override: ^vt.Screen = nil,
	scrollbar: Scrollbar = {},
) -> bool {
	if cpu.image == nil do return false
	screen := screen_override
	if screen == nil do screen = vt.terminal_screen(terminal)
	scrollbar_geometry := scrollbar_geometry(window, screen, scrollbar)
	if !damage_rows(cpu, terminal, screen, force, selection_state, scrollbar_geometry) do return false
	for dirty, row in cpu.dirty_rows {
		if dirty do render_row(cpu, font, window, terminal, screen, row, ligatures, selection_state, scrollbar)
	}
	return true
}

damage_rows :: proc(
	cpu: ^CPU,
	terminal: ^vt.Terminal,
	screen: ^vt.Screen,
	force: bool,
	selection_state: ^selection.State = nil,
	scrollbar: Scrollbar_Geometry = {},
) -> bool {
	if cpu.image == nil do return false
	full_redraw := force
	if len(cpu.previous) != len(screen.cells) {
		delete(cpu.previous)
		cpu.previous = make([]vt.Cell, len(screen.cells))
		full_redraw = true
	}
	if len(cpu.dirty_rows) != screen.rows {
		delete(cpu.dirty_rows)
		cpu.dirty_rows = make([]bool, screen.rows)
		full_redraw = true
	} else {
		for index in 0..<len(cpu.dirty_rows) do cpu.dirty_rows[index] = false
	}
	if cpu.previous_alternate != terminal.using_alternate do full_redraw = true
	scrollbar_changed := cpu.previous_scrollbar != scrollbar
	if scrollbar_changed &&
	   (cpu.previous_scrollbar.visible != scrollbar.visible ||
	    cpu.previous_scrollbar.track_visible != scrollbar.track_visible ||
	    cpu.previous_scrollbar.track_color != scrollbar.track_color ||
	    cpu.previous_scrollbar.x != scrollbar.x || cpu.previous_scrollbar.width != scrollbar.width ||
	    cpu.previous_scrollbar.track_height != scrollbar.track_height ||
	    cpu.previous_scrollbar.cell_height != scrollbar.cell_height) {
		full_redraw = true
	}
	current_selection: selection.State
	if selection_state != nil do current_selection = selection_state^
	selection_changed := current_selection != cpu.previous_selection
	current_cursor_visible := cursor_visible(terminal)
	cursor_visibility_changed := cpu.previous_cursor_visible != current_cursor_visible
	image_generation := u64(0)
	if screen.image_registry != nil do image_generation = screen.image_registry.generation
	if cpu.previous_image_generation != image_generation do full_redraw = true
	if cpu.previous_image_row_offset != screen.image_row_offset do full_redraw = true
	any_dirty := false
	for row in 0..<screen.rows {
		dirty := full_redraw || row == screen.cursor.row || row == cpu.previous_cursor.row
		if scrollbar_changed &&
		   (scrollbar_row_affected(cpu.previous_scrollbar, row) || scrollbar_row_affected(scrollbar, row)) {
			dirty = true
		}
		if selection_changed &&
		   (selection_row_affected(&current_selection, row) || selection_row_affected(&cpu.previous_selection, row)) {
			dirty = true
		}
		if cursor_visibility_changed && (row == screen.cursor.row || row == cpu.previous_cursor.row) do dirty = true
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
		cpu.dirty_rows[row] = true
		any_dirty = true
		copy(
			cpu.previous[row*screen.columns:(row+1)*screen.columns],
			screen.cells[row*screen.columns:(row+1)*screen.columns],
		)
	}
	cpu.previous_cursor = screen.cursor
	cpu.previous_cursor_visible = current_cursor_visible
	cpu.previous_alternate = terminal.using_alternate
	cpu.previous_image_generation = image_generation
	cpu.previous_image_row_offset = screen.image_row_offset
	cpu.previous_selection = current_selection
	cpu.previous_scrollbar = scrollbar
	return any_dirty
}

selection_row_affected :: proc(state: ^selection.State, row: int) -> bool {
	if state == nil || !state.active do return false
	first, last := selection.bounds(state)
	return row >= first.row && row <= last.row
}

cpu_present :: proc(cpu: ^CPU, window: ^x11.Window, columns: int) {
	for dirty, row in cpu.dirty_rows {
		if !dirty do continue
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
			u32(cpu.width),
			u32(height),
		)
	}
	_ = xlib.Flush(window.display)
}

cpu_draw :: proc(
	cpu: ^CPU,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	ligatures: bool,
	force: bool,
	selection_state: ^selection.State = nil,
	screen_override: ^vt.Screen = nil,
	scrollbar: Scrollbar = {},
) {
	if !cpu_render(cpu, font, window, terminal, ligatures, force, selection_state, screen_override, scrollbar) do return
	screen := screen_override
	if screen == nil do screen = vt.terminal_screen(terminal)
	cpu_present(cpu, window, screen.columns)
}

render_row :: proc(
	cpu: ^CPU,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	screen: ^vt.Screen,
	row: int,
	ligatures: bool,
	selection_state: ^selection.State,
	scrollbar: Scrollbar,
) {
	if row*window.cell_h >= cpu.height do return
	build_row_commands(&cpu.commands, font, window, terminal, screen, row, ligatures, selection_state, scrollbar, active_force_bold)
	for command in cpu.commands {
		switch command.kind {
		case .Rectangle:
			if command.opacity == 0 {
				fill_rect(cpu, window, command.x, command.y, command.width, command.height, command.color)
			} else {
				blend_rect(cpu, window, command.x, command.y, command.width, command.height, command.color, command.opacity)
			}
		case .Image:
			if screen.image_registry == nil do continue
			image := graphics.find_image(screen.image_registry, command.image_id)
			if image != nil do draw_image(cpu, window, image, command)
		case .Glyph:
			glyph := fonts.face_glyph(font, command.face_id, command.glyph_index)
			if glyph == nil do continue
			draw_glyph(cpu, window, glyph, command.x, command.y, command.color, command.clip_left, command.clip_right)
		}
	}
}

draw_image :: proc(cpu: ^CPU, window: ^x11.Window, image: ^graphics.Resource, command: Command) {
	left := max(0, command.clip_left)
	right := min(cpu.width, command.clip_right)
	top := max(0, command.clip_top)
	bottom := min(cpu.height, command.clip_bottom)
	if left >= right || top >= bottom || command.width <= 0 || command.height <= 0 do return
	channels := graphics.bytes_per_pixel(image.format)
	for destination_y in top..<bottom {
		source_y := command.source_y+(destination_y-command.y)*command.source_height/command.height
		source_y = clamp(source_y, command.source_y, command.source_y+command.source_height-1)
		for destination_x in left..<right {
			source_x := command.source_x+(destination_x-command.x)*command.source_width/command.width
			source_x = clamp(source_x, command.source_x, command.source_x+command.source_width-1)
			index := source_y*image.stride+source_x*channels
			red := u32(image.pixels[index])
			green := u32(image.pixels[index+1])
			blue := u32(image.pixels[index+2])
			color := red<<16|green<<8|blue
			pixel := &cpu.pixels[destination_y*cpu.width+destination_x]
			if image.format == .RGBA8 {
				pixel^ = blend(window, pixel^, color, image.pixels[index+3])
			} else {
				pixel^ = rgb_to_pixel(window, color)
			}
		}
	}
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

blend_rect :: proc(cpu: ^CPU, window: ^x11.Window, x, y, width, height: int, color: u32, opacity: u8) {
	left, top := max(0, x), max(0, y)
	right, bottom := min(cpu.width, x+width), min(cpu.height, y+height)
	for destination_y in top..<bottom {
		for destination_x in left..<right {
			pixel := &cpu.pixels[destination_y*cpu.width+destination_x]
			pixel^ = blend(window, pixel^, color, opacity)
		}
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
	if cell.attributes.faint do foreground = mix_color(foreground, background)
	if cell.attributes.hidden do foreground = background
	return
}

mix_color :: proc(foreground, background: u32) -> u32 {
	red := (((foreground>>16)&0xff)+((background>>16)&0xff))/2
	green := (((foreground>>8)&0xff)+((background>>8)&0xff))/2
	blue := ((foreground&0xff)+(background&0xff))/2
	return red<<16|green<<8|blue
}

terminal_color :: proc(color: vt.Color, foreground: bool) -> u32 {
	switch color.kind {
	case .Default: return active_theme.foreground if foreground else active_theme.background
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
	return active_theme.ansi[clamp(index, 0, len(active_theme.ansi)-1)]
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
	if !cursor_visible(terminal) || row != screen.cursor.row || column != screen.cursor.column do return false
	return terminal.modes.cursor_style == .Blinking_Block || terminal.modes.cursor_style == .Steady_Block
}
