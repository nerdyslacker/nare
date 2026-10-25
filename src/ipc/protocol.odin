package ipc

import "core:strings"

MAGIC :: "NARE"
VERSION :: u16(1)
HEADER_SIZE :: 16
MAX_PAYLOAD_BYTES :: 128 * 1024
MAX_ARGUMENTS :: 256
MAX_STRING_BYTES :: 32 * 1024

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
	request^ = {}
}

append_u16 :: proc(output: ^[dynamic]byte, value: u16) {
	append(output, byte(value), byte(value >> 8))
}

append_u32 :: proc(output: ^[dynamic]byte, value: u32) {
	append(output, byte(value), byte(value >> 8), byte(value >> 16), byte(value >> 24))
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

decoder_feed :: proc(decoder: ^Decoder, data: []byte, frames: ^[dynamic]Frame) -> Error {
	if len(data) > HEADER_SIZE+MAX_PAYLOAD_BYTES || len(decoder.buffer) > HEADER_SIZE+MAX_PAYLOAD_BYTES-len(data) {
		return .Limit
	}
	append(&decoder.buffer, ..data)
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
	if offset != len(frame.payload) {
		create_request_destroy(&decoded)
		return .Malformed
	}
	request^ = decoded
	return .None
}
