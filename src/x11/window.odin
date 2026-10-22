package x11

import "core:math"
import keyboard "../input"
import xlib "vendor:x11/xlib"

DEFAULT_WIDTH  :: 800
DEFAULT_HEIGHT :: 480

Error :: enum { None, Open_Display, Create_Window, Create_Renderer, WM_Protocol }
Event_Kind :: enum { None, Close, Redraw, Resize, Focus, Input, Mouse }

Event :: struct {
	kind:       Event_Kind,
	width:      int,
	height:     int,
	focused:    bool,
	input:      [64]byte,
	input_size: int,
	key:        keyboard.Key,
	modifiers:  keyboard.Modifiers,
	mouse:      keyboard.Mouse_Event,
}

Window :: struct {
	display:   ^xlib.Display,
	id:        xlib.Window,
	gc:        xlib.GC,
	font:      ^xlib.XFontStruct,
	visual:    ^xlib.Visual,
	wm_delete: xlib.Atom,
	width:     int,
	height:    int,
	dpi:       f32,
	black:     uint,
	white:     uint,
	cell_w:    int,
	cell_h:    int,
	focused:   bool,
	mouse_tracking: int,
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
	window.black = xlib.BlackPixel(display, screen)
	window.white = xlib.WhitePixel(display, screen)
	window.visual = xlib.DefaultVisual(display, screen)
	window.font = xlib.LoadQueryFont(display, "fixed")
	if window.font == nil {
		close(&window)
		return window, .Create_Renderer
	}
	values := xlib.XGCValues{
		foreground = window.white,
		background = window.black,
		font = window.font.fid,
		graphics_exposures = false,
	}
	window.gc = xlib.CreateGC(
		display,
		xlib.Drawable(window.id),
		{.GCForeground, .GCBackground, .GCFont, .GCGraphicsExposures},
		&values,
	)
	if window.gc == nil {
		close(&window)
		return window, .Create_Renderer
	}
	scale := max(window.dpi / 96, 0.75)
	window.cell_w = max(1, int(math.round(f32(window.font.max_bounds.width) * scale)))
	window.cell_h = max(1, int(math.round(f32(window.font.ascent+window.font.descent) * scale)))
	xlib.SelectInput(display, window.id, base_event_mask())
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
		result.key = key_from_keysym(keysym)
		if .ShiftMask in event.xkey.state do result.modifiers += {.Shift}
		if .Mod1Mask in event.xkey.state do result.modifiers += {.Alt}
		if .ControlMask in event.xkey.state do result.modifiers += {.Control}
		if result.key != .Text || count > 0 {
			result.kind = .Input
			result.input_size = int(count)
		}
	case .ButtonPress, .ButtonRelease:
		result.kind = .Mouse
		result.mouse.action = .Press if event.type == .ButtonPress else .Release
		result.mouse.button = int(event.xbutton.button)
		result.mouse.column = max(1, int(event.xbutton.x)/window.cell_w+1)
		result.mouse.row = max(1, int(event.xbutton.y)/window.cell_h+1)
		result.mouse.modifiers = modifiers_from_state(event.xbutton.state)
	case .MotionNotify:
		result.kind = .Mouse
		result.mouse.action = .Motion
		result.mouse.button = held_button(event.xmotion.state)
		result.mouse.column = max(1, int(event.xmotion.x)/window.cell_w+1)
		result.mouse.row = max(1, int(event.xmotion.y)/window.cell_h+1)
		result.mouse.modifiers = modifiers_from_state(event.xmotion.state)
	case:
	}
	return result, true
}

base_event_mask :: proc() -> xlib.EventMask {
	return {.KeyPress, .ButtonPress, .ButtonRelease, .Exposure, .StructureNotify, .FocusChange}
}

set_mouse_tracking :: proc(window: ^Window, tracking: int) {
	if tracking == window.mouse_tracking do return
	mask := base_event_mask()
	if tracking == 1002 {
		mask += {.ButtonMotion}
	} else if tracking == 1003 {
		mask += {.PointerMotion}
	}
	xlib.SelectInput(window.display, window.id, mask)
	window.mouse_tracking = tracking
}

modifiers_from_state :: proc(state: xlib.InputMask) -> keyboard.Modifiers {
	result: keyboard.Modifiers
	if .ShiftMask in state do result += {.Shift}
	if .Mod1Mask in state do result += {.Alt}
	if .ControlMask in state do result += {.Control}
	return result
}

held_button :: proc(state: xlib.InputMask) -> int {
	if .Button1Mask in state do return 1
	if .Button2Mask in state do return 2
	if .Button3Mask in state do return 3
	return 0
}

key_from_keysym :: proc(keysym: xlib.KeySym) -> keyboard.Key {
	#partial switch keysym {
	case .XK_Return: return .Enter
	case .XK_BackSpace: return .Backspace
	case .XK_Tab, .XK_ISO_Left_Tab: return .Tab
	case .XK_Escape: return .Escape
	case .XK_Up: return .Up
	case .XK_Down: return .Down
	case .XK_Left: return .Left
	case .XK_Right: return .Right
	case .XK_Home: return .Home
	case .XK_End: return .End
	case .XK_Insert: return .Insert
	case .XK_Delete: return .Delete
	case .XK_Prior: return .Page_Up
	case .XK_Next: return .Page_Down
	case .XK_F1: return .F1
	case .XK_F2: return .F2
	case .XK_F3: return .F3
	case .XK_F4: return .F4
	case .XK_F5: return .F5
	case .XK_F6: return .F6
	case .XK_F7: return .F7
	case .XK_F8: return .F8
	case .XK_F9: return .F9
	case .XK_F10: return .F10
	case .XK_F11: return .F11
	case .XK_F12: return .F12
	case: return .Text
	}
}

close :: proc(window: ^Window) {
	if window.display == nil do return
	if window.gc != nil do xlib.FreeGC(window.display, window.gc)
	if window.font != nil do xlib.FreeFont(window.display, window.font)
	if window.id != 0 do xlib.DestroyWindow(window.display, window.id)
	xlib.CloseDisplay(window.display)
	window^ = {}
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None:          return "none"
	case .Open_Display:  return "could not open X11 display"
	case .Create_Window: return "could not create X11 window"
	case .Create_Renderer: return "could not initialize X11 text renderer"
	case .WM_Protocol:   return "could not register WM_DELETE_WINDOW"
	}
	return "unknown X11 error"
}
