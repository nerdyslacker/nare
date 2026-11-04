package graphics

import base64 "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "core:time"
import zlib "vendor:zlib"

KITTY_BACKGROUND_Z_THRESHOLD :: i32(-1_073_741_824)

MAX_KITTY_COMPRESSED_BYTES :: MAX_IMAGE_BYTES+(MAX_IMAGE_BYTES>>12)+(MAX_IMAGE_BYTES>>14)+(MAX_IMAGE_BYTES>>25)+13
MAX_KITTY_ENCODED_BYTES :: ((MAX_KITTY_COMPRESSED_BYTES+2)/3)*4
MAX_KITTY_CHUNKS :: 32_768
MAX_KITTY_CHUNK_BYTES :: 128 * 1024
KITTY_TRANSFER_TIMEOUT :: 10*time.Second

Kitty_Action :: enum {
	Transmit,
	Transmit_And_Display,
	Query,
	Display,
	Delete,
	Frame,
	Animate,
	Compose,
	Unsupported,
}

Kitty_Error :: enum {
	None,
	Malformed,
	Unsupported,
	Invalid_Data,
	Image_Limit,
}

Kitty_Medium :: enum { Direct, File, Temporary_File, Shared_Memory }

Kitty_Delete_Target :: enum {
	Visible,
	Image,
	Cursor,
	Cell,
	Cell_Z,
	ID_Range,
	Column,
	Row,
	Z_Index,
}

Kitty_Command :: struct {
	action: Kitty_Action,
	format: Pixel_Format,
	width, height: int,
	data_size: int,
	data_offset: i64,
	image_id: u32,
	placement_id: u32,
	columns, rows: int,
	destination_x, destination_y: int,
	source_x, source_y: int,
	source_width, source_height: int,
	z: i32,
	no_cursor_move: bool,
	delete_target: Kitty_Delete_Target,
	delete_data: bool,
	png: bool,
	compressed: bool,
	more: bool,
	quiet: int,
	medium: Kitty_Medium,
	virtual: bool,
	parent_image_id: u32,
	parent_placement_id: u32,
	parent_offset_x, parent_offset_y: int,
}

Kitty_Transfer :: struct {
	active: bool,
	command: Kitty_Command,
	encoded: [dynamic]byte,
	encoded_limit: int,
	chunk_count: int,
	last_activity: time.Tick,
}

Kitty_Frame :: struct {
	command: Kitty_Command,
	payload: []byte,
	action_present: bool,
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
	transfer.last_activity = {}
}

kitty_transfer_expire :: proc(transfer: ^Kitty_Transfer, now: time.Tick) -> bool {
	if !transfer.active || time.tick_diff(transfer.last_activity, now) < KITTY_TRANSFER_TIMEOUT do return false
	kitty_transfer_reset(transfer)
	return true
}

kitty_transfer_timeout_ms :: proc(transfer: ^Kitty_Transfer, now: time.Tick) -> int {
	if !transfer.active do return -1
	remaining := KITTY_TRANSFER_TIMEOUT-time.tick_diff(transfer.last_activity, now)
	if remaining <= 0 do return 0
	return max(1, int((remaining+time.Millisecond-time.Nanosecond)/time.Millisecond))
}

kitty_receive_direct :: proc(
	transfer: ^Kitty_Transfer,
	data: []byte,
	limits: ^Limits = nil,
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
		if frame.command.action == .Delete {
			kitty_transfer_reset(transfer)
			return frame.command, {}, true, .None
		}
		command = transfer.command
		if !frame.continuation_controls || frame.action_present && frame.command.action != command.action {
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
		transfer.last_activity = time.tick_now()
		if frame.command.more do return command, {}, false, .None
		command.more = false
		image, err = kitty_decode_payload(command, transfer.encoded[:], limits)
		kitty_transfer_reset(transfer)
		return command, image, true, err
	}

	command = frame.command
	if command.action == .Display || command.action == .Delete || command.action == .Animate || command.action == .Compose {
		return command, {}, true, .None
	}
	if command.medium != .Direct do return command, {}, true, .Unsupported
	encoded_limit, limit_error := kitty_encoded_limit(command, limits)
	if limit_error != .None do return command, {}, true, limit_error
	if command.more {
		if command.action == .Query do return command, {}, true, .Unsupported
		transfer.active = true
		transfer.command = command
		transfer.encoded_limit = encoded_limit
		transfer.last_activity = time.tick_now()
		if chunk_error := kitty_append_chunk(transfer, frame.payload, true); chunk_error != .None {
			kitty_transfer_reset(transfer)
			return command, {}, true, chunk_error
		}
		return command, {}, false, .None
	}
	if frame.more_present && len(frame.payload) > MAX_KITTY_CHUNK_BYTES {
		return command, {}, true, .Image_Limit
	}
	image, err = kitty_decode_payload(command, frame.payload, limits)
	return command, image, true, err
}

kitty_decode_direct :: proc(data: []byte, limits: ^Limits = nil) -> (Kitty_Command, Decoded_Image, Kitty_Error) {
	transfer: Kitty_Transfer
	defer kitty_transfer_destroy(&transfer)
	command, image, complete, err := kitty_receive_direct(&transfer, data, limits)
	if !complete do return command, {}, .Unsupported
	return command, image, err
}

kitty_parse_direct_frame :: proc(data: []byte) -> (Kitty_Frame, Kitty_Error) {
	command := Kitty_Command{action = .Transmit, format = .RGBA8}
	frame := Kitty_Frame{command = command}
	if len(data) < 3 || data[0] != 'G' do return frame, .Malformed
	separator := strings.index_byte(string(data), ';')
	control := string(data[1:])
	payload: []byte
	if separator >= 0 {
		if separator < 1 do return frame, .Malformed
		control = string(data[1:separator])
		payload = data[separator+1:]
	}
	seen_action, seen_format, seen_width, seen_height := false, false, false, false
	seen_data_size, seen_data_offset := false, false
	seen_id, seen_placement, seen_columns, seen_rows := false, false, false, false
	seen_medium, seen_compression, seen_more, seen_quiet := false, false, false, false
	seen_source_x, seen_source_y, seen_source_width, seen_source_height := false, false, false, false
	seen_destination_x, seen_destination_y := false, false
	seen_z, seen_cursor_policy, seen_delete := false, false, false
	seen_virtual, seen_parent_image, seen_parent_placement := false, false, false
	seen_parent_offset_x, seen_parent_offset_y := false, false
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
			case 'f': command.action = .Frame
			case 'a': command.action = .Animate
			case 'c': command.action = .Compose
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
		case 'S':
			if seen_data_size do return Kitty_Frame{command = command}, .Malformed
			seen_data_size = true
			data_size, ok := parse_kitty_uint(value)
			if !ok || data_size == 0 || data_size > u64(MAX_KITTY_COMPRESSED_BYTES) do return Kitty_Frame{command = command}, .Malformed
			command.data_size = int(data_size)
		case 'O':
			if seen_data_offset do return Kitty_Frame{command = command}, .Malformed
			seen_data_offset = true
			data_offset, ok := parse_kitty_uint(value)
			if !ok || data_offset > u64(max(i64)) do return Kitty_Frame{command = command}, .Malformed
			command.data_offset = i64(data_offset)
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
		case 'X':
			if seen_destination_x do return Kitty_Frame{command = command}, .Malformed
			seen_destination_x = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.destination_x = int(parsed)
		case 'Y':
			if seen_destination_y do return Kitty_Frame{command = command}, .Malformed
			seen_destination_y = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(int)) do return Kitty_Frame{command = command}, .Malformed
			command.destination_y = int(parsed)
		case 'z':
			if seen_z do return Kitty_Frame{command = command}, .Malformed
			seen_z = true
			parsed_bytes := 0
			parsed, ok := strconv.parse_int(value, 10, &parsed_bytes)
			if !ok || parsed_bytes != len(value) || parsed < int(min(i32)) || parsed > int(max(i32)) {
				return Kitty_Frame{command = command}, .Malformed
			}
			command.z = i32(parsed)
		case 'U':
			if seen_virtual do return Kitty_Frame{command = command}, .Malformed
			seen_virtual = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > 1 do return Kitty_Frame{command = command}, .Malformed
			command.virtual = parsed == 1
		case 'P':
			if seen_parent_image do return Kitty_Frame{command = command}, .Malformed
			seen_parent_image = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(u32)) do return Kitty_Frame{command = command}, .Malformed
			command.parent_image_id = u32(parsed)
		case 'Q':
			if seen_parent_placement do return Kitty_Frame{command = command}, .Malformed
			seen_parent_placement = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > u64(max(u32)) do return Kitty_Frame{command = command}, .Malformed
			command.parent_placement_id = u32(parsed)
		case 'H':
			if seen_parent_offset_x do return Kitty_Frame{command = command}, .Malformed
			seen_parent_offset_x = true
			parsed_bytes := 0
			parsed, ok := strconv.parse_int(value, 10, &parsed_bytes)
			if !ok || parsed_bytes != len(value) || parsed < int(min(i32)) || parsed > int(max(i32)) {
				return Kitty_Frame{command = command}, .Malformed
			}
			command.parent_offset_x = parsed
		case 'V':
			if seen_parent_offset_y do return Kitty_Frame{command = command}, .Malformed
			seen_parent_offset_y = true
			parsed_bytes := 0
			parsed, ok := strconv.parse_int(value, 10, &parsed_bytes)
			if !ok || parsed_bytes != len(value) || parsed < int(min(i32)) || parsed > int(max(i32)) {
				return Kitty_Frame{command = command}, .Malformed
			}
			command.parent_offset_y = parsed
		case 'C':
			if seen_cursor_policy do return Kitty_Frame{command = command}, .Malformed
			seen_cursor_policy = true
			parsed, ok := parse_kitty_uint(value)
			if !ok || parsed > 1 do return Kitty_Frame{command = command}, .Malformed
			command.no_cursor_move = parsed == 1
		case 't':
			if seen_medium do return Kitty_Frame{command = command}, .Malformed
			seen_medium = true
			if len(value) != 1 do return Kitty_Frame{command = command}, .Malformed
			switch value[0] {
			case 'd': command.medium = .Direct
			case 'f': command.medium = .File
			case 't': command.medium = .Temporary_File
			case 's': command.medium = .Shared_Memory
			case: unsupported = true
			}
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
		case 'd':
			if seen_delete || len(value) != 1 do return Kitty_Frame{command = command}, .Malformed
			seen_delete = true
			switch value[0] {
			case 'a': command.delete_target = .Visible
			case 'A':
				command.delete_target = .Visible
				command.delete_data = true
			case 'i': command.delete_target = .Image
			case 'I':
				command.delete_target = .Image
				command.delete_data = true
			case 'c': command.delete_target = .Cursor
			case 'C':
				command.delete_target = .Cursor
				command.delete_data = true
			case 'p': command.delete_target = .Cell
			case 'P':
				command.delete_target = .Cell
				command.delete_data = true
			case 'q': command.delete_target = .Cell_Z
			case 'Q':
				command.delete_target = .Cell_Z
				command.delete_data = true
			case 'r': command.delete_target = .ID_Range
			case 'R':
				command.delete_target = .ID_Range
				command.delete_data = true
			case 'x': command.delete_target = .Column
			case 'X':
				command.delete_target = .Column
				command.delete_data = true
			case 'y': command.delete_target = .Row
			case 'Y':
				command.delete_target = .Row
				command.delete_data = true
			case 'z': command.delete_target = .Z_Index
			case 'Z':
				command.delete_target = .Z_Index
				command.delete_data = true
			case: unsupported = true
			}
		case: unsupported = true
		}
	}
	if unsupported || command.action == .Unsupported {
		return Kitty_Frame{command = command}, .Unsupported
	}
	if command.action != .Delete && seen_delete do return Kitty_Frame{command = command}, .Malformed
	if command.medium == .Direct && seen_data_offset do return Kitty_Frame{command = command}, .Malformed
	if command.action == .Display {
		if command.image_id == 0 || len(payload) != 0 || seen_format || seen_width || seen_height ||
		   seen_data_size || seen_data_offset || seen_medium || seen_compression || seen_more {
			return Kitty_Frame{command = command}, .Malformed
		}
	} else if command.action == .Delete {
		if len(payload) != 0 || seen_format || seen_width || seen_height || seen_data_size || seen_data_offset || seen_medium ||
		   seen_compression || seen_more || seen_columns || seen_rows || seen_source_width ||
		   seen_source_height || seen_destination_x || seen_destination_y || seen_cursor_policy {
			return Kitty_Frame{command = command}, .Malformed
		}
		switch command.delete_target {
		case .Visible, .Cursor:
			if seen_id || seen_placement || seen_source_x || seen_source_y || seen_z do return Kitty_Frame{command = command}, .Malformed
		case .Image:
			if command.image_id == 0 || seen_source_x || seen_source_y || seen_z do return Kitty_Frame{command = command}, .Malformed
		case .Cell:
			if seen_id || seen_placement || !seen_source_x || !seen_source_y || command.source_x == 0 || command.source_y == 0 || seen_z {
				return Kitty_Frame{command = command}, .Malformed
			}
		case .Cell_Z:
			if seen_id || seen_placement || !seen_source_x || !seen_source_y || command.source_x == 0 || command.source_y == 0 || !seen_z {
				return Kitty_Frame{command = command}, .Malformed
			}
		case .ID_Range:
			if seen_id || seen_placement || !seen_source_x || !seen_source_y || command.source_x == 0 ||
			   command.source_y == 0 || command.source_x > command.source_y ||
			   u64(command.source_y) > u64(max(u32)) || seen_z {
				return Kitty_Frame{command = command}, .Malformed
			}
		case .Column:
			if seen_id || seen_placement || !seen_source_x || command.source_x == 0 || seen_source_y || seen_z do return Kitty_Frame{command = command}, .Malformed
		case .Row:
			if seen_id || seen_placement || seen_source_x || !seen_source_y || command.source_y == 0 || seen_z do return Kitty_Frame{command = command}, .Malformed
		case .Z_Index:
			if seen_id || seen_placement || seen_source_x || seen_source_y || !seen_z do return Kitty_Frame{command = command}, .Malformed
		}
	} else if command.action == .Frame {
		if command.image_id == 0 || seen_placement || seen_virtual || seen_parent_image || seen_parent_placement ||
		   seen_parent_offset_x || seen_parent_offset_y || seen_cursor_policy {
			return Kitty_Frame{command = command}, .Malformed
		}
	} else if command.action == .Animate {
		if command.image_id == 0 || len(payload) != 0 || seen_format || seen_data_size || seen_data_offset ||
		   seen_medium || seen_compression || seen_more || seen_placement || seen_source_x || seen_source_y ||
		   seen_source_width || seen_source_height || seen_destination_x || seen_destination_y ||
		   seen_virtual || seen_parent_image || seen_parent_placement || seen_parent_offset_x || seen_parent_offset_y {
			return Kitty_Frame{command = command}, .Malformed
		}
	} else if command.action == .Compose {
		if command.image_id == 0 || len(payload) != 0 || !seen_columns || !seen_rows || seen_format ||
		   seen_width || seen_height || seen_data_size || seen_data_offset || seen_medium || seen_compression ||
		   seen_more || seen_placement || seen_z || seen_virtual || seen_parent_image || seen_parent_placement ||
		   seen_parent_offset_x || seen_parent_offset_y {
			return Kitty_Frame{command = command}, .Malformed
		}
	}
	if seen_virtual && seen_parent_image do return Kitty_Frame{command = command}, .Malformed
	if (seen_parent_placement || seen_parent_offset_x || seen_parent_offset_y) && !seen_parent_image {
		return Kitty_Frame{command = command}, .Malformed
	}
	if seen_parent_image && command.action != .Display && command.action != .Transmit_And_Display {
		return Kitty_Frame{command = command}, .Malformed
	}
	frame.command = command
	frame.payload = payload
	frame.action_present = seen_action
	frame.more_present = seen_more
	frame.quiet_present = seen_quiet
	frame.continuation_controls = key_count == int(seen_action)+int(seen_more)+int(seen_quiet)
	return frame, .None
}

kitty_encoded_limit :: proc(command: Kitty_Command, limits: ^Limits = nil) -> (int, Kitty_Error) {
	if command.png {
		if command.compressed do return 0, .Unsupported
		return ((MAX_PNG_BYTES+2)/3)*4, .None
	}
	_, byte_count, layout_error := image_layout_with_limits(command.width, command.height, command.format, limits)
	if command.width <= 0 || command.height <= 0 do return 0, .Malformed
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
	if more && len(payload)%4 != 0 do return .Invalid_Data
	append(&transfer.encoded, ..payload)
	transfer.chunk_count += 1
	return .None
}

kitty_decode_payload :: proc(command: Kitty_Command, payload: []byte, limits: ^Limits = nil) -> (Decoded_Image, Kitty_Error) {
	encoded_limit, limit_error := kitty_encoded_limit(command, limits)
	if limit_error != .None do return {}, limit_error
	if len(payload) == 0 || len(payload) > encoded_limit do return {}, .Image_Limit
	decode_options: base64.Decode_Options = {.Strict}
	if len(payload)%4 != 0 do decode_options += {.No_Padding}
	decoded, decode_error := base64.decode(string(payload), options = decode_options)
	if decode_error != nil do return {}, .Invalid_Data
	if command.data_size > 0 && len(decoded) != command.data_size {
		delete(decoded)
		return {}, .Invalid_Data
	}
	return kitty_decode_bytes(command, decoded, limits)
}

kitty_decode_bytes :: proc(command: Kitty_Command, decoded: []byte, limits: ^Limits = nil) -> (Decoded_Image, Kitty_Error) {
	if command.png {
		image, png_error := decode_png(decoded, limits)
		delete(decoded)
		switch png_error {
		case .None: return image, .None
		case .Limit: return {}, .Image_Limit
		case .Unsupported: return {}, .Unsupported
		case .Invalid_Data: return {}, .Invalid_Data
		}
	}
	stride, byte_count, _, layout_error := kitty_payload_layout(command, limits)
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
	_, image_error := validate_image_with_limits(&image, limits)
	if image_error != .None {
		decoded_image_destroy(&image)
		if image_error == .Invalid_Pixel_Data do return {}, .Invalid_Data
		return {}, .Image_Limit
	}
	return image, .None
}

kitty_input_limit :: proc(command: Kitty_Command, limits: ^Limits = nil) -> (int, Kitty_Error) {
	if command.png {
		if command.compressed do return 0, .Unsupported
		return MAX_PNG_BYTES, .None
	}
	_, byte_count, layout_error := image_layout_with_limits(command.width, command.height, command.format, limits)
	if command.width <= 0 || command.height <= 0 do return 0, .Malformed
	if layout_error != .None do return 0, .Image_Limit
	if command.compressed do return kitty_compressed_bound(byte_count), .None
	return byte_count, .None
}

kitty_payload_layout :: proc(command: Kitty_Command, limits: ^Limits = nil) -> (stride, byte_count, encoded_limit: int, err: Kitty_Error) {
	layout_error: Error
	stride, byte_count, layout_error = image_layout_with_limits(command.width, command.height, command.format, limits)
	if command.width <= 0 || command.height <= 0 do return 0, 0, 0, .Malformed
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

kitty_normalized_gap :: proc(gap: i32) -> i32 {
	if gap == 0 do return DEFAULT_FRAME_GAP_MS
	if gap < 0 do return -1
	return gap
}

kitty_frame_bytes :: proc(resource: ^Resource) -> int {
	return resource.width*resource.height*bytes_per_pixel(resource.format)
}

kitty_fill_canvas :: proc(pixels: []byte, channels: int, background: u32) {
	if background == 0 do return
	red := byte(background >> 24)
	green := byte(background >> 16)
	blue := byte(background >> 8)
	alpha := byte(background)
	for offset := 0; offset+channels <= len(pixels); offset += channels {
		pixels[offset] = red
		pixels[offset+1] = green
		pixels[offset+2] = blue
		if channels == 4 do pixels[offset+3] = alpha
	}
}

kitty_blend_frame_rect :: proc(
	canvas: []byte,
	canvas_stride, channels: int,
	source: []byte,
	source_stride: int,
	x, y, width, height: int,
	replace: bool,
) {
	for row in 0..<height {
		destination_row := (y+row)*canvas_stride+x*channels
		source_row := row*source_stride
		for column in 0..<width {
			destination := destination_row+column*channels
			origin := source_row+column*channels
			if replace || channels == 3 {
				copy(canvas[destination:destination+channels], source[origin:origin+channels])
				continue
			}
			alpha := int(source[origin+3])
			if alpha == 255 {
				copy(canvas[destination:destination+4], source[origin:origin+4])
				continue
			}
			if alpha == 0 do continue
			inverse := 255-alpha
			for channel in 0..<3 {
				canvas[destination+channel] = byte((int(source[origin+channel])*alpha+int(canvas[destination+channel])*inverse+127)/255)
			}
			canvas[destination+3] = byte(min(255, alpha+int(canvas[destination+3])*inverse/255))
		}
	}
}

kitty_add_frame :: proc(
	registry: ^Registry,
	resource: ^Resource,
	command: Kitty_Command,
	image: ^Decoded_Image,
) -> Kitty_Error {
	if resource == nil || image == nil || image.width <= 0 || image.height <= 0 do return .Invalid_Data
	if image.format != resource.format do return .Invalid_Data
	channels := bytes_per_pixel(resource.format)
	if channels <= 0 || resource.width <= 0 || resource.height <= 0 do return .Invalid_Data
	frame_size := kitty_frame_bytes(resource)
	if frame_size <= 0 do return .Image_Limit
	x := command.source_x
	y := command.source_y
	if x < 0 || y < 0 || x+image.width > resource.width || y+image.height > resource.height {
		return .Invalid_Data
	}
	edit_index := -1
	if command.rows > 0 {
		edit_index = command.rows-1
		if edit_index >= len(resource.frames) do return .Invalid_Data
	}
	base_index := -1
	if edit_index < 0 && command.columns > 0 {
		base_index = command.columns-1
		if base_index >= len(resource.frames) do return .Invalid_Data
	}
	gap := kitty_normalized_gap(command.z)
	if edit_index >= 0 {
		frame := &resource.frames[edit_index]
		kitty_blend_frame_rect(
			frame.pixels,
			resource.stride,
			channels,
			image.pixels,
			image.stride,
			x,
			y,
			image.width,
			image.height,
			command.destination_x == 1,
		)
		if command.z != 0 do frame.gap_ms = gap
		if edit_index == resource.current_frame {
			resource.pixels = frame.pixels
			resource.version += 1
		}
		return .None
	}
	if len(resource.frames) >= MAX_KITTY_FRAMES do return .Image_Limit
	if resource.frame_bytes+frame_size > MAX_CACHE_BYTES do return .Image_Limit
	if registry != nil {
		if registry.decoded_bytes+frame_size > registry.limits.cache_bytes ||
		   registry.protocol_bytes[int(Protocol.Kitty)]+frame_size > protocol_budget(registry, .Kitty) {
			return .Image_Limit
		}
		if registry.shared_cache != nil && registry.shared_cache.decoded_bytes+frame_size > registry.shared_cache.limit {
			return .Image_Limit
		}
	}
	pixels := make([]byte, frame_size)
	if base_index >= 0 {
		copy(pixels, resource.frames[base_index].pixels)
	} else {
		kitty_fill_canvas(pixels, channels, u32(command.destination_y))
	}
	kitty_blend_frame_rect(
		pixels,
		resource.stride,
		channels,
		image.pixels,
		image.stride,
		x,
		y,
		image.width,
		image.height,
		command.destination_x == 1,
	)
	append(&resource.frames, Frame{pixels = pixels, gap_ms = gap})
	resource.frame_bytes += frame_size
	if registry != nil {
		registry.decoded_bytes += frame_size
		registry.protocol_bytes[int(Protocol.Kitty)] += frame_size
		if registry.shared_cache != nil do registry.shared_cache.decoded_bytes += frame_size
	}
	return .None
}

kitty_control_animation :: proc(resource: ^Resource, command: Kitty_Command) -> Kitty_Error {
	if resource == nil || len(resource.frames) == 0 do return .Invalid_Data
	if command.columns > 0 {
		if !resource_set_frame(resource, command.columns-1) do return .Invalid_Data
	}
	if command.rows > 0 {
		index := command.rows-1
		if index >= len(resource.frames) do return .Invalid_Data
		if command.z != 0 do resource.frames[index].gap_ms = kitty_normalized_gap(command.z)
	}
	if command.height > 0 {
		if command.height == 1 {
			resource.loops_remaining = -1
		} else {
			resource.loops_remaining = command.height-1
		}
	}
	if command.width != 0 {
		switch command.width {
		case 1:
			resource.animation = .Stopped
			resource.loops_remaining = 0
			resource.next_frame = {}
		case 2:
			resource.animation = .Loading
			if command.height == 0 do resource.loops_remaining = -1
			resource.next_frame = kitty_next_frame_time(resource, time.tick_now())
		case 3:
			resource.animation = .Running
			if command.height == 0 do resource.loops_remaining = -1
			resource.next_frame = kitty_next_frame_time(resource, time.tick_now())
		case:
			return .Invalid_Data
		}
	}
	return .None
}

kitty_compose_frames :: proc(resource: ^Resource, command: Kitty_Command) -> Kitty_Error {
	if resource == nil || len(resource.frames) == 0 do return .Invalid_Data
	source_index := command.rows-1
	destination_index := command.columns-1
	if source_index < 0 || destination_index < 0 ||
	   source_index >= len(resource.frames) || destination_index >= len(resource.frames) {
		return .Invalid_Data
	}
	width := command.source_width
	height := command.source_height
	if width <= 0 do width = resource.width
	if height <= 0 do height = resource.height
	x := command.source_x
	y := command.source_y
	target_x := command.destination_x
	target_y := command.destination_y
	if x < 0 || y < 0 || target_x < 0 || target_y < 0 ||
	   x+width > resource.width || y+height > resource.height ||
	   target_x+width > resource.width || target_y+height > resource.height {
		return .Invalid_Data
	}
	if source_index == destination_index && x < target_x+width && target_x < x+width &&
	   y < target_y+height && target_y < y+height {
		return .Invalid_Data
	}
	channels := bytes_per_pixel(resource.format)
	source := resource.frames[source_index].pixels
	destination := resource.frames[destination_index].pixels
	for row in 0..<height {
		source_offset := (y+row)*resource.stride+x*channels
		destination_offset := (target_y+row)*resource.stride+target_x*channels
		if command.no_cursor_move || channels == 3 {
			copy(destination[destination_offset:destination_offset+width*channels], source[source_offset:source_offset+width*channels])
			continue
		}
		for column in 0..<width {
			origin := source_offset+column*channels
			target := destination_offset+column*channels
			alpha := int(source[origin+3])
			if alpha == 255 {
				copy(destination[target:target+4], source[origin:origin+4])
				continue
			}
			if alpha == 0 do continue
			inverse := 255-alpha
			for channel in 0..<3 {
				destination[target+channel] = byte((int(source[origin+channel])*alpha+int(destination[target+channel])*inverse+127)/255)
			}
			destination[target+3] = byte(min(255, alpha+int(destination[target+3])*inverse/255))
		}
	}
	if destination_index == resource.current_frame {
		resource.pixels = destination
		resource.version += 1
	}
	return .None
}

kitty_frame_gap :: proc(resource: ^Resource, index: int) -> i32 {
	if index < 0 || index >= len(resource.frames) do return DEFAULT_FRAME_GAP_MS
	gap := resource.frames[index].gap_ms
	if gap == 0 do return DEFAULT_FRAME_GAP_MS
	return gap
}

kitty_next_frame_time :: proc(resource: ^Resource, now: time.Tick) -> time.Tick {
	gap := kitty_frame_gap(resource, resource.current_frame)
	if gap <= 0 do gap = DEFAULT_FRAME_GAP_MS
	return time.tick_add(now, time.Duration(gap)*time.Millisecond)
}

kitty_animation_advance :: proc(resource: ^Resource, now: time.Tick) -> bool {
	if resource == nil || (resource.animation != .Running && resource.animation != .Loading) || len(resource.frames) <= 1 do return false
	if resource.next_frame == {} {
		resource.next_frame = kitty_next_frame_time(resource, now)
		return false
	}
	if time.tick_since(resource.next_frame) < 0 do return false
	index := resource.current_frame
	for step := 0; step < len(resource.frames); step += 1 {
		next := index+1
		if next >= len(resource.frames) {
			if resource.animation == .Loading {
				resource.next_frame = {}
				return false
			}
			if resource.loops_remaining == 0 {
				resource.animation = .Stopped
				resource.next_frame = {}
				return false
			}
			if resource.loops_remaining > 0 do resource.loops_remaining -= 1
			next = 0
		}
		index = next
		if kitty_frame_gap(resource, index) < 0 do continue
		if !resource_set_frame(resource, index) do return false
		resource.next_frame = kitty_next_frame_time(resource, now)
		return true
	}
	resource.next_frame = kitty_next_frame_time(resource, now)
	return false
}

kitty_animation_timeout_ms :: proc(resource: ^Resource, now: time.Tick) -> int {
	if resource == nil || (resource.animation != .Running && resource.animation != .Loading) || len(resource.frames) <= 1 do return -1
	if resource.next_frame == {} do return 1
	remaining := -time.tick_since(resource.next_frame)
	if remaining <= 0 do return 0
	return max(1, int((remaining+time.Millisecond-time.Nanosecond)/time.Millisecond))
}
