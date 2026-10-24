package graphics

import "core:c"
import stb "vendor:stb/image"

JPEG_Error :: enum {
	None,
	Invalid_Data,
	Limit,
}

decode_jpeg :: proc(data: []byte, limits: ^Limits = nil) -> (Decoded_Image, JPEG_Error) {
	if len(data) < 4 || len(data) > MAX_IMAGE_BYTES || data[0] != 0xff || data[1] != 0xd8 do return {}, .Invalid_Data
	width, height, channels: c.int
	if stb.info_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels) == 0 do return {}, .Invalid_Data
	stride, byte_count, layout_error := image_layout_with_limits(int(width), int(height), .RGBA8, limits)
	if layout_error != .None do return {}, .Limit
	decoded_width, decoded_height, decoded_channels: c.int
	decoded := stb.load_from_memory(raw_data(data), c.int(len(data)), &decoded_width, &decoded_height, &decoded_channels, 4)
	if decoded == nil do return {}, .Invalid_Data
	defer stb.image_free(decoded)
	if decoded_width != width || decoded_height != height do return {}, .Invalid_Data
	pixels := make([]byte, byte_count)
	copy(pixels, decoded[:byte_count])
	return Decoded_Image{
		width = int(width),
		height = int(height),
		stride = stride,
		format = .RGBA8,
		pixels = pixels,
	}, .None
}
