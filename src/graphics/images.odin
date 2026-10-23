package graphics

MAX_IMAGE_DIMENSION :: 16_384
MAX_IMAGE_PIXELS :: 16 * 1024 * 1024
MAX_IMAGE_BYTES :: 64 * 1024 * 1024
MAX_CACHE_BYTES :: 256 * 1024 * 1024
MAX_PLACEMENT_CELLS :: 65_535

Pixel_Format :: enum {
	RGB8,
	RGBA8,
}

Protocol :: enum {
	None,
	Kitty,
	Sixel,
	ITerm2,
}

Screen :: enum {
	Main,
	Alternate,
}

Error :: enum {
	None,
	Invalid_Limit,
	Invalid_Dimensions,
	Invalid_Stride,
	Invalid_Pixel_Data,
	Image_Too_Large,
	Cache_Full,
	Duplicate_Protocol_ID,
	Unknown_Image,
	Invalid_Placement,
	ID_Exhausted,
}

Decoded_Image :: struct {
	width, height: int,
	stride: int,
	format: Pixel_Format,
	pixels: []byte,
}

Resource :: struct {
	id: u64,
	protocol: Protocol,
	protocol_id: u32,
	width, height: int,
	stride: int,
	format: Pixel_Format,
	pixels: []byte,
	placement_count: int,
	last_used: u64,
}

Placement_Request :: struct {
	image_id: u64,
	protocol_id: u32,
	screen: Screen,
	row, column: int,
	rows, columns: int,
	source_x, source_y: int,
	source_width, source_height: int,
	z: i32,
	preserve_aspect: bool,
}

Placement :: struct {
	id: u64,
	image_id: u64,
	protocol_id: u32,
	screen: Screen,
	row, column: int,
	rows, columns: int,
	source_x, source_y: int,
	source_width, source_height: int,
	z: i32,
	preserve_aspect: bool,
}

Registry :: struct {
	resources: [dynamic]Resource,
	placements: [dynamic]Placement,
	decoded_bytes: int,
	budget_bytes: int,
	next_resource_id: u64,
	next_placement_id: u64,
	clock: u64,
}

registry_init :: proc(registry: ^Registry, budget_bytes: int = MAX_CACHE_BYTES) -> Error {
	if budget_bytes < 0 || budget_bytes > MAX_CACHE_BYTES do return .Invalid_Limit
	registry.budget_bytes = budget_bytes
	registry.next_resource_id = 1
	registry.next_placement_id = 1
	return .None
}

registry_destroy :: proc(registry: ^Registry) {
	for &resource in registry.resources do delete(resource.pixels)
	delete(registry.resources)
	delete(registry.placements)
	registry^ = {}
}

decoded_image_destroy :: proc(image: ^Decoded_Image) {
	delete(image.pixels)
	image^ = {}
}

add_image :: proc(
	registry: ^Registry,
	protocol: Protocol,
	protocol_id: u32,
	image: ^Decoded_Image,
) -> (u64, Error) {
	byte_count, validation_error := validate_image(image)
	if validation_error != .None do return 0, validation_error
	if protocol_id != 0 && find_protocol_image(registry, protocol, protocol_id) != nil {
		return 0, .Duplicate_Protocol_ID
	}
	if registry.next_resource_id == 0 || registry.next_resource_id == max(u64) do return 0, .ID_Exhausted
	if byte_count > registry.budget_bytes do return 0, .Cache_Full
	evict_for(registry, byte_count)
	if registry.decoded_bytes > registry.budget_bytes-byte_count do return 0, .Cache_Full

	id := registry.next_resource_id
	registry.next_resource_id += 1
	registry.clock += 1
	append(&registry.resources, Resource{
		id = id,
		protocol = protocol,
		protocol_id = protocol_id,
		width = image.width,
		height = image.height,
		stride = image.stride,
		format = image.format,
		pixels = image.pixels,
		last_used = registry.clock,
	})
	registry.decoded_bytes += byte_count
	image^ = {}
	return id, .None
}

add_placement :: proc(registry: ^Registry, request: Placement_Request) -> (u64, Error) {
	resource := find_image(registry, request.image_id)
	if resource == nil do return 0, .Unknown_Image
	if registry.next_placement_id == 0 || registry.next_placement_id == max(u64) do return 0, .ID_Exhausted
	if request.rows <= 0 || request.rows > MAX_PLACEMENT_CELLS ||
	   request.columns <= 0 || request.columns > MAX_PLACEMENT_CELLS ||
	   request.source_x < 0 || request.source_x >= resource.width ||
	   request.source_y < 0 || request.source_y >= resource.height {
		return 0, .Invalid_Placement
	}
	source_width := request.source_width
	if source_width == 0 do source_width = resource.width-request.source_x
	source_height := request.source_height
	if source_height == 0 do source_height = resource.height-request.source_y
	if source_width <= 0 || source_width > resource.width-request.source_x ||
	   source_height <= 0 || source_height > resource.height-request.source_y {
		return 0, .Invalid_Placement
	}

	id := registry.next_placement_id
	registry.next_placement_id += 1
	append(&registry.placements, Placement{
		id = id,
		image_id = request.image_id,
		protocol_id = request.protocol_id,
		screen = request.screen,
		row = request.row,
		column = request.column,
		rows = request.rows,
		columns = request.columns,
		source_x = request.source_x,
		source_y = request.source_y,
		source_width = source_width,
		source_height = source_height,
		z = request.z,
		preserve_aspect = request.preserve_aspect,
	})
	resource.placement_count += 1
	touch(registry, resource)
	return id, .None
}

find_image :: proc(registry: ^Registry, id: u64) -> ^Resource {
	for &resource in registry.resources {
		if resource.id == id do return &resource
	}
	return nil
}

find_protocol_image :: proc(registry: ^Registry, protocol: Protocol, protocol_id: u32) -> ^Resource {
	if protocol_id == 0 do return nil
	for &resource in registry.resources {
		if resource.protocol == protocol && resource.protocol_id == protocol_id do return &resource
	}
	return nil
}

find_placement :: proc(registry: ^Registry, id: u64) -> ^Placement {
	for &placement in registry.placements {
		if placement.id == id do return &placement
	}
	return nil
}

remove_placement :: proc(registry: ^Registry, id: u64) -> bool {
	for index in 0..<len(registry.placements) {
		if registry.placements[index].id != id do continue
		remove_placement_at(registry, index)
		return true
	}
	return false
}

delete_image :: proc(registry: ^Registry, id: u64) -> bool {
	for index in 0..<len(registry.resources) {
		if registry.resources[index].id != id do continue
		delete_resource_at(registry, index)
		return true
	}
	return false
}

clear_screen :: proc(registry: ^Registry, screen: Screen) {
	for index := len(registry.placements)-1; index >= 0; index -= 1 {
		if registry.placements[index].screen == screen do remove_placement_at(registry, index)
	}
}

registry_clear :: proc(registry: ^Registry) {
	for &resource in registry.resources do delete(resource.pixels)
	clear(&registry.resources)
	clear(&registry.placements)
	registry.decoded_bytes = 0
}

validate_image :: proc(image: ^Decoded_Image) -> (int, Error) {
	stride, byte_count, layout_error := image_layout(image.width, image.height, image.format)
	if layout_error != .None do return 0, layout_error
	if image.stride < stride do return 0, .Invalid_Stride
	if image.stride > MAX_IMAGE_BYTES/image.height do return 0, .Image_Too_Large
	byte_count = image.stride*image.height
	if len(image.pixels) != byte_count do return 0, .Invalid_Pixel_Data
	return byte_count, .None
}

image_layout :: proc(width, height: int, format: Pixel_Format) -> (stride, byte_count: int, err: Error) {
	if width <= 0 || height <= 0 || width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION {
		return 0, 0, .Invalid_Dimensions
	}
	if width > MAX_IMAGE_PIXELS/height do return 0, 0, .Image_Too_Large
	channels := bytes_per_pixel(format)
	stride = width*channels
	if stride > MAX_IMAGE_BYTES/height do return 0, 0, .Image_Too_Large
	return stride, stride*height, .None
}

bytes_per_pixel :: proc(format: Pixel_Format) -> int {
	switch format {
	case .RGB8: return 3
	case .RGBA8: return 4
	}
	return 0
}

touch :: proc(registry: ^Registry, resource: ^Resource) {
	registry.clock += 1
	resource.last_used = registry.clock
}

evict_for :: proc(registry: ^Registry, incoming_bytes: int) {
	for registry.decoded_bytes > registry.budget_bytes-incoming_bytes {
		oldest_index := -1
		oldest_tick := max(u64)
		for resource, index in registry.resources {
			if resource.placement_count == 0 && resource.last_used < oldest_tick {
				oldest_index = index
				oldest_tick = resource.last_used
			}
		}
		if oldest_index < 0 do return
		delete_resource_at(registry, oldest_index)
	}
}

remove_placement_at :: proc(registry: ^Registry, index: int) {
	image_id := registry.placements[index].image_id
	resource := find_image(registry, image_id)
	if resource != nil do resource.placement_count = max(0, resource.placement_count-1)
	ordered_remove(&registry.placements, index)
}

delete_resource_at :: proc(registry: ^Registry, index: int) {
	id := registry.resources[index].id
	for placement_index := len(registry.placements)-1; placement_index >= 0; placement_index -= 1 {
		if registry.placements[placement_index].image_id == id do ordered_remove(&registry.placements, placement_index)
	}
	registry.decoded_bytes -= len(registry.resources[index].pixels)
	delete(registry.resources[index].pixels)
	ordered_remove(&registry.resources, index)
}
