package render

import vt "../vt"
import x11 "../x11"

SCROLLBAR_WIDTH :: 6
SCROLLBAR_MIN_THUMB :: 12
SCROLLBAR_TRACK_COLOR :: u32(0x282828)
SCROLLBAR_THUMB_COLOR :: u32(0x8a8a8a)

Scrollbar :: struct {
	history_rows: int,
	offset: int,
}

Scrollbar_Geometry :: struct {
	visible: bool,
	x, y, width, height, track_height, cell_height: int,
}

scrollbar_geometry :: proc(window: ^x11.Window, screen: ^vt.Screen, scrollbar: Scrollbar) -> Scrollbar_Geometry {
	track_width := min(SCROLLBAR_WIDTH, max(1, screen.columns*window.cell_w))
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
		x = max(0, screen.columns*window.cell_w-track_width),
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
	append_rectangle(output, geometry.x, row_top, geometry.width, row_bottom-row_top, SCROLLBAR_TRACK_COLOR)
	thumb_top := max(row_top, geometry.y)
	thumb_bottom := min(row_bottom, geometry.y+geometry.height)
	if thumb_top < thumb_bottom {
		append_rectangle(output, geometry.x, thumb_top, geometry.width, thumb_bottom-thumb_top, SCROLLBAR_THUMB_COLOR)
	}
}
