package x11

import "core:strings"
import keyboard "../input"
import xlib "vendor:x11/xlib"

DEFAULT_WIDTH  :: 800
DEFAULT_HEIGHT :: 480
DIRECT_SELECTION_BYTES :: 32 * 1024
SELECTION_CHUNK_BYTES :: 32 * 1024
MAX_SELECTION_BYTES :: 16 * 1024 * 1024
MAX_OUTGOING_TRANSFERS :: 4

Error :: enum { None, Open_Display, Create_Window, Create_Renderer, WM_Protocol, Selection_Atoms }
Event_Kind :: enum { None, Close, Redraw, Resize, Focus, Input, Mouse, Paste, Paste_Failed }
Selection_Kind :: enum { Primary, Clipboard }

Outgoing_Selection :: struct {
	requestor: xlib.Window,
	property: xlib.Atom,
	target: xlib.Atom,
	data: [dynamic]byte,
	offset: int,
}

Incoming_Selection :: struct {
	active: bool,
	property: xlib.Atom,
	target: xlib.Atom,
}

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
	visual:    ^xlib.Visual,
	depth:     int,
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
	primary_atom: xlib.Atom,
	clipboard_atom: xlib.Atom,
	utf8_atom: xlib.Atom,
	string_atom: xlib.Atom,
	targets_atom: xlib.Atom,
	atom_atom: xlib.Atom,
	incr_atom: xlib.Atom,
	selection_property: xlib.Atom,
	primary_data: [dynamic]byte,
	clipboard_data: [dynamic]byte,
	paste_data: [dynamic]byte,
	outgoing_selections: [dynamic]Outgoing_Selection,
	incoming_selection: Incoming_Selection,
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
	window.depth = int(xlib.DefaultDepth(display, screen))
	values := xlib.XGCValues{
		foreground = window.white,
		background = window.black,
		graphics_exposures = false,
	}
	window.gc = xlib.CreateGC(
		display,
		xlib.Drawable(window.id),
		{.GCForeground, .GCBackground, .GCGraphicsExposures},
		&values,
	)
	if window.gc == nil {
		close(&window)
		return window, .Create_Renderer
	}
	window.cell_w = 8
	window.cell_h = 16
	xlib.SelectInput(display, window.id, base_event_mask())
	window.wm_delete = xlib.InternAtom(display, "WM_DELETE_WINDOW", false)
	if window.wm_delete == 0 || xlib.SetWMProtocols(display, window.id, &window.wm_delete, 1) == .Success {
		close(&window)
		return window, .WM_Protocol
	}
	window.primary_atom = xlib.InternAtom(display, "PRIMARY", false)
	window.clipboard_atom = xlib.InternAtom(display, "CLIPBOARD", false)
	window.utf8_atom = xlib.InternAtom(display, "UTF8_STRING", false)
	window.string_atom = xlib.InternAtom(display, "STRING", false)
	window.targets_atom = xlib.InternAtom(display, "TARGETS", false)
	window.atom_atom = xlib.InternAtom(display, "ATOM", false)
	window.incr_atom = xlib.InternAtom(display, "INCR", false)
	window.selection_property = xlib.InternAtom(display, "NARE_SELECTION", false)
	if window.primary_atom == 0 || window.clipboard_atom == 0 || window.utf8_atom == 0 ||
	   window.string_atom == 0 || window.targets_atom == 0 || window.atom_atom == 0 || window.incr_atom == 0 ||
	   window.selection_property == 0 {
		close(&window)
		return window, .Selection_Atoms
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

set_cell_size :: proc(window: ^Window, width, height: int) {
	window.cell_w = max(1, width)
	window.cell_h = max(1, height)
}

set_title :: proc(window: ^Window, title: string) {
	owned := strings.clone_to_cstring(title)
	defer delete(owned)
	xlib.StoreName(window.display, window.id, owned)
	_ = xlib.Flush(window.display)
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
	case .SelectionRequest:
		handle_selection_request(window, &event.xselectionrequest)
	case .SelectionClear:
		if event.xselectionclear.selection == window.primary_atom do clear(&window.primary_data)
		if event.xselectionclear.selection == window.clipboard_atom do clear(&window.clipboard_data)
	case .SelectionNotify:
		if event.xselection.property == 0 {
			result.kind = .Paste_Failed
		} else if receive_selection(window, &event.xselection) {
			result.kind = .Paste
		}
	case .PropertyNotify:
		if event.xproperty.state == .PropertyDelete {
			send_selection_chunk(window, &event.xproperty)
		} else if receive_selection_chunk(window, &event.xproperty) {
			result.kind = .Paste
		}
	case:
	}
	return result, true
}

base_event_mask :: proc() -> xlib.EventMask {
	return {.KeyPress, .ButtonPress, .ButtonRelease, .ButtonMotion, .Exposure, .StructureNotify, .FocusChange, .PropertyChange}
}

own_selection :: proc(window: ^Window, kind: Selection_Kind, data: []byte) -> bool {
	if len(data) > MAX_SELECTION_BYTES do return false
	atom := window.primary_atom if kind == .Primary else window.clipboard_atom
	target := &window.primary_data if kind == .Primary else &window.clipboard_data
	clear(target)
	append(target, ..data)
	xlib.SetSelectionOwner(window.display, atom, window.id, xlib.Time(xlib.CurrentTime))
	_ = xlib.Flush(window.display)
	return xlib.GetSelectionOwner(window.display, atom) == window.id
}

request_selection :: proc(window: ^Window, kind: Selection_Kind) {
	clear(&window.paste_data)
	window.incoming_selection = {}
	_ = xlib.DeleteProperty(window.display, window.id, window.selection_property)
	atom := window.primary_atom if kind == .Primary else window.clipboard_atom
	xlib.ConvertSelection(
		window.display,
		atom,
		window.utf8_atom,
		window.selection_property,
		window.id,
		xlib.Time(xlib.CurrentTime),
	)
	_ = xlib.Flush(window.display)
}

take_paste :: proc(window: ^Window) -> []byte {
	return window.paste_data[:]
}

consume_paste :: proc(window: ^Window) {
	clear(&window.paste_data)
}

handle_selection_request :: proc(window: ^Window, request: ^xlib.XSelectionRequestEvent) {
	property := request.property
	if property == 0 do property = request.target
	reply := xlib.XEvent{}
	reply.xselection = {
		type = .SelectionNotify,
		display = request.display,
		requestor = request.requestor,
		selection = request.selection,
		target = request.target,
		property = 0,
		time = request.time,
	}
	data: []byte
	if request.selection == window.primary_atom {
		data = window.primary_data[:]
	} else if request.selection == window.clipboard_atom {
		data = window.clipboard_data[:]
	} else {
		_ = xlib.SendEvent(window.display, request.requestor, false, {}, &reply)
		_ = xlib.Flush(window.display)
		return
	}
	if request.target == window.targets_atom {
		targets := [3]xlib.Atom{window.targets_atom, window.utf8_atom, window.string_atom}
		_ = xlib.ChangeProperty(
			window.display,
			request.requestor,
			property,
			window.atom_atom,
			32,
			xlib.PropModeReplace,
			raw_data(targets[:]),
			len(targets),
		)
		reply.xselection.property = property
	} else if request.target == window.utf8_atom || request.target == window.string_atom {
		if len(data) <= DIRECT_SELECTION_BYTES {
			_ = xlib.ChangeProperty(
				window.display,
				request.requestor,
				property,
				request.target,
				8,
				xlib.PropModeReplace,
				raw_data(data),
				i32(len(data)),
			)
			reply.xselection.property = property
		} else if begin_outgoing_selection(window, request.requestor, property, request.target, data) {
			total_bytes := [1]uint{uint(len(data))}
			_ = xlib.ChangeProperty(
				window.display,
				request.requestor,
				property,
				window.incr_atom,
				32,
				xlib.PropModeReplace,
				raw_data(total_bytes[:]),
				1,
			)
			reply.xselection.property = property
		}
	}
	_ = xlib.SendEvent(window.display, request.requestor, false, {}, &reply)
	_ = xlib.Flush(window.display)
}

receive_selection :: proc(window: ^Window, event: ^xlib.XSelectionEvent) -> bool {
	if event.property != window.selection_property do return false
	if event.selection != window.primary_atom && event.selection != window.clipboard_atom do return false
	if event.target != window.utf8_atom do return false
	actual_type: xlib.Atom
	actual_format: i32
	item_count, bytes_after: uint
	property: rawptr
	status := xlib.GetWindowProperty(
		window.display,
		window.id,
		event.property,
		0,
		MAX_SELECTION_BYTES/4,
		true,
		xlib.Atom(xlib.AnyPropertyType),
		&actual_type,
		&actual_format,
		&item_count,
		&bytes_after,
		&property,
	)
	defer if property != nil do xlib.Free(property)
	if status != 0 || bytes_after != 0 || (property == nil && item_count > 0) do return false
	if actual_type == window.incr_atom {
		if actual_format != 32 || item_count > 1 do return false
		expected := 0
		if item_count == 1 do expected = int(([^]uint)(property)[0])
		if expected < 0 || expected > MAX_SELECTION_BYTES do return false
		clear(&window.paste_data)
		window.incoming_selection = {
			active = true,
			property = event.property,
			target = event.target,
		}
		return false
	}
	if actual_format != 8 do return false
	if actual_type != window.utf8_atom && actual_type != window.string_atom do return false
	if item_count > MAX_SELECTION_BYTES do return false
	clear(&window.paste_data)
	if item_count > 0 do append(&window.paste_data, ..(([^]byte)(property))[:int(item_count)])
	return true
}

begin_outgoing_selection :: proc(
	window: ^Window,
	requestor: xlib.Window,
	property, target: xlib.Atom,
	data: []byte,
) -> bool {
	if len(window.outgoing_selections) >= MAX_OUTGOING_TRANSFERS do return false
	for &transfer in window.outgoing_selections {
		if transfer.requestor == requestor && transfer.property == property do return false
	}
	transfer := Outgoing_Selection{requestor = requestor, property = property, target = target}
	append(&transfer.data, ..data)
	append(&window.outgoing_selections, transfer)
	xlib.SelectInput(window.display, requestor, {.PropertyChange})
	return true
}

send_selection_chunk :: proc(window: ^Window, event: ^xlib.XPropertyEvent) {
	for index := 0; index < len(window.outgoing_selections); index += 1 {
		transfer := &window.outgoing_selections[index]
		if transfer.requestor != event.window || transfer.property != event.atom do continue
		chunk_size := selection_chunk_size(len(transfer.data), transfer.offset)
		chunk := transfer.data[transfer.offset:transfer.offset+chunk_size]
		chunk_data: rawptr
		if chunk_size > 0 do chunk_data = raw_data(chunk)
		_ = xlib.ChangeProperty(
			window.display,
			transfer.requestor,
			transfer.property,
			transfer.target,
			8,
			xlib.PropModeReplace,
			chunk_data,
			i32(chunk_size),
		)
		transfer.offset += chunk_size
		if chunk_size == 0 do remove_outgoing_selection(window, index)
		_ = xlib.Flush(window.display)
		return
	}
}

remove_outgoing_selection :: proc(window: ^Window, index: int) {
	delete(window.outgoing_selections[index].data)
	ordered_remove(&window.outgoing_selections, index)
}

receive_selection_chunk :: proc(window: ^Window, event: ^xlib.XPropertyEvent) -> bool {
	transfer := &window.incoming_selection
	if !transfer.active || event.window != window.id || event.atom != transfer.property do return false
	actual_type: xlib.Atom
	actual_format: i32
	item_count, bytes_after: uint
	property: rawptr
	status := xlib.GetWindowProperty(
		window.display,
		window.id,
		transfer.property,
		0,
		MAX_SELECTION_BYTES/4,
		true,
		xlib.Atom(xlib.AnyPropertyType),
		&actual_type,
		&actual_format,
		&item_count,
		&bytes_after,
		&property,
	)
	defer if property != nil do xlib.Free(property)
	if status != 0 || (property == nil && item_count > 0) || actual_format != 8 || bytes_after != 0 || actual_type != transfer.target {
		cancel_incoming_selection(window)
		return false
	}
	if item_count == 0 {
		transfer.active = false
		return true
	}
	chunk := (([^]byte)(property))[:int(item_count)]
	if !append_selection_chunk(&window.paste_data, chunk) {
		cancel_incoming_selection(window)
		return false
	}
	return false
}

selection_chunk_size :: proc(total_bytes, offset: int) -> int {
	return min(SELECTION_CHUNK_BYTES, max(0, total_bytes-offset))
}

append_selection_chunk :: proc(output: ^[dynamic]byte, chunk: []byte) -> bool {
	if !selection_chunk_fits(len(output^), len(chunk)) do return false
	append(output, ..chunk)
	return true
}

selection_chunk_fits :: proc(current_bytes, chunk_bytes: int) -> bool {
	return current_bytes >= 0 && current_bytes <= MAX_SELECTION_BYTES &&
	       chunk_bytes >= 0 && chunk_bytes <= MAX_SELECTION_BYTES-current_bytes
}

cancel_incoming_selection :: proc(window: ^Window) {
	if window.incoming_selection.property != 0 {
		_ = xlib.DeleteProperty(window.display, window.id, window.incoming_selection.property)
	}
	window.incoming_selection = {}
	clear(&window.paste_data)
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
	delete(window.primary_data)
	delete(window.clipboard_data)
	delete(window.paste_data)
	for &transfer in window.outgoing_selections do delete(transfer.data)
	delete(window.outgoing_selections)
	if window.gc != nil do xlib.FreeGC(window.display, window.gc)
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
	case .Selection_Atoms: return "could not initialize X11 selections"
	}
	return "unknown X11 error"
}
