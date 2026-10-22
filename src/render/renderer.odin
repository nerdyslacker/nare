package render

import fonts "../font"
import vt "../vt"
import x11 "../x11"

Kind :: enum { CPU, GPU, Auto }
Error :: enum { None, Font, CPU, GPU_Unavailable }

Renderer :: struct {
	font: fonts.Manager,
	cpu: CPU,
	gpu: GPU,
	active: Kind,
	ligatures: bool,
}

init :: proc(
	renderer: ^Renderer,
	window: ^x11.Window,
	kind: Kind,
	ligatures: bool = true,
	family: string = fonts.DEFAULT_FAMILY,
) -> Error {
	font_error := fonts.init(&renderer.font, family)
	if font_error != .None do return .Font
	x11.set_cell_size(window, renderer.font.cell_width, renderer.font.cell_height)
	if !cpu_resize(&renderer.cpu, window) {
		destroy(renderer)
		return .CPU
	}
	renderer.active = .CPU
	gpu_ready := false
	if kind != .CPU {
		gpu_ready = gpu_init(&renderer.gpu, window)
	}
	selected, available := select_kind(kind, gpu_ready)
	if !available {
		destroy(renderer, window)
		return .GPU_Unavailable
	}
	renderer.active = selected
	renderer.ligatures = ligatures
	return .None
}

select_kind :: proc(requested: Kind, gpu_ready: bool) -> (selected: Kind, available: bool) {
	switch requested {
	case .CPU:
		return .CPU, true
	case .GPU:
		return .GPU, gpu_ready
	case .Auto:
		if gpu_ready do return .GPU, true
		return .CPU, true
	}
	return .CPU, false
}

destroy :: proc(renderer: ^Renderer, window: ^x11.Window = nil) {
	if window != nil do gpu_destroy(&renderer.gpu, window)
	cpu_destroy(&renderer.cpu)
	fonts.destroy(&renderer.font)
	renderer^ = {}
}

resize :: proc(renderer: ^Renderer, window: ^x11.Window) -> bool {
	if !cpu_resize(&renderer.cpu, window) do return false
	if renderer.active == .GPU && !gpu_resize(&renderer.gpu, window) {
		gpu_destroy(&renderer.gpu, window)
		renderer.active = .CPU
	}
	return true
}

draw :: proc(renderer: ^Renderer, window: ^x11.Window, terminal: ^vt.Terminal, force: bool = false) {
	if terminal.modes.synchronized_updates do return
	if renderer.active == .CPU {
		cpu_draw(&renderer.cpu, &renderer.font, window, terminal, renderer.ligatures, force)
		return
	}
	if !cpu_render(&renderer.cpu, &renderer.font, window, terminal, renderer.ligatures, force) do return
	if !gpu_present(&renderer.gpu, &renderer.cpu, window) {
		gpu_destroy(&renderer.gpu, window)
		renderer.active = .CPU
		screen := vt.terminal_screen(terminal)
		cpu_present(&renderer.cpu, window, screen.columns)
	}
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
