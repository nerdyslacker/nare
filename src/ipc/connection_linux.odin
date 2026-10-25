#+build linux

package ipc

import "core:sys/posix"

MAX_PENDING_WRITE_BYTES :: 256 * 1024
MAX_FRAMES_PER_READ :: 256

IO_Error :: enum {
	None,
	Would_Block,
	Closed,
	Limit,
	Protocol,
	Read,
	Write,
}

Connection :: struct {
	fd: posix.FD,
	decoder: Decoder,
	pending: [dynamic]byte,
	pending_offset: int,
}

connection_init :: proc(connection: ^Connection, fd: posix.FD) {
	connection^ = {fd = fd}
}

connection_destroy :: proc(connection: ^Connection) {
	if connection.fd >= 0 do _ = posix.close(connection.fd)
	decoder_destroy(&connection.decoder)
	delete(connection.pending)
	connection^ = {fd = -1}
}

connection_compact :: proc(connection: ^Connection) {
	if connection.pending_offset == 0 do return
	remaining := len(connection.pending)-connection.pending_offset
	copy(connection.pending[:remaining], connection.pending[connection.pending_offset:])
	resize(&connection.pending, remaining)
	connection.pending_offset = 0
}

connection_queue_frame :: proc(
	connection: ^Connection,
	kind: Kind,
	request_id: u32,
	payload: []byte,
) -> IO_Error {
	if len(payload) > MAX_PAYLOAD_BYTES do return .Limit
	connection_compact(connection)
	if len(connection.pending) > MAX_PENDING_WRITE_BYTES-HEADER_SIZE-len(payload) do return .Limit
	if append_frame(&connection.pending, kind, request_id, payload) != .None do return .Limit
	return .None
}

connection_queue_bytes :: proc(connection: ^Connection, data: []byte) -> IO_Error {
	connection_compact(connection)
	if len(data) > MAX_PENDING_WRITE_BYTES-len(connection.pending) do return .Limit
	append(&connection.pending, ..data)
	return .None
}

connection_flush :: proc(connection: ^Connection) -> IO_Error {
	for connection.pending_offset < len(connection.pending) {
		data := connection.pending[connection.pending_offset:]
		count := posix.send(connection.fd, raw_data(data), len(data), {.NOSIGNAL})
		if count > 0 {
			connection.pending_offset += int(count)
			continue
		}
		if count == 0 do return .Closed
		#partial switch posix.errno() {
		case .EINTR: continue
		case .EAGAIN: return .Would_Block
		case: return .Write
		}
	}
	clear(&connection.pending)
	connection.pending_offset = 0
	return .None
}

connection_read :: proc(connection: ^Connection, frames: ^[dynamic]Frame) -> IO_Error {
	buffer: [16 * 1024]byte
	initial_count := len(frames^)
	for len(frames^)-initial_count < MAX_FRAMES_PER_READ {
		count := posix.recv(connection.fd, &buffer[0], len(buffer), {})
		if count > 0 {
			decode_error := decoder_feed(&connection.decoder, buffer[:int(count)], frames)
			if decode_error == .Limit do return .Limit
			if decode_error != .None do return .Protocol
			if len(frames^)-initial_count >= MAX_FRAMES_PER_READ do return .Limit
			continue
		}
		if count == 0 do return .Closed
		#partial switch posix.errno() {
		case .EINTR: continue
		case .EAGAIN:
			if len(frames^) == initial_count do return .Would_Block
			return .None
		case: return .Read
		}
	}
	return .Limit
}
