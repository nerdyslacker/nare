package render

import "core:dynlib"
import fonts "../font"
import graphics "../graphics"
import selection "../selection"
import vt "../vt"
import x11 "../x11"
import vulkan "vendor:vulkan"

VULKAN_DESCRIPTOR_SETS :: 4096
VULKAN_VERTEX_SHADER :: #load("shaders/terminal.vert.spv")
VULKAN_SOLID_SHADER :: #load("shaders/solid.frag.spv")
VULKAN_TEXTURED_SHADER :: #load("shaders/textured.frag.spv")

Vulkan_Vertex :: struct {
	x, y, u, v: f32,
}

Vulkan_Push :: struct {
	color: [4]f32,
}

Vulkan_Texture :: struct {
	image:      vulkan.Image,
	view:       vulkan.ImageView,
	memory:     vulkan.DeviceMemory,
	descriptor: vulkan.DescriptorSet,
	width:      int,
	height:     int,
	layout:     vulkan.ImageLayout,
}

Vulkan_Image :: struct {
	texture:    Vulkan_Texture,
	image_id:   u64,
	version:    u64,
	byte_count: int,
	last_used:  u64,
}

Vulkan_Row :: struct {
	start, count: int,
	y, height:    int,
}

Vulkan :: struct {
	library:                  dynlib.Library,
	instance:                 vulkan.Instance,
	surface:                  vulkan.SurfaceKHR,
	physical_device:          vulkan.PhysicalDevice,
	device:                   vulkan.Device,
	queue:                    vulkan.Queue,
	queue_family:             u32,
	swapchain:                vulkan.SwapchainKHR,
	swapchain_images:         []vulkan.Image,
	swapchain_initialized:    []bool,
	swapchain_format:         vulkan.Format,
	swapchain_color_space:    vulkan.ColorSpaceKHR,
	render_pass:              vulkan.RenderPass,
	pipeline_layout:          vulkan.PipelineLayout,
	solid_pipeline:           vulkan.Pipeline,
	glyph_pipeline:           vulkan.Pipeline,
	image_pipeline:           vulkan.Pipeline,
	descriptor_layout:        vulkan.DescriptorSetLayout,
	descriptor_pool:          vulkan.DescriptorPool,
	sampler:                  vulkan.Sampler,
	command_pool:             vulkan.CommandPool,
	command_buffer:           vulkan.CommandBuffer,
	vertex_buffer:            vulkan.Buffer,
	vertex_memory:            vulkan.DeviceMemory,
	vertex_mapped:            rawptr,
	vertex_capacity:          int,
	vertex_count:             int,
	image_available:          vulkan.Semaphore,
	render_finished:          []vulkan.Semaphore,
	fence:                    vulkan.Fence,
	offscreen:                Vulkan_Texture,
	framebuffer:              vulkan.Framebuffer,
	atlas:                    Atlas,
	atlas_texture:            Vulkan_Texture,
	atlas_descriptor:         vulkan.DescriptorSet,
	atlas_pixels:             []u8,
	atlas_dirty:              bool,
	present_image:            u32,
	needs_full_redraw:        bool,
	images:                   [dynamic]Vulkan_Image,
	image_bytes:              int,
	image_clock:              u64,
	image_stats:              GPU_Image_Stats,
	commands:                 [dynamic]Command,
	row_commands:             [dynamic]Command,
	rows:                     [dynamic]Vulkan_Row,
	scratch:                  Command_Scratch,
	width:                    int,
	height:                   int,
}

when !GPU_ENABLED {
	vulkan_graphics_max_cache_bytes :: proc() -> int {
		return graphics.MAX_CACHE_BYTES
	}
}

vulkan_image_stats :: proc(vk: ^Vulkan) -> GPU_Image_Stats {
	return vk.image_stats if vk != nil else GPU_Image_Stats{}
}

vulkan_release_image_textures :: proc(vk: ^Vulkan, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return true
	} else {
		_ = window
		vk.image_stats.releases += u64(len(vk.images))
		for index := len(vk.images)-1; index >= 0; index -= 1 {
			vulkan_remove_image(vk, index)
		}
		return true
	}
}

when GPU_ENABLED {
	vulkan_result_ok :: proc(result: vulkan.Result) -> bool {
		return result == .SUCCESS
	}

	vulkan_find_memory_type :: proc(
		vk: ^Vulkan,
		type_bits: u32,
		required: vulkan.MemoryPropertyFlags,
	) -> (u32, bool) {
		properties: vulkan.PhysicalDeviceMemoryProperties
		vulkan.GetPhysicalDeviceMemoryProperties(vk.physical_device, &properties)
		for index in 0..<properties.memoryTypeCount {
			if type_bits&(1<<index) == 0 do continue
			if required <= properties.memoryTypes[index].propertyFlags do return index, true
		}
		return 0, false
	}

	vulkan_create_buffer :: proc(
		vk: ^Vulkan,
		size: vulkan.DeviceSize,
		usage: vulkan.BufferUsageFlags,
		required: vulkan.MemoryPropertyFlags,
		buffer: ^vulkan.Buffer,
		memory: ^vulkan.DeviceMemory,
	) -> bool {
		info := vulkan.BufferCreateInfo{
			sType = .BUFFER_CREATE_INFO,
			size = size,
			usage = usage,
			sharingMode = .EXCLUSIVE,
		}
		if !vulkan_result_ok(vulkan.CreateBuffer(vk.device, &info, nil, buffer)) do return false
		requirements: vulkan.MemoryRequirements
		vulkan.GetBufferMemoryRequirements(vk.device, buffer^, &requirements)
		type_index, ok := vulkan_find_memory_type(vk, requirements.memoryTypeBits, required)
		if !ok {
			vulkan.DestroyBuffer(vk.device, buffer^, nil)
			buffer^ = 0
			return false
		}
		allocate := vulkan.MemoryAllocateInfo{
			sType = .MEMORY_ALLOCATE_INFO,
			allocationSize = requirements.size,
			memoryTypeIndex = type_index,
		}
		if !vulkan_result_ok(vulkan.AllocateMemory(vk.device, &allocate, nil, memory)) {
			vulkan.DestroyBuffer(vk.device, buffer^, nil)
			buffer^ = 0
			return false
		}
		if !vulkan_result_ok(vulkan.BindBufferMemory(vk.device, buffer^, memory^, 0)) {
			vulkan.FreeMemory(vk.device, memory^, nil)
			vulkan.DestroyBuffer(vk.device, buffer^, nil)
			buffer^ = 0
			memory^ = 0
			return false
		}
		return true
	}

	vulkan_destroy_buffer :: proc(vk: ^Vulkan, buffer: ^vulkan.Buffer, memory: ^vulkan.DeviceMemory) {
		if vk.device == nil do return
		if buffer^ != 0 do vulkan.DestroyBuffer(vk.device, buffer^, nil)
		if memory^ != 0 do vulkan.FreeMemory(vk.device, memory^, nil)
		buffer^ = 0
		memory^ = 0
	}

	vulkan_create_texture :: proc(
		vk: ^Vulkan,
		width, height: int,
		format: vulkan.Format,
		usage: vulkan.ImageUsageFlags,
		texture: ^Vulkan_Texture,
	) -> bool {
		info := vulkan.ImageCreateInfo{
			sType = .IMAGE_CREATE_INFO,
			imageType = .D2,
			format = format,
			extent = {u32(width), u32(height), 1},
			mipLevels = 1,
			arrayLayers = 1,
			samples = {._1},
			tiling = .OPTIMAL,
			usage = usage,
			sharingMode = .EXCLUSIVE,
			initialLayout = .UNDEFINED,
		}
		if !vulkan_result_ok(vulkan.CreateImage(vk.device, &info, nil, &texture.image)) do return false
		requirements: vulkan.MemoryRequirements
		vulkan.GetImageMemoryRequirements(vk.device, texture.image, &requirements)
		type_index, ok := vulkan_find_memory_type(vk, requirements.memoryTypeBits, {.DEVICE_LOCAL})
		if !ok {
			vulkan.DestroyImage(vk.device, texture.image, nil)
			texture.image = 0
			return false
		}
		allocate := vulkan.MemoryAllocateInfo{
			sType = .MEMORY_ALLOCATE_INFO,
			allocationSize = requirements.size,
			memoryTypeIndex = type_index,
		}
		if !vulkan_result_ok(vulkan.AllocateMemory(vk.device, &allocate, nil, &texture.memory)) {
			vulkan.DestroyImage(vk.device, texture.image, nil)
			texture.image = 0
			return false
		}
		if !vulkan_result_ok(vulkan.BindImageMemory(vk.device, texture.image, texture.memory, 0)) {
			vulkan.FreeMemory(vk.device, texture.memory, nil)
			vulkan.DestroyImage(vk.device, texture.image, nil)
			texture.image = 0
			texture.memory = 0
			return false
		}
		view_info := vulkan.ImageViewCreateInfo{
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = texture.image,
			viewType = .D2,
			format = format,
			components = {
				r = .IDENTITY,
				g = .IDENTITY,
				b = .IDENTITY,
				a = .IDENTITY,
			},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		if !vulkan_result_ok(vulkan.CreateImageView(vk.device, &view_info, nil, &texture.view)) {
			vulkan.FreeMemory(vk.device, texture.memory, nil)
			vulkan.DestroyImage(vk.device, texture.image, nil)
			texture.image = 0
			texture.memory = 0
			return false
		}
		texture.width = width
		texture.height = height
		texture.layout = .UNDEFINED
		return true
	}

	vulkan_destroy_texture :: proc(vk: ^Vulkan, texture: ^Vulkan_Texture, free_descriptor: bool) {
		if vk.device == nil do return
		if free_descriptor && texture.descriptor != 0 {
			descriptors := [1]vulkan.DescriptorSet{texture.descriptor}
			_ = vulkan.FreeDescriptorSets(vk.device, vk.descriptor_pool, 1, &descriptors[0])
		}
		if texture.view != 0 do vulkan.DestroyImageView(vk.device, texture.view, nil)
		if texture.image != 0 do vulkan.DestroyImage(vk.device, texture.image, nil)
		if texture.memory != 0 do vulkan.FreeMemory(vk.device, texture.memory, nil)
		texture^ = {}
	}

	vulkan_allocate_descriptor :: proc(vk: ^Vulkan, view: vulkan.ImageView) -> (vulkan.DescriptorSet, bool) {
		layout := [1]vulkan.DescriptorSetLayout{vk.descriptor_layout}
		info := vulkan.DescriptorSetAllocateInfo{
			sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = vk.descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts = &layout[0],
		}
		sets := [1]vulkan.DescriptorSet{}
		if !vulkan_result_ok(vulkan.AllocateDescriptorSets(vk.device, &info, &sets[0])) do return 0, false
		image_info := vulkan.DescriptorImageInfo{
			sampler = vk.sampler,
			imageView = view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		write := vulkan.WriteDescriptorSet{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = sets[0],
			dstBinding = 0,
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &image_info,
		}
		writes := [1]vulkan.WriteDescriptorSet{write}
		vulkan.UpdateDescriptorSets(vk.device, 1, &writes[0], 0, nil)
		return sets[0], true
	}

	vulkan_transition_image :: proc(
		cmd: vulkan.CommandBuffer,
		image: vulkan.Image,
		old_layout, new_layout: vulkan.ImageLayout,
		src_stage, dst_stage: vulkan.PipelineStageFlags,
		src_access, dst_access: vulkan.AccessFlags,
	) {
		barrier := vulkan.ImageMemoryBarrier{
			sType = .IMAGE_MEMORY_BARRIER,
			srcAccessMask = src_access,
			dstAccessMask = dst_access,
			oldLayout = old_layout,
			newLayout = new_layout,
			srcQueueFamilyIndex = vulkan.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vulkan.QUEUE_FAMILY_IGNORED,
			image = image,
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		barriers := [1]vulkan.ImageMemoryBarrier{barrier}
		vulkan.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barriers[0])
	}

	vulkan_begin_commands :: proc(vk: ^Vulkan) -> bool {
		_ = vulkan.ResetCommandPool(vk.device, vk.command_pool, {})
		begin := vulkan.CommandBufferBeginInfo{
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		return vulkan_result_ok(vulkan.BeginCommandBuffer(vk.command_buffer, &begin))
	}

	vulkan_end_commands :: proc(vk: ^Vulkan) -> bool {
		return vulkan_result_ok(vulkan.EndCommandBuffer(vk.command_buffer))
	}

	vulkan_submit_wait :: proc(vk: ^Vulkan) -> bool {
		if !vulkan_end_commands(vk) do return false
		submit := vulkan.SubmitInfo{
			sType = .SUBMIT_INFO,
			commandBufferCount = 1,
			pCommandBuffers = &vk.command_buffer,
		}
		submits := [1]vulkan.SubmitInfo{submit}
		if !vulkan_result_ok(vulkan.QueueSubmit(vk.queue, 1, &submits[0], 0)) do return false
		return vulkan_result_ok(vulkan.QueueWaitIdle(vk.queue))
	}

	vulkan_upload_texture :: proc(vk: ^Vulkan, texture: ^Vulkan_Texture, pixels: []u8) -> bool {
		byte_count := texture.width*texture.height*4
		if byte_count <= 0 || len(pixels) < byte_count do return false
		staging_buffer: vulkan.Buffer
		staging_memory: vulkan.DeviceMemory
		if !vulkan_create_buffer(
			vk,
			vulkan.DeviceSize(byte_count),
			{.TRANSFER_SRC},
			{.HOST_VISIBLE, .HOST_COHERENT},
			&staging_buffer,
			&staging_memory,
		) {
			return false
		}
		defer vulkan_destroy_buffer(vk, &staging_buffer, &staging_memory)
		mapped: rawptr
		if !vulkan_result_ok(vulkan.MapMemory(vk.device, staging_memory, 0, vulkan.DeviceSize(byte_count), {}, &mapped)) do return false
		destination := cast([^]u8)mapped
		copy(destination[:byte_count], pixels)
		vulkan.UnmapMemory(vk.device, staging_memory)
		if !vulkan_begin_commands(vk) do return false
		old_layout := texture.layout
		src_stage := vulkan.PipelineStageFlags{.TOP_OF_PIPE}
		src_access: vulkan.AccessFlags
		if old_layout != .UNDEFINED {
			src_stage = {.FRAGMENT_SHADER}
			src_access = {.SHADER_READ}
		}
		vulkan_transition_image(
			vk.command_buffer,
			texture.image,
			old_layout,
			.TRANSFER_DST_OPTIMAL,
			src_stage,
			{.TRANSFER},
			src_access,
			{.TRANSFER_WRITE},
		)
		region := vulkan.BufferImageCopy{
			bufferOffset = 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = {
				aspectMask = {.COLOR},
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			imageOffset = {0, 0, 0},
			imageExtent = {u32(texture.width), u32(texture.height), 1},
		}
		regions := [1]vulkan.BufferImageCopy{region}
		vulkan.CmdCopyBufferToImage(
			vk.command_buffer,
			staging_buffer,
			texture.image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&regions[0],
		)
		vulkan_transition_image(
			vk.command_buffer,
			texture.image,
			.TRANSFER_DST_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER},
			{.FRAGMENT_SHADER},
			{.TRANSFER_WRITE},
			{.SHADER_READ},
		)
		if !vulkan_submit_wait(vk) do return false
		texture.layout = .SHADER_READ_ONLY_OPTIMAL
		return true
	}

	vulkan_choose_format :: proc(formats: []vulkan.SurfaceFormatKHR) -> (vulkan.Format, vulkan.ColorSpaceKHR) {
		for format in formats {
			if format.colorSpace != .SRGB_NONLINEAR do continue
			if format.format == .B8G8R8A8_UNORM || format.format == .R8G8B8A8_UNORM {
				return format.format, format.colorSpace
			}
		}
		if len(formats) > 0 do return formats[0].format, formats[0].colorSpace
		return .B8G8R8A8_UNORM, .SRGB_NONLINEAR
	}

	vulkan_create_swapchain :: proc(vk: ^Vulkan, window: ^x11.Window) -> bool {
		capabilities: vulkan.SurfaceCapabilitiesKHR
		if !vulkan_result_ok(vulkan.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk.physical_device, vk.surface, &capabilities)) do return false
		format_count: u32
		if !vulkan_result_ok(vulkan.GetPhysicalDeviceSurfaceFormatsKHR(vk.physical_device, vk.surface, &format_count, nil)) do return false
		if format_count == 0 do return false
		formats := make([]vulkan.SurfaceFormatKHR, format_count)
		defer delete(formats)
		if !vulkan_result_ok(vulkan.GetPhysicalDeviceSurfaceFormatsKHR(vk.physical_device, vk.surface, &format_count, raw_data(formats))) do return false
		if vk.swapchain_format == .UNDEFINED {
			vk.swapchain_format, vk.swapchain_color_space = vulkan_choose_format(formats)
		}
		extent := capabilities.currentExtent
		if extent.width == ~u32(0) || extent.height == ~u32(0) {
			extent = {u32(window.width), u32(window.height)}
		}
		extent.width = clamp(extent.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
		extent.height = clamp(extent.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height)
		if extent.width == 0 || extent.height == 0 do return false
		image_count := capabilities.minImageCount+1
		if capabilities.maxImageCount > 0 do image_count = min(image_count, capabilities.maxImageCount)
		composite: vulkan.CompositeAlphaFlagsKHR = {.OPAQUE}
		if !(composite <= capabilities.supportedCompositeAlpha) do composite = {.INHERIT}
		info := vulkan.SwapchainCreateInfoKHR{
			sType = .SWAPCHAIN_CREATE_INFO_KHR,
			surface = vk.surface,
			minImageCount = image_count,
			imageFormat = vk.swapchain_format,
			imageColorSpace = vk.swapchain_color_space,
			imageExtent = extent,
			imageArrayLayers = 1,
			imageUsage = {.COLOR_ATTACHMENT, .TRANSFER_DST},
			imageSharingMode = .EXCLUSIVE,
			preTransform = capabilities.currentTransform,
			compositeAlpha = composite,
			presentMode = .FIFO,
			clipped = true,
		}
		if !vulkan_result_ok(vulkan.CreateSwapchainKHR(vk.device, &info, nil, &vk.swapchain)) do return false
		count: u32
		if !vulkan_result_ok(vulkan.GetSwapchainImagesKHR(vk.device, vk.swapchain, &count, nil)) do return false
		if count == 0 do return false
		if vk.swapchain_images != nil do delete(vk.swapchain_images)
		if vk.swapchain_initialized != nil do delete(vk.swapchain_initialized)
		vk.swapchain_images = make([]vulkan.Image, count)
		vk.swapchain_initialized = make([]bool, count)
		if !vulkan_result_ok(vulkan.GetSwapchainImagesKHR(vk.device, vk.swapchain, &count, raw_data(vk.swapchain_images))) do return false
		vulkan_destroy_render_finished(vk)
		vk.render_finished = make([]vulkan.Semaphore, count)
		semaphore_info := vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		for index in 0..<count {
			if !vulkan_result_ok(vulkan.CreateSemaphore(vk.device, &semaphore_info, nil, &vk.render_finished[index])) do return false
		}
		vk.width = int(extent.width)
		vk.height = int(extent.height)
		return true
	}

	vulkan_destroy_render_finished :: proc(vk: ^Vulkan) {
		if vk.device != nil {
			for semaphore in vk.render_finished {
				if semaphore != 0 do vulkan.DestroySemaphore(vk.device, semaphore, nil)
			}
		}
		if vk.render_finished != nil {
			delete(vk.render_finished)
			vk.render_finished = nil
		}
	}

	vulkan_create_render_pass :: proc(vk: ^Vulkan) -> bool {
		attachment := vulkan.AttachmentDescription{
			format = vk.swapchain_format,
			samples = {._1},
			loadOp = .LOAD,
			storeOp = .STORE,
			stencilLoadOp = .DONT_CARE,
			stencilStoreOp = .DONT_CARE,
			initialLayout = .TRANSFER_SRC_OPTIMAL,
			finalLayout = .TRANSFER_SRC_OPTIMAL,
		}
		reference := vulkan.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
		subpass := vulkan.SubpassDescription{
			pipelineBindPoint = .GRAPHICS,
			colorAttachmentCount = 1,
			pColorAttachments = &reference,
		}
		dependency := vulkan.SubpassDependency{
			srcSubpass = vulkan.SUBPASS_EXTERNAL,
			dstSubpass = 0,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT, .TRANSFER},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}
		info := vulkan.RenderPassCreateInfo{
			sType = .RENDER_PASS_CREATE_INFO,
			attachmentCount = 1,
			pAttachments = &attachment,
			subpassCount = 1,
			pSubpasses = &subpass,
			dependencyCount = 1,
			pDependencies = &dependency,
		}
		return vulkan_result_ok(vulkan.CreateRenderPass(vk.device, &info, nil, &vk.render_pass))
	}

	vulkan_create_shader_module :: proc(vk: ^Vulkan, code: []u8) -> (vulkan.ShaderModule, bool) {
		if len(code) == 0 || len(code)%4 != 0 do return 0, false
		words := make([]u32, len(code)/4)
		defer delete(words)
		word_bytes := cast([^]u8)raw_data(words)
		copy(word_bytes[:len(code)], code)
		info := vulkan.ShaderModuleCreateInfo{
			sType = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(code),
			pCode = cast(^u32)raw_data(words),
		}
		module: vulkan.ShaderModule
		if !vulkan_result_ok(vulkan.CreateShaderModule(vk.device, &info, nil, &module)) do return 0, false
		return module, true
	}

	vulkan_create_pipeline :: proc(
		vk: ^Vulkan,
		vertex: vulkan.ShaderModule,
		fragment: vulkan.ShaderModule,
		src_blend: vulkan.BlendFactor,
		dst_blend: vulkan.BlendFactor,
		pipeline: ^vulkan.Pipeline,
	) -> bool {
		stages := [2]vulkan.PipelineShaderStageCreateInfo{
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = vertex,
				pName = "main",
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = fragment,
				pName = "main",
			},
		}
		binding := vulkan.VertexInputBindingDescription{
			binding = 0,
			stride = size_of(Vulkan_Vertex),
			inputRate = .VERTEX,
		}
		attributes := [2]vulkan.VertexInputAttributeDescription{
			{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0},
			{location = 1, binding = 0, format = .R32G32_SFLOAT, offset = size_of(f32)*2},
		}
		vertex_input := vulkan.PipelineVertexInputStateCreateInfo{
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = 1,
			pVertexBindingDescriptions = &binding,
			vertexAttributeDescriptionCount = 2,
			pVertexAttributeDescriptions = &attributes[0],
		}
		input_assembly := vulkan.PipelineInputAssemblyStateCreateInfo{
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}
		viewport := vulkan.PipelineViewportStateCreateInfo{
			sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount = 1,
		}
		rasterization := vulkan.PipelineRasterizationStateCreateInfo{
			sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			cullMode = {},
			frontFace = .COUNTER_CLOCKWISE,
			lineWidth = 1,
		}
		multisample := vulkan.PipelineMultisampleStateCreateInfo{
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
		}
		blend_attachment := vulkan.PipelineColorBlendAttachmentState{
			blendEnable = true,
			srcColorBlendFactor = src_blend,
			dstColorBlendFactor = dst_blend,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
			alphaBlendOp = .ADD,
			colorWriteMask = {.R, .G, .B, .A},
		}
		color_blend := vulkan.PipelineColorBlendStateCreateInfo{
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments = &blend_attachment,
		}
		dynamic_states := [2]vulkan.DynamicState{.VIEWPORT, .SCISSOR}
		dynamic_info := vulkan.PipelineDynamicStateCreateInfo{
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = 2,
			pDynamicStates = &dynamic_states[0],
		}
		info := vulkan.GraphicsPipelineCreateInfo{
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			stageCount = 2,
			pStages = &stages[0],
			pVertexInputState = &vertex_input,
			pInputAssemblyState = &input_assembly,
			pViewportState = &viewport,
			pRasterizationState = &rasterization,
			pMultisampleState = &multisample,
			pColorBlendState = &color_blend,
			pDynamicState = &dynamic_info,
			layout = vk.pipeline_layout,
			renderPass = vk.render_pass,
			subpass = 0,
			basePipelineIndex = -1,
		}
		pipelines := [1]vulkan.Pipeline{}
		if !vulkan_result_ok(vulkan.CreateGraphicsPipelines(vk.device, 0, 1, &info, nil, &pipelines[0])) do return false
		pipeline^ = pipelines[0]
		return true
	}

	vulkan_create_pipelines :: proc(vk: ^Vulkan) -> bool {
		vertex, vertex_ok := vulkan_create_shader_module(vk, VULKAN_VERTEX_SHADER)
		if !vertex_ok do return false
		defer vulkan.DestroyShaderModule(vk.device, vertex, nil)
		solid, solid_ok := vulkan_create_shader_module(vk, VULKAN_SOLID_SHADER)
		if !solid_ok do return false
		defer vulkan.DestroyShaderModule(vk.device, solid, nil)
		textured, textured_ok := vulkan_create_shader_module(vk, VULKAN_TEXTURED_SHADER)
		if !textured_ok do return false
		defer vulkan.DestroyShaderModule(vk.device, textured, nil)
		if !vulkan_create_pipeline(vk, vertex, solid, .SRC_ALPHA, .ONE_MINUS_SRC_ALPHA, &vk.solid_pipeline) do return false
		if !vulkan_create_pipeline(vk, vertex, textured, .ONE, .ONE_MINUS_SRC_ALPHA, &vk.glyph_pipeline) do return false
		return vulkan_create_pipeline(vk, vertex, textured, .SRC_ALPHA, .ONE_MINUS_SRC_ALPHA, &vk.image_pipeline)
	}

	vulkan_create_offscreen :: proc(vk: ^Vulkan) -> bool {
		texture := Vulkan_Texture{}
		if !vulkan_create_texture(
			vk,
			vk.width,
			vk.height,
			vk.swapchain_format,
			{.COLOR_ATTACHMENT, .TRANSFER_SRC},
			&texture,
		) {
			return false
		}
		vk.offscreen = texture
		if vk.framebuffer != 0 {
			vulkan.DestroyFramebuffer(vk.device, vk.framebuffer, nil)
			vk.framebuffer = 0
		}
		attachments := [1]vulkan.ImageView{vk.offscreen.view}
		info := vulkan.FramebufferCreateInfo{
			sType = .FRAMEBUFFER_CREATE_INFO,
			renderPass = vk.render_pass,
			attachmentCount = 1,
			pAttachments = &attachments[0],
			width = u32(vk.width),
			height = u32(vk.height),
			layers = 1,
		}
		if !vulkan_result_ok(vulkan.CreateFramebuffer(vk.device, &info, nil, &vk.framebuffer)) do return false
		if !vulkan_begin_commands(vk) do return false
		vulkan_transition_image(
			vk.command_buffer,
			vk.offscreen.image,
			.UNDEFINED,
			.TRANSFER_DST_OPTIMAL,
			{.TOP_OF_PIPE},
			{.TRANSFER},
			{},
			{.TRANSFER_WRITE},
		)
		red, green, blue := theme_background_components()
		clear := vulkan.ClearColorValue{}
		clear.float32 = {red, green, blue, 1}
		range := vulkan.ImageSubresourceRange{
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		}
		ranges := [1]vulkan.ImageSubresourceRange{range}
		vulkan.CmdClearColorImage(vk.command_buffer, vk.offscreen.image, .TRANSFER_DST_OPTIMAL, &clear, 1, &ranges[0])
		vulkan_transition_image(
			vk.command_buffer,
			vk.offscreen.image,
			.TRANSFER_DST_OPTIMAL,
			.TRANSFER_SRC_OPTIMAL,
			{.TRANSFER},
			{.BOTTOM_OF_PIPE},
			{.TRANSFER_WRITE},
			{},
		)
		if !vulkan_submit_wait(vk) do return false
		vk.offscreen.layout = .TRANSFER_SRC_OPTIMAL
		return true
	}

	vulkan_recreate_swapchain :: proc(vk: ^Vulkan, window: ^x11.Window) -> bool {
		if vk.device == nil do return false
		_ = vulkan.DeviceWaitIdle(vk.device)
		if vk.framebuffer != 0 {
			vulkan.DestroyFramebuffer(vk.device, vk.framebuffer, nil)
			vk.framebuffer = 0
		}
		vulkan_destroy_texture(vk, &vk.offscreen, false)
		vulkan_destroy_render_finished(vk)
		if vk.swapchain != 0 {
			vulkan.DestroySwapchainKHR(vk.device, vk.swapchain, nil)
			vk.swapchain = 0
		}
		if vk.swapchain_images != nil {
			delete(vk.swapchain_images)
			vk.swapchain_images = nil
		}
		if vk.swapchain_initialized != nil {
			delete(vk.swapchain_initialized)
			vk.swapchain_initialized = nil
		}
		if !vulkan_create_swapchain(vk, window) do return false
		if !vulkan_create_offscreen(vk) do return false
		vk.width = window.width
		vk.height = window.height
		return true
	}

	vulkan_ensure_vertex_buffer :: proc(vk: ^Vulkan, needed: int) -> bool {
		if needed <= vk.vertex_capacity && vk.vertex_mapped != nil do return true
		capacity := max(needed, max(vk.vertex_capacity*2, 65536))
		if vk.vertex_mapped != nil {
			vulkan.UnmapMemory(vk.device, vk.vertex_memory)
			vk.vertex_mapped = nil
		}
		vulkan_destroy_buffer(vk, &vk.vertex_buffer, &vk.vertex_memory)
		size := vulkan.DeviceSize(capacity*size_of(Vulkan_Vertex))
		if !vulkan_create_buffer(
			vk,
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
			&vk.vertex_buffer,
			&vk.vertex_memory,
		) {
			return false
		}
		mapped_address: rawptr
		if !vulkan_result_ok(vulkan.MapMemory(vk.device, vk.vertex_memory, 0, size, {}, &mapped_address)) {
			vulkan_destroy_buffer(vk, &vk.vertex_buffer, &vk.vertex_memory)
			return false
		}
		vk.vertex_mapped = mapped_address
		vk.vertex_capacity = capacity
		return true
	}

	vulkan_atlas_store :: proc(vk: ^Vulkan, entry: ^Atlas_Entry, glyph: ^fonts.Glyph) {
		if entry.width <= 0 || entry.height <= 0 do return
		for y in 0..<entry.height {
			for x in 0..<entry.width {
				source := y*glyph.width+x
				target := (entry.y+y)*ATLAS_WIDTH*4+(entry.x+x)*4
				if glyph.kind == .Coverage {
					alpha := glyph.pixels[source]
					vk.atlas_pixels[target] = alpha
					vk.atlas_pixels[target+1] = alpha
					vk.atlas_pixels[target+2] = alpha
					vk.atlas_pixels[target+3] = alpha
				} else {
					source *= 4
					vk.atlas_pixels[target] = glyph.pixels[source+2]
					vk.atlas_pixels[target+1] = glyph.pixels[source+1]
					vk.atlas_pixels[target+2] = glyph.pixels[source]
					vk.atlas_pixels[target+3] = glyph.pixels[source+3]
				}
			}
		}
	}

	vulkan_prepare_atlas :: proc(vk: ^Vulkan, font: ^fonts.Manager) -> bool {
		attempt := 0
		for attempt < 3 {
			attempt += 1
			processed := false
			restart := false
			for command in vk.commands {
				if command.kind != .Glyph do continue
				if atlas_find(&vk.atlas, command.face_id, command.glyph_index) != nil {
					processed = true
					continue
				}
				glyph := fonts.face_glyph(font, command.face_id, command.glyph_index)
				if glyph == nil || glyph.width == 0 || glyph.height == 0 do continue
				entry, reset := atlas_place(&vk.atlas, command.face_id, command.glyph_index, glyph.width, glyph.height)
				if entry == nil do return false
				vulkan_atlas_store(vk, entry, glyph)
				vk.atlas_dirty = true
				if reset && processed {
					restart = true
					break
				}
				processed = true
			}
			if !restart do return true
		}
		return false
	}

	vulkan_upload_resource_texture :: proc(vk: ^Vulkan, texture: ^Vulkan_Texture, resource: ^graphics.Resource) -> bool {
		channels := graphics.bytes_per_pixel(resource.format)
		if channels <= 0 do return false
		pixels := make([]u8, resource.width*resource.height*4)
		defer delete(pixels)
		for y in 0..<resource.height {
			for x in 0..<resource.width {
				source := y*resource.stride+x*channels
				target := (y*resource.width+x)*4
				pixels[target] = resource.pixels[source]
				pixels[target+1] = resource.pixels[source+1]
				pixels[target+2] = resource.pixels[source+2]
				pixels[target+3] = 255
				if channels == 4 do pixels[target+3] = resource.pixels[source+3]
			}
		}
		return vulkan_upload_texture(vk, texture, pixels)
	}

	vulkan_create_image_texture :: proc(vk: ^Vulkan, resource: ^graphics.Resource) -> bool {
		channels := graphics.bytes_per_pixel(resource.format)
		if channels <= 0 || resource.stride%channels != 0 do return false
		byte_count := resource.width*resource.height*channels
		texture := Vulkan_Texture{}
		if !vulkan_create_texture(
			vk,
			resource.width,
			resource.height,
			.R8G8B8A8_UNORM,
			{.SAMPLED, .TRANSFER_DST},
			&texture,
		) {
			return false
		}
		descriptor, descriptor_ok := vulkan_allocate_descriptor(vk, texture.view)
		if !descriptor_ok {
			vulkan_destroy_texture(vk, &texture, false)
			return false
		}
		texture.descriptor = descriptor
		if !vulkan_upload_resource_texture(vk, &texture, resource) {
			vulkan_destroy_texture(vk, &texture, true)
			return false
		}
		vk.image_clock += 1
		append(&vk.images, Vulkan_Image{
			texture = texture,
			image_id = resource.id,
			version = resource.version,
			byte_count = byte_count,
			last_used = vk.image_clock,
		})
		vk.image_bytes += byte_count
		vk.image_stats.uploads += 1
		vk.image_stats.uploaded_bytes += u64(byte_count)
		return true
	}

	vulkan_find_image :: proc(vk: ^Vulkan, image_id: u64) -> ^Vulkan_Image {
		for &entry in vk.images {
			if entry.image_id == image_id do return &entry
		}
		return nil
	}

	vulkan_eviction_index :: proc(entries: []Vulkan_Image) -> int {
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

	vulkan_touch_image :: proc(vk: ^Vulkan, entry: ^Vulkan_Image) {
		vk.image_clock += 1
		entry.last_used = vk.image_clock
	}

	vulkan_remove_image :: proc(vk: ^Vulkan, index: int) {
		entry := vk.images[index]
		vulkan_destroy_texture(vk, &entry.texture, true)
		vk.image_bytes -= entry.byte_count
		ordered_remove(&vk.images, index)
		if len(vk.images) == 0 {
			delete(vk.images)
			vk.images = nil
		}
	}

	vulkan_prepare_images :: proc(vk: ^Vulkan, registry: ^graphics.Registry) -> bool {
		for index := len(vk.images)-1; index >= 0; index -= 1 {
			if registry == nil || graphics.find_image(registry, vk.images[index].image_id) == nil {
				vulkan_remove_image(vk, index)
				vk.image_stats.releases += 1
			}
		}
		if registry == nil do return true
		budget := clamp(registry.limits.cache_bytes, 0, MAX_IMAGE_TEXTURE_BYTES)
		for command in vk.commands {
			if command.kind != .Image do continue
			resource := graphics.find_image(registry, command.image_id)
			if resource == nil do continue
			vk.image_stats.texture_lookups += 1
			entry := vulkan_find_image(vk, resource.id)
			if entry != nil {
				if entry.version != resource.version {
					if !vulkan_upload_resource_texture(vk, &entry.texture, resource) do return false
					entry.version = resource.version
					vk.image_stats.uploads += 1
					vk.image_stats.uploaded_bytes += u64(entry.byte_count)
				}
				vk.image_stats.cache_hits += 1
				vulkan_touch_image(vk, entry)
				continue
			}
			channels := graphics.bytes_per_pixel(resource.format)
			if channels <= 0 do continue
			byte_count := resource.width*resource.height*channels
			if byte_count > budget do continue
			for vk.image_bytes > budget-byte_count {
				oldest := vulkan_eviction_index(vk.images[:])
				if oldest < 0 do return false
				vulkan_remove_image(vk, oldest)
				vk.image_stats.evictions += 1
			}
			if !vulkan_create_image_texture(vk, resource) do return false
		}
		return true
	}


	vulkan_emit_quad :: proc(
		vk: ^Vulkan,
		left, top, right, bottom: int,
		u0, v0, u1, v1: f32,
	) -> bool {
		if vk.vertex_count+6 > vk.vertex_capacity || vk.vertex_mapped == nil do return false
		vertices := cast([^]Vulkan_Vertex)vk.vertex_mapped
		x0 := f32(left)*2/f32(vk.width)-1
		x1 := f32(right)*2/f32(vk.width)-1
		y0 := f32(top)*2/f32(vk.height)-1
		y1 := f32(bottom)*2/f32(vk.height)-1
		first := vk.vertex_count
		vertices[first+0] = {x0, y0, u0, v0}
		vertices[first+1] = {x1, y0, u1, v0}
		vertices[first+2] = {x1, y1, u1, v1}
		vertices[first+3] = {x0, y0, u0, v0}
		vertices[first+4] = {x1, y1, u1, v1}
		vertices[first+5] = {x0, y1, u0, v1}
		vk.vertex_count += 6
		return true
	}

	vulkan_push_color :: proc(vk: ^Vulkan, cmd: vulkan.CommandBuffer, red, green, blue, alpha: f32) {
		push := Vulkan_Push{color = {red, green, blue, alpha}}
		vulkan.CmdPushConstants(vk.command_buffer, vk.pipeline_layout, {.FRAGMENT}, 0, size_of(Vulkan_Push), &push)
	}

	vulkan_color :: proc(color: u32, alpha: f32) -> (f32, f32, f32, f32) {
		return f32((color>>16)&0xff)/255, f32((color>>8)&0xff)/255, f32(color&0xff)/255, alpha
	}

	vulkan_emit_rectangle :: proc(vk: ^Vulkan, command: Command) -> bool {
		if command.width <= 0 || command.height <= 0 do return false
		return vulkan_emit_quad(vk, command.x, command.y, command.x+command.width, command.y+command.height, 0, 0, 0, 0)
	}

	vulkan_emit_glyph :: proc(vk: ^Vulkan, command: Command) -> bool {
		entry := atlas_find(&vk.atlas, command.face_id, command.glyph_index)
		if entry == nil do return false
		left := max(0, max(command.clip_left, command.x))
		right := min(vk.width, min(command.clip_right, command.x+command.width))
		top := max(0, command.y)
		bottom := min(vk.height, command.y+command.height)
		if left >= right || top >= bottom do return false
		u0 := f32(entry.x+left-command.x)/f32(ATLAS_WIDTH)
		u1 := f32(entry.x+right-command.x)/f32(ATLAS_WIDTH)
		v0 := f32(entry.y+top-command.y)/f32(ATLAS_HEIGHT)
		v1 := f32(entry.y+bottom-command.y)/f32(ATLAS_HEIGHT)
		return vulkan_emit_quad(vk, left, top, right, bottom, u0, v0, u1, v1)
	}

	vulkan_bind_descriptor :: proc(vk: ^Vulkan, cmd: vulkan.CommandBuffer, descriptor: vulkan.DescriptorSet) {
		sets := [1]vulkan.DescriptorSet{descriptor}
		vulkan.CmdBindDescriptorSets(cmd, .GRAPHICS, vk.pipeline_layout, 0, 1, &sets[0], 0, nil)
	}

	vulkan_draw_vertices :: proc(vk: ^Vulkan, cmd: vulkan.CommandBuffer, first: int) {
		vulkan.CmdDraw(cmd, 6, 1, u32(first), 0)
	}

	vulkan_record_row :: proc(vk: ^Vulkan, cmd: vulkan.CommandBuffer, row: Vulkan_Row, registry: ^graphics.Registry) {
		index := row.start
		end := row.start+row.count
		for index < end {
			command := vk.commands[index]
			switch command.kind {
			case .Rectangle:
				vulkan.CmdBindPipeline(cmd, .GRAPHICS, vk.solid_pipeline)
				for index < end && vk.commands[index].kind == .Rectangle {
					current := vk.commands[index]
					first := vk.vertex_count
					if vulkan_emit_rectangle(vk, current) {
						alpha := f32(255)/255
						if current.opacity != 0 do alpha = f32(current.opacity)/255
						red, green, blue, a := vulkan_color(current.color, alpha)
						vulkan_push_color(vk, cmd, red, green, blue, a)
						vulkan_draw_vertices(vk, cmd, first)
					}
					index += 1
				}
			case .Glyph:
				vulkan.CmdBindPipeline(cmd, .GRAPHICS, vk.glyph_pipeline)
				vulkan_bind_descriptor(vk, cmd, vk.atlas_descriptor)
				for index < end && vk.commands[index].kind == .Glyph {
					current := vk.commands[index]
					first := vk.vertex_count
					if vulkan_emit_glyph(vk, current) {
						red, green, blue, alpha := vulkan_color(current.color, 1)
						vulkan_push_color(vk, cmd, red, green, blue, alpha)
						vulkan_draw_vertices(vk, cmd, first)
					}
					index += 1
				}
			case .Image:
				resource := graphics.find_image(registry, command.image_id)
				entry := vulkan_find_image(vk, command.image_id)
				if resource == nil || entry == nil {
					index += 1
					continue
				}
				left := max(0, max(command.clip_left, command.x))
				right := min(vk.width, min(command.clip_right, command.x+command.width))
				top := max(0, max(command.clip_top, command.y))
				bottom := min(vk.height, min(command.clip_bottom, command.y+command.height))
				if left >= right || top >= bottom {
					index += 1
					continue
				}
				u0, v0, u1, v1 := image_texture_coordinates(command, resource.width, resource.height, left, top, right, bottom)
				first := vk.vertex_count
				if vulkan_emit_quad(vk, left, top, right, bottom, u0, v0, u1, v1) {
					vulkan.CmdBindPipeline(cmd, .GRAPHICS, vk.image_pipeline)
					vulkan_bind_descriptor(vk, cmd, entry.texture.descriptor)
					vulkan_push_color(vk, cmd, 1, 1, 1, 1)
					vulkan_draw_vertices(vk, cmd, first)
					vk.image_stats.draws += 1
				}
				index += 1
			}
		}
	}

	vulkan_record_present :: proc(vk: ^Vulkan, cmd: vulkan.CommandBuffer, image_index: u32) {
		src_stage := vulkan.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
		src_access: vulkan.AccessFlags = {.COLOR_ATTACHMENT_WRITE}
		vulkan_transition_image(
			cmd,
			vk.offscreen.image,
			.TRANSFER_SRC_OPTIMAL,
			.TRANSFER_SRC_OPTIMAL,
			src_stage,
			{.TRANSFER},
			src_access,
			{.TRANSFER_READ},
		)
		old_layout := vulkan.ImageLayout.UNDEFINED
		if vk.swapchain_initialized[image_index] do old_layout = .PRESENT_SRC_KHR
		vulkan_transition_image(
			cmd,
			vk.swapchain_images[image_index],
			old_layout,
			.TRANSFER_DST_OPTIMAL,
			{.TOP_OF_PIPE},
			{.TRANSFER},
			{},
			{.TRANSFER_WRITE},
		)
		source_layers := vulkan.ImageSubresourceLayers{
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		}
		blit := vulkan.ImageBlit{
			srcSubresource = source_layers,
			srcOffsets = {{0, 0, 0}, {i32(vk.width), i32(vk.height), 1}},
			dstSubresource = source_layers,
			dstOffsets = {{0, 0, 0}, {i32(vk.width), i32(vk.height), 1}},
		}
		regions := [1]vulkan.ImageBlit{blit}
		vulkan.CmdBlitImage(
			cmd,
			vk.offscreen.image,
			.TRANSFER_SRC_OPTIMAL,
			vk.swapchain_images[image_index],
			.TRANSFER_DST_OPTIMAL,
			1,
			&regions[0],
			.NEAREST,
		)
		vulkan_transition_image(
			cmd,
			vk.swapchain_images[image_index],
			.TRANSFER_DST_OPTIMAL,
			.PRESENT_SRC_KHR,
			{.TRANSFER},
			{.BOTTOM_OF_PIPE},
			{.TRANSFER_WRITE},
			{},
		)
		vk.swapchain_initialized[image_index] = true
	}

	vulkan_record_frame :: proc(vk: ^Vulkan, registry: ^graphics.Registry) -> bool {
		if !vulkan_begin_commands(vk) do return false
		cmd := vk.command_buffer
		vk.vertex_count = 0
		offset: vulkan.DeviceSize = 0
		buffers := [1]vulkan.Buffer{vk.vertex_buffer}
		vulkan.CmdBindVertexBuffers(cmd, 0, 1, &buffers[0], &offset)
		begin := vulkan.RenderPassBeginInfo{
			sType = .RENDER_PASS_BEGIN_INFO,
			renderPass = vk.render_pass,
			framebuffer = vk.framebuffer,
			renderArea = {
				offset = {0, 0},
				extent = {u32(vk.width), u32(vk.height)},
			},
		}
		vulkan.CmdBeginRenderPass(cmd, &begin, .INLINE)
		viewport := vulkan.Viewport{
			x = 0,
			y = 0,
			width = f32(vk.width),
			height = f32(vk.height),
			minDepth = 0,
			maxDepth = 1,
		}
		vulkan.CmdSetViewport(cmd, 0, 1, &viewport)
		for row in vk.rows {
			scissor := vulkan.Rect2D{
				offset = {0, i32(row.y)},
				extent = {u32(vk.width), u32(row.height)},
			}
			vulkan.CmdSetScissor(cmd, 0, 1, &scissor)
			vulkan_record_row(vk, cmd, row, registry)
		}
		vulkan.CmdEndRenderPass(cmd)
		vulkan_record_present(vk, cmd, vk.present_image)
		return vulkan_end_commands(vk)
	}

	vulkan_submit_present :: proc(vk: ^Vulkan, image_index: u32, window: ^x11.Window) -> bool {
		if int(image_index) >= len(vk.render_finished) do return false
		wait_stage := [1]vulkan.PipelineStageFlags{{.TRANSFER}}
		waits := [1]vulkan.Semaphore{vk.image_available}
		signals := [1]vulkan.Semaphore{vk.render_finished[image_index]}
		commands := [1]vulkan.CommandBuffer{vk.command_buffer}
		submit := vulkan.SubmitInfo{
			sType = .SUBMIT_INFO,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &waits[0],
			pWaitDstStageMask = &wait_stage[0],
			commandBufferCount = 1,
			pCommandBuffers = &commands[0],
			signalSemaphoreCount = 1,
			pSignalSemaphores = &signals[0],
		}
		submits := [1]vulkan.SubmitInfo{submit}
		fences := [1]vulkan.Fence{vk.fence}
		_ = vulkan.ResetFences(vk.device, 1, &fences[0])
		if !vulkan_result_ok(vulkan.QueueSubmit(vk.queue, 1, &submits[0], vk.fence)) do return false
		swapchains := [1]vulkan.SwapchainKHR{vk.swapchain}
		indices := [1]u32{image_index}
		present := vulkan.PresentInfoKHR{
			sType = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &signals[0],
			swapchainCount = 1,
			pSwapchains = &swapchains[0],
			pImageIndices = &indices[0],
		}
		result := vulkan.QueuePresentKHR(vk.queue, &present)
		if result == .ERROR_OUT_OF_DATE_KHR {
			vk.needs_full_redraw = true
			return vulkan_recreate_swapchain(vk, window)
		}
		return result == .SUCCESS || result == .SUBOPTIMAL_KHR
	}

	vulkan_acquire_image :: proc(vk: ^Vulkan, window: ^x11.Window) -> (image_index: u32, recreated: bool, ok: bool) {
		for _ in 0..<3 {
			fences := [1]vulkan.Fence{vk.fence}
			if !vulkan_result_ok(vulkan.WaitForFences(vk.device, 1, &fences[0], true, ~u64(0))) do return 0, false, false
			result := vulkan.AcquireNextImageKHR(vk.device, vk.swapchain, ~u64(0), vk.image_available, 0, &image_index)
			if result == .ERROR_OUT_OF_DATE_KHR {
				if !vulkan_recreate_swapchain(vk, window) do return 0, false, false
				recreated = true
				continue
			}
			if result != .SUCCESS && result != .SUBOPTIMAL_KHR do return 0, false, false
			_ = vulkan.ResetCommandPool(vk.device, vk.command_pool, {})
			return image_index, recreated, true
		}
		return 0, false, false
	}
}

vulkan_init :: proc(vk: ^Vulkan, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		library, loaded := dynlib.load_library("libvulkan.so.1")
		if !loaded do return false
		vk.library = library
		address, found := dynlib.symbol_address(library, "vkGetInstanceProcAddr")
		if !found {
			vulkan_destroy(vk, window)
			return false
		}
		vulkan.load_proc_addresses_global(address)
		if vulkan.CreateInstance == nil {
			vulkan_destroy(vk, window)
			return false
		}
		application := vulkan.ApplicationInfo{
			sType = .APPLICATION_INFO,
			pApplicationName = "nare",
			pEngineName = "nare",
			apiVersion = vulkan.API_VERSION_1_0,
		}
		extensions := [2]cstring{
			cstring(vulkan.KHR_SURFACE_EXTENSION_NAME),
			cstring(vulkan.KHR_XLIB_SURFACE_EXTENSION_NAME),
		}
		instance_info := vulkan.InstanceCreateInfo{
			sType = .INSTANCE_CREATE_INFO,
			pApplicationInfo = &application,
			enabledExtensionCount = 2,
			ppEnabledExtensionNames = &extensions[0],
		}
		if !vulkan_result_ok(vulkan.CreateInstance(&instance_info, nil, &vk.instance)) {
			vulkan_destroy(vk, window)
			return false
		}
		vulkan.load_proc_addresses_instance(vk.instance)
		surface_info := vulkan.XlibSurfaceCreateInfoKHR{
			sType = .XLIB_SURFACE_CREATE_INFO_KHR,
			dpy = window.display,
			window = window.id,
		}
		if !vulkan_result_ok(vulkan.CreateXlibSurfaceKHR(vk.instance, &surface_info, nil, &vk.surface)) {
			vulkan_destroy(vk, window)
			return false
		}
		device_count: u32
		if !vulkan_result_ok(vulkan.EnumeratePhysicalDevices(vk.instance, &device_count, nil)) || device_count == 0 {
			vulkan_destroy(vk, window)
			return false
		}
		devices := make([]vulkan.PhysicalDevice, device_count)
		defer delete(devices)
		if !vulkan_result_ok(vulkan.EnumeratePhysicalDevices(vk.instance, &device_count, raw_data(devices))) {
			vulkan_destroy(vk, window)
			return false
		}
		found_device := false
		for device in devices {
			family, family_ok := vulkan_pick_queue_family(vk, device)
			if !family_ok do continue
			vk.physical_device = device
			vk.queue_family = family
			found_device = true
			break
		}
		if !found_device {
			vulkan_destroy(vk, window)
			return false
		}
		priority: f32 = 1
		queue_info := vulkan.DeviceQueueCreateInfo{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = vk.queue_family,
			queueCount = 1,
			pQueuePriorities = &priority,
		}
		device_extensions := [1]cstring{cstring(vulkan.KHR_SWAPCHAIN_EXTENSION_NAME)}
		device_info := vulkan.DeviceCreateInfo{
			sType = .DEVICE_CREATE_INFO,
			queueCreateInfoCount = 1,
			pQueueCreateInfos = &queue_info,
			enabledExtensionCount = 1,
			ppEnabledExtensionNames = &device_extensions[0],
		}
		if !vulkan_result_ok(vulkan.CreateDevice(vk.physical_device, &device_info, nil, &vk.device)) {
			vulkan_destroy(vk, window)
			return false
		}
		vulkan.load_proc_addresses_device(vk.device)
		vulkan.GetDeviceQueue(vk.device, vk.queue_family, 0, &vk.queue)
		binding := vulkan.DescriptorSetLayoutBinding{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		}
		descriptor_layout := vulkan.DescriptorSetLayoutCreateInfo{
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = 1,
			pBindings = &binding,
		}
		if !vulkan_result_ok(vulkan.CreateDescriptorSetLayout(vk.device, &descriptor_layout, nil, &vk.descriptor_layout)) {
			vulkan_destroy(vk, window)
			return false
		}
		pool_size := vulkan.DescriptorPoolSize{
			type = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = VULKAN_DESCRIPTOR_SETS,
		}
		pool_info := vulkan.DescriptorPoolCreateInfo{
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			flags = {.FREE_DESCRIPTOR_SET},
			maxSets = VULKAN_DESCRIPTOR_SETS,
			poolSizeCount = 1,
			pPoolSizes = &pool_size,
		}
		if !vulkan_result_ok(vulkan.CreateDescriptorPool(vk.device, &pool_info, nil, &vk.descriptor_pool)) {
			vulkan_destroy(vk, window)
			return false
		}
		sampler_info := vulkan.SamplerCreateInfo{
			sType = .SAMPLER_CREATE_INFO,
			magFilter = .NEAREST,
			minFilter = .NEAREST,
			mipmapMode = .NEAREST,
			addressModeU = .CLAMP_TO_EDGE,
			addressModeV = .CLAMP_TO_EDGE,
			addressModeW = .CLAMP_TO_EDGE,
			maxLod = 0,
		}
		if !vulkan_result_ok(vulkan.CreateSampler(vk.device, &sampler_info, nil, &vk.sampler)) {
			vulkan_destroy(vk, window)
			return false
		}
		push_range := vulkan.PushConstantRange{
			stageFlags = {.FRAGMENT},
			offset = 0,
			size = size_of(Vulkan_Push),
		}
		layout_info := vulkan.PipelineLayoutCreateInfo{
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = 1,
			pSetLayouts = &vk.descriptor_layout,
			pushConstantRangeCount = 1,
			pPushConstantRanges = &push_range,
		}
		if !vulkan_result_ok(vulkan.CreatePipelineLayout(vk.device, &layout_info, nil, &vk.pipeline_layout)) {
			vulkan_destroy(vk, window)
			return false
		}
		command_pool_info := vulkan.CommandPoolCreateInfo{
			sType = .COMMAND_POOL_CREATE_INFO,
			flags = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = vk.queue_family,
		}
		if !vulkan_result_ok(vulkan.CreateCommandPool(vk.device, &command_pool_info, nil, &vk.command_pool)) {
			vulkan_destroy(vk, window)
			return false
		}
		allocate := vulkan.CommandBufferAllocateInfo{
			sType = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool = vk.command_pool,
			level = .PRIMARY,
			commandBufferCount = 1,
		}
		if !vulkan_result_ok(vulkan.AllocateCommandBuffers(vk.device, &allocate, &vk.command_buffer)) {
			vulkan_destroy(vk, window)
			return false
		}
		semaphore_info := vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
		if !vulkan_result_ok(vulkan.CreateSemaphore(vk.device, &semaphore_info, nil, &vk.image_available)) {
			vulkan_destroy(vk, window)
			return false
		}
		fence_info := vulkan.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
		if !vulkan_result_ok(vulkan.CreateFence(vk.device, &fence_info, nil, &vk.fence)) {
			vulkan_destroy(vk, window)
			return false
		}
		if !vulkan_create_swapchain(vk, window) {
			vulkan_destroy(vk, window)
			return false
		}
		if !vulkan_create_render_pass(vk) || !vulkan_create_pipelines(vk) || !vulkan_create_offscreen(vk) {
			vulkan_destroy(vk, window)
			return false
		}
		vk.atlas_pixels = make([]u8, ATLAS_WIDTH*ATLAS_HEIGHT*4)
		if !vulkan_create_texture(
			vk,
			ATLAS_WIDTH,
			ATLAS_HEIGHT,
			.R8G8B8A8_UNORM,
			{.SAMPLED, .TRANSFER_DST},
			&vk.atlas_texture,
		) {
			vulkan_destroy(vk, window)
			return false
		}
		descriptor, descriptor_ok := vulkan_allocate_descriptor(vk, vk.atlas_texture.view)
		if !descriptor_ok {
			vulkan_destroy(vk, window)
			return false
		}
		vk.atlas_descriptor = descriptor
		if !vulkan_upload_texture(vk, &vk.atlas_texture, vk.atlas_pixels) {
			vulkan_destroy(vk, window)
			return false
		}
		vk.atlas_dirty = false
		if !vulkan_ensure_vertex_buffer(vk, 65536) {
			vulkan_destroy(vk, window)
			return false
		}
		vk.width = window.width
		vk.height = window.height
		return true
	}
}

vulkan_pick_queue_family :: proc(vk: ^Vulkan, device: vulkan.PhysicalDevice) -> (u32, bool) {
	when !GPU_ENABLED {
		return 0, false
	} else {
		count: u32
		vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
		if count == 0 do return 0, false
		families := make([]vulkan.QueueFamilyProperties, count)
		defer delete(families)
		vulkan.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))
		for family, index in families {
			if !(vulkan.QueueFlags{.GRAPHICS} <= family.queueFlags) do continue
			supported: b32
			result := vulkan.GetPhysicalDeviceSurfaceSupportKHR(device, u32(index), vk.surface, &supported)
			if !vulkan_result_ok(result) || !supported do continue
			return u32(index), true
		}
		return 0, false
	}
}

vulkan_destroy :: proc(vk: ^Vulkan, window: ^x11.Window) {
	when GPU_ENABLED {
		_ = window
		if vk.device != nil {
			_ = vulkan.DeviceWaitIdle(vk.device)
			for index := len(vk.images)-1; index >= 0; index -= 1 {
				vulkan_remove_image(vk, index)
			}
			vk.image_stats.releases += u64(len(vk.images))
			vulkan_destroy_texture(vk, &vk.atlas_texture, true)
			vulkan_destroy_texture(vk, &vk.offscreen, false)
			if vk.framebuffer != 0 do vulkan.DestroyFramebuffer(vk.device, vk.framebuffer, nil)
			if vk.solid_pipeline != 0 do vulkan.DestroyPipeline(vk.device, vk.solid_pipeline, nil)
			if vk.glyph_pipeline != 0 do vulkan.DestroyPipeline(vk.device, vk.glyph_pipeline, nil)
			if vk.image_pipeline != 0 do vulkan.DestroyPipeline(vk.device, vk.image_pipeline, nil)
			if vk.render_pass != 0 do vulkan.DestroyRenderPass(vk.device, vk.render_pass, nil)
			vulkan_destroy_buffer(vk, &vk.vertex_buffer, &vk.vertex_memory)
			if vk.sampler != 0 do vulkan.DestroySampler(vk.device, vk.sampler, nil)
			if vk.command_pool != 0 do vulkan.DestroyCommandPool(vk.device, vk.command_pool, nil)
			if vk.fence != 0 do vulkan.DestroyFence(vk.device, vk.fence, nil)
			vulkan_destroy_render_finished(vk)
			if vk.image_available != 0 do vulkan.DestroySemaphore(vk.device, vk.image_available, nil)
			if vk.descriptor_pool != 0 do vulkan.DestroyDescriptorPool(vk.device, vk.descriptor_pool, nil)
			if vk.descriptor_layout != 0 do vulkan.DestroyDescriptorSetLayout(vk.device, vk.descriptor_layout, nil)
			if vk.pipeline_layout != 0 do vulkan.DestroyPipelineLayout(vk.device, vk.pipeline_layout, nil)
			if vk.swapchain != 0 do vulkan.DestroySwapchainKHR(vk.device, vk.swapchain, nil)
			vulkan.DestroyDevice(vk.device, nil)
		}
		if vk.instance != nil {
			if vk.surface != 0 do vulkan.DestroySurfaceKHR(vk.instance, vk.surface, nil)
			vulkan.DestroyInstance(vk.instance, nil)
		}
		if vk.library != nil do _ = dynlib.unload_library(vk.library)
	}
	atlas_destroy(&vk.atlas)
	if vk.swapchain_images != nil do delete(vk.swapchain_images)
	if vk.swapchain_initialized != nil do delete(vk.swapchain_initialized)
	if vk.render_finished != nil do delete(vk.render_finished)
	if vk.atlas_pixels != nil do delete(vk.atlas_pixels)
	if vk.images != nil do delete(vk.images)
	delete(vk.commands)
	delete(vk.row_commands)
	delete(vk.rows)
	command_scratch_destroy(&vk.scratch)
	vk^ = {}
}

vulkan_resize :: proc(vk: ^Vulkan, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if vk.device == nil || window.width <= 0 || window.height <= 0 do return false
		if vk.width == window.width && vk.height == window.height && vk.swapchain != 0 do return true
		return vulkan_recreate_swapchain(vk, window)
	}
}

vulkan_draw :: proc(
	vk: ^Vulkan,
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
		if vk.device == nil || vk.width != damage.width || vk.height != damage.height do return false
		screen := screen_override
		if screen == nil do screen = vt.terminal_screen(terminal)
		scrollbar_geometry_state := scrollbar_geometry(window, screen, scrollbar)
		image_index, recreated, acquired := vulkan_acquire_image(vk, window)
		if !acquired do return false
		vk.present_image = image_index
		full_redraw := force || recreated || vk.needs_full_redraw
		vk.needs_full_redraw = false
		if !damage_rows(damage, terminal, screen, full_redraw, selection_state, scrollbar_geometry_state) {
			if !vulkan_begin_commands(vk) do return false
			vulkan_record_present(vk, vk.command_buffer, image_index)
			if !vulkan_end_commands(vk) do return false
			return vulkan_submit_present(vk, image_index, window)
		}
		clear(&vk.commands)
		clear(&vk.rows)
		for dirty, row in damage.dirty_rows {
			if !dirty do continue
			if row*window.cell_h >= vk.height do continue
			build_row_commands(
				&vk.row_commands,
				font,
				window,
				terminal,
				screen,
				row,
				ligatures,
				selection_state,
				scrollbar,
				&vk.scratch,
			)
			start := len(vk.commands)
			append(&vk.commands, ..vk.row_commands[:])
			append(&vk.rows, Vulkan_Row{
				start = start,
				count = len(vk.row_commands),
				y = row*window.cell_h,
				height = min(window.cell_h, vk.height-row*window.cell_h),
			})
		}
		if !vulkan_prepare_atlas(vk, font) do return false
		if !vulkan_prepare_images(vk, screen.image_registry) do return false
		if !vulkan_ensure_vertex_buffer(vk, max(1024, len(vk.commands)*6)) do return false
		if vk.atlas_dirty {
			if !vulkan_upload_texture(vk, &vk.atlas_texture, vk.atlas_pixels) do return false
			vk.atlas_dirty = false
		}
		if !vulkan_record_frame(vk, screen.image_registry) do return false
		return vulkan_submit_present(vk, image_index, window)
	}
}

vulkan_present_cached :: proc(vk: ^Vulkan, window: ^x11.Window) -> bool {
	when !GPU_ENABLED {
		return false
	} else {
		if vk.device == nil || vk.swapchain == 0 || vk.width <= 0 || vk.height <= 0 do return false
		image_index, recreated, acquired := vulkan_acquire_image(vk, window)
		if !acquired do return false
		if recreated do vk.needs_full_redraw = true
		if !vulkan_begin_commands(vk) do return false
		vulkan_record_present(vk, vk.command_buffer, image_index)
		if !vulkan_end_commands(vk) do return false
		return vulkan_submit_present(vk, image_index, window)
	}
}
