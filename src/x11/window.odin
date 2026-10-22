package x11

import "core:math"
import xlib "vendor:x11/xlib"

DEFAULT_WIDTH  :: 800
DEFAULT_HEIGHT :: 480

Error :: enum { None, Open_Display, Create_Window, WM_Protocol }
Event_Kind :: enum { None, Close, Redraw, Resize, Focus, Input }

Event :: struct {
	kind:       Event_Kind,
	width:      int,
	height:     int,
	focused:    bool,
	input:      [64]byte,
	input_size: int,
}

Window :: struct {
	display:   ^xlib.Display,
	id:        xlib.Window,
	wm_delete: xlib.Atom,
	width:     int,
	height:    int,
	dpi:       f32,
	cell_w:    int,
	cell_h:    int,
	focused:   bool,
}

open :: proc(title: cstring = "nare") -> (window: Window, err: Error) {
	display := xlib.OpenDisplay(nil)
	if display == nil do return window, .Open_Display
	window.display = display
	screen := xlib.DefaultScreen(display)
	window.id = xlib.CreateSimpleWindow(
		display,
		xlib.RootWindow(display, screen),
		0,
		0,
		DEFAULT_WIDTH,
		DEFAULT_HEIGHT,
		0,
		xlib.WhitePixel(display, screen),
		xlib.BlackPixel(display, screen),
	)
	if window.id == 0 {
		close(&window)
		return window, .Create_Window
	}

	window.width = DEFAULT_WIDTH
	window.height = DEFAULT_HEIGHT
	window.dpi = display_dpi(display, screen)
	scale := max(window.dpi / 96, 0.75)
	window.cell_w = max(1, int(math.round(8 * scale)))
	window.cell_h = max(1, int(math.round(16 * scale)))
	xlib.SelectInput(display, window.id, {.KeyPress, .Exposure, .StructureNotify, .FocusChange})
	window.wm_delete = xlib.InternAtom(display, "WM_DELETE_WINDOW", false)
	if window.wm_delete == 0 || xlib.SetWMProtocols(display, window.id, &window.wm_delete, 1) == .Success {
		close(&window)
		return window, .WM_Protocol
	}
	xlib.StoreName(display, window.id, title)
	_ = xlib.MapWindow(display, window.id)
	_ = xlib.Flush(display)
	return window, .None
}

display_dpi :: proc(display: ^xlib.Display, screen: i32) -> f32 {
	pixels := xlib.DisplayWidth(display, screen)
	millimeters := xlib.DisplayWidthMM(display, screen)
	if pixels <= 0 || millimeters <= 0 do return 96
	return f32(pixels) * 25.4 / f32(millimeters)
}

connection_fd :: proc(window: ^Window) -> int {
	return int(xlib.ConnectionNumber(window.display))
}

grid_size :: proc(window: ^Window) -> (columns, rows: int) {
	return max(1, window.width / window.cell_w), max(1, window.height / window.cell_h)
}

next_event :: proc(window: ^Window) -> (result: Event, available: bool) {
	if xlib.Pending(window.display) == 0 do return result, false
	event: xlib.XEvent
	xlib.NextEvent(window.display, &event)
	#partial switch event.type {
	case .ClientMessage:
		if xlib.Atom(event.xclient.data.l[0]) == window.wm_delete do result.kind = .Close
	case .Expose:
		result.kind = .Redraw
	case .ConfigureNotify:
		if int(event.xconfigure.width) != window.width || int(event.xconfigure.height) != window.height {
			window.width = int(event.xconfigure.width)
			window.height = int(event.xconfigure.height)
			result.kind = .Resize
			result.width = window.width
			result.height = window.height
		}
	case .FocusIn:
		window.focused = true
		result.kind = .Focus
		result.focused = true
	case .FocusOut:
		window.focused = false
		result.kind = .Focus
	case .KeyPress:
		keysym: xlib.KeySym
		count := xlib.LookupString(&event.xkey, &result.input[0], len(result.input), &keysym, nil)
		if count > 0 {
			result.kind = .Input
			result.input_size = int(count)
		}
	case:
	}
	return result, true
}

redraw :: proc(window: ^Window) {
	xlib.ClearWindow(window.display, window.id)
	_ = xlib.Flush(window.display)
}

close :: proc(window: ^Window) {
	if window.display == nil do return
	if window.id != 0 do xlib.DestroyWindow(window.display, window.id)
	xlib.CloseDisplay(window.display)
	window^ = {}
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None:          return "none"
	case .Open_Display:  return "could not open X11 display"
	case .Create_Window: return "could not create X11 window"
	case .WM_Protocol:   return "could not register WM_DELETE_WINDOW"
	}
	return "unknown X11 error"
}
