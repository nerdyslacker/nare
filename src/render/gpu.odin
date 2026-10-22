package render

import x11 "../x11"
import xlib "vendor:x11/xlib"

GPU_ENABLED :: #config(RENDERER_GPU, false)

GPU :: struct {
	ctx: rawptr,
	texture: u32,
	width, height: int,
	double_buffered: bool,
	drawable: xlib.XID,
}

when GPU_ENABLED {
	foreign import gl_library "system:GL"

	@(default_calling_convention="c", link_prefix="glX")
	foreign gl_library {
		QueryExtension :: proc(display: ^xlib.Display, error_base, event_base: ^i32) -> b32 ---
		CreateContext :: proc(display: ^xlib.Display, visual: ^xlib.XVisualInfo, share: rawptr, direct: b32) -> rawptr ---
		DestroyContext :: proc(display: ^xlib.Display, ctx: rawptr) ---
		MakeCurrent :: proc(display: ^xlib.Display, drawable: xlib.XID, ctx: rawptr) -> b32 ---
		SwapBuffers :: proc(display: ^xlib.Display, drawable: xlib.XID) ---
		GetConfig :: proc(display: ^xlib.Display, visual: ^xlib.XVisualInfo, attribute: i32, value: ^i32) -> i32 ---
	}

	@(default_calling_convention="c", link_prefix="gl")
	foreign gl_library {
		GenTextures :: proc(count: i32, textures: [^]u32) ---
		DeleteTextures :: proc(count: i32, textures: [^]u32) ---
		BindTexture :: proc(target, texture: u32) ---
		TexParameteri :: proc(target, parameter: u32, value: i32) ---
		PixelStorei :: proc(parameter: u32, value: i32) ---
		TexImage2D :: proc(target: u32, level, internal_format, width, height, border: i32, format, data_type: u32, pixels: rawptr) ---
		TexSubImage2D :: proc(target: u32, level, x, y, width, height: i32, format, data_type: u32, pixels: rawptr) ---
		Enable :: proc(capability: u32) ---
		Disable :: proc(capability: u32) ---
		Viewport :: proc(x, y, width, height: i32) ---
		ClearColor :: proc(red, green, blue, alpha: f32) ---
		Clear :: proc(mask: u32) ---
		Begin :: proc(mode: u32) ---
		End :: proc() ---
		TexCoord2f :: proc(s, t: f32) ---
		Vertex2f :: proc(x, y: f32) ---
		GetError :: proc() -> u32 ---
		Flush :: proc() ---
	}
}

GLX_USE_GL      :: 1
GLX_RGBA        :: 4
GLX_DOUBLEBUFFER :: 5
GL_TEXTURE_2D   :: 0x0de1
GL_TEXTURE_MAG_FILTER :: 0x2800
GL_TEXTURE_MIN_FILTER :: 0x2801
GL_NEAREST      :: 0x2600
GL_RGB          :: 0x1907
GL_BGRA         :: 0x80e1
GL_UNSIGNED_BYTE :: 0x1401
GL_UNPACK_ALIGNMENT :: 0x0cf5
GL_COLOR_BUFFER_BIT :: 0x00004000
GL_QUADS        :: 0x0007
GL_NO_ERROR     :: 0

gpu_init :: proc(gpu: ^GPU, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		error_base, event_base: i32
		if QueryExtension(window.display, &error_base, &event_base) == false do return false
		template := xlib.XVisualInfo{visualid = xlib.VisualIDFromVisual(window.visual)}
		count: i32
		visuals := xlib.GetVisualInfo(window.display, {.VisualIDMask}, &template, &count)
		if visuals == nil || count == 0 do return false
		defer xlib.Free(visuals)
		use_gl, rgba, double_buffered: i32
		if GetConfig(window.display, &visuals[0], GLX_USE_GL, &use_gl) != 0 || use_gl == 0 do return false
		if GetConfig(window.display, &visuals[0], GLX_RGBA, &rgba) != 0 || rgba == 0 do return false
		_ = GetConfig(window.display, &visuals[0], GLX_DOUBLEBUFFER, &double_buffered)
		gpu.ctx = CreateContext(window.display, &visuals[0], nil, true)
		if gpu.ctx == nil do return false
		if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) == false {
			DestroyContext(window.display, gpu.ctx)
			gpu^ = {}
			return false
		}
		GenTextures(1, &gpu.texture)
		if gpu.texture == 0 || GetError() != GL_NO_ERROR {
			gpu_destroy(gpu, window)
			return false
		}
		gpu.double_buffered = double_buffered != 0
		gpu.drawable = xlib.XID(window.id)
		if !gpu_resize(gpu, window) {
			gpu_destroy(gpu, window)
			return false
		}
		return true
	}
}

gpu_destroy :: proc(gpu: ^GPU, window: ^x11.Window) {
	when GPU_ENABLED {
		if gpu.ctx != nil {
			if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) != false && gpu.texture != 0 {
				DeleteTextures(1, &gpu.texture)
			}
			_ = MakeCurrent(window.display, xlib.XID(0), nil)
			DestroyContext(window.display, gpu.ctx)
		}
	}
	gpu^ = {}
}

gpu_resize :: proc(gpu: ^GPU, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if gpu.ctx == nil || window.width <= 0 || window.height <= 0 do return false
		if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) == false do return false
		BindTexture(GL_TEXTURE_2D, gpu.texture)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
		PixelStorei(GL_UNPACK_ALIGNMENT, 4)
		TexImage2D(GL_TEXTURE_2D, 0, GL_RGB, i32(window.width), i32(window.height), 0, GL_BGRA, GL_UNSIGNED_BYTE, nil)
		gpu.width = window.width
		gpu.height = window.height
		return GetError() == GL_NO_ERROR
	}
}

gpu_present :: proc(gpu: ^GPU, cpu: ^CPU, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if gpu.ctx == nil || gpu.width != cpu.width || gpu.height != cpu.height do return false
		if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) == false do return false
		BindTexture(GL_TEXTURE_2D, gpu.texture)
		for dirty, row in cpu.dirty_rows {
			if !dirty do continue
			y := row * window.cell_h
			if y >= cpu.height do continue
			height := min(window.cell_h, cpu.height-y)
			pixels := rawptr(&cpu.pixels[y*cpu.width])
			TexSubImage2D(GL_TEXTURE_2D, 0, 0, i32(y), i32(cpu.width), i32(height), GL_BGRA, GL_UNSIGNED_BYTE, pixels)
		}
		Viewport(0, 0, i32(gpu.width), i32(gpu.height))
		ClearColor(0, 0, 0, 1)
		Clear(GL_COLOR_BUFFER_BIT)
		Enable(GL_TEXTURE_2D)
		Begin(GL_QUADS)
		TexCoord2f(0, 0); Vertex2f(-1, 1)
		TexCoord2f(1, 0); Vertex2f(1, 1)
		TexCoord2f(1, 1); Vertex2f(1, -1)
		TexCoord2f(0, 1); Vertex2f(-1, -1)
		End()
		Disable(GL_TEXTURE_2D)
		if GetError() != GL_NO_ERROR do return false
		if gpu.double_buffered {
			SwapBuffers(window.display, xlib.XID(window.id))
		} else {
			Flush()
		}
		return true
	}
}
