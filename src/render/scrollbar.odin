package render

import vt "../vt"
import x11 "../x11"

SCROLLBAR_HIT_WIDTH :: 12
SCROLLBAR_THUMB_WIDTH :: 4
SCROLLBAR_MIN_THUMB :: 24
SCROLLBAR_TRACK_ALPHA :: u32(160)
SCROLLBAR_THUMB_LIGHTEN :: u32(72)

Scrollbar :: struct {
	history_rows: int,
	offset: int,
	hovered: bool,
	track_color: u32,
}

Scrollbar_Geometry :: struct {
	visible: bool,
	track_visible: bool,
	track_color: u32,
	x, y, width, height, track_height, cell_height: int,
}

scrollbar_geometry :: proc(window: ^x11.Window, screen: ^vt.Screen, scrollbar: Scrollbar) -> Scrollbar_Geometry {
	track_width := min(SCROLLBAR_HIT_WIDTH, max(1, window.width))
	track_height := min(window.height, screen.rows*window.cell_h)
	if scrollbar.history_rows <= 0 || track_height <= 0 do return {}
	total_rows := scrollbar.history_rows+screen.rows
	thumb_height := clamp(track_height*screen.rows/total_rows, min(SCROLLBAR_MIN_THUMB, track_height), track_height)
	travel := track_height-thumb_height
	offset := clamp(scrollbar.offset, 0, scrollbar.history_rows)
	y := 0
	if travel > 0 do y = travel*(scrollbar.history_rows-offset)/scrollbar.history_rows
	return {
		visible = true,
		track_visible = scrollbar.hovered,
		track_color = scrollbar.track_color,
		x = max(0, window.width-track_width),
		y = y,
		width = track_width,
		height = thumb_height,
		track_height = track_height,
		cell_height = window.cell_h,
	}
}

scrollbar_row_affected :: proc(geometry: Scrollbar_Geometry, row: int) -> bool {
	if !geometry.visible || geometry.cell_height <= 0 do return false
	row_top, row_bottom := row*geometry.cell_height, (row+1)*geometry.cell_height
	return geometry.y < row_bottom && geometry.y+geometry.height > row_top
}

scrollbar_offset_at :: proc(scrollbar: Scrollbar, geometry: Scrollbar_Geometry, pointer_y, grab_y: int) -> int {
	if !geometry.visible || scrollbar.history_rows <= 0 do return 0
	travel := geometry.track_height-geometry.height
	if travel <= 0 do return 0
	thumb_y := clamp(pointer_y-grab_y, 0, travel)
	return scrollbar.history_rows-thumb_y*scrollbar.history_rows/travel
}

scrollbar_thumb_color :: proc() -> u32 {
	background := active_theme.background
	foreground := active_theme.foreground
	amount := SCROLLBAR_THUMB_LIGHTEN
	inverse := u32(255)-amount
	red := (((background>>16)&0xff)*inverse+((foreground>>16)&0xff)*amount)/255
	green := (((background>>8)&0xff)*inverse+((foreground>>8)&0xff)*amount)/255
	blue := ((background&0xff)*inverse+(foreground&0xff)*amount)/255
	return red<<16 | green<<8 | blue
}

append_scrollbar_commands :: proc(
	output: ^[dynamic]Command,
	window: ^x11.Window,
	screen: ^vt.Screen,
	row: int,
	scrollback: Scrollbar,
) {
	geometry := scrollbar_geometry(window, screen, scrollback)
	if !geometry.visible do return
	row_top := row*window.cell_h
	row_bottom := min(geometry.track_height, row_top+window.cell_h)
	if row_top >= row_bottom do return
	if geometry.track_visible {
		append_translucent_rectangle(
			output,
			geometry.x,
			row_top,
			geometry.width,
			row_bottom-row_top,
			geometry.track_color,
			u8(SCROLLBAR_TRACK_ALPHA),
		)
	}
	thumb_top := max(row_top, geometry.y)
	thumb_bottom := min(row_bottom, geometry.y+geometry.height)
	if thumb_top < thumb_bottom {
		thumb_width := min(SCROLLBAR_THUMB_WIDTH, geometry.width)
		if geometry.track_visible do thumb_width = geometry.width
		thumb_x := geometry.x+geometry.width-thumb_width
		thumb_color := scrollbar_thumb_color()
		cap := min(2, geometry.height/2)
		part_top := thumb_top
		part_bottom := thumb_bottom
		if thumb_top < geometry.y+cap {
			part_top = min(thumb_bottom, geometry.y+cap)
			append_rectangle(output, thumb_x+1, thumb_top, max(1, thumb_width-2), part_top-thumb_top, thumb_color)
		}
		if part_top < min(part_bottom, geometry.y+geometry.height-cap) {
			middle_bottom := min(part_bottom, geometry.y+geometry.height-cap)
			append_rectangle(output, thumb_x, part_top, thumb_width, middle_bottom-part_top, thumb_color)
			part_top = middle_bottom
		}
		if part_top < part_bottom {
			append_rectangle(output, thumb_x+1, part_top, max(1, thumb_width-2), part_bottom-part_top, thumb_color)
		}
	}
}
