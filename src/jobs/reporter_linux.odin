#+build linux

package jobs

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import ipc "../ipc"

MAX_REPORTER_CLIENTS :: 16
MAX_REPORT_PAYLOAD :: 1024
MAX_REPORTS_PER_SECOND :: 256
REPORT_TIMEOUT :: 2*time.Second
TOKEN_BYTES :: 16

Reporter_Client :: struct {
	connection: ipc.Connection,
	closed, close_after_flush: bool,
}

Reporter_Server :: struct {
	listener: ipc.Listener,
	clients: [dynamic]^Reporter_Client,
	registry: ^Registry,
	window: u64,
	token, path: string,
	enabled: bool,
	rate_started: time.Tick,
	rate_count: int,
}

Report_Error :: enum {
	None,
	Unavailable,
	Invalid_Environment,
	Invalid_Request,
	Rejected,
	Timeout,
	Transport,
}

report_error_string :: proc(err: Report_Error) -> string {
	switch err {
	case .None: return "none"
	case .Unavailable: return "no eligible nare window is available"
	case .Invalid_Environment: return "invalid nare job reporting environment"
	case .Invalid_Request: return "invalid job report"
	case .Rejected: return "job report was rejected"
	case .Timeout: return "job report timed out"
	case .Transport: return "job reporting connection failed"
	}
	return "job reporting failed"
}

reporter_open :: proc(server: ^Reporter_Server, registry: ^Registry, window: u64) -> bool {
	if server == nil || registry == nil || window == 0 do return false
	server^ = {listener = {fd = -1}}
	runtime := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	directory, directory_error := ipc.private_runtime_subdirectory(runtime, "nare")
	if directory_error != .None do return false
	defer delete(directory)
	path := fmt.aprintf("%s/jobs-%d-%d.sock", directory, posix.getpid(), window)
	listener, listener_error := ipc.listener_open(path)
	delete(path)
	if listener_error != .None do return false
	token, token_ok := reporter_token()
	if !token_ok {
		ipc.listener_close(&listener)
		return false
	}
	server^ = {
		listener = listener,
		registry = registry,
		window = window,
		token = token,
		path = strings.clone(listener.path),
		enabled = true,
	}
	return true
}

reporter_close :: proc(server: ^Reporter_Server) {
	if server == nil do return
	for client in server.clients {
		ipc.connection_destroy(&client.connection)
		free(client)
	}
	delete(server.clients)
	if server.enabled && server.listener.fd >= 0 do ipc.listener_close(&server.listener)
	delete(server.token)
	delete(server.path)
	server^ = {listener = {fd = -1}}
}

reporter_accept :: proc(server: ^Reporter_Server) {
	if server == nil || !server.enabled do return
	for len(server.clients) < MAX_REPORTER_CLIENTS {
		fd, accept_error := ipc.listener_accept(&server.listener)
		if accept_error == .Would_Block do return
		if accept_error == .Interrupted do continue
		if accept_error != .None do return
		client := new(Reporter_Client)
		ipc.connection_init(&client.connection, fd)
		append(&server.clients, client)
	}
}

reporter_client_events :: proc(client: ^Reporter_Client) -> posix.Poll_Event {
	events: posix.Poll_Event = {.IN}
	if client != nil && client.connection.pending_offset < len(client.connection.pending) do events += {.OUT}
	return events
}

reporter_client_poll :: proc(server: ^Reporter_Server, client: ^Reporter_Client, events: posix.Poll_Event) {
	if server == nil || client == nil || client.closed do return
	if .ERR in events || .NVAL in events do client.closed = true
	hangup := .HUP in events
	if !client.closed && .IN in events {
		frames: [dynamic]ipc.Frame
		read_error := ipc.connection_read(&client.connection, &frames)
		if len(frames) != 1 || !reporter_handle_frame(server, client, &frames[0]) do client.closed = true
		ipc.frames_destroy(&frames)
		if read_error != .None && read_error != .Would_Block do client.closed = true
	}
	if hangup && client.connection.pending_offset >= len(client.connection.pending) do client.closed = true
	if !client.closed && (.OUT in events || client.close_after_flush) {
		flush_error := ipc.connection_flush(&client.connection)
		if flush_error != .None && flush_error != .Would_Block do client.closed = true
		if client.close_after_flush && client.connection.pending_offset >= len(client.connection.pending) do client.closed = true
	}
}

reporter_cleanup :: proc(server: ^Reporter_Server) {
	if server == nil do return
	for index := len(server.clients)-1; index >= 0; index -= 1 {
		client := server.clients[index]
		if !client.closed do continue
		ipc.connection_destroy(&client.connection)
		free(client)
		ordered_remove(&server.clients, index)
	}
}

reporter_handle_frame :: proc(server: ^Reporter_Server, client: ^Reporter_Client, frame: ^ipc.Frame) -> bool {
	now := time.tick_now()
	if server.rate_started == {} || time.tick_diff(server.rate_started, now) >= time.Second {
		server.rate_started = now
		server.rate_count = 0
	}
	if server.rate_count >= MAX_REPORTS_PER_SECOND do return reporter_error(client, frame.request_id, "job report rate limit reached")
	server.rate_count += 1
	if len(frame.payload) > MAX_REPORT_PAYLOAD do return reporter_error(client, frame.request_id, "job report is too large")
	offset := 0
	token, token_ok := report_read_string(frame.payload[:], &offset, 64)
	reporter, reporter_ok := ipc.read_u64(frame.payload[:], offset)
	offset += 8
	external_id, id_ok := report_read_string(frame.payload[:], &offset, MAX_EXTERNAL_ID_BYTES)
	if !token_ok || !reporter_ok || !id_ok || token != server.token || reporter == 0 || !valid_external_id(external_id) {
		return reporter_error(client, frame.request_id, "invalid job identity")
	}
	job_id: u64
	#partial switch frame.kind {
	case .Job_Start:
		label, label_ok := report_read_string(frame.payload[:], &offset, MAX_LABEL_BYTES)
		pid_value, pid_ok := ipc.read_u32(frame.payload[:], offset)
		offset += 4
		if !label_ok || !pid_ok || offset != len(frame.payload) || !valid_display_text(label) || int(pid_value) < 0 {
			return reporter_error(client, frame.request_id, "invalid job start")
		}
		owner := Owner{window = server.window, pane = reporter}
		job_id = register_reported(server.registry, owner, reporter, external_id, label, int(pid_value))
		if job_id == 0 do return reporter_error(client, frame.request_id, "job already exists or registry is full")
	case .Job_Progress:
		percent, percent_ok := ipc.read_u16(frame.payload[:], offset)
		offset += 2
		message, message_ok := report_read_string(frame.payload[:], &offset, MAX_MESSAGE_BYTES)
		job := by_reporter_id(server.registry, reporter, external_id)
		if !percent_ok || !message_ok || offset != len(frame.payload) || percent > 100 || !valid_display_text(message) ||
		   job == nil || !set_progress(server.registry, job.id, int(percent), message) {
			return reporter_error(client, frame.request_id, "unknown or finished job")
		}
		job_id = job.id
	case .Job_Finish, .Job_Fail:
		exit_value, exit_ok := ipc.read_u32(frame.payload[:], offset)
		offset += 4
		signal_value, signal_ok := ipc.read_u32(frame.payload[:], offset)
		offset += 4
		job := by_reporter_id(server.registry, reporter, external_id)
		if !exit_ok || !signal_ok || offset != len(frame.payload) || exit_value > u32(max(i32)) ||
		   signal_value > u32(max(i32)) || job == nil {
			return reporter_error(client, frame.request_id, "unknown job")
		}
		exit_code := int(exit_value)
		if frame.kind == .Job_Fail && exit_code == 0 do exit_code = 1
		finish(server.registry, job.id, exit_code, int(signal_value))
		job_id = job.id
	case:
		return reporter_error(client, frame.request_id, "unexpected job message")
	}
	payload: [dynamic]byte
	defer delete(payload)
	ipc.append_u64(&payload, job_id)
	if ipc.connection_queue_frame(&client.connection, .Job_Ack, frame.request_id, payload[:]) != .None do return false
	client.close_after_flush = true
	return true
}

reporter_error :: proc(client: ^Reporter_Client, request_id: u32, message: string) -> bool {
	encoded: [dynamic]byte
	defer delete(encoded)
	if ipc.append_error(&encoded, request_id, .Invalid_Request, message) != .None ||
	   ipc.connection_queue_bytes(&client.connection, encoded[:]) != .None {
		return false
	}
	client.close_after_flush = true
	return true
}

report_start :: proc(path, token: string, reporter: u64, external_id, label: string, pid: int = 0) -> (u64, Report_Error) {
	if !valid_environment(path, token, reporter) || !valid_external_id(external_id) || !valid_display_text(label) ||
	   label == "" || len(label) > MAX_LABEL_BYTES || pid < 0 {
		return 0, .Invalid_Request
	}
	payload: [dynamic]byte
	defer delete(payload)
	report_append_identity(&payload, token, reporter, external_id)
	report_append_string(&payload, label)
	ipc.append_u32(&payload, u32(pid))
	return report_request(path, .Job_Start, payload[:])
}

report_progress :: proc(path, token: string, reporter: u64, external_id: string, percent: int, message: string = "") -> Report_Error {
	if !valid_environment(path, token, reporter) || !valid_external_id(external_id) || percent < 0 || percent > 100 ||
	   len(message) > MAX_MESSAGE_BYTES || !valid_display_text(message) {
		return .Invalid_Request
	}
	payload: [dynamic]byte
	defer delete(payload)
	report_append_identity(&payload, token, reporter, external_id)
	ipc.append_u16(&payload, u16(percent))
	report_append_string(&payload, message)
	_, err := report_request(path, .Job_Progress, payload[:])
	return err
}

report_finish :: proc(path, token: string, reporter: u64, external_id: string, exit_code: int, failed: bool = false, signal: int = 0) -> Report_Error {
	if !valid_environment(path, token, reporter) || !valid_external_id(external_id) || exit_code < 0 || exit_code > int(max(i32)) ||
	   signal < 0 || signal > int(max(i32)) {
		return .Invalid_Request
	}
	payload: [dynamic]byte
	defer delete(payload)
	report_append_identity(&payload, token, reporter, external_id)
	ipc.append_u32(&payload, u32(exit_code))
	ipc.append_u32(&payload, u32(signal))
	kind := ipc.Kind.Job_Fail if failed else ipc.Kind.Job_Finish
	_, err := report_request(path, kind, payload[:])
	return err
}

report_request :: proc(path: string, kind: ipc.Kind, payload: []byte) -> (u64, Report_Error) {
	fd, connect_error := ipc.connect_socket(path)
	if connect_error != .None do return 0, .Unavailable
	connection: ipc.Connection
	ipc.connection_init(&connection, fd)
	defer ipc.connection_destroy(&connection)
	request_id := u32(1)
	if ipc.connection_queue_frame(&connection, kind, request_id, payload) != .None do return 0, .Invalid_Request
	started := time.tick_now()
	for time.tick_since(started) < REPORT_TIMEOUT {
		events: posix.Poll_Event = {.IN}
		if connection.pending_offset < len(connection.pending) do events += {.OUT}
		poll_fd := posix.pollfd{fd = connection.fd, events = events}
		remaining := REPORT_TIMEOUT-time.tick_since(started)
		timeout_ms := max(1, int(remaining/time.Millisecond))
		result := posix.poll(&poll_fd, 1, i32(min(timeout_ms, 200)))
		if result < 0 {
			if posix.errno() == .EINTR do continue
			return 0, .Transport
		}
		if .OUT in poll_fd.revents {
			flush_error := ipc.connection_flush(&connection)
			if flush_error != .None && flush_error != .Would_Block do return 0, .Transport
		}
		if .IN in poll_fd.revents {
			frames: [dynamic]ipc.Frame
			read_error := ipc.connection_read(&connection, &frames)
			for &frame in frames {
				if frame.request_id != request_id do continue
				if frame.kind == .Job_Ack && len(frame.payload) == 8 {
					id, ok := ipc.read_u64(frame.payload[:], 0)
					ipc.frames_destroy(&frames)
					return id, .None if ok && id != 0 else .Rejected
				}
				if frame.kind == .Error {
					ipc.frames_destroy(&frames)
					return 0, .Rejected
				}
			}
			ipc.frames_destroy(&frames)
			if read_error != .None && read_error != .Would_Block do return 0, .Transport
		}
		if .ERR in poll_fd.revents || .NVAL in poll_fd.revents || .HUP in poll_fd.revents do return 0, .Transport
	}
	return 0, .Timeout
}

reporter_token :: proc() -> (string, bool) {
	path := strings.clone_to_cstring("/dev/urandom")
	fd := posix.open(path, {.CLOEXEC})
	delete(path)
	if fd < 0 do return "", false
	defer posix.close(fd)
	random: [TOKEN_BYTES]byte
	offset := 0
	for offset < len(random) {
		count := posix.read(fd, &random[offset], uint(len(random)-offset))
		if count < 0 && posix.errno() == .EINTR do continue
		if count <= 0 do return "", false
		offset += int(count)
	}
	hex := "0123456789abcdef"
	encoded := make([]byte, TOKEN_BYTES*2)
	for value, index in random {
		encoded[index*2] = hex[int(value>>4)]
		encoded[index*2+1] = hex[int(value&15)]
	}
	return string(encoded), true
}

report_append_identity :: proc(payload: ^[dynamic]byte, token: string, reporter: u64, external_id: string) {
	report_append_string(payload, token)
	ipc.append_u64(payload, reporter)
	report_append_string(payload, external_id)
}

report_append_string :: proc(payload: ^[dynamic]byte, value: string) {
	ipc.append_u16(payload, u16(len(value)))
	append(payload, ..transmute([]byte)value)
}

report_read_string :: proc(payload: []byte, offset: ^int, maximum: int) -> (string, bool) {
	size, ok := ipc.read_u16(payload, offset^)
	if !ok || int(size) > maximum || offset^+2+int(size) > len(payload) do return "", false
	offset^ += 2
	value := string(payload[offset^:offset^+int(size)])
	offset^ += int(size)
	return value, true
}

valid_environment :: proc(path, token: string, reporter: u64) -> bool {
	return path != "" && path[0] == '/' && len(path) < 108 && !ipc.contains_nul(path) &&
	       len(token) == TOKEN_BYTES*2 && valid_hex(token) && reporter != 0
}

valid_hex :: proc(value: string) -> bool {
	for octet in transmute([]byte)value do if !((octet >= '0' && octet <= '9') || (octet >= 'a' && octet <= 'f')) do return false
	return true
}

valid_external_id :: proc(value: string) -> bool {
	if value == "" || len(value) > MAX_EXTERNAL_ID_BYTES do return false
	for octet in transmute([]byte)value {
		if !((octet >= 'a' && octet <= 'z') || (octet >= 'A' && octet <= 'Z') ||
		   (octet >= '0' && octet <= '9') || octet == '_' || octet == '-' || octet == '.' || octet == ':') {
			return false
		}
	}
	return true
}

valid_display_text :: proc(value: string) -> bool {
	if ipc.contains_nul(value) do return false
	for octet in transmute([]byte)value do if octet < 0x20 || octet == 0x7f do return false
	return true
}
