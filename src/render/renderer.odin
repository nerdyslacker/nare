package render

import fonts "../font"
import selection "../selection"
import vt "../vt"
import x11 "../x11"

Kind :: enum { CPU, GPU, Auto }
GPU_Backend :: enum { Auto, OpenGL, Vulkan }
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
active_bold_is_bright := false

set_theme :: proc(theme: Theme) {
	active_theme = theme
}

set_bold_is_bright :: proc(enabled: bool) {
	active_bold_is_bright = enabled
}

Renderer :: struct {
	font: ^fonts.Manager,
	owned_font: fonts.Manager,
	owns_font: bool,
	cpu: CPU,
	gpu: GPU,
	vulkan: Vulkan,
	gpu_backend: GPU_Backend,
	active: Kind,
	ligatures: bool,
	suspended: bool,
}

init :: proc(
	renderer: ^Renderer,
	window: ^x11.Window,
	kind: Kind,
	gpu_backend: GPU_Backend = .OpenGL,
	ligatures: bool = true,
	family: string = fonts.DEFAULT_FAMILY,
	point_size: int = fonts.DEFAULT_POINT_SIZE,
	bold_family: string = "auto",
	italic_family: string = "auto",
	bold_italic_family: string = "auto",
	cell_width_percent: int = 100,
	cell_height_percent: int = 100,
	shared_font: ^fonts.Manager = nil,
) -> Error {
	if shared_font != nil {
		renderer.font = shared_font
	} else {
		font_error := fonts.init(
			&renderer.owned_font, family, point_size, bold_family, italic_family, bold_italic_family,
			cell_width_percent, cell_height_percent, window.dpi,
		)
		if font_error != .None do return .Font
		renderer.font = &renderer.owned_font
		renderer.owns_font = true
	}
	x11.set_cell_size(window, renderer.font.cell_width, renderer.font.cell_height)
	renderer.active = .CPU
	renderer.gpu_backend = gpu_backend
	gpu_ready := false
	selected_backend := gpu_backend
	if kind != .CPU {
		backends: [2]GPU_Backend
		count := 0
		switch gpu_backend {
		case .OpenGL:
			backends[0] = .OpenGL
			count = 1
		case .Vulkan:
			backends[0] = .Vulkan
			count = 1
		case .Auto:
			backends[0] = .Vulkan
			backends[1] = .OpenGL
			count = 2
		}
		for index in 0..<count {
			if try_gpu_backend(renderer, window, backends[index]) {
				gpu_ready = true
				selected_backend = backends[index]
				break
			}
		}
	}
	if gpu_ready {
		if !cpu_damage_resize(&renderer.cpu, window.width, window.height) {
			destroy(renderer, window)
			return .CPU
		}
		renderer.active = .GPU
		renderer.gpu_backend = selected_backend
	} else if !cpu_resize(&renderer.cpu, window) {
		destroy(renderer, window)
		return .CPU
	}
	renderer.ligatures = ligatures
	return .None
}

try_gpu_backend :: proc(renderer: ^Renderer, window: ^x11.Window, backend: GPU_Backend) -> bool {
	switch backend {
	case .OpenGL:
		return gpu_init(&renderer.gpu, window)
	case .Vulkan:
		return vulkan_init(&renderer.vulkan, window)
	case .Auto:
		return false
	}
	return false
}

destroy_gpu_backend :: proc(renderer: ^Renderer, window: ^x11.Window) {
	switch renderer.gpu_backend {
	case .Vulkan:
		vulkan_destroy(&renderer.vulkan, window)
	case .OpenGL, .Auto:
		gpu_destroy(&renderer.gpu, window)
	}
}

destroy :: proc(renderer: ^Renderer, window: ^x11.Window = nil) {
	if window != nil {
		gpu_destroy(&renderer.gpu, window)
		vulkan_destroy(&renderer.vulkan, window)
	}
	cpu_destroy(&renderer.cpu)
	if renderer.owns_font do fonts.destroy(&renderer.owned_font)
	renderer^ = {}
}

suspend :: proc(renderer: ^Renderer, window: ^x11.Window) {
	if renderer == nil || window == nil || renderer.suspended do return
	if renderer.active == .GPU {
		switch renderer.gpu_backend {
		case .Vulkan:
			_ = vulkan_release_image_textures(&renderer.vulkan, window)
			delete(renderer.vulkan.commands)
			renderer.vulkan.commands = nil
			delete(renderer.vulkan.row_commands)
			renderer.vulkan.row_commands = nil
			delete(renderer.vulkan.rows)
			renderer.vulkan.rows = nil
			command_scratch_destroy(&renderer.vulkan.scratch)
		case .OpenGL, .Auto:
			_ = gpu_release_image_textures(&renderer.gpu, window)
			delete(renderer.gpu.commands)
			renderer.gpu.commands = nil
			command_scratch_destroy(&renderer.gpu.command_scratch)
		}
	}
	cpu_destroy(&renderer.cpu)
	renderer.suspended = true
}

resume :: proc(renderer: ^Renderer, window: ^x11.Window) -> bool {
	if renderer == nil || window == nil do return false
	if !renderer.suspended do return true
	if renderer.active == .GPU {
		usable := false
		switch renderer.gpu_backend {
		case .Vulkan:
			usable = renderer.vulkan.device != nil
			if usable && cpu_damage_resize(&renderer.cpu, window.width, window.height) && vulkan_resize(&renderer.vulkan, window) {
				renderer.suspended = false
				return true
			}
		case .OpenGL, .Auto:
			usable = renderer.gpu.ctx != nil
			if usable && cpu_damage_resize(&renderer.cpu, window.width, window.height) {
				renderer.suspended = false
				return true
			}
		}
		if usable do destroy_gpu_backend(renderer, window)
	}
	if !cpu_resize(&renderer.cpu, window) do return false
	renderer.active = .CPU
	renderer.suspended = false
	return true
}

resize :: proc(renderer: ^Renderer, window: ^x11.Window) -> bool {
	if renderer.suspended do return false
	if renderer.active == .GPU {
		if !cpu_damage_resize(&renderer.cpu, window.width, window.height) do return false
		resized := false
		switch renderer.gpu_backend {
		case .Vulkan:
			resized = vulkan_resize(&renderer.vulkan, window)
		case .OpenGL, .Auto:
			resized = gpu_resize(&renderer.gpu, window)
		}
		if resized do return true
		destroy_gpu_backend(renderer, window)
		if !cpu_resize(&renderer.cpu, window) do return false
		renderer.active = .CPU
		return true
	}
	return cpu_resize(&renderer.cpu, window)
}

present_cached :: proc(renderer: ^Renderer, window: ^x11.Window) {
	if renderer.suspended do return
	if renderer.active == .GPU {
		switch renderer.gpu_backend {
		case .Vulkan:
			_ = vulkan_present_cached(&renderer.vulkan, window)
		case .OpenGL, .Auto:
			_ = gpu_present_cached(&renderer.gpu, window)
		}
		return
	}
	cpu_present_cached(&renderer.cpu, window)
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
	if renderer.suspended || terminal.modes.synchronized_updates do return
	if renderer.active == .CPU {
		cpu_draw(&renderer.cpu, renderer.font, window, terminal, renderer.ligatures, force, selection_state, screen_override, scrollbar)
		return
	}
	drawn := false
	switch renderer.gpu_backend {
	case .Vulkan:
		drawn = vulkan_draw(
			&renderer.vulkan,
			&renderer.cpu,
			renderer.font,
			window,
			terminal,
			renderer.ligatures,
			force,
			selection_state,
			screen_override,
			scrollbar,
		)
	case .OpenGL, .Auto:
		drawn = gpu_draw(
			&renderer.gpu,
			&renderer.cpu,
			renderer.font,
			window,
			terminal,
			renderer.ligatures,
			force,
			selection_state,
			screen_override,
			scrollbar,
		)
	}
	if !drawn {
		destroy_gpu_backend(renderer, window)
		if !cpu_resize(&renderer.cpu, window) do return
		renderer.active = .CPU
		_ = cpu_render(&renderer.cpu, renderer.font, window, terminal, renderer.ligatures, true, selection_state, screen_override, scrollbar)
		screen := screen_override
		if screen == nil do screen = vt.terminal_screen(terminal)
		cpu_present(&renderer.cpu, window, screen.rows)
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
