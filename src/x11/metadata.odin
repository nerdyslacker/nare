package x11

import graphics "../graphics"
import xlib "vendor:x11/xlib"

WINDOW_ICON_SIZE :: 128
WINDOW_ICON_PNG :: #load("../../assets/logo_256.png")

set_window_metadata :: proc(window: ^Window) {
	class_hint := xlib.XClassHint{res_name = "nare", res_class = "nare"}
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
	class_hint := xlib.XClassHint{res_name = "nare-quake", res_class = "nare"}
	xlib.SetClassHint(window.display, window.id, &class_hint)
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
