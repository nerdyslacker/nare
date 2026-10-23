package graphics

import base64 "core:encoding/base64"
import "core:strconv"
import "core:strings"
import zlib "vendor:zlib"

MAX_KITTY_COMPRESSED_BYTES :: MAX_IMAGE_BYTES+(MAX_IMAGE_BYTES>>12)+(MAX_IMAGE_BYTES>>14)+(MAX_IMAGE_BYTES>>25)+13
MAX_KITTY_ENCODED_BYTES :: ((MAX_KITTY_COMPRESSED_BYTES+2)/3)*4
MAX_KITTY_CHUNKS :: 32_768
MAX_KITTY_CHUNK_BYTES :: 4096

Kitty_Action :: enum {
	Transmit,
	Transmit_And_Display,
	Query,
	Display,
	Delete,
	Unsupported,
}

Kitty_Error :: enum {
	None,
	Malformed,
	Unsupported,
	Invalid_Data,
	Image_Limit,
}

Kitty_Command :: struct {
	action: Kitty_Action,
	format: Pixel_Format,
	width, height: int,
	image_id: u32,
	placement_id: u32,
	columns, rows: int,
	source_x, source_y: int,
	source_width, source_height: int,
	z: i32,
	no_cursor_move: bool,
	png: bool,
	compressed: bool,
	more: bool,
	quiet: int,
}

Kitty_Transfer :: struct {
	active: bool,
	command: Kitty_Command,
	encoded: [dynamic]byte,
	encoded_limit: int,
	chunk_count: int,
}

Kitty_Frame :: struct {
	command: Kitty_Command,
	payload: []byte,
	more_present: bool,
	quiet_present: bool,
	continuation_controls: bool,
}

kitty_transfer_destroy :: proc(transfer: ^Kitty_Transfer) {
	delete(transfer.encoded)
	transfer^ = {}
}

kitty_transfer_reset :: proc(transfer: ^Kitty_Transfer) {
	delete(transfer.encoded)
	transfer.encoded = nil
	transfer.active = false
	transfer.command = {}
	transfer.encoded_limit = 0
	transfer.chunk_count = 0
}

kitty_receive_direct :: proc(
	transfer: ^Kitty_Transfer,
	data: []byte,
) -> (command: Kitty_Command, image: Decoded_Image, complete: bool, err: Kitty_Error) {
	frame, frame_error := kitty_parse_direct_frame(data)
	if frame_error != .None {
		command = frame.command
		if transfer.active {
			command = transfer.command
			kitty_transfer_reset(transfer)
		}
		return command, {}, true, frame_error
	}

	if transfer.active {
		command = transfer.command
		if !frame.more_present || !frame.continuation_controls {
			kitty_transfer_reset(transfer)
			return command, {}, true, .Malformed
		}
		if frame.quiet_present {
			command.quiet = frame.command.quiet
			transfer.command.quiet = command.quiet
		}
		if chunk_error := kitty_append_chunk(transfer, frame.payload, frame.command.more); chunk_error != .None {
			kitty_transfer_reset(transfer)
			return command, {}, true, chunk_error
		}
		if frame.command.more do return command, {}, false, .None
		command.more = false
		image, err = kitty_decode_payload(command, transfer.encoded[:])
		kitty_transfer_reset(transfer)
		return command, image, true, err
	}

	command = frame.command
	encoded_limit, limit_error := kitty_encoded_limit(command)
	if limit_error != .None do return command, {}, true, limit_error
	if command.more {
		if command.action == .Query do return command, {}, true, .Unsupported
		transfer.active = true
		transfer.command = command
		transfer.encoded_limit = encoded_limit
		if chunk_error := kitty_append_chunk(transfer, frame.payload, true); chunk_error != .None {
			kitty_transfer_reset(transfer)
			return command, {}, true, chunk_error
		}
		return command, {}, false, .None
	}
	if frame.more_present && len(frame.payload) > MAX_KITTY_CHUNK_BYTES {
		return command, {}, true, .Image_Limit
	}
	image, err = kitty_decode_payload(command, frame.payload)
	return command, image, true, err
}

kitty_decode_direct :: proc(data: []byte) -> (Kitty_Command, Decoded_Image, Kitty_Error) {
	transfer: Kitty_Transfer
	defer kitty_transfer_destroy(&transfer)
	command, image, complete, err := kitty_receive_direct(&transfer, data)
	if !complete do return command, {}, .Unsupported
	return command, image, err
}

kitty_parse_direct_frame :: proc(data: []byte) -> (Kitty_Frame, Kitty_Error) {
	command := Kitty_Command{action = .Transmit, format = .RGBA8}
	frame := Kitty_Frame{command = command}
	if len(data) < 3 || data[0] != 'G' do return frame, .Malformed
	separator := strings.index_byte(string(data), ';')
	if separator < 1 do return frame, .Malformed
	control := string(data[1:separator])
	payload := data[separator+1:]
	seen_action, seen_format, seen_width, seen_height := false, false, false, false
	seen_id, seen_placement, seen_columns, seen_rows := false, false, false, false
	seen_medium, seen_compression, seen_more, seen_quiet := false, false, false, false
	seen_source_x, seen_source_y, seen_source_width, seen_source_height := false, false, false, false
	seen_z, seen_cursor_policy := false, false
	unsupported := false
	key_count := 0
	remaining := control
	for len(remaining) > 0 {
		part := remaining
		if comma := strings.index_byte(remaining, ','); comma >= 0 {
			part = remaining[:comma]
			remaining = remaining[comma+1:]
		} else {
			remaining = ""
		}
		if len(part) < 3 || part[1] != '=' do return Kitty_Frame{command = command}, .Malformed
		key_count += 1
		key, value := part[0], part[2:]
		if value == "" do return Kitty_Frame{command = command}, .Malformed
		switch key {
		case 'a':
			if seen_action || len(value) != 1 do return Kitty_Frame{command = command}, .Malformed
			seen_action = true
			switch value[0] {
			case 't': command.action = .Transmit
			case 'T': command.action = .Transmit_And_Display
			case 'q': command.action = .Query
			case 'p': command.action = .Display
			case 'd': command.action = .Delete
			case: command.action = .Unsupported
			}
		case 'f':
			if seen_format do return Kitty_Frame{command = command}, .Malformed
			seen_format = true
			format, ok := parse_kitty_uint(value)
			if !ok do return Kitty_Frame{command = command}, .Malformed
			switch format {
			case 24: command.format = .RGB8
			case 32: command.format = .RGBA8
			case 100:
				command.format = .RGBA8
				command.png = true
			case: unsupported = true
			}
		case 's':
			if seen_width do return Kitty_Frame{command = command}, .Malformed
			seen_width = true
			width, ok := parse_kitty_uint(value)
			if !ok || width > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.width = int(width)
		case 'v':
			if seen_height do return Kitty_Frame{command = command}, .Malformed
			seen_height = true
			height, ok := parse_kitty_uint(value)
			if !ok || height > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.height = int(height)
		case 'i':
			if seen_id do return Kitty_Frame{command = command}, .Malformed
			seen_id = true
			id, ok := parse_kitty_uint(value)
			if !ok || id > u64(max(u32)) do return Kitty_Frame{command = command}, .Malformed
			command.image_id = u32(id)
		case 'p':
			if seen_placement do return Kitty_Frame{command = command}, .Malformed
			seen_placement = true
			id, ok := parse_kitty_uint(value)
			if !ok || id > u64(max(u32)) do return Kitty_Frame{command = command}, .Malformed
			command.placement_id = u32(id)
		case 'c':
			if seen_columns do return Kitty_Frame{command = command}, .Malformed
			seen_columns = true
			columns, ok := parse_kitty_uint(value)
			if !ok || columns > u64(MAX_PLACEMENT_CELLS) do return Kitty_Frame{command = command}, .Malformed
			command.columns = int(columns)
		case 'r':
			if seen_rows do return Kitty_Frame{command = command}, .Malformed
			seen_rows = true
			rows, ok := parse_kitty_uint(value)
			if !ok || rows > u64(MAX_PLACEMENT_CELLS) do return Kitty_Frame{command = command}, .Malformed
			command.rows = int(rows)
		case 'x':
			if seen_source_x do return Kitty_Frame{command = command}, .Malformed
			seen_source_x = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.source_x = int(parsed)
		case 'y':
			if seen_source_y do return Kitty_Frame{command = command}, .Malformed
			seen_source_y = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.source_y = int(parsed)
		case 'w':
			if seen_source_width do return Kitty_Frame{command = command}, .Malformed
			seen_source_width = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.source_width = int(parsed)
		case 'h':
			if seen_source_height do return Kitty_Frame{command = command}, .Malformed
			seen_source_height = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.source_height = int(parsed)
		case 'z':
			if seen_z do return Kitty_Frame{command = command}, .Malformed
			seen_z = true
			parsed_bytes := 0
			parsed, ok := strconv.parse_int(value, 10, &parsed_bytes)
			if !ok || parsed_bytes != len(value) || parsed < int(min(i32)) || parsed > int(max(i32)) {
				return Kitty_Frame{command = command}, .Malformed
			}
			command.z = i32(parsed)
		case 'C':
			if seen_cursor_policy do return Kitty_Frame{command = command}, .Malformed
			seen_cursor_policy = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > 1 do return Kitty_Frame{command = command}, .Malformed
			command.no_cursor_move = parsed == 1
		case 't':
			if seen_medium do return Kitty_Frame{command = command}, .Malformed
			seen_medium = true
			if value != "d" do unsupported = true
		case 'm':
			if seen_more do return Kitty_Frame{command = command}, .Malformed
			seen_more = true
			more, ok := parse_kitty_uint(value)
			if !ok || more > 1 do return Kitty_Frame{command = command}, .Malformed
			command.more = more == 1
		case 'q':
			if seen_quiet do return Kitty_Frame{command = command}, .Malformed
			seen_quiet = true
			quiet, ok := parse_kitty_uint(value)
			if !ok || quiet > 2 do return Kitty_Frame{command = command}, .Malformed
			command.quiet = int(quiet)
		case 'o':
			if seen_compression do return Kitty_Frame{command = command}, .Malformed
			seen_compression = true
			if value == "z" {
				command.compressed = true
			} else {
				unsupported = true
			}
		case: unsupported = true
		}
	}
	if unsupported || command.action != .Transmit && command.action != .Transmit_And_Display && command.action != .Query {
		return Kitty_Frame{command = command}, .Unsupported
	}
	frame.command = command
	frame.payload = payload
	frame.more_present = seen_more
	frame.quiet_present = seen_quiet
	frame.continuation_controls = seen_more && key_count == 1+int(seen_quiet)
	return frame, .None
}

kitty_encoded_limit :: proc(command: Kitty_Command) -> (int, Kitty_Error) {
	if command.png {
		if command.compressed do return 0, .Unsupported
		return ((MAX_PNG_BYTES+2)/3)*4, .None
	}
	_, byte_count, layout_error := image_layout(command.width, command.height, command.format)
	if layout_error == .Invalid_Dimensions do return 0, .Malformed
	if layout_error != .None do return 0, .Image_Limit
	input_limit := byte_count
	if command.compressed do input_limit = kitty_compressed_bound(byte_count)
	encoded_limit := ((input_limit+2)/3)*4
	if encoded_limit > MAX_KITTY_ENCODED_BYTES do return 0, .Image_Limit
	return encoded_limit, .None
}

kitty_append_chunk :: proc(transfer: ^Kitty_Transfer, payload: []byte, more: bool) -> Kitty_Error {
	if len(payload) > MAX_KITTY_CHUNK_BYTES ||
	   transfer.chunk_count >= MAX_KITTY_CHUNKS ||
	   len(payload) > transfer.encoded_limit-len(transfer.encoded) {
		return .Image_Limit
	}
	if more && (len(payload) == 0 || len(payload)%4 != 0) do return .Invalid_Data
	append(&transfer.encoded, ..payload)
	transfer.chunk_count += 1
	return .None
}

kitty_decode_payload :: proc(command: Kitty_Command, payload: []byte) -> (Decoded_Image, Kitty_Error) {
	encoded_limit, limit_error := kitty_encoded_limit(command)
	if limit_error != .None do return {}, limit_error
	if len(payload) == 0 || len(payload) > encoded_limit do return {}, .Image_Limit
	decoded, decode_error := base64.decode(string(payload), options = {.Strict})
	if decode_error != nil do return {}, .Invalid_Data
	if command.png {
		image, png_error := decode_png(decoded)
		delete(decoded)
		switch png_error {
		case .None: return image, .None
		case .Limit: return {}, .Image_Limit
		case .Unsupported: return {}, .Unsupported
		case .Invalid_Data: return {}, .Invalid_Data
		}
	}
	stride, byte_count, _, layout_error := kitty_payload_layout(command)
	if layout_error != .None {
		delete(decoded)
		return {}, layout_error
	}
	pixels := decoded
	if command.compressed {
		pixels = make([]byte, byte_count)
		destination_length := zlib.uLongf(byte_count)
		compressed_bytes := len(decoded)
		source_length := zlib.uLong(compressed_bytes)
		status := zlib.uncompress2(
			raw_data(pixels),
			&destination_length,
			raw_data(decoded),
			&source_length,
		)
		delete(decoded)
		if status != zlib.OK || int(destination_length) != byte_count || int(source_length) != compressed_bytes {
			delete(pixels)
			return {}, .Invalid_Data
		}
	}
	image := Decoded_Image{
		width = command.width,
		height = command.height,
		stride = stride,
		format = command.format,
		pixels = pixels,
	}
	_, image_error := validate_image(&image)
	if image_error != .None {
		decoded_image_destroy(&image)
		if image_error == .Invalid_Pixel_Data do return {}, .Invalid_Data
		return {}, .Image_Limit
	}
	return image, .None
}

kitty_payload_layout :: proc(command: Kitty_Command) -> (stride, byte_count, encoded_limit: int, err: Kitty_Error) {
	layout_error: Error
	stride, byte_count, layout_error = image_layout(command.width, command.height, command.format)
	if layout_error == .Invalid_Dimensions do return 0, 0, 0, .Malformed
	if layout_error != .None do return 0, 0, 0, .Image_Limit
	input_limit := byte_count
	if command.compressed do input_limit = kitty_compressed_bound(byte_count)
	encoded_limit = ((input_limit+2)/3)*4
	if encoded_limit > MAX_KITTY_ENCODED_BYTES do return 0, 0, 0, .Image_Limit
	return stride, byte_count, encoded_limit, .None
}

kitty_compressed_bound :: proc(byte_count: int) -> int {
	return byte_count+(byte_count>>12)+(byte_count>>14)+(byte_count>>25)+13
}

parse_kitty_uint :: proc(value: string) -> (u64, bool) {
	parsed_bytes := 0
	result, ok := strconv.parse_u64(value, 10, &parsed_bytes)
	return result, ok && parsed_bytes == len(value)
}
