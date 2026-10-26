package render

import fonts "../font"
import graphics "../graphics"
import selection "../selection"
import vt "../vt"
import x11 "../x11"
import xlib "vendor:x11/xlib"

GPU_ENABLED :: #config(RENDERER_GPU, false)
MAX_IMAGE_TEXTURE_BYTES :: graphics.MAX_CACHE_BYTES

Image_Texture :: struct {
	image_id: u64,
	texture: u32,
	byte_count: int,
	last_used: u64,
}

GPU_Image_Stats :: struct {
	texture_lookups: u64,
	cache_hits: u64,
	uploads: u64,
	uploaded_bytes: u64,
	evictions: u64,
	releases: u64,
	draws: u64,
}

GPU :: struct {
	ctx: rawptr,
	surface_texture: u32,
	atlas_texture: u32,
	framebuffer: u32,
	width, height: int,
	double_buffered: bool,
	drawable: xlib.XID,
	atlas: Atlas,
	commands: [dynamic]Command,
	image_textures: [dynamic]Image_Texture,
	image_texture_bytes: int,
	image_texture_budget: int,
	image_texture_clock: u64,
	image_stats: GPU_Image_Stats,
}

gpu_image_stats :: proc(gpu: ^GPU) -> GPU_Image_Stats {
	return gpu.image_stats if gpu != nil else GPU_Image_Stats{}
}

gpu_reset_image_stats :: proc(gpu: ^GPU) {
	if gpu != nil do gpu.image_stats = {}
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
		GenFramebuffers :: proc(count: i32, framebuffers: [^]u32) ---
		DeleteFramebuffers :: proc(count: i32, framebuffers: [^]u32) ---
		BindFramebuffer :: proc(target, framebuffer: u32) ---
		FramebufferTexture2D :: proc(target, attachment, texture_target, texture: u32, level: i32) ---
		CheckFramebufferStatus :: proc(target: u32) -> u32 ---
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
		Scissor :: proc(x, y, width, height: i32) ---
		BlendFunc :: proc(source, destination: u32) ---
		Color4f :: proc(red, green, blue, alpha: f32) ---
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
GL_RGBA         :: 0x1908
GL_BGRA         :: 0x80e1
GL_UNSIGNED_BYTE :: 0x1401
GL_UNPACK_ALIGNMENT :: 0x0cf5
GL_UNPACK_ROW_LENGTH :: 0x0cf2
GL_COLOR_BUFFER_BIT :: 0x00004000
GL_QUADS        :: 0x0007
GL_NO_ERROR     :: 0
GL_BLEND        :: 0x0be2
GL_SCISSOR_TEST :: 0x0c11
GL_ONE          :: 1
GL_SRC_ALPHA    :: 0x0302
GL_ONE_MINUS_SRC_ALPHA :: 0x0303
GL_FRAMEBUFFER  :: 0x8d40
GL_COLOR_ATTACHMENT0 :: 0x8ce0
GL_FRAMEBUFFER_COMPLETE :: 0x8cd5

image_texture_coordinates :: proc(
	command: Command,
	image_width, image_height: int,
	left, top, right, bottom: int,
) -> (u0, v0, u1, v1: f32) {
	if command.width <= 0 || command.height <= 0 || image_width <= 0 || image_height <= 0 do return
	u0 = (f32(command.source_x)+f32(left-command.x)*f32(command.source_width)/f32(command.width))/f32(image_width)
	u1 = (f32(command.source_x)+f32(right-command.x)*f32(command.source_width)/f32(command.width))/f32(image_width)
	v0 = (f32(command.source_y)+f32(top-command.y)*f32(command.source_height)/f32(command.height))/f32(image_height)
	v1 = (f32(command.source_y)+f32(bottom-command.y)*f32(command.source_height)/f32(command.height))/f32(image_height)
	return
}

image_texture_eviction_index :: proc(entries: []Image_Texture) -> int {
	oldest_index := -1
	oldest_tick := max(u64)
	for entry, index in entries {
		if entry.last_used < oldest_tick {
			oldest_index = index
			oldest_tick = entry.last_used
		}
	}
	return oldest_index
}

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
		textures: [2]u32
		GenTextures(2, &textures[0])
		gpu.surface_texture = textures[0]
		gpu.atlas_texture = textures[1]
		GenFramebuffers(1, &gpu.framebuffer)
		if gpu.surface_texture == 0 || gpu.atlas_texture == 0 || gpu.framebuffer == 0 || GetError() != GL_NO_ERROR {
			gpu_destroy(gpu, window)
			return false
		}
		BindTexture(GL_TEXTURE_2D, gpu.atlas_texture)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
		TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, ATLAS_WIDTH, ATLAS_HEIGHT, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
		gpu.double_buffered = double_buffered != 0
		gpu.drawable = xlib.XID(window.id)
		gpu.image_texture_budget = MAX_IMAGE_TEXTURE_BYTES
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
			if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) != false {
				for texture in gpu.image_textures {
					texture_id := texture.texture
					DeleteTextures(1, &texture_id)
				}
				textures := [2]u32{gpu.surface_texture, gpu.atlas_texture}
				DeleteTextures(2, &textures[0])
				if gpu.framebuffer != 0 do DeleteFramebuffers(1, &gpu.framebuffer)
			}
			_ = MakeCurrent(window.display, xlib.XID(0), nil)
			DestroyContext(window.display, gpu.ctx)
		}
	}
	atlas_destroy(&gpu.atlas)
	delete(gpu.commands)
	delete(gpu.image_textures)
	gpu^ = {}
}

gpu_resize :: proc(gpu: ^GPU, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if gpu.ctx == nil || window.width <= 0 || window.height <= 0 do return false
		if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) == false do return false
		BindTexture(GL_TEXTURE_2D, gpu.surface_texture)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
		PixelStorei(GL_UNPACK_ALIGNMENT, 4)
		TexImage2D(GL_TEXTURE_2D, 0, GL_RGB, i32(window.width), i32(window.height), 0, GL_BGRA, GL_UNSIGNED_BYTE, nil)
		BindFramebuffer(GL_FRAMEBUFFER, gpu.framebuffer)
		FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gpu.surface_texture, 0)
		if CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE {
			BindFramebuffer(GL_FRAMEBUFFER, 0)
			return false
		}
		Viewport(0, 0, i32(window.width), i32(window.height))
		red, green, blue := theme_background_components()
		ClearColor(red, green, blue, 1)
		Clear(GL_COLOR_BUFFER_BIT)
		BindFramebuffer(GL_FRAMEBUFFER, 0)
		gpu.width = window.width
		gpu.height = window.height
		return GetError() == GL_NO_ERROR
	}
}

gpu_draw :: proc(
	gpu: ^GPU,
	damage: ^CPU,
	font: ^fonts.Manager,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	ligatures: bool,
	force: bool,
	selection_state: ^selection.State = nil,
	screen_override: ^vt.Screen = nil,
	scrollbar: Scrollbar = {},
) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if gpu.ctx == nil || gpu.width != damage.width || gpu.height != damage.height do return false
		screen := screen_override
		if screen == nil do screen = vt.terminal_screen(terminal)
		scrollbar_geometry := scrollbar_geometry(window, screen, scrollbar)
		if !damage_rows(damage, terminal, screen, force, selection_state, scrollbar_geometry) do return true
		if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) == false do return false
		BindFramebuffer(GL_FRAMEBUFFER, gpu.framebuffer)
		Viewport(0, 0, i32(gpu.width), i32(gpu.height))
		Enable(GL_SCISSOR_TEST)
		for dirty, row in damage.dirty_rows {
			if !dirty do continue
			y := row * window.cell_h
			if y >= gpu.height do continue
			height := min(window.cell_h, gpu.height-y)
			Scissor(0, i32(gpu.height-y-height), i32(gpu.width), i32(height))
			build_row_commands(&gpu.commands, font, window, terminal, screen, row, ligatures, selection_state, scrollbar, active_force_bold)
			if !gpu_prepare_atlas(gpu, font) {
				BindFramebuffer(GL_FRAMEBUFFER, 0)
				return false
			}
			if !gpu_prepare_images(gpu, screen.image_registry) {
				BindFramebuffer(GL_FRAMEBUFFER, 0)
				return false
			}
			gpu_draw_commands(gpu, screen.image_registry)
		}
		Disable(GL_SCISSOR_TEST)
		BindFramebuffer(GL_FRAMEBUFFER, 0)
		Viewport(0, 0, i32(gpu.width), i32(gpu.height))
		red, green, blue := theme_background_components()
		ClearColor(red, green, blue, 1)
		Clear(GL_COLOR_BUFFER_BIT)
		BindTexture(GL_TEXTURE_2D, gpu.surface_texture)
		Enable(GL_TEXTURE_2D)
		Color4f(1, 1, 1, 1)
		Begin(GL_QUADS)
		TexCoord2f(0, 1); Vertex2f(-1, 1)
		TexCoord2f(1, 1); Vertex2f(1, 1)
		TexCoord2f(1, 0); Vertex2f(1, -1)
		TexCoord2f(0, 0); Vertex2f(-1, -1)
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

gpu_present_cached :: proc(gpu: ^GPU, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if gpu.ctx == nil || gpu.surface_texture == 0 || gpu.width <= 0 || gpu.height <= 0 do return false
		if MakeCurrent(window.display, xlib.XID(window.id), gpu.ctx) == false do return false
		BindFramebuffer(GL_FRAMEBUFFER, 0)
		Disable(GL_SCISSOR_TEST)
		Viewport(0, i32(window.height-gpu.height), i32(gpu.width), i32(gpu.height))
		red, green, blue := theme_background_components()
		ClearColor(red, green, blue, 1)
		Clear(GL_COLOR_BUFFER_BIT)
		BindTexture(GL_TEXTURE_2D, gpu.surface_texture)
		Enable(GL_TEXTURE_2D)
		Color4f(1, 1, 1, 1)
		Begin(GL_QUADS)
		TexCoord2f(0, 1); Vertex2f(-1, 1)
		TexCoord2f(1, 1); Vertex2f(1, 1)
		TexCoord2f(1, 0); Vertex2f(1, -1)
		TexCoord2f(0, 0); Vertex2f(-1, -1)
		End()
		Disable(GL_TEXTURE_2D)
		if GetError() != GL_NO_ERROR do return false
		if gpu.double_buffered do SwapBuffers(window.display, xlib.XID(window.id))
		else do Flush()
		return true
	}
}

theme_background_components :: proc() -> (red, green, blue: f32) {
	red = f32((active_theme.background>>16)&0xff)/255
	green = f32((active_theme.background>>8)&0xff)/255
	blue = f32(active_theme.background&0xff)/255
	return
}

when GPU_ENABLED {
	gpu_prepare_atlas :: proc(gpu: ^GPU, font: ^fonts.Manager) -> bool {
		BindTexture(GL_TEXTURE_2D, gpu.atlas_texture)
		PixelStorei(GL_UNPACK_ALIGNMENT, 1)
		attempt := 0
		for attempt < 3 {
			attempt += 1
			generation := gpu.atlas.generation
			processed := false
			restart := false
			for command in gpu.commands {
				if command.kind != .Glyph do continue
				if atlas_find(&gpu.atlas, command.face_id, command.glyph_index) != nil {
					processed = true
					continue
				}
				glyph := fonts.face_glyph(font, command.face_id, command.glyph_index)
				if glyph == nil || glyph.width == 0 || glyph.height == 0 do continue
				entry, reset := atlas_place(&gpu.atlas, command.face_id, command.glyph_index, glyph.width, glyph.height)
				if entry == nil do return false
				if !gpu_upload_glyph(entry, glyph) do return false
				if reset && processed && gpu.atlas.generation != generation {
					restart = true
					break
				}
				generation = gpu.atlas.generation
				processed = true
			}
			if !restart do return true
		}
		return false
	}

	gpu_upload_glyph :: proc(entry: ^Atlas_Entry, glyph: ^fonts.Glyph) -> bool {
		pixels := make([]u8, glyph.width*glyph.height*4)
		defer delete(pixels)
		for index in 0..<glyph.width*glyph.height {
			if glyph.kind == .Coverage {
				alpha := glyph.pixels[index]
				pixels[index*4] = alpha
				pixels[index*4+1] = alpha
				pixels[index*4+2] = alpha
				pixels[index*4+3] = alpha
			} else {
				pixels[index*4] = glyph.pixels[index*4+2]
				pixels[index*4+1] = glyph.pixels[index*4+1]
				pixels[index*4+2] = glyph.pixels[index*4]
				pixels[index*4+3] = glyph.pixels[index*4+3]
			}
		}
		TexSubImage2D(
			GL_TEXTURE_2D,
			0,
			i32(entry.x),
			i32(entry.y),
			i32(entry.width),
			i32(entry.height),
			GL_RGBA,
			GL_UNSIGNED_BYTE,
			raw_data(pixels),
		)
		return GetError() == GL_NO_ERROR
	}

	gpu_prepare_images :: proc(gpu: ^GPU, registry: ^graphics.Registry) -> bool {
		for index := len(gpu.image_textures)-1; index >= 0; index -= 1 {
			if registry == nil || graphics.find_image(registry, gpu.image_textures[index].image_id) == nil {
				gpu_remove_image_texture(gpu, index)
				gpu.image_stats.releases += 1
			}
		}
		if registry == nil do return true
		for command in gpu.commands {
			if command.kind != .Image do continue
			resource := graphics.find_image(registry, command.image_id)
			if resource == nil do continue
			gpu.image_stats.texture_lookups += 1
			entry := gpu_find_image_texture(gpu, resource.id)
			if entry != nil {
				gpu.image_stats.cache_hits += 1
				gpu_touch_image_texture(gpu, entry)
				continue
			}
			if !gpu_upload_image(gpu, resource) do return false
		}
		return true
	}

	gpu_upload_image :: proc(gpu: ^GPU, resource: ^graphics.Resource) -> bool {
		channels := graphics.bytes_per_pixel(resource.format)
		if channels <= 0 || resource.stride%channels != 0 do return false
		byte_count := resource.width*resource.height*channels
		if byte_count > gpu.image_texture_budget do return false
		for gpu.image_texture_bytes > gpu.image_texture_budget-byte_count {
			oldest := image_texture_eviction_index(gpu.image_textures[:])
			if oldest < 0 do return false
			gpu_remove_image_texture(gpu, oldest)
			gpu.image_stats.evictions += 1
		}

		texture: u32
		GenTextures(1, &texture)
		if texture == 0 || GetError() != GL_NO_ERROR {
			if texture != 0 do DeleteTextures(1, &texture)
			return false
		}
		BindTexture(GL_TEXTURE_2D, texture)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
		TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
		PixelStorei(GL_UNPACK_ALIGNMENT, 1)
		PixelStorei(GL_UNPACK_ROW_LENGTH, i32(resource.stride/channels))
		format: u32 = GL_RGB
		if resource.format == .RGBA8 do format = GL_RGBA
		TexImage2D(
			GL_TEXTURE_2D,
			0,
			i32(format),
			i32(resource.width),
			i32(resource.height),
			0,
			format,
			GL_UNSIGNED_BYTE,
			raw_data(resource.pixels),
		)
		PixelStorei(GL_UNPACK_ROW_LENGTH, 0)
		if GetError() != GL_NO_ERROR {
			DeleteTextures(1, &texture)
			return false
		}
		gpu.image_texture_clock += 1
		append(&gpu.image_textures, Image_Texture{
			image_id = resource.id,
			texture = texture,
			byte_count = byte_count,
			last_used = gpu.image_texture_clock,
		})
		gpu.image_texture_bytes += byte_count
		gpu.image_stats.uploads += 1
		gpu.image_stats.uploaded_bytes += u64(byte_count)
		return true
	}

	gpu_find_image_texture :: proc(gpu: ^GPU, image_id: u64) -> ^Image_Texture {
		for &entry in gpu.image_textures {
			if entry.image_id == image_id do return &entry
		}
		return nil
	}

	gpu_touch_image_texture :: proc(gpu: ^GPU, entry: ^Image_Texture) {
		gpu.image_texture_clock += 1
		entry.last_used = gpu.image_texture_clock
	}

	gpu_remove_image_texture :: proc(gpu: ^GPU, index: int) {
		entry := gpu.image_textures[index]
		DeleteTextures(1, &entry.texture)
		gpu.image_texture_bytes -= entry.byte_count
		ordered_remove(&gpu.image_textures, index)
	}

	gpu_draw_commands :: proc(gpu: ^GPU, registry: ^graphics.Registry) {
		ordered := false
		for command in gpu.commands {
			if command.kind == .Image || command.opacity != 0 {
				ordered = true
				break
			}
		}
		if ordered {
			gpu_draw_ordered_commands(gpu, registry)
			return
		}

		Disable(GL_TEXTURE_2D)
		Disable(GL_BLEND)
		Begin(GL_QUADS)
		for command in gpu.commands {
			if command.kind != .Rectangle do continue
			gpu_color(command.color)
			gpu_quad(gpu, command.x, command.y, command.x+command.width, command.y+command.height)
		}
		End()

		BindTexture(GL_TEXTURE_2D, gpu.atlas_texture)
		Enable(GL_TEXTURE_2D)
		Enable(GL_BLEND)
		BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
		Begin(GL_QUADS)
		for command in gpu.commands {
			if command.kind != .Glyph do continue
			gpu_glyph_quad(gpu, command)
		}
		End()
		Disable(GL_BLEND)
		Disable(GL_TEXTURE_2D)
	}

	gpu_draw_ordered_commands :: proc(gpu: ^GPU, registry: ^graphics.Registry) {
		for command in gpu.commands {
			switch command.kind {
			case .Rectangle:
				Disable(GL_TEXTURE_2D)
				if command.opacity == 0 {
					Disable(GL_BLEND)
					gpu_color(command.color)
				} else {
					Enable(GL_BLEND)
					BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
					gpu_color_alpha(command.color, command.opacity)
				}
				Begin(GL_QUADS)
				gpu_quad(gpu, command.x, command.y, command.x+command.width, command.y+command.height)
				End()
			case .Glyph:
				BindTexture(GL_TEXTURE_2D, gpu.atlas_texture)
				Enable(GL_TEXTURE_2D)
				Enable(GL_BLEND)
				BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
				Begin(GL_QUADS)
				gpu_glyph_quad(gpu, command)
				End()
			case .Image:
				resource := graphics.find_image(registry, command.image_id)
				entry := gpu_find_image_texture(gpu, command.image_id)
				if resource == nil || entry == nil do continue
				left := max(0, max(command.clip_left, command.x))
				right := min(gpu.width, min(command.clip_right, command.x+command.width))
				top := max(0, max(command.clip_top, command.y))
				bottom := min(gpu.height, min(command.clip_bottom, command.y+command.height))
				if left >= right || top >= bottom do continue
				gpu.image_stats.draws += 1
				u0, v0, u1, v1 := image_texture_coordinates(command, resource.width, resource.height, left, top, right, bottom)
				BindTexture(GL_TEXTURE_2D, entry.texture)
				Enable(GL_TEXTURE_2D)
				Enable(GL_BLEND)
				BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
				Color4f(1, 1, 1, 1)
				Begin(GL_QUADS)
				gpu_textured_quad(gpu, left, top, right, bottom, u0, v0, u1, v1)
				End()
			}
		}
		Disable(GL_BLEND)
		Disable(GL_TEXTURE_2D)
	}

	gpu_glyph_quad :: proc(gpu: ^GPU, command: Command) {
		entry := atlas_find(&gpu.atlas, command.face_id, command.glyph_index)
		if entry == nil do return
		left := max(0, max(command.clip_left, command.x))
		right := min(gpu.width, min(command.clip_right, command.x+command.width))
		top := max(0, command.y)
		bottom := min(gpu.height, command.y+command.height)
		if left >= right || top >= bottom do return
		if command.glyph_kind == .Coverage {
			gpu_color(command.color)
		} else {
			Color4f(1, 1, 1, 1)
		}
		u0 := f32(entry.x+left-command.x)/f32(ATLAS_WIDTH)
		u1 := f32(entry.x+right-command.x)/f32(ATLAS_WIDTH)
		v0 := f32(entry.y+top-command.y)/f32(ATLAS_HEIGHT)
		v1 := f32(entry.y+bottom-command.y)/f32(ATLAS_HEIGHT)
		gpu_textured_quad(gpu, left, top, right, bottom, u0, v0, u1, v1)
	}

	gpu_color :: proc(color: u32) {
		Color4f(f32((color>>16)&0xff)/255, f32((color>>8)&0xff)/255, f32(color&0xff)/255, 1)
	}

	gpu_color_alpha :: proc(color: u32, opacity: u8) {
		Color4f(f32((color>>16)&0xff)/255, f32((color>>8)&0xff)/255, f32(color&0xff)/255, f32(opacity)/255)
	}

	gpu_quad :: proc(gpu: ^GPU, left, top, right, bottom: int) {
		x0 := f32(left)*2/f32(gpu.width)-1
		x1 := f32(right)*2/f32(gpu.width)-1
		y0 := 1-f32(top)*2/f32(gpu.height)
		y1 := 1-f32(bottom)*2/f32(gpu.height)
		Vertex2f(x0, y0)
		Vertex2f(x1, y0)
		Vertex2f(x1, y1)
		Vertex2f(x0, y1)
	}

	gpu_textured_quad :: proc(gpu: ^GPU, left, top, right, bottom: int, u0, v0, u1, v1: f32) {
		x0 := f32(left)*2/f32(gpu.width)-1
		x1 := f32(right)*2/f32(gpu.width)-1
		y0 := 1-f32(top)*2/f32(gpu.height)
		y1 := 1-f32(bottom)*2/f32(gpu.height)
		TexCoord2f(u0, v0); Vertex2f(x0, y0)
		TexCoord2f(u1, v0); Vertex2f(x1, y0)
		TexCoord2f(u1, v1); Vertex2f(x1, y1)
		TexCoord2f(u0, v1); Vertex2f(x0, y1)
	}
}
