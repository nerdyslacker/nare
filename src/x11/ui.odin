package x11

import xlib "vendor:x11/xlib"

focus_child :: proc(child: ^Window) {
	if !window_is_viewable(child) do return
	xlib.SetInputFocus(child.display, child.id, .RevertToParent, xlib.Time(xlib.CurrentTime))
	_ = xlib.Flush(child.display)
}

focus_window :: proc(window: ^Window) {
	if !window_is_viewable(window) do return
	xlib.SetInputFocus(window.display, window.id, .RevertToParent, xlib.Time(xlib.CurrentTime))
	_ = xlib.Flush(window.display)
}

window_is_viewable :: proc(window: ^Window) -> bool {
	if window == nil || window.display == nil || window.id == 0 do return false
	attributes: xlib.XWindowAttributes
	return xlib.GetWindowAttributes(window.display, window.id, &attributes) != 0 && attributes.map_state == .IsViewable
}

set_surface_colors :: proc(window: ^Window, background, border: u32, border_width: int = 0) {
	xlib.SetWindowBackground(window.display, window.id, uint(background))
	xlib.SetWindowBorder(window.display, window.id, uint(border))
	xlib.SetWindowBorderWidth(window.display, window.id, u32(max(0, border_width)))
	xlib.ClearWindow(window.display, window.id)
}
