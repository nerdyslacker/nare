package ipc

import "core:strings"

MAGIC :: "NARE"
VERSION :: u16(2)
HEADER_SIZE :: 16
MAX_PAYLOAD_BYTES :: 128 * 1024
MAX_ARGUMENTS :: 256
MAX_STRING_BYTES :: 32 * 1024
MAX_ERROR_MESSAGE_BYTES :: 1024
MAX_TITLE_BYTES :: 1024
MAX_FRAMES_PER_FEED :: 256

CREATE_OVERRIDE_FONT_SIZE :: u16(1 << 0)
CREATE_OVERRIDE_RENDERER :: u16(1 << 1)
CREATE_OVERRIDE_LIGATURES :: u16(1 << 2)
CREATE_OVERRIDE_TITLE :: u16(1 << 3)
CREATE_OVERRIDE_MASK :: CREATE_OVERRIDE_FONT_SIZE | CREATE_OVERRIDE_RENDERER | CREATE_OVERRIDE_LIGATURES | CREATE_OVERRIDE_TITLE

Kind :: enum u16 {
	Create = 1,
	Created,
	Exit,
	Error,
	Ping,
	Pong,
}

Error :: enum {
	None,
	Limit,
	Malformed,
	Unsupported_Version,
	Unsupported_Kind,
}

Remote_Error_Code :: enum u16 {
	Invalid_Request = 1,
	Launch_Failed,
	Server_Busy,
	Internal,
}

Remote_Error :: struct {
	code: Remote_Error_Code,
	message: string,
}

Renderer_Override :: enum u8 {
	CPU = 1,
	GPU,
	Auto,
}

Frame :: struct {
	kind: Kind,
	request_id: u32,
	payload: [dynamic]byte,
}

Decoder :: struct {
	buffer: [dynamic]byte,
}

Create_Request :: struct {
	wait: bool,
	working_directory: string,
	arguments: [dynamic]string,
	override_font_size: bool,
	font_size: u16,
	override_renderer: bool,
	renderer: Renderer_Override,
	override_ligatures: bool,
	ligatures: bool,
	override_title: bool,
	title: string,
}

frame_destroy :: proc(frame: ^Frame) {
	delete(frame.payload)
	frame^ = {}
}

frames_destroy :: proc(frames: ^[dynamic]Frame) {
	for &frame in frames^ do frame_destroy(&frame)
	delete(frames^)
	frames^ = nil
}

decoder_destroy :: proc(decoder: ^Decoder) {
	delete(decoder.buffer)
	decoder^ = {}
}

create_request_destroy :: proc(request: ^Create_Request) {
	delete(request.working_directory)
	for argument in request.arguments do delete(argument)
	delete(request.arguments)
	delete(request.title)
	request^ = {}
}

remote_error_destroy :: proc(remote_error: ^Remote_Error) {
	delete(remote_error.message)
	remote_error^ = {}
}

append_u16 :: proc(output: ^[dynamic]byte, value: u16) {
	append(output, byte(value), byte(value >> 8))
}

append_u32 :: proc(output: ^[dynamic]byte, value: u32) {
	append(output, byte(value), byte(value >> 8), byte(value >> 16), byte(value >> 24))
}

append_u64 :: proc(output: ^[dynamic]byte, value: u64) {
	append_u32(output, u32(value))
	append_u32(output, u32(value >> 32))
}

read_u16 :: proc(data: []byte, offset: int) -> (u16, bool) {
	if offset < 0 || offset+2 > len(data) do return 0, false
	return u16(data[offset]) | u16(data[offset+1]) << 8, true
}

read_u32 :: proc(data: []byte, offset: int) -> (u32, bool) {
	if offset < 0 || offset+4 > len(data) do return 0, false
	return u32(data[offset]) |
	       u32(data[offset+1]) << 8 |
	       u32(data[offset+2]) << 16 |
	       u32(data[offset+3]) << 24, true
}

read_u64 :: proc(data: []byte, offset: int) -> (u64, bool) {
	low, low_ok := read_u32(data, offset)
	high, high_ok := read_u32(data, offset+4)
	return u64(low) | u64(high) << 32, low_ok && high_ok
}

valid_kind :: proc(value: u16) -> (Kind, bool) {
	switch value {
	case u16(Kind.Create): return .Create, true
	case u16(Kind.Created): return .Created, true
	case u16(Kind.Exit): return .Exit, true
	case u16(Kind.Error): return .Error, true
	case u16(Kind.Ping): return .Ping, true
	case u16(Kind.Pong): return .Pong, true
	}
	return {}, false
}

append_frame :: proc(output: ^[dynamic]byte, kind: Kind, request_id: u32, payload: []byte) -> Error {
	if len(payload) > MAX_PAYLOAD_BYTES do return .Limit
	append(output, MAGIC)
	append_u16(output, VERSION)
	append_u16(output, u16(kind))
	append_u32(output, request_id)
	append_u32(output, u32(len(payload)))
	append(output, ..payload)
	return .None
}

append_created :: proc(output: ^[dynamic]byte, request_id: u32, session_id: u64) -> Error {
	payload: [8]byte
	encoded: [dynamic]byte
	defer delete(encoded)
	append_u64(&encoded, session_id)
	copy(payload[:], encoded[:])
	return append_frame(output, .Created, request_id, payload[:])
}

decode_created :: proc(frame: ^Frame) -> (u64, Error) {
	if frame.kind != .Created || len(frame.payload) != 8 do return 0, .Malformed
	session_id, ok := read_u64(frame.payload[:], 0)
	if !ok || session_id == 0 do return 0, .Malformed
	return session_id, .None
}

append_exit :: proc(output: ^[dynamic]byte, request_id: u32, status: i32) -> Error {
	payload: [dynamic]byte
	defer delete(payload)
	append_u32(&payload, cast(u32)status)
	return append_frame(output, .Exit, request_id, payload[:])
}

decode_exit :: proc(frame: ^Frame) -> (i32, Error) {
	if frame.kind != .Exit || len(frame.payload) != 4 do return 0, .Malformed
	status, ok := read_u32(frame.payload[:], 0)
	if !ok do return 0, .Malformed
	return cast(i32)status, .None
}

valid_remote_error_code :: proc(value: u16) -> (Remote_Error_Code, bool) {
	switch value {
	case u16(Remote_Error_Code.Invalid_Request): return .Invalid_Request, true
	case u16(Remote_Error_Code.Launch_Failed): return .Launch_Failed, true
	case u16(Remote_Error_Code.Server_Busy): return .Server_Busy, true
	case u16(Remote_Error_Code.Internal): return .Internal, true
	}
	return {}, false
}

append_error :: proc(
	output: ^[dynamic]byte,
	request_id: u32,
	code: Remote_Error_Code,
	message: string,
) -> Error {
	if len(message) == 0 || len(message) > MAX_ERROR_MESSAGE_BYTES || contains_nul(message) do return .Limit
	payload: [dynamic]byte
	defer delete(payload)
	append_u16(&payload, u16(code))
	append_u16(&payload, u16(len(message)))
	append(&payload, message)
	return append_frame(output, .Error, request_id, payload[:])
}

decode_error :: proc(frame: ^Frame, remote_error: ^Remote_Error) -> Error {
	if frame.kind != .Error || len(frame.payload) < 4 do return .Malformed
	code_value, code_ok := read_u16(frame.payload[:], 0)
	message_size, size_ok := read_u16(frame.payload[:], 2)
	code, supported := valid_remote_error_code(code_value)
	if !code_ok || !size_ok || !supported || message_size == 0 || message_size > MAX_ERROR_MESSAGE_BYTES ||
	   int(message_size) != len(frame.payload)-4 {
		return .Malformed
	}
	message := string(frame.payload[4:])
	if contains_nul(message) do return .Malformed
	remote_error^ = {code = code, message = strings.clone(message)}
	return .None
}

decoder_feed :: proc(decoder: ^Decoder, data: []byte, frames: ^[dynamic]Frame) -> Error {
	if len(data) > HEADER_SIZE+MAX_PAYLOAD_BYTES || len(decoder.buffer) > HEADER_SIZE+MAX_PAYLOAD_BYTES-len(data) {
		return .Limit
	}
	append(&decoder.buffer, ..data)
	initial_count := len(frames^)
	for len(decoder.buffer) >= HEADER_SIZE {
		if decoder.buffer[0] != 'N' || decoder.buffer[1] != 'A' ||
		   decoder.buffer[2] != 'R' || decoder.buffer[3] != 'E' {
			clear(&decoder.buffer)
			return .Malformed
		}
		version, version_ok := read_u16(decoder.buffer[:], 4)
		kind_value, kind_ok := read_u16(decoder.buffer[:], 6)
		request_id, request_ok := read_u32(decoder.buffer[:], 8)
		payload_size, size_ok := read_u32(decoder.buffer[:], 12)
		if !version_ok || !kind_ok || !request_ok || !size_ok {
			clear(&decoder.buffer)
			return .Malformed
		}
		if version != VERSION {
			clear(&decoder.buffer)
			return .Unsupported_Version
		}
		kind, supported := valid_kind(kind_value)
		if !supported {
			clear(&decoder.buffer)
			return .Unsupported_Kind
		}
		if payload_size > MAX_PAYLOAD_BYTES {
			clear(&decoder.buffer)
			return .Limit
		}
		total_size := HEADER_SIZE+int(payload_size)
		if len(decoder.buffer) < total_size do break
		if len(frames^)-initial_count >= MAX_FRAMES_PER_FEED do return .Limit
		frame := Frame{kind = kind, request_id = request_id}
		append(&frame.payload, ..decoder.buffer[HEADER_SIZE:total_size])
		append(frames, frame)
		remaining := len(decoder.buffer)-total_size
		copy(decoder.buffer[:remaining], decoder.buffer[total_size:])
		resize(&decoder.buffer, remaining)
	}
	return .None
}

contains_nul :: proc(value: string) -> bool {
	for octet in transmute([]byte)value do if octet == 0 do return true
	return false
}

encode_create :: proc(request: ^Create_Request, request_id: u32, output: ^[dynamic]byte) -> Error {
	if len(request.arguments) == 0 || len(request.arguments) > MAX_ARGUMENTS ||
	   len(request.working_directory) > MAX_STRING_BYTES || contains_nul(request.working_directory) {
		return .Limit
	}
	payload: [dynamic]byte
	defer delete(payload)
	flags := u16(1) if request.wait else u16(0)
	append_u16(&payload, flags)
	append_u16(&payload, u16(len(request.arguments)))
	append_u32(&payload, u32(len(request.working_directory)))
	append(&payload, ..transmute([]byte)request.working_directory)
	for argument in request.arguments {
		if len(argument) == 0 || len(argument) > MAX_STRING_BYTES || contains_nul(argument) do return .Limit
		if len(payload) > MAX_PAYLOAD_BYTES-4-len(argument) do return .Limit
		append_u32(&payload, u32(len(argument)))
		append(&payload, ..transmute([]byte)argument)
	}
	overrides: u16
	if request.override_font_size {
		if request.font_size == 0 do return .Limit
		overrides |= CREATE_OVERRIDE_FONT_SIZE
	}
	if request.override_renderer {
		if request.renderer < .CPU || request.renderer > .Auto do return .Limit
		overrides |= CREATE_OVERRIDE_RENDERER
	}
	if request.override_ligatures do overrides |= CREATE_OVERRIDE_LIGATURES
	if request.override_title {
		if len(request.title) == 0 || len(request.title) > MAX_TITLE_BYTES || contains_nul(request.title) do return .Limit
		overrides |= CREATE_OVERRIDE_TITLE
	}
	if overrides != 0 {
		append_u16(&payload, overrides)
		if request.override_font_size do append_u16(&payload, request.font_size)
		if request.override_renderer do append(&payload, byte(request.renderer))
		if request.override_ligatures do append(&payload, byte(1) if request.ligatures else byte(0))
		if request.override_title {
			append_u16(&payload, u16(len(request.title)))
			append(&payload, ..transmute([]byte)request.title)
		}
	}
	return append_frame(output, .Create, request_id, payload[:])
}

decode_create :: proc(frame: ^Frame, request: ^Create_Request) -> Error {
	if frame.kind != .Create do return .Malformed
	flags, flags_ok := read_u16(frame.payload[:], 0)
	argument_count, count_ok := read_u16(frame.payload[:], 2)
	working_directory_size, cwd_ok := read_u32(frame.payload[:], 4)
	if !flags_ok || !count_ok || !cwd_ok || flags & ~u16(1) != 0 ||
	   argument_count == 0 || argument_count > MAX_ARGUMENTS || working_directory_size > MAX_STRING_BYTES {
		return .Malformed
	}
	offset := 8
	if int(working_directory_size) > len(frame.payload)-offset do return .Malformed
	working_directory := frame.payload[offset:offset+int(working_directory_size)]
	if contains_nul(string(working_directory)) do return .Malformed
	offset += len(working_directory)
	decoded := Create_Request{wait = flags & 1 != 0}
	decoded.working_directory = strings.clone(string(working_directory))
	for _ in 0..<int(argument_count) {
		argument_size, ok := read_u32(frame.payload[:], offset)
		if !ok || argument_size == 0 || argument_size > MAX_STRING_BYTES {
			create_request_destroy(&decoded)
			return .Malformed
		}
		offset += 4
		if int(argument_size) > len(frame.payload)-offset {
			create_request_destroy(&decoded)
			return .Malformed
		}
		argument := frame.payload[offset:offset+int(argument_size)]
		if contains_nul(string(argument)) {
			create_request_destroy(&decoded)
			return .Malformed
		}
		append(&decoded.arguments, strings.clone(string(argument)))
		offset += len(argument)
	}
	if offset == len(frame.payload) {
		request^ = decoded
		return .None
	}
	overrides, overrides_ok := read_u16(frame.payload[:], offset)
	if !overrides_ok || overrides == 0 || overrides & ~CREATE_OVERRIDE_MASK != 0 {
		create_request_destroy(&decoded)
		return .Malformed
	}
	offset += 2
	if overrides & CREATE_OVERRIDE_FONT_SIZE != 0 {
		font_size, ok := read_u16(frame.payload[:], offset)
		if !ok || font_size == 0 {create_request_destroy(&decoded); return .Malformed}
		decoded.override_font_size = true
		decoded.font_size = font_size
		offset += 2
	}
	if overrides & CREATE_OVERRIDE_RENDERER != 0 {
		if offset >= len(frame.payload) {create_request_destroy(&decoded); return .Malformed}
		renderer := Renderer_Override(frame.payload[offset])
		if renderer < .CPU || renderer > .Auto {create_request_destroy(&decoded); return .Malformed}
		decoded.override_renderer = true
		decoded.renderer = renderer
		offset += 1
	}
	if overrides & CREATE_OVERRIDE_LIGATURES != 0 {
		if offset >= len(frame.payload) || frame.payload[offset] > 1 {create_request_destroy(&decoded); return .Malformed}
		decoded.override_ligatures = true
		decoded.ligatures = frame.payload[offset] == 1
		offset += 1
	}
	if overrides & CREATE_OVERRIDE_TITLE != 0 {
		title_size, ok := read_u16(frame.payload[:], offset)
		if !ok || title_size == 0 || title_size > MAX_TITLE_BYTES {create_request_destroy(&decoded); return .Malformed}
		offset += 2
		if int(title_size) > len(frame.payload)-offset {create_request_destroy(&decoded); return .Malformed}
		title := string(frame.payload[offset:offset+int(title_size)])
		if contains_nul(title) {create_request_destroy(&decoded); return .Malformed}
		decoded.override_title = true
		decoded.title = strings.clone(title)
		offset += int(title_size)
	}
	if offset != len(frame.payload) {create_request_destroy(&decoded); return .Malformed}
	request^ = decoded
	return .None
}
