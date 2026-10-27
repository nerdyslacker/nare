#+build linux, freebsd, openbsd

package x11

import xlib "vendor:x11/xlib"

foreign import system_x11 "system:X11"

@(default_calling_convention="c")
foreign system_x11 {
	@(link_name="XDestroyIC")
	destroy_input_context :: proc(ctx: xlib.XIC) ---

	@(link_name="XCloseIM")
	close_input_method :: proc(input_method: xlib.XIM) -> xlib.Status ---
}
