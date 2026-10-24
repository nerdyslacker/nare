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
