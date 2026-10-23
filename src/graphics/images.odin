package graphics

MAX_IMAGE_DIMENSION :: 16_384
MAX_IMAGE_PIXELS :: 16 * 1024 * 1024
MAX_IMAGE_BYTES :: 64 * 1024 * 1024
MAX_CACHE_BYTES :: 256 * 1024 * 1024
MAX_PLACEMENT_CELLS :: 65_535
MAX_PLACEMENT_PIXELS :: MAX_PLACEMENT_CELLS*MAX_IMAGE_DIMENSION

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
	pixel_offset_x, pixel_offset_y: int,
	pixel_width, pixel_height: int,
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
	pixel_offset_x, pixel_offset_y: int,
	pixel_width, pixel_height: int,
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
	generation: u64,
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
	if request.rows <= 0 || request.rows > MAX_PLACEMENT_CELLS ||
	   request.columns <= 0 || request.columns > MAX_PLACEMENT_CELLS ||
	   request.pixel_offset_x < 0 || request.pixel_offset_y < 0 ||
	   request.pixel_width < 0 || request.pixel_width > MAX_PLACEMENT_PIXELS ||
	   request.pixel_height < 0 || request.pixel_height > MAX_PLACEMENT_PIXELS ||
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

	placement := Placement{
		image_id = request.image_id,
		protocol_id = request.protocol_id,
		screen = request.screen,
		row = request.row,
		column = request.column,
		rows = request.rows,
		columns = request.columns,
		pixel_offset_x = request.pixel_offset_x,
		pixel_offset_y = request.pixel_offset_y,
		pixel_width = request.pixel_width,
		pixel_height = request.pixel_height,
		source_x = request.source_x,
		source_y = request.source_y,
		source_width = source_width,
		source_height = source_height,
		z = request.z,
		preserve_aspect = request.preserve_aspect,
	}
	if request.protocol_id != 0 {
		for &existing in registry.placements {
			if existing.image_id != request.image_id || existing.protocol_id != request.protocol_id do continue
			placement.id = existing.id
			existing = placement
			touch(registry, resource)
			registry.generation += 1
			return placement.id, .None
		}
	}

	if registry.next_placement_id == 0 || registry.next_placement_id == max(u64) do return 0, .ID_Exhausted
	placement.id = registry.next_placement_id
	registry.next_placement_id += 1
	append(&registry.placements, placement)
	resource.placement_count += 1
	touch(registry, resource)
	registry.generation += 1
	return placement.id, .None
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

delete_protocol_image :: proc(
	registry: ^Registry,
	protocol: Protocol,
	protocol_id, placement_id: u32,
	delete_data: bool,
) -> bool {
	resource := find_protocol_image(registry, protocol, protocol_id)
	if resource == nil do return false
	resource_id := resource.id
	affected := placement_id == 0
	for index := len(registry.placements)-1; index >= 0; index -= 1 {
		placement := registry.placements[index]
		if placement.image_id != resource_id || placement_id != 0 && placement.protocol_id != placement_id do continue
		remove_placement_at(registry, index)
		affected = true
	}
	resource = find_image(registry, resource_id)
	if delete_data && affected && resource != nil && resource.placement_count == 0 do return delete_image(registry, resource_id)
	return true
}

delete_visible_placements :: proc(registry: ^Registry, screen: Screen, top, bottom: int, delete_data: bool) {
	for resource_index := len(registry.resources)-1; resource_index >= 0; resource_index -= 1 {
		resource_id := registry.resources[resource_index].id
		affected := false
		for placement_index := len(registry.placements)-1; placement_index >= 0; placement_index -= 1 {
			placement := registry.placements[placement_index]
			if placement.image_id == resource_id && placement.screen == screen &&
			   placement.row <= bottom && placement.row+placement.rows > top {
				remove_placement_at(registry, placement_index)
				affected = true
			}
		}
		if delete_data && affected && registry.resources[resource_index].placement_count == 0 {
			delete_resource_at(registry, resource_index)
		}
	}
}

clear_screen :: proc(registry: ^Registry, screen: Screen) {
	for index := len(registry.placements)-1; index >= 0; index -= 1 {
		if registry.placements[index].screen == screen do remove_placement_at(registry, index)
	}
}

registry_clear :: proc(registry: ^Registry) {
	had_placements := len(registry.placements) > 0
	for &resource in registry.resources do delete(resource.pixels)
	clear(&registry.resources)
	clear(&registry.placements)
	registry.decoded_bytes = 0
	if had_placements do registry.generation += 1
}

screen_has_placements :: proc(registry: ^Registry, screen: Screen) -> bool {
	for placement in registry.placements {
		if placement.screen == screen do return true
	}
	return false
}

scroll_up :: proc(
	registry: ^Registry,
	screen: Screen,
	top, bottom, history_rows: int,
	full_viewport, retain_history: bool,
) {
	changed := false
	for index := len(registry.placements)-1; index >= 0; index -= 1 {
		placement := &registry.placements[index]
		entirely_inside := placement.row >= top && placement.row+placement.rows-1 <= bottom
		in_full_viewport := full_viewport && placement.row <= bottom && placement.row+placement.rows > top
		in_history := retain_history && placement.row < top
		if placement.screen != screen || (!entirely_inside && !in_full_viewport && !in_history) do continue
		placement.row -= 1
		changed = true
		if retain_history {
			if placement.row+placement.rows <= -max(0, history_rows) do remove_placement_at(registry, index)
		} else if placement.row < top {
			clip_placement_top(placement, top-placement.row)
			if placement.rows <= 0 do remove_placement_at(registry, index)
		}
	}
	if changed do registry.generation += 1
}

scroll_down :: proc(registry: ^Registry, screen: Screen, top, bottom: int, full_viewport: bool) {
	changed := false
	for index := len(registry.placements)-1; index >= 0; index -= 1 {
		placement := &registry.placements[index]
		entirely_inside := placement.row >= top && placement.row+placement.rows-1 <= bottom
		in_full_viewport := full_viewport && placement.row <= bottom && placement.row+placement.rows > top
		if placement.screen != screen || (!entirely_inside && !in_full_viewport) do continue
		placement.row += 1
		changed = true
		overflow := placement.row+placement.rows-1-bottom
		if overflow > 0 {
			clip_placement_bottom(placement, overflow)
			if placement.rows <= 0 do remove_placement_at(registry, index)
		}
	}
	if changed do registry.generation += 1
}

clip_placement_top :: proc(placement: ^Placement, cells: int) {
	clipped := min(max(0, cells), placement.rows)
	if clipped == 0 do return
	pixels := (placement.source_height*clipped+placement.rows-1)/placement.rows
	destination_pixels := 0
	if placement.pixel_height > 0 do destination_pixels = (placement.pixel_height*clipped+placement.rows-1)/placement.rows
	placement.source_y += pixels
	placement.source_height = max(0, placement.source_height-pixels)
	placement.pixel_height = max(0, placement.pixel_height-destination_pixels)
	placement.pixel_offset_y = 0
	placement.row += clipped
	placement.rows -= clipped
}

clip_placement_bottom :: proc(placement: ^Placement, cells: int) {
	clipped := min(max(0, cells), placement.rows)
	if clipped == 0 do return
	pixels := (placement.source_height*clipped+placement.rows-1)/placement.rows
	destination_pixels := 0
	if placement.pixel_height > 0 do destination_pixels = (placement.pixel_height*clipped+placement.rows-1)/placement.rows
	placement.source_height = max(0, placement.source_height-pixels)
	placement.pixel_height = max(0, placement.pixel_height-destination_pixels)
	placement.rows -= clipped
}

clear_visible :: proc(registry: ^Registry, screen: Screen, top, bottom: int) {
	for index := len(registry.placements)-1; index >= 0; index -= 1 {
		placement := registry.placements[index]
		if placement.screen == screen && placement.row <= bottom && placement.row+placement.rows > top {
			remove_placement_at(registry, index)
		}
	}
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
	registry.generation += 1
}

delete_resource_at :: proc(registry: ^Registry, index: int) {
	id := registry.resources[index].id
	had_placements := false
	for placement_index := len(registry.placements)-1; placement_index >= 0; placement_index -= 1 {
		if registry.placements[placement_index].image_id == id {
			ordered_remove(&registry.placements, placement_index)
			had_placements = true
		}
	}
	registry.decoded_bytes -= len(registry.resources[index].pixels)
	delete(registry.resources[index].pixels)
	ordered_remove(&registry.resources, index)
	if had_placements do registry.generation += 1
}
