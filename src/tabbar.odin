package main

import c "core:c"
import libc "core:c/libc"
import "core:strings"
import "core:unicode/utf8"
import fonts "font"
import drawing "render"
import x11 "x11"
import xlib "vendor:x11/xlib"

Tab_Draw_Label :: struct {
	text: string,
	active: bool,
	root: bool,
	tmux: bool,
}

Statusbar_Draw_Module :: struct {
	text: string,
	foreground, background: u32,
	jobs: bool,
}

Statusbar_Render_Cache :: struct {
	image: ^xlib.XImage,
	pixels: []u32,
	width, height: int,
	font: ^fonts.Manager,
	font_ascent, font_cell_height: int,
	background, foreground, accent: u32,
	blocks, border: bool,
	left, center, right: string,
	jobs_hit_left, jobs_hit_right: int,
	jobs_hit_valid: bool,
	image_allocations, rasterizations, presentations: u64,
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
	background, active_foreground, active_background, inactive_foreground, inactive_background, root_background, tmux_background: u32,
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
	new_tab_space := tab_new_tab_space_width(font, window.width)
	bar_content_width := max(1, window.width-new_tab_space)
	widths := tab_layout_widths(font, labels, active_bold, bar_content_width)
	total_width := 0
	for width in widths do total_width += width
	overflow := total_width > bar_content_width
	arrow_width := 0
	content_left := 0
	content_right := bar_content_width
	if overflow {
		arrow_width = tab_arrow_width(font, window.width, height)
		content_left = arrow_width
		content_right = max(content_left, bar_content_width-arrow_width)
		page_width := content_right-content_left
		max_offset := max(0, total_width-page_width)
		scroll_offset^ = clamp(scroll_offset^, 0, max_offset)
		if reveal_active && active_index >= 0 && active_index < len(labels) {
			active_left := tab_width_between(widths, 0, active_index)
			active_right := active_left+widths[active_index]
			if active_left < scroll_offset^ do scroll_offset^ = active_left
			else if active_right > scroll_offset^+page_width do scroll_offset^ = active_right-page_width
			scroll_offset^ = clamp(scroll_offset^, 0, max_offset)
		}
		draw_tab_arrow(pixels, window, font, "<", 0, arrow_width, height, inactive_background, active_background)
		draw_tab_arrow(pixels, window, font, ">", content_right, arrow_width, height, inactive_background, active_background)
		append(bounds, {x = 0, width = arrow_width, tab_index = TAB_HIT_LEFT})
		append(bounds, {x = content_right, width = arrow_width, tab_index = TAB_HIT_RIGHT})
	} else {
		scroll_offset^ = 0
	}
	x := content_left-scroll_offset^
	for label, index in labels {
		tab_width := widths[index]
		if x+tab_width <= content_left {
			x += tab_width
			continue
		}
		if x >= content_right do break
		bold := label.active && active_bold
		visible_left := max(content_left, x)
		visible_right := min(content_right, x+tab_width)
		width := visible_right-visible_left
		if width <= 0 do break
		append(bounds, {x = visible_left, width = width, tab_index = index})
		bg := active_background if label.active else inactive_background
		fg := active_foreground if label.active else inactive_foreground
		if label.active && label.tmux do bg = tmux_background
		if label.root {
			if label.active {
				bg = root_background
				fg = active_foreground
			} else {
				bg = muted_root_tab_color(root_background, inactive_background)
				fg = inactive_foreground
			}
		}
		fill_tab_rect(pixels, window, visible_left, 0, width, height, bg)
		draw_tab_text(pixels, window, font, label.text, x+6, 2+font.ascent, fg, bold, visible_left, visible_right-6)
		x += tab_width
	}
	xlib.PutImage(window.display, xlib.Drawable(window.id), window.gc, image, 0, 0, 0, i32(y), u32(window.width), u32(height))
	_ = xlib.Flush(window.display)
}

draw_workspace_search_bar :: proc(
	window: ^x11.Window,
	font: ^fonts.Manager,
	text: string,
	y, height: int,
	background, foreground: u32,
) {
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
	draw_tab_text(pixels, window, font, text, 8, 3+font.ascent, foreground, false, 0, window.width-8)
	xlib.PutImage(window.display, xlib.Drawable(window.id), window.gc, image, 0, 0, 0, i32(y), u32(window.width), u32(height))
	_ = xlib.Flush(window.display)
}

draw_workspace_close_dialog :: proc(
	window: ^x11.Window,
	font: ^fonts.Manager,
	background, foreground, accent, secondary: u32,
) {
	if window.width <= 0 || window.height <= 0 do return
	byte_count := window.width*window.height*size_of(u32)
	data := libc.malloc(c.size_t(byte_count))
	if data == nil do return
	image := xlib.CreateImage(window.display, window.visual, u32(window.depth), .ZPixmap, 0, data, u32(window.width), u32(window.height), 32, i32(window.width*size_of(u32)))
	if image == nil {
		libc.free(data)
		return
	}
	defer xlib.DestroyImage(image)
	pixels := (([^]u32)(data))[:window.width*window.height]
	background_pixel := drawing.rgb_to_pixel(window, background)
	for &pixel in pixels do pixel = background_pixel
	border := 2
	fill_tab_rect(pixels, window, 0, 0, window.width, border, accent)
	fill_tab_rect(pixels, window, 0, window.height-border, window.width, border, accent)
	fill_tab_rect(pixels, window, 0, 0, border, window.height, accent)
	fill_tab_rect(pixels, window, window.width-border, 0, border, window.height, accent)
	message := "Close this terminal?"
	message_width := tab_text_width(font, message, true)
	draw_tab_text(pixels, window, font, message, max(12, (window.width-message_width)/2), font.ascent+12, foreground, true, 8, window.width-8)
	button_y := window.height-font.cell_height-12
	button_height := font.cell_height+4
	button_gap := 8
	button_width := max(1, (window.width-24-button_gap)/2)
	close_x := 12
	cancel_x := close_x+button_width+button_gap
	fill_tab_rect(pixels, window, close_x, button_y, button_width, button_height, accent)
	fill_tab_rect(pixels, window, cancel_x, button_y, button_width, button_height, secondary)
	close_label := "Close [Enter]"
	cancel_label := "Cancel [Esc]"
	close_text_x := close_x+max(4, (button_width-tab_text_width(font, close_label, false))/2)
	cancel_text_x := cancel_x+max(4, (button_width-tab_text_width(font, cancel_label, false))/2)
	draw_tab_text(pixels, window, font, close_label, close_text_x, button_y+font.ascent+2, foreground, false, close_x+4, close_x+button_width-4)
	draw_tab_text(pixels, window, font, cancel_label, cancel_text_x, button_y+font.ascent+2, foreground, false, cancel_x+4, cancel_x+button_width-4)
	xlib.PutImage(window.display, xlib.Drawable(window.id), window.gc, image, 0, 0, 0, 0, u32(window.width), u32(window.height))
	_ = xlib.Flush(window.display)
}

draw_workspace_statusbar_jobs :: proc(
	window: ^x11.Window,
	font: ^fonts.Manager,
	rows: []Statusbar_Draw_Module,
	selected: int,
	x, y, width, row_height: int,
	accent: u32,
) {
	height := row_height*len(rows)
	if window == nil || width <= 0 || height <= 0 do return
	byte_count := width*height*size_of(u32)
	data := libc.malloc(c.size_t(byte_count))
	if data == nil do return
	image := xlib.CreateImage(window.display, window.visual, u32(window.depth), .ZPixmap, 0, data, u32(width), u32(height), 32, i32(width*size_of(u32)))
	if image == nil {libc.free(data); return}
	defer xlib.DestroyImage(image)
	pixels := (([^]u32)(data))[:width*height]
	for row, index in rows {
		row_y := row_height*index
		fill_tab_rect(pixels, window, 0, row_y, width, row_height, row.background)
		if index == selected do fill_tab_rect(pixels, window, 0, row_y, min(3, width), row_height, accent)
		text := ui_fit_text(font, row.text, max(0, width-16))
		draw_tab_text(pixels, window, font, text, 8, row_y+font.ascent+3, row.foreground, false, 8, width-8)
	}
	xlib.PutImage(window.display, xlib.Drawable(window.id), window.gc, image, 0, 0, i32(x), i32(y), u32(width), u32(height))
	_ = xlib.Flush(window.display)
}

draw_workspace_statusbar :: proc(
	cache: ^Statusbar_Render_Cache,
	window: ^x11.Window,
	font: ^fonts.Manager,
	left, center, right: string,
	left_modules, center_modules, right_modules: []Statusbar_Draw_Module,
	separator: string,
	blocks, border: bool,
	y, height, row_y, row_height: int,
	background, foreground, accent: u32,
) {
	if cache == nil || height <= 0 || window.width <= 0 do return
	geometry_changed := cache.image == nil || cache.width != window.width || cache.height != height
	if geometry_changed {
		statusbar_render_cache_release_image(cache)
		byte_count := window.width*height*size_of(u32)
		data := libc.malloc(c.size_t(byte_count))
		if data == nil do return
		cache.image = xlib.CreateImage(window.display, window.visual, u32(window.depth), .ZPixmap, 0, data, u32(window.width), u32(height), 32, i32(window.width*size_of(u32)))
		if cache.image == nil {
			libc.free(data)
			return
		}
		cache.pixels = (([^]u32)(data))[:window.width*height]
		cache.width = window.width
		cache.height = height
		cache.image_allocations += 1
	}
	content_changed := geometry_changed || cache.font != font || cache.font_ascent != font.ascent || cache.font_cell_height != font.cell_height ||
	                   cache.background != background || cache.foreground != foreground || cache.accent != accent ||
	                   cache.blocks != blocks || cache.border != border ||
	                   cache.left != left || cache.center != center || cache.right != right
	if content_changed {
		cache.rasterizations += 1
		cache.jobs_hit_valid = false
		cache.jobs_hit_left, cache.jobs_hit_right = 0, 0
		background_pixel := drawing.rgb_to_pixel(window, background)
		for &pixel in cache.pixels do pixel = background_pixel
		if border do fill_tab_rect(cache.pixels, window, 0, 0, window.width, min(2, height), accent)
		padding := 8
		baseline := row_y+max(font.ascent+2, (row_height-font.cell_height)/2+font.ascent)
		if blocks {
			padding = 0
			right_width := statusbar_module_group_width(font, right_modules)
			right_x := window.width-padding-right_width
			statusbar_draw_module_group(cache, window, font, right_modules, right_x, baseline, row_y, row_height, padding, window.width-padding)
			right_boundary := max(padding, right_x)
			left_right := max(padding, right_boundary-padding)
			left_width := min(statusbar_module_group_width(font, left_modules), max(0, left_right-padding))
			left_end := statusbar_draw_module_group(cache, window, font, left_modules, padding, baseline, row_y, row_height, padding, padding+left_width)
			center_left := min(right_boundary, left_end+padding)
			center_right := max(center_left, right_boundary-padding)
			center_width := min(statusbar_module_group_width(font, center_modules), center_right-center_left)
			center_x := clamp((window.width-center_width)/2, center_left, max(center_left, center_right-center_width))
			statusbar_draw_module_group(cache, window, font, center_modules, center_x, baseline, row_y, row_height, center_left, center_right)
		} else {
			right_text := ui_fit_text(font, right, max(0, window.width-padding*2))
			right_width := tab_text_width(font, right_text, false)
			right_x := max(padding, window.width-padding-right_width)
			if right_text != "" {
				draw_tab_text(cache.pixels, window, font, right_text, right_x, baseline, foreground, false, right_x, window.width-padding)
				statusbar_record_plain_job_hits(cache, font, right_modules, separator, right_x, right_x+right_width)
			}
			left_available := max(0, right_x-padding*2)
			left_text := ui_fit_text(font, left, left_available)
			left_width := tab_text_width(font, left_text, false)
			left_end := padding+left_width
			if left_text != "" {
				draw_tab_text(cache.pixels, window, font, left_text, padding, baseline, foreground, false, padding, left_end)
				statusbar_record_plain_job_hits(cache, font, left_modules, separator, padding, left_end)
			}
			if center != "" {
				center_left := min(right_x, left_end+padding)
				center_right := max(center_left, right_x-padding)
				center_text := ui_fit_text(font, center, center_right-center_left)
				center_width := tab_text_width(font, center_text, false)
				center_x := clamp((window.width-center_width)/2, center_left, max(center_left, center_right-center_width))
				draw_tab_text(cache.pixels, window, font, center_text, center_x, baseline, foreground, false, center_left, center_right)
				statusbar_record_plain_job_hits(cache, font, center_modules, separator, center_x, center_x+center_width)
			}
		}
		cache.font = font
		cache.font_ascent = font.ascent
		cache.font_cell_height = font.cell_height
		cache.background, cache.foreground, cache.accent = background, foreground, accent
		cache.blocks, cache.border = blocks, border
		statusbar_cache_string(&cache.left, left)
		statusbar_cache_string(&cache.center, center)
		statusbar_cache_string(&cache.right, right)
	}
	cache.presentations += 1
	xlib.PutImage(window.display, xlib.Drawable(window.id), window.gc, cache.image, 0, 0, 0, i32(y), u32(window.width), u32(height))
	_ = xlib.Flush(window.display)
}

statusbar_record_job_hit :: proc(cache: ^Statusbar_Render_Cache, left, right: int) {
	if cache == nil || right <= left do return
	if !cache.jobs_hit_valid {
		cache.jobs_hit_left = left
		cache.jobs_hit_right = right
		cache.jobs_hit_valid = true
	} else {
		cache.jobs_hit_left = min(cache.jobs_hit_left, left)
		cache.jobs_hit_right = max(cache.jobs_hit_right, right)
	}
}

statusbar_record_plain_job_hits :: proc(
	cache: ^Statusbar_Render_Cache,
	font: ^fonts.Manager,
	modules: []Statusbar_Draw_Module,
	separator: string,
	left, right: int,
) {
	if right <= left do return
	cursor := left
	separator_width := tab_text_width(font, separator, false)
	for module, index in modules {
		if index > 0 do cursor += separator_width
		module_right := cursor+tab_text_width(font, module.text, false)
		if module.jobs do statusbar_record_job_hit(cache, max(left, cursor), min(right, module_right))
		cursor = module_right
		if cursor >= right do break
	}
}

statusbar_module_group_width :: proc(font: ^fonts.Manager, modules: []Statusbar_Draw_Module) -> int {
	width := 0
	for module in modules do width += tab_text_width(font, module.text, false)+12
	return width
}

statusbar_draw_module_group :: proc(
	cache: ^Statusbar_Render_Cache,
	window: ^x11.Window,
	font: ^fonts.Manager,
	modules: []Statusbar_Draw_Module,
	x, baseline, row_y, row_height, clip_left, clip_right: int,
) -> int {
	cursor := x
	for module in modules {
		module_width := tab_text_width(font, module.text, false)+12
		visible_left := max(cursor, clip_left)
		visible_right := min(cursor+module_width, clip_right)
		if visible_right > visible_left {
			fill_tab_rect(cache.pixels, window, visible_left, row_y, visible_right-visible_left, row_height, module.background)
			if module.jobs do statusbar_record_job_hit(cache, visible_left, visible_right)
			text_left := max(cursor+6, visible_left)
			text_right := min(cursor+module_width-6, visible_right)
			if text_right > text_left {
				text := ui_fit_text(font, module.text, text_right-text_left)
				draw_tab_text(cache.pixels, window, font, text, text_left, baseline, module.foreground, false, text_left, text_right)
			}
		}
		cursor += module_width
		if cursor >= clip_right do break
	}
	return min(cursor, clip_right)
}

statusbar_render_cache_destroy :: proc(cache: ^Statusbar_Render_Cache) {
	if cache == nil do return
	statusbar_render_cache_invalidate(cache)
	cache^ = {}
}

statusbar_render_cache_invalidate :: proc(cache: ^Statusbar_Render_Cache) {
	if cache == nil do return
	image_allocations := cache.image_allocations
	rasterizations := cache.rasterizations
	presentations := cache.presentations
	statusbar_render_cache_release_image(cache)
	delete(cache.left)
	delete(cache.center)
	delete(cache.right)
	cache^ = {}
	cache.image_allocations = image_allocations
	cache.rasterizations = rasterizations
	cache.presentations = presentations
}

statusbar_render_cache_release_image :: proc(cache: ^Statusbar_Render_Cache) {
	if cache.image != nil do xlib.DestroyImage(cache.image)
	cache.image = nil
	cache.pixels = nil
	cache.width, cache.height = 0, 0
}

statusbar_cache_string :: proc(target: ^string, value: string) {
	if target^ == value do return
	delete(target^)
	target^ = strings.clone(value)
}

ui_fit_text :: proc(font: ^fonts.Manager, text: string, available: int) -> string {
	if available <= 0 do return ""
	if tab_text_width(font, text, false) <= available do return text
	ellipsis := "…"
	ellipsis_width := tab_text_width(font, ellipsis, false)
	if ellipsis_width > available do return ""
	output := make([dynamic]byte, 0, len(text), context.temp_allocator)
	width := 0
	for codepoint in text {
		glyph := fonts.glyph_for_codepoint(font, codepoint, .Regular)
		advance := glyph.advance if glyph != nil else font.cell_width
		if width+advance+ellipsis_width > available do break
		encoded, count := utf8.encode_rune(codepoint)
		append(&output, ..encoded[:count])
		width += advance
	}
	append(&output, ..transmute([]byte)ellipsis)
	return string(output[:])
}

muted_root_tab_color :: proc(root, inactive: u32) -> u32 {
	red := (((root>>16)&0xff)*2+((inactive>>16)&0xff))/3
	green := (((root>>8)&0xff)*2+((inactive>>8)&0xff))/3
	blue := ((root&0xff)*2+(inactive&0xff))/3
	return red<<16|green<<8|blue
}

tab_arrow_width :: proc(font: ^fonts.Manager, window_width, height: int) -> int {
	return min(max(height, font.cell_width+12), max(1, window_width/4))
}

tab_new_tab_space_width :: proc(font: ^fonts.Manager, window_width: int) -> int {
	return min(max(20, font.cell_width*3), max(1, window_width/4))
}

tab_label_width :: proc(font: ^fonts.Manager, label: Tab_Draw_Label, active_bold: bool) -> int {
	return max(1, tab_text_width(font, label.text, label.active && active_bold)+12)
}

tab_layout_widths :: proc(font: ^fonts.Manager, labels: []Tab_Draw_Label, active_bold: bool, available: int) -> []int {
	widths := make([]int, len(labels), context.temp_allocator)
	minimums := make([]int, len(labels), context.temp_allocator)
	total := 0
	minimum_total := 0
	minimum_width := font.cell_width*5+12
	for label, index in labels {
		widths[index] = tab_label_width(font, label, active_bold)
		minimums[index] = min(widths[index], minimum_width)
		total += widths[index]
		minimum_total += minimums[index]
	}
	if total <= available do return widths
	if minimum_total > available {
		copy(widths, minimums)
		return widths
	}
	for total > available {
		shrinkable := 0
		for width, index in widths do if width > minimums[index] do shrinkable += 1
		if shrinkable == 0 do break
		step := max(1, (total-available+shrinkable-1)/shrinkable)
		for &width, index in widths {
			if width <= minimums[index] do continue
			reduction := min(width-minimums[index], min(step, total-available))
			width -= reduction
			total -= reduction
			if total <= available do break
		}
	}
	return widths
}

tab_width_between :: proc(widths: []int, first, end: int) -> int {
	width := 0
	for index in max(0, first)..<min(end, len(widths)) do width += widths[index]
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
