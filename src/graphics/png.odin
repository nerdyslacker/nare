package graphics

import "core:hash"
import zlib "vendor:zlib"

MAX_PNG_BYTES :: MAX_IMAGE_BYTES
PNG_SIGNATURE := [8]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}

PNG_Error :: enum {
	None,
	Invalid_Data,
	Limit,
	Unsupported,
}

decode_png :: proc(data: []byte) -> (Decoded_Image, PNG_Error) {
	if len(data) < 33 || len(data) > MAX_PNG_BYTES || !png_signature_valid(data) do return {}, .Invalid_Data
	offset := 8
	width, height, channels, color_type := 0, 0, 0, byte(0)
	seen_header, seen_palette, seen_transparency, seen_data, ended_data, seen_end := false, false, false, false, false, false
	palette: [256][3]byte
	palette_alpha: [256]byte
	for &alpha in palette_alpha do alpha = 255
	palette_count := 0
	transparent_gray: i32 = -1
	transparent_red, transparent_green, transparent_blue: i32 = -1, -1, -1
	idat: [dynamic]byte
	defer delete(idat)

	for offset < len(data) {
		if len(data)-offset < 12 do return {}, .Invalid_Data
		chunk_length_u32 := png_u32(data[offset:])
		if chunk_length_u32 > u32(MAX_PNG_BYTES) do return {}, .Limit
		chunk_length := int(chunk_length_u32)
		if chunk_length > len(data)-offset-12 do return {}, .Invalid_Data
		chunk_type := data[offset+4:offset+8]
		chunk_data := data[offset+8:offset+8+chunk_length]
		stored_crc := png_u32(data[offset+8+chunk_length:])
		computed_crc := hash.crc32(chunk_type)
		computed_crc = hash.crc32(chunk_data, computed_crc)
		if stored_crc != computed_crc do return {}, .Invalid_Data
		offset += chunk_length+12
		if !seen_header && !png_chunk_is(chunk_type, "IHDR") do return {}, .Invalid_Data

		if png_chunk_is(chunk_type, "IHDR") {
			if seen_header || seen_data || chunk_length != 13 do return {}, .Invalid_Data
			seen_header = true
			width_u32, height_u32 := png_u32(chunk_data), png_u32(chunk_data[4:])
			if width_u32 == 0 || height_u32 == 0 ||
			   width_u32 > u32(MAX_IMAGE_DIMENSION) || height_u32 > u32(MAX_IMAGE_DIMENSION) ||
			   u64(width_u32)*u64(height_u32) > u64(MAX_IMAGE_PIXELS) {
				return {}, .Limit
			}
			if chunk_data[8] != 8 || chunk_data[10] != 0 || chunk_data[11] != 0 do return {}, .Unsupported
			if chunk_data[12] != 0 do return {}, .Unsupported
			color_type = chunk_data[9]
			switch color_type {
			case 0: channels = 1
			case 2: channels = 3
			case 3: channels = 1
			case 4: channels = 2
			case 6: channels = 4
			case: return {}, .Unsupported
			}
			width, height = int(width_u32), int(height_u32)
		} else if png_chunk_is(chunk_type, "PLTE") {
			if !seen_header || seen_palette || seen_data || color_type == 0 || color_type == 4 ||
			   chunk_length == 0 || chunk_length > 768 || chunk_length%3 != 0 {
				return {}, .Invalid_Data
			}
			seen_palette = true
			palette_count = chunk_length/3
			for index in 0..<palette_count {
				copy(palette[index][:], chunk_data[index*3:index*3+3])
			}
		} else if png_chunk_is(chunk_type, "tRNS") {
			if !seen_header || seen_transparency || seen_data do return {}, .Invalid_Data
			seen_transparency = true
			switch color_type {
			case 0:
				if chunk_length != 2 do return {}, .Invalid_Data
				transparent_gray = i32(png_u16(chunk_data))
				if transparent_gray > 255 do return {}, .Invalid_Data
			case 2:
				if chunk_length != 6 do return {}, .Invalid_Data
				transparent_red = i32(png_u16(chunk_data))
				transparent_green = i32(png_u16(chunk_data[2:]))
				transparent_blue = i32(png_u16(chunk_data[4:]))
				if transparent_red > 255 || transparent_green > 255 || transparent_blue > 255 do return {}, .Invalid_Data
			case 3:
				if !seen_palette || chunk_length > palette_count do return {}, .Invalid_Data
				copy(palette_alpha[:chunk_length], chunk_data)
			case: return {}, .Invalid_Data
			}
		} else if png_chunk_is(chunk_type, "IDAT") {
			if !seen_header || ended_data do return {}, .Invalid_Data
			if len(idat) > MAX_PNG_BYTES-chunk_length do return {}, .Limit
			append(&idat, ..chunk_data)
			seen_data = true
		} else if png_chunk_is(chunk_type, "IEND") {
			if !seen_header || !seen_data || seen_end || chunk_length != 0 do return {}, .Invalid_Data
			seen_end = true
			break
		} else {
			if seen_data do ended_data = true
			if chunk_type[0]&0x20 == 0 do return {}, .Unsupported
		}
	}
	if !seen_end || offset != len(data) || color_type == 3 && !seen_palette do return {}, .Invalid_Data

	row_bytes := width*channels
	if row_bytes > MAX_IMAGE_BYTES/height do return {}, .Limit
	inflated_bytes := (row_bytes+1)*height
	if inflated_bytes > MAX_IMAGE_BYTES+MAX_IMAGE_DIMENSION do return {}, .Limit
	scanlines := make([]byte, inflated_bytes)
	defer delete(scanlines)
	destination_length := zlib.uLongf(inflated_bytes)
	source_length := zlib.uLong(len(idat))
	status := zlib.uncompress2(raw_data(scanlines), &destination_length, raw_data(idat), &source_length)
	if status != zlib.OK || int(destination_length) != inflated_bytes || int(source_length) != len(idat) {
		return {}, .Invalid_Data
	}
	if !png_unfilter(scanlines, width, height, channels) do return {}, .Invalid_Data

	stride, byte_count, layout_error := image_layout(width, height, .RGBA8)
	if layout_error != .None do return {}, .Limit
	pixels := make([]byte, byte_count)
	for row in 0..<height {
		source := scanlines[row*(row_bytes+1)+1:][:row_bytes]
		for column in 0..<width {
			source_offset := column*channels
			destination := pixels[(row*width+column)*4:][:4]
			switch color_type {
			case 0:
				gray := source[source_offset]
				destination[0], destination[1], destination[2] = gray, gray, gray
				destination[3] = 0 if transparent_gray == i32(gray) else 255
			case 2:
				red, green, blue := source[source_offset], source[source_offset+1], source[source_offset+2]
				destination[0], destination[1], destination[2] = red, green, blue
				destination[3] = 0 if transparent_red == i32(red) && transparent_green == i32(green) && transparent_blue == i32(blue) else 255
			case 3:
				index := int(source[source_offset])
				if index >= palette_count {
					delete(pixels)
					return {}, .Invalid_Data
				}
				copy(destination[:3], palette[index][:])
				destination[3] = palette_alpha[index]
			case 4:
				gray := source[source_offset]
				destination[0], destination[1], destination[2], destination[3] = gray, gray, gray, source[source_offset+1]
			case 6:
				copy(destination, source[source_offset:source_offset+4])
			}
		}
	}
	return Decoded_Image{width = width, height = height, stride = stride, format = .RGBA8, pixels = pixels}, .None
}

png_unfilter :: proc(scanlines: []byte, width, height, channels: int) -> bool {
	row_bytes := width*channels
	row_span := row_bytes+1
	for row in 0..<height {
		filter := scanlines[row*row_span]
		current := scanlines[row*row_span+1:][:row_bytes]
		previous: []byte
		if row > 0 do previous = scanlines[(row-1)*row_span+1:][:row_bytes]
		for index in 0..<row_bytes {
			left: byte
			if index >= channels do left = current[index-channels]
			up: byte
			if row > 0 do up = previous[index]
			upper_left: byte
			if row > 0 && index >= channels do upper_left = previous[index-channels]
			switch filter {
			case 0:
			case 1: current[index] += left
			case 2: current[index] += up
			case 3: current[index] += byte((u16(left)+u16(up))/2)
			case 4: current[index] += png_paeth(left, up, upper_left)
			case: return false
			}
		}
	}
	return true
}

png_paeth :: proc(left, up, upper_left: byte) -> byte {
	predictor := int(left)+int(up)-int(upper_left)
	left_distance := abs(predictor-int(left))
	up_distance := abs(predictor-int(up))
	upper_left_distance := abs(predictor-int(upper_left))
	if left_distance <= up_distance && left_distance <= upper_left_distance do return left
	if up_distance <= upper_left_distance do return up
	return upper_left
}

png_chunk_is :: proc(chunk_type: []byte, expected: string) -> bool {
	return len(chunk_type) == 4 && len(expected) == 4 &&
	       chunk_type[0] == expected[0] && chunk_type[1] == expected[1] &&
	       chunk_type[2] == expected[2] && chunk_type[3] == expected[3]
}

png_signature_valid :: proc(data: []byte) -> bool {
	for value, index in PNG_SIGNATURE {
		if data[index] != value do return false
	}
	return true
}

png_u32 :: proc(data: []byte) -> u32 {
	return u32(data[0])<<24 | u32(data[1])<<16 | u32(data[2])<<8 | u32(data[3])
}

png_u16 :: proc(data: []byte) -> u16 {
	return u16(data[0])<<8 | u16(data[1])
}
