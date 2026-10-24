package x11

import xlib "vendor:x11/xlib"

focus_child :: proc(child: ^Window) {
	_ = xlib.Sync(child.display, false)
	xlib.SetInputFocus(child.display, child.id, .RevertToParent, xlib.Time(xlib.CurrentTime))
	_ = xlib.Flush(child.display)
}

focus_window :: proc(window: ^Window) {
	_ = xlib.Sync(window.display, false)
	xlib.SetInputFocus(window.display, window.id, .RevertToParent, xlib.Time(xlib.CurrentTime))
	_ = xlib.Flush(window.display)
}

set_surface_colors :: proc(window: ^Window, background, border: u32, border_width: int = 0) {
	xlib.SetWindowBackground(window.display, window.id, uint(background))
	xlib.SetWindowBorder(window.display, window.id, uint(border))
	xlib.SetWindowBorderWidth(window.display, window.id, u32(max(0, border_width)))
	xlib.ClearWindow(window.display, window.id)
}
