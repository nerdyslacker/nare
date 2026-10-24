package render

import fonts "../font"
import selection "../selection"
import vt "../vt"
import x11 "../x11"

Kind :: enum { CPU, GPU, Auto }
Error :: enum { None, Font, CPU, GPU_Unavailable }

Theme :: struct {
	foreground: u32,
	background: u32,
	selection_foreground: u32,
	selection_background: u32,
	cursor: u32,
	cursor_text: u32,
	ansi: [16]u32,
}

DEFAULT_THEME :: Theme{
	foreground = 0xfffdfd,
	background = 0x011224,
	selection_foreground = 0x011224,
	selection_background = 0x9c49fc,
	cursor = 0xfffdfd,
	cursor_text = 0x011224,
	ansi = {
		0x071c33, 0xff6b7a, 0x63d9a0, 0xf6c96b,
		0x5e9cff, 0x9c49fc, 0x4fc3d9, 0xdce6f2,
		0x425a76, 0xff8a97, 0x83e6b5, 0xffd983,
		0x82b4ff, 0xb977ff, 0x70d9ed, 0xfffdfd,
	},
}

active_theme := DEFAULT_THEME
active_force_bold := false

set_theme :: proc(theme: Theme) {
	active_theme = theme
}

Renderer :: struct {
	font: fonts.Manager,
	cpu: CPU,
	gpu: GPU,
	active: Kind,
	ligatures: bool,
	force_bold: bool,
}

init :: proc(
	renderer: ^Renderer,
	window: ^x11.Window,
	kind: Kind,
	ligatures: bool = true,
	family: string = fonts.DEFAULT_FAMILY,
	pixel_size: int = fonts.DEFAULT_PIXEL_SIZE,
	force_bold: bool = false,
	bold_family: string = "auto",
	italic_family: string = "auto",
	bold_italic_family: string = "auto",
	cell_width_percent: int = 100,
	cell_height_percent: int = 100,
) -> Error {
	font_error := fonts.init(&renderer.font, family, pixel_size, bold_family, italic_family, bold_italic_family, cell_width_percent, cell_height_percent)
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
	renderer.force_bold = force_bold
	active_force_bold = force_bold
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

draw :: proc(
	renderer: ^Renderer,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	force: bool = false,
	selection_state: ^selection.State = nil,
	screen_override: ^vt.Screen = nil,
	scrollbar: Scrollbar = {},
) {
	if terminal.modes.synchronized_updates do return
	if renderer.active == .CPU {
		cpu_draw(&renderer.cpu, &renderer.font, window, terminal, renderer.ligatures, force, selection_state, screen_override, scrollbar)
		return
	}
	if !gpu_draw(&renderer.gpu, &renderer.cpu, &renderer.font, window, terminal, renderer.ligatures, force, selection_state, screen_override, scrollbar) {
		gpu_destroy(&renderer.gpu, window)
		renderer.active = .CPU
		_ = cpu_render(&renderer.cpu, &renderer.font, window, terminal, renderer.ligatures, true, selection_state, screen_override, scrollbar)
		screen := screen_override
		if screen == nil do screen = vt.terminal_screen(terminal)
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
