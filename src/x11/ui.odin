package x11

import xlib "vendor:x11/xlib"

configure_top_level :: proc(window: ^Window, x, y, width, height: int) {
	if window == nil || window.display == nil || window.id == 0 do return
	window.x, window.y = x, y
	window.width, window.height = max(1, width), max(1, height)
	xlib.MoveResizeWindow(window.display, window.id, i32(x), i32(y), u32(window.width), u32(window.height))
}

show_top_level :: proc(window: ^Window, take_focus: bool = true) {
	if window == nil || window.display == nil || window.id == 0 do return
	viewable := window_is_viewable(window)
	if take_focus {
		focus: xlib.Window
		revert: xlib.FocusRevert
		xlib.GetInputFocus(window.display, &focus, &revert)
		if focus != 0 && !focus_within(window) do window.previous_focus = focus
	}
	_ = xlib.MapRaised(window.display, window.id)
	window.mapped = true
	window.pending_focus = take_focus && !viewable
	if take_focus {
		request_top_level_activation(window)
		if viewable do focus_window(window)
	}
	_ = xlib.Flush(window.display)
}

request_top_level_activation :: proc(window: ^Window) {
	request_window_activation(window, window.id)
}

request_window_activation :: proc(window: ^Window, target: xlib.Window) {
	active_atom := xlib.InternAtom(window.display, "_NET_ACTIVE_WINDOW", false)
	if active_atom != 0 {
		screen := xlib.DefaultScreen(window.display)
		root := xlib.RootWindow(window.display, screen)
		event: xlib.XEvent
		event.xclient = {
			type = .ClientMessage,
			display = window.display,
			window = target,
			message_type = active_atom,
			format = 32,
		}
		event.xclient.data.l[0] = 1
		event.xclient.data.l[1] = int(xlib.CurrentTime)
		_ = xlib.SendEvent(window.display, root, false, {.SubstructureRedirect, .SubstructureNotify}, &event)
	}
}

hide_top_level :: proc(window: ^Window) {
	if window == nil || window.display == nil || window.id == 0 || !window.mapped do return
	_ = xlib.UnmapWindow(window.display, window.id)
	window.mapped = false
	window.pending_focus = false
	if window.previous_focus != 0 {
		attributes: xlib.XWindowAttributes
		if xlib.GetWindowAttributes(window.display, window.previous_focus, &attributes) != 0 && attributes.map_state == .IsViewable {
			request_window_activation(window, window.previous_focus)
		}
	}
	_ = xlib.Flush(window.display)
}

focus_within :: proc(window: ^Window) -> bool {
	if window == nil || window.display == nil || window.id == 0 do return false
	focused: xlib.Window
	revert: xlib.FocusRevert
	xlib.GetInputFocus(window.display, &focused, &revert)
	if focused == window.id do return true
	for focused != 0 {
		root, parent: xlib.Window
		children: [^]xlib.Window
		count: u32
		if xlib.QueryTree(window.display, focused, &root, &parent, &children, &count) != .Success do return false
		if children != nil do xlib.Free(children)
		if parent == window.id do return true
		if parent == 0 || parent == focused || parent == root do return false
		focused = parent
	}
	return false
}

pointer_button_down :: proc(window: ^Window) -> bool {
	root, child: xlib.Window
	root_x, root_y, x, y: i32
	mask: xlib.KeyMask
	if xlib.QueryPointer(window.display, window.id, &root, &child, &root_x, &root_y, &x, &y, &mask) == false do return false
	buttons := transmute(xlib.InputMask)mask
	return .Button1Mask in buttons || .Button2Mask in buttons || .Button3Mask in buttons
}

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
