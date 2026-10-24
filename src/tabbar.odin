package main

import c "core:c"
import libc "core:c/libc"
import fonts "font"
import drawing "render"
import x11 "x11"
import xlib "vendor:x11/xlib"

Tab_Draw_Label :: struct {
	text: string,
	active: bool,
}

TAB_HIT_EMPTY :: -1
TAB_HIT_LEFT  :: -2
TAB_HIT_RIGHT :: -3

tab_text_width :: proc(font: ^fonts.Manager, text: string, bold: bool) -> int {
	width := 0
	style := fonts.Style.Bold if bold else .Regular
	for codepoint in text {
		glyph := fonts.glyph_for_codepoint(font, codepoint, style)
		width += glyph.advance if glyph != nil else font.cell_width
	}
	return width
}

draw_workspace_tab_bar :: proc(
	window: ^x11.Window,
	font: ^fonts.Manager,
	labels: []Tab_Draw_Label,
	bounds: ^[dynamic]Tab_Bounds,
	y, height: int,
	background, active_foreground, active_background, inactive_foreground, inactive_background: u32,
	active_bold: bool,
	active_index: int,
	scroll_offset: ^int,
	reveal_active: bool,
) {
	clear(bounds)
	if height <= 0 || window.width <= 0 do return
	byte_count := window.width*height*size_of(u32)
	data := libc.malloc(c.size_t(byte_count))
	if data == nil do return
	image := xlib.CreateImage(window.display, window.visual, u32(window.depth), .ZPixmap, 0, data, u32(window.width), u32(height), 32, i32(window.width*size_of(u32)))
	if image == nil {
		libc.free(data)
		return
	}
	defer xlib.DestroyImage(image)
	pixels := (([^]u32)(data))[:window.width*height]
	background_pixel := drawing.rgb_to_pixel(window, background)
	for &pixel in pixels do pixel = background_pixel
	total_width := 0
	for label in labels do total_width += tab_label_width(font, label, active_bold)
	overflow := total_width > window.width
	arrow_width := 0
	content_left := 0
	content_right := window.width
	if overflow {
		arrow_width = tab_arrow_width(font, window.width, height)
		content_left = arrow_width
		content_right = max(content_left, window.width-arrow_width)
		page_width := content_right-content_left
		max_offset := max(0, total_width-page_width)
		scroll_offset^ = clamp(scroll_offset^, 0, max_offset)
		if reveal_active && active_index >= 0 && active_index < len(labels) {
			active_left := tab_width_between(font, labels, 0, active_index, active_bold)
			active_right := active_left+tab_label_width(font, labels[active_index], active_bold)
			if active_left < scroll_offset^ do scroll_offset^ = active_left
			else if active_right > scroll_offset^+page_width do scroll_offset^ = active_right-page_width
			scroll_offset^ = clamp(scroll_offset^, 0, max_offset)
		}
		draw_tab_arrow(pixels, window, font, "<", 0, arrow_width, height, inactive_background, active_background)
		draw_tab_arrow(pixels, window, font, ">", window.width-arrow_width, arrow_width, height, inactive_background, active_background)
		append(bounds, {x = 0, width = arrow_width, tab_index = TAB_HIT_LEFT})
		append(bounds, {x = window.width-arrow_width, width = arrow_width, tab_index = TAB_HIT_RIGHT})
	} else {
		scroll_offset^ = 0
	}
	x := content_left-scroll_offset^
	for label, index in labels {
		natural_width := tab_label_width(font, label, active_bold)
		if x+natural_width <= content_left {
			x += natural_width
			continue
		}
		if x >= content_right do break
		bold := label.active && active_bold
		visible_left := max(content_left, x)
		visible_right := min(content_right, x+natural_width)
		width := visible_right-visible_left
		if width <= 0 do break
		append(bounds, {x = visible_left, width = width, tab_index = index})
		bg := active_background if label.active else inactive_background
		fg := active_foreground if label.active else inactive_foreground
		fill_tab_rect(pixels, window, visible_left, 0, width, height, bg)
		draw_tab_text(pixels, window, font, label.text, x+6, 2+font.ascent, fg, bold, visible_left, visible_right-6)
		x += natural_width
	}
	xlib.PutImage(window.display, xlib.Drawable(window.id), window.gc, image, 0, 0, 0, i32(y), u32(window.width), u32(height))
	_ = xlib.Flush(window.display)
}

tab_arrow_width :: proc(font: ^fonts.Manager, window_width, height: int) -> int {
	return min(max(height, font.cell_width+12), max(1, window_width/4))
}

tab_label_width :: proc(font: ^fonts.Manager, label: Tab_Draw_Label, active_bold: bool) -> int {
	return max(1, tab_text_width(font, label.text, label.active && active_bold)+12)
}

tab_width_between :: proc(font: ^fonts.Manager, labels: []Tab_Draw_Label, first, end: int, active_bold: bool) -> int {
	width := 0
	for index in max(0, first)..<min(end, len(labels)) do width += tab_label_width(font, labels[index], active_bold)
	return width
}

draw_tab_arrow :: proc(pixels: []u32, window: ^x11.Window, font: ^fonts.Manager, text: string, x, width, height: int, background, foreground: u32) {
	fill_tab_rect(pixels, window, x, 0, width, height, background)
	text_width := tab_text_width(font, text, true)
	draw_tab_text(pixels, window, font, text, x+max(0, (width-text_width)/2), 2+font.ascent, foreground, true, x, x+width)
}

fill_tab_rect :: proc(pixels: []u32, window: ^x11.Window, x, y, width, height: int, color: u32) {
	pixel := drawing.rgb_to_pixel(window, color)
	for row in max(0, y)..<min(height+y, len(pixels)/window.width) {
		left := max(0, x)
		right := min(window.width, x+width)
		for column in left..<right do pixels[row*window.width+column] = pixel
	}
}

draw_tab_text :: proc(pixels: []u32, window: ^x11.Window, font: ^fonts.Manager, text: string, x, baseline: int, color: u32, bold: bool, clip_left, clip_right: int) {
	style := fonts.Style.Bold if bold else .Regular
	pen := x
	for codepoint in text {
		glyph := fonts.glyph_for_codepoint(font, codepoint, style)
		if glyph == nil { pen += font.cell_width; continue }
		left := pen+glyph.left
		top := baseline-glyph.top
		for row in 0..<glyph.height {
			destination_y := top+row
			if destination_y < 0 || destination_y >= len(pixels)/window.width do continue
			for column in 0..<glyph.width {
				destination_x := left+column
				if destination_x < clip_left || destination_x >= clip_right || destination_x >= window.width do continue
				offset := row*glyph.width+column
				alpha := glyph.pixels[offset]
				if glyph.kind == .BGRA do alpha = glyph.pixels[offset*4+3]
				if alpha == 0 do continue
				background := drawing.pixel_to_rgb(window, pixels[destination_y*window.width+destination_x])
				pixels[destination_y*window.width+destination_x] = drawing.rgb_to_pixel(window, blend_tab_color(background, color, alpha))
			}
		}
		pen += glyph.advance
		if pen >= clip_right do break
	}
}

blend_tab_color :: proc(background, foreground: u32, alpha: u8) -> u32 {
	inverse := 255-u32(alpha)
	red := (((foreground>>16)&0xff)*u32(alpha)+((background>>16)&0xff)*inverse)/255
	green := (((foreground>>8)&0xff)*u32(alpha)+((background>>8)&0xff)*inverse)/255
	blue := ((foreground&0xff)*u32(alpha)+(background&0xff)*inverse)/255
	return red<<16|green<<8|blue
}
