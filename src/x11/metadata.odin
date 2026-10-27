package x11

import graphics "../graphics"
import xlib "vendor:x11/xlib"

WINDOW_ICON_SIZE :: 128
WINDOW_ICON_PNG :: #load("../../assets/logo_256.png")
RULE_IDENTITY_PROPERTY :: "_NARE_RULE_INSTANCE"
MAX_RULE_IDENTITY_BYTES :: 128
NARE_LITE :: #config(NARE_LITE, false)

when NARE_LITE {
	WINDOW_INSTANCE :: "nare-lite"
	WINDOW_CLASS :: "nare-lite"
	QUAKE_INSTANCE :: "nare-lite-quake"
} else {
	WINDOW_INSTANCE :: "nare"
	WINDOW_CLASS :: "nare"
	QUAKE_INSTANCE :: "nare-quake"
}

set_window_metadata :: proc(window: ^Window) {
	class_hint := xlib.XClassHint{res_name = WINDOW_INSTANCE, res_class = WINDOW_CLASS}
	xlib.SetClassHint(window.display, window.id, &class_hint)
	icon_atom := xlib.InternAtom(window.display, "_NET_WM_ICON", false)
	if icon_atom == 0 do return
	image, image_error := graphics.decode_png(transmute([]byte)WINDOW_ICON_PNG)
	if image_error != .None do return
	defer graphics.decoded_image_destroy(&image)
	icon := window_icon_data(&image, WINDOW_ICON_SIZE)
	defer delete(icon)
	if len(icon) == 0 do return
	_ = xlib.ChangeProperty(
		window.display,
		window.id,
		icon_atom,
		xlib.XA_CARDINAL,
		32,
		xlib.PropModeReplace,
		raw_data(icon),
		i32(len(icon)),
	)
}

set_rule_identity :: proc(window: ^Window, name: string) {
	if window == nil || window.display == nil || window.id == 0 || name == "" || len(name) > MAX_RULE_IDENTITY_BYTES do return
	property := xlib.InternAtom(window.display, RULE_IDENTITY_PROPERTY, false)
	type_atom := xlib.InternAtom(window.display, "UTF8_STRING", false)
	if property == 0 || type_atom == 0 do return
	_ = xlib.ChangeProperty(window.display, window.id, property, type_atom, 8, xlib.PropModeReplace, raw_data(name), i32(len(name)))
	_ = xlib.Flush(window.display)
}

focus_rule_instance :: proc(window: ^Window, name: string) -> bool {
	if window == nil || window.display == nil || name == "" || len(name) > MAX_RULE_IDENTITY_BYTES do return false
	previous_handler := xlib.SetErrorHandler(ignore_rule_lookup_error)
	defer {
		_ = xlib.Sync(window.display, false)
		_ = xlib.SetErrorHandler(previous_handler)
	}
	property := xlib.InternAtom(window.display, RULE_IDENTITY_PROPERTY, true)
	if property == 0 do return false
	root := xlib.RootWindow(window.display, xlib.DefaultScreen(window.display))
	target := find_rule_window(window.display, root, property, name, 0)
	if target == 0 do return false
	request_window_activation(window, target)
	_ = xlib.MapRaised(window.display, target)
	_ = xlib.Flush(window.display)
	return true
}

ignore_rule_lookup_error :: proc "c" (_: ^xlib.Display, _: ^xlib.XErrorEvent) -> i32 {
	return 0
}

find_rule_window :: proc(display: ^xlib.Display, parent: xlib.Window, property: xlib.Atom, name: string, depth: int) -> xlib.Window {
	if depth > 3 do return 0
	root, ignored_parent: xlib.Window
	children: [^]xlib.Window
	count: u32
	if xlib.QueryTree(display, parent, &root, &ignored_parent, &children, &count) != .Success do return 0
	defer if children != nil do xlib.Free(children)
	for index in 0..<int(count) {
		candidate := children[index]
		actual_type: xlib.Atom
		actual_format: i32
		items, remaining: uint
		data: rawptr
		status := xlib.GetWindowProperty(display, candidate, property, 0, MAX_RULE_IDENTITY_BYTES, false, xlib.AnyPropertyType, &actual_type, &actual_format, &items, &remaining, &data)
		if status == 0 && data != nil {
			matches := actual_format == 8 && int(items) == len(name) && string(([^]byte)(data)[:int(items)]) == name
			xlib.Free(data)
			if matches do return candidate
		}
		if nested := find_rule_window(display, candidate, property, name, depth+1); nested != 0 do return nested
	}
	return 0
}

set_opacity :: proc(window: ^Window, opacity: f32) {
	atom := xlib.InternAtom(window.display, "_NET_WM_WINDOW_OPACITY", false)
	if atom == 0 do return
	value := [1]uint{uint(f64(clamp(opacity, 0, 1))*f64(max(u32)))}
	_ = xlib.ChangeProperty(
		window.display, window.id, atom, xlib.XA_CARDINAL, 32,
		xlib.PropModeReplace, raw_data(value[:]), 1,
	)
}

set_decorations :: proc(window: ^Window, enabled: bool) {
	atom := xlib.InternAtom(window.display, "_MOTIF_WM_HINTS", false)
	if atom == 0 do return
	// flags, functions, decorations, input mode, status
	hints := [5]uint{2, 0, 1 if enabled else 0, 0, 0}
	_ = xlib.ChangeProperty(
		window.display, window.id, atom, atom, 32,
		xlib.PropModeReplace, raw_data(hints[:]), len(hints),
	)
}

set_quake_hints :: proc(window: ^Window, keep_above, skip_taskbar: bool) {
	attributes := xlib.XSetWindowAttributes{override_redirect = true}
	xlib.ChangeWindowAttributes(window.display, window.id, {.CWOverrideRedirect}, &attributes)
	set_decorations(window, false)
	type_atom := xlib.InternAtom(window.display, "_NET_WM_WINDOW_TYPE", false)
	utility_atom := xlib.InternAtom(window.display, "_NET_WM_WINDOW_TYPE_UTILITY", false)
	state_atom := xlib.InternAtom(window.display, "_NET_WM_STATE", false)
	above_atom := xlib.InternAtom(window.display, "_NET_WM_STATE_ABOVE", false)
	skip_taskbar_atom := xlib.InternAtom(window.display, "_NET_WM_STATE_SKIP_TASKBAR", false)
	skip_pager_atom := xlib.InternAtom(window.display, "_NET_WM_STATE_SKIP_PAGER", false)
	if type_atom != 0 && utility_atom != 0 {
		values := [1]xlib.Atom{utility_atom}
		_ = xlib.ChangeProperty(window.display, window.id, type_atom, xlib.XA_ATOM, 32, xlib.PropModeReplace, raw_data(values[:]), 1)
	}
	states: [3]xlib.Atom
	count := 0
	if keep_above && above_atom != 0 { states[count] = above_atom; count += 1 }
	if skip_taskbar && skip_taskbar_atom != 0 { states[count] = skip_taskbar_atom; count += 1 }
	if skip_taskbar && skip_pager_atom != 0 { states[count] = skip_pager_atom; count += 1 }
	if state_atom != 0 {
		_ = xlib.ChangeProperty(window.display, window.id, state_atom, xlib.XA_ATOM, 32, xlib.PropModeReplace, raw_data(states[:]), i32(count))
	}
	class_hint := xlib.XClassHint{res_name = QUAKE_INSTANCE, res_class = WINDOW_CLASS}
	xlib.SetClassHint(window.display, window.id, &class_hint)
}

window_is_maximized_or_fullscreen :: proc(window: ^Window) -> bool {
	if window == nil || window.display == nil || window.id == 0 do return false
	state_atom := xlib.InternAtom(window.display, "_NET_WM_STATE", true)
	maximized_horizontal := xlib.InternAtom(window.display, "_NET_WM_STATE_MAXIMIZED_HORZ", true)
	maximized_vertical := xlib.InternAtom(window.display, "_NET_WM_STATE_MAXIMIZED_VERT", true)
	fullscreen := xlib.InternAtom(window.display, "_NET_WM_STATE_FULLSCREEN", true)
	if state_atom == 0 do return false
	actual: xlib.Atom
	format: i32
	count, after: uint
	data: rawptr
	if xlib.GetWindowProperty(
		window.display, window.id, state_atom, 0, 32, false, xlib.XA_ATOM,
		&actual, &format, &count, &after, &data,
	) != 0 || data == nil {
		return false
	}
	defer xlib.Free(data)
	if actual != xlib.XA_ATOM || format != 32 do return false
	values := ([^]xlib.Atom)(data)
	horizontal, vertical := false, false
	for index in 0..<int(count) {
		if fullscreen != 0 && values[index] == fullscreen do return true
		if maximized_horizontal != 0 && values[index] == maximized_horizontal do horizontal = true
		if maximized_vertical != 0 && values[index] == maximized_vertical do vertical = true
	}
	return horizontal && vertical
}

window_icon_data :: proc(image: ^graphics.Decoded_Image, size: int) -> []uint {
	if image == nil || image.width <= 0 || image.height <= 0 || size <= 0 || size > 256 do return nil
	channels := graphics.bytes_per_pixel(image.format)
	if channels != 3 && channels != 4 do return nil
	icon := make([]uint, 2+size*size)
	icon[0], icon[1] = uint(size), uint(size)
	for y in 0..<size {
		source_y := y*image.height/size
		for x in 0..<size {
			source_x := x*image.width/size
			offset := source_y*image.stride+source_x*channels
			alpha := byte(255)
			if channels == 4 do alpha = image.pixels[offset+3]
			icon[2+y*size+x] = uint(alpha)<<24 |
			                         uint(image.pixels[offset])<<16 |
			                         uint(image.pixels[offset+1])<<8 |
			                         uint(image.pixels[offset+2])
		}
	}
	return icon
}
