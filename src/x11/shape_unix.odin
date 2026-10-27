#+build linux, freebsd, openbsd

package x11

import xlib "vendor:x11/xlib"

foreign import system_xext "system:Xext"

@(default_calling_convention="c")
foreign system_xext {
	@(link_name="XShapeQueryExtension")
	shape_query_extension :: proc(display: ^xlib.Display, event_base, error_base: ^i32) -> b32 ---

	@(link_name="XShapeCombineRectangles")
	shape_combine_rectangles :: proc(
		display: ^xlib.Display,
		window: xlib.Window,
		destination_kind, x_offset, y_offset: i32,
		rectangles: [^]xlib.XRectangle,
		count, operation, ordering: i32,
	) ---

	@(link_name="XShapeCombineMask")
	shape_combine_mask :: proc(
		display: ^xlib.Display,
		window: xlib.Window,
		destination_kind, x_offset, y_offset: i32,
		mask: xlib.Pixmap,
		operation: i32,
	) ---
}

SHAPE_BOUNDING :: i32(0)
SHAPE_SET :: i32(0)
SHAPE_UNSORTED :: i32(0)

shape_supported :: proc(window: ^Window) -> bool {
	if window == nil || window.display == nil do return false
	if !window.shape_checked {
		window.shape_checked = true
		event_base, error_base: i32
		window.shape_available = shape_query_extension(window.display, &event_base, &error_base) != false
	}
	return window.shape_available
}

set_top_level_clip :: proc(window: ^Window, x, y, width, height: int) -> bool {
	if !shape_supported(window) do return false
	if width <= 0 || height <= 0 {
		shape_combine_rectangles(window.display, window.id, SHAPE_BOUNDING, 0, 0, nil, 0, SHAPE_SET, SHAPE_UNSORTED)
		return true
	}
	rectangle := xlib.XRectangle{
		x = i16(clamp(x, 0, int(max(i16)))),
		y = i16(clamp(y, 0, int(max(i16)))),
		width = u16(clamp(width, 1, int(max(u16)))),
		height = u16(clamp(height, 1, int(max(u16)))),
	}
	shape_combine_rectangles(window.display, window.id, SHAPE_BOUNDING, 0, 0, &rectangle, 1, SHAPE_SET, SHAPE_UNSORTED)
	return true
}

clear_top_level_clip :: proc(window: ^Window) {
	if !shape_supported(window) do return
	shape_combine_mask(window.display, window.id, SHAPE_BOUNDING, 0, 0, 0, SHAPE_SET)
}
