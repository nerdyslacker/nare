package graphics

TIFF_Error :: enum {
	None,
	Invalid_Data,
	Unsupported,
	Limit,
}

TIFF_Byte_Order :: enum { Little, Big }

TIFF_Field :: struct {
	type: u16,
	count: u32,
	offset: int,
}

decode_tiff :: proc(data: []byte, limits: ^Limits = nil) -> (Decoded_Image, TIFF_Error) {
	if len(data) < 8 || len(data) > MAX_IMAGE_BYTES do return {}, .Invalid_Data
	order: TIFF_Byte_Order
	if data[0] == 'I' && data[1] == 'I' {
		order = .Little
	} else if data[0] == 'M' && data[1] == 'M' {
		order = .Big
	} else {
		return {}, .Invalid_Data
	}
	magic, magic_ok := tiff_u16(data, 2, order)
	if !magic_ok || magic != 42 do return {}, .Invalid_Data
	ifd_offset_u32, offset_ok := tiff_u32(data, 4, order)
	if !offset_ok || u64(ifd_offset_u32) > u64(max(int)) do return {}, .Invalid_Data
	ifd_offset := int(ifd_offset_u32)
	entry_count, count_ok := tiff_u16(data, ifd_offset, order)
	if !count_ok || entry_count == 0 || entry_count > 256 do return {}, .Invalid_Data
	if ifd_offset > len(data)-2 || int(entry_count) > (len(data)-ifd_offset-2)/12 do return {}, .Invalid_Data

	width, height, compression, photometric := 0, 0, 1, -1
	samples, rows_per_strip, planar, orientation := 1, 0, 1, 1
	bits, strip_offsets, strip_counts: [dynamic]int
	defer {
		delete(bits)
		delete(strip_offsets)
		delete(strip_counts)
	}
	for index in 0..<int(entry_count) {
		entry_offset := ifd_offset+2+index*12
		tag, _ := tiff_u16(data, entry_offset, order)
		field, field_ok := tiff_field(data, entry_offset, order)
		if !field_ok do return {}, .Invalid_Data
		switch tag {
		case 256: width = tiff_field_scalar(data, field, order)
		case 257: height = tiff_field_scalar(data, field, order)
		case 258:
			if !tiff_field_values(data, field, order, &bits) do return {}, .Invalid_Data
		case 259: compression = tiff_field_scalar(data, field, order)
		case 262: photometric = tiff_field_scalar(data, field, order)
		case 273:
			if !tiff_field_values(data, field, order, &strip_offsets) do return {}, .Invalid_Data
		case 274: orientation = tiff_field_scalar(data, field, order)
		case 277: samples = tiff_field_scalar(data, field, order)
		case 278: rows_per_strip = tiff_field_scalar(data, field, order)
		case 279:
			if !tiff_field_values(data, field, order, &strip_counts) do return {}, .Invalid_Data
		case 284: planar = tiff_field_scalar(data, field, order)
		case:
		}
	}
	if width <= 0 || height <= 0 || (samples != 3 && samples != 4) || len(bits) != samples ||
	   compression != 1 || photometric != 2 || planar != 1 || orientation != 1 ||
	   len(strip_offsets) == 0 || len(strip_offsets) != len(strip_counts) {
		return {}, .Unsupported
	}
	for value in bits do if value != 8 do return {}, .Unsupported
	if rows_per_strip <= 0 do rows_per_strip = height
	stride, byte_count, layout_error := image_layout_with_limits(width, height, .RGBA8, limits)
	if layout_error != .None do return {}, .Limit
	pixels := make([]byte, byte_count)
	row := 0
	for strip_index in 0..<len(strip_offsets) {
		strip_rows := min(rows_per_strip, height-row)
		if strip_rows <= 0 {
			delete(pixels)
			return {}, .Invalid_Data
		}
		source_bytes := strip_rows*width*samples
		offset, count := strip_offsets[strip_index], strip_counts[strip_index]
		if offset < 0 || count < source_bytes || offset > len(data)-source_bytes {
			delete(pixels)
			return {}, .Invalid_Data
		}
		for strip_row in 0..<strip_rows {
			for column in 0..<width {
				source := offset+(strip_row*width+column)*samples
				destination := (row+strip_row)*stride+column*4
				copy(pixels[destination:destination+3], data[source:source+3])
				pixels[destination+3] = data[source+3] if samples == 4 else 255
			}
		}
		row += strip_rows
	}
	if row != height {
		delete(pixels)
		return {}, .Invalid_Data
	}
	return {width = width, height = height, stride = stride, format = .RGBA8, pixels = pixels}, .None
}

tiff_field :: proc(data: []byte, entry_offset: int, order: TIFF_Byte_Order) -> (TIFF_Field, bool) {
	type, type_ok := tiff_u16(data, entry_offset+2, order)
	count, count_ok := tiff_u32(data, entry_offset+4, order)
	if !type_ok || !count_ok || count == 0 || count > MAX_IMAGE_DIMENSION do return {}, false
	element_size := 2 if type == 3 else 4 if type == 4 else 0
	if element_size == 0 || u64(count) > u64(max(int))/u64(element_size) do return {}, false
	byte_count := int(count)*element_size
	offset := entry_offset+8
	if byte_count > 4 {
		value_offset, ok := tiff_u32(data, offset, order)
		if !ok || u64(value_offset) > u64(max(int)) do return {}, false
		offset = int(value_offset)
	}
	if offset < 0 || offset > len(data)-byte_count do return {}, false
	return TIFF_Field{type = type, count = count, offset = offset}, true
}

tiff_field_scalar :: proc(data: []byte, field: TIFF_Field, order: TIFF_Byte_Order) -> int {
	if field.count != 1 do return -1
	if field.type == 3 {
		value, ok := tiff_u16(data, field.offset, order)
		return int(value) if ok else -1
	}
	value, ok := tiff_u32(data, field.offset, order)
	if !ok || u64(value) > u64(max(int)) do return -1
	return int(value)
}

tiff_field_values :: proc(data: []byte, field: TIFF_Field, order: TIFF_Byte_Order, output: ^[dynamic]int) -> bool {
	if len(output^) != 0 do return false
	for index in 0..<int(field.count) {
		value := -1
		if field.type == 3 {
			parsed, ok := tiff_u16(data, field.offset+index*2, order)
			if ok do value = int(parsed)
		} else {
			parsed, ok := tiff_u32(data, field.offset+index*4, order)
			if ok && u64(parsed) <= u64(max(int)) do value = int(parsed)
		}
		if value < 0 do return false
		append(output, value)
	}
	return true
}

tiff_u16 :: proc(data: []byte, offset: int, order: TIFF_Byte_Order) -> (u16, bool) {
	if offset < 0 || offset > len(data)-2 do return 0, false
	if order == .Little do return u16(data[offset])|u16(data[offset+1])<<8, true
	return u16(data[offset])<<8|u16(data[offset+1]), true
}

tiff_u32 :: proc(data: []byte, offset: int, order: TIFF_Byte_Order) -> (u32, bool) {
	if offset < 0 || offset > len(data)-4 do return 0, false
	if order == .Little {
		return u32(data[offset])|u32(data[offset+1])<<8|u32(data[offset+2])<<16|u32(data[offset+3])<<24, true
	}
	return u32(data[offset])<<24|u32(data[offset+1])<<16|u32(data[offset+2])<<8|u32(data[offset+3]), true
}
