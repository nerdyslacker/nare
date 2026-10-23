package graphics

import base64 "core:encoding/base64"
import "core:strconv"
import "core:strings"

MAX_KITTY_ENCODED_BYTES :: ((MAX_IMAGE_BYTES+2)/3)*4

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
	more: bool,
	quiet: int,
}

kitty_decode_direct :: proc(data: []byte) -> (Kitty_Command, Decoded_Image, Kitty_Error) {
	command := Kitty_Command{action = .Transmit, format = .RGBA8}
	if len(data) < 3 || data[0] != 'G' do return command, {}, .Malformed
	separator := strings.index_byte(string(data), ';')
	if separator < 1 do return command, {}, .Malformed
	control := string(data[1:separator])
	payload := data[separator+1:]
	seen_action, seen_format, seen_width, seen_height := false, false, false, false
	seen_id, seen_placement, seen_columns, seen_rows := false, false, false, false
	seen_medium, seen_more, seen_quiet := false, false, false
	seen_source_x, seen_source_y, seen_source_width, seen_source_height := false, false, false, false
	seen_z, seen_cursor_policy := false, false
	unsupported := false
	remaining := control
	for len(remaining) > 0 {
		part := remaining
		if comma := strings.index_byte(remaining, ','); comma >= 0 {
			part = remaining[:comma]
			remaining = remaining[comma+1:]
		} else {
			remaining = ""
		}
		if len(part) < 3 || part[1] != '=' do return command, {}, .Malformed
		key, value := part[0], part[2:]
		if value == "" do return command, {}, .Malformed
		switch key {
		case 'a':
			if seen_action || len(value) != 1 do return command, {}, .Malformed
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
			if seen_format do return command, {}, .Malformed
			seen_format = true
			format, ok := parse_kitty_uint(value)
			if !ok do return command, {}, .Malformed
			switch format {
			case 24: command.format = .RGB8
			case 32: command.format = .RGBA8
			case: unsupported = true
			}
		case 's':
			if seen_width do return command, {}, .Malformed
			seen_width = true
			width, ok := parse_kitty_uint(value)
			if !ok || width > u64(max(int)) do return command, {}, .Malformed
			command.width = int(width)
		case 'v':
			if seen_height do return command, {}, .Malformed
			seen_height = true
			height, ok := parse_kitty_uint(value)
			if !ok || height > u64(max(int)) do return command, {}, .Malformed
			command.height = int(height)
		case 'i':
			if seen_id do return command, {}, .Malformed
			seen_id = true
			id, ok := parse_kitty_uint(value)
			if !ok || id > u64(max(u32)) do return command, {}, .Malformed
			command.image_id = u32(id)
		case 'p':
			if seen_placement do return command, {}, .Malformed
			seen_placement = true
			id, ok := parse_kitty_uint(value)
			if !ok || id > u64(max(u32)) do return command, {}, .Malformed
			command.placement_id = u32(id)
		case 'c':
			if seen_columns do return command, {}, .Malformed
			seen_columns = true
			columns, ok := parse_kitty_uint(value)
			if !ok || columns > u64(MAX_PLACEMENT_CELLS) do return command, {}, .Malformed
			command.columns = int(columns)
		case 'r':
			if seen_rows do return command, {}, .Malformed
			seen_rows = true
			rows, ok := parse_kitty_uint(value)
			if !ok || rows > u64(MAX_PLACEMENT_CELLS) do return command, {}, .Malformed
			command.rows = int(rows)
		case 'x':
			if seen_source_x do return command, {}, .Malformed
			seen_source_x = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return command, {}, .Malformed
			command.source_x = int(parsed)
		case 'y':
			if seen_source_y do return command, {}, .Malformed
			seen_source_y = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return command, {}, .Malformed
			command.source_y = int(parsed)
		case 'w':
			if seen_source_width do return command, {}, .Malformed
			seen_source_width = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return command, {}, .Malformed
			command.source_width = int(parsed)
		case 'h':
			if seen_source_height do return command, {}, .Malformed
			seen_source_height = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return command, {}, .Malformed
			command.source_height = int(parsed)
		case 'z':
			if seen_z do return command, {}, .Malformed
			seen_z = true
			parsed_bytes := 0
			parsed, ok := strconv.parse_int(value, 10, &parsed_bytes)
			if !ok || parsed_bytes != len(value) || parsed < int(min(i32)) || parsed > int(max(i32)) {
				return command, {}, .Malformed
			}
			command.z = i32(parsed)
		case 'C':
			if seen_cursor_policy do return command, {}, .Malformed
			seen_cursor_policy = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > 1 do return command, {}, .Malformed
			command.no_cursor_move = parsed == 1
		case 't':
			if seen_medium do return command, {}, .Malformed
			seen_medium = true
			if value != "d" do unsupported = true
		case 'm':
			if seen_more do return command, {}, .Malformed
			seen_more = true
			more, ok := parse_kitty_uint(value)
			if !ok || more > 1 do return command, {}, .Malformed
			command.more = more == 1
		case 'q':
			if seen_quiet do return command, {}, .Malformed
			seen_quiet = true
			quiet, ok := parse_kitty_uint(value)
			if !ok || quiet > 2 do return command, {}, .Malformed
			command.quiet = int(quiet)
		case 'o': unsupported = true
		case: unsupported = true
		}
	}
	if unsupported || command.action != .Transmit && command.action != .Transmit_And_Display && command.action != .Query {
		return command, {}, .Unsupported
	}
	if command.more do return command, {}, .Unsupported
	stride, byte_count, layout_error := image_layout(command.width, command.height, command.format)
	if layout_error == .Invalid_Dimensions do return command, {}, .Malformed
	if layout_error != .None do return command, {}, .Image_Limit
	encoded_limit := ((byte_count+2)/3)*4
	if len(payload) == 0 || len(payload) > encoded_limit || len(payload) > MAX_KITTY_ENCODED_BYTES {
		return command, {}, .Image_Limit
	}
	decoded, decode_error := base64.decode(string(payload), options = {.Strict})
	if decode_error != nil do return command, {}, .Invalid_Data
	image := Decoded_Image{
		width = command.width,
		height = command.height,
		stride = stride,
		format = command.format,
		pixels = decoded,
	}
	_, image_error := validate_image(&image)
	if image_error != .None {
		decoded_image_destroy(&image)
		if image_error == .Invalid_Pixel_Data do return command, {}, .Invalid_Data
		return command, {}, .Image_Limit
	}
	return command, image, .None
}

parse_kitty_uint :: proc(value: string) -> (u64, bool) {
	parsed_bytes := 0
	result, ok := strconv.parse_u64(value, 10, &parsed_bytes)
	return result, ok && parsed_bytes == len(value)
}
