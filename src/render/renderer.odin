package render

import fonts "../font"
import vt "../vt"
import x11 "../x11"

Kind :: enum { CPU, GPU, Auto }
Error :: enum { None, Font, CPU, GPU_Unavailable }

Renderer :: struct {
	font: fonts.Manager,
	cpu: CPU,
	ligatures: bool,
}

init :: proc(
	renderer: ^Renderer,
	window: ^x11.Window,
	kind: Kind,
	ligatures: bool = true,
	family: string = fonts.DEFAULT_FAMILY,
) -> Error {
	if kind == .GPU do return .GPU_Unavailable
	font_error := fonts.init(&renderer.font, family)
	if font_error != .None do return .Font
	x11.set_cell_size(window, renderer.font.cell_width, renderer.font.cell_height)
	if !cpu_resize(&renderer.cpu, window) {
		destroy(renderer)
		return .CPU
	}
	renderer.ligatures = ligatures
	return .None
}

destroy :: proc(renderer: ^Renderer) {
	cpu_destroy(&renderer.cpu)
	fonts.destroy(&renderer.font)
	renderer^ = {}
}

resize :: proc(renderer: ^Renderer, window: ^x11.Window) -> bool {
	return cpu_resize(&renderer.cpu, window)
}

draw :: proc(renderer: ^Renderer, window: ^x11.Window, terminal: ^vt.Terminal, force: bool = false) {
	if terminal.modes.synchronized_updates do return
	cpu_draw(&renderer.cpu, &renderer.font, window, terminal, renderer.ligatures, force)
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None: return "none"
	case .Font: return "could not initialize the font pipeline"
	case .CPU: return "could not initialize the CPU renderer"
	case .GPU_Unavailable: return "GPU renderer is not available in this build"
	}
	return "unknown renderer error"
}
