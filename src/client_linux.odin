#+build linux

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import config "config"
import ipc "ipc"

client_connect :: proc(socket_path: string) -> (posix.FD, ipc.Socket_Error) {
	if socket_path != "" do return ipc.connect_socket(socket_path)
	runtime_directory := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	path, path_error := ipc.runtime_socket_path(runtime_directory)
	if path_error != .None do return -1, path_error
	defer delete(path)
	return ipc.connect_socket(path)
}

client_apply_overrides :: proc(request: ^ipc.Create_Request, settings: ^config.Settings, arguments: []string) {
	for argument in arguments {
		if argument == "-e" do break
		if strings.has_prefix(argument, "--font-size=") {
			request.override_font_size = true
			request.font_size = u16(settings.font_size)
		} else if strings.has_prefix(argument, "--renderer=") {
			request.override_renderer = true
			switch settings.renderer {
			case .CPU: request.renderer = .CPU
			case .GPU: request.renderer = .GPU
			case .Auto: request.renderer = .Auto
			}
		} else if strings.has_prefix(argument, "--ligatures=") {
			request.override_ligatures = true
			request.ligatures = settings.ligatures
		} else if strings.has_prefix(argument, "--title=") {
			request.override_title = true
			request.title = settings.title
		}
	}
}

client_run :: proc(command: []cstring, settings: ^config.Settings, arguments: []string, socket_path: string, wait: bool) -> int {
	fd, connect_error := client_connect(socket_path)
	if connect_error != .None {
		fmt.eprintf("could not connect to server: %v\n", connect_error)
		return 1
	}
	connection: ipc.Connection
	ipc.connection_init(&connection, fd)
	defer ipc.connection_destroy(&connection)
	directory := settings.working_directory
	if directory == "" {
		current_directory, directory_error := os.getwd(context.temp_allocator)
		if directory_error != nil {
			fmt.eprintln("could not determine client working directory")
			return 1
		}
		directory = current_directory
	}
	request := ipc.Create_Request{wait = wait, working_directory = directory}
	client_apply_overrides(&request, settings, arguments)
	for argument in command {
		if argument == nil do break
		append(&request.arguments, string(argument))
	}
	defer delete(request.arguments)
	encoded: [dynamic]byte
	defer delete(encoded)
	if ipc.encode_create(&request, 1, &encoded) != .None ||
	   ipc.connection_queue_bytes(&connection, encoded[:]) != .None {
		fmt.eprintln("could not encode server request")
		return 1
	}
	created := false
	for {
		events: posix.Poll_Event = {.IN}
		if connection.pending_offset < len(connection.pending) do events += {.OUT}
		poll_fd := posix.pollfd{fd = connection.fd, events = events}
		if posix.poll(&poll_fd, 1, -1) < 0 {
			if posix.errno() == .EINTR do continue
			return 1
		}
		if .ERR in poll_fd.revents || .NVAL in poll_fd.revents {
			fmt.eprintln("server disconnected")
			return 1
		}
		hangup := .HUP in poll_fd.revents
		if .OUT in poll_fd.revents {
			flush_error := ipc.connection_flush(&connection)
			if flush_error != .None && flush_error != .Would_Block do return 1
		}
		if .IN in poll_fd.revents {
			frames: [dynamic]ipc.Frame
			read_error := ipc.connection_read(&connection, &frames)
			for &frame in frames {
				if frame.request_id != 1 do continue
				#partial switch frame.kind {
				case .Created:
					_, response_error := ipc.decode_created(&frame)
					if response_error != .None {
						ipc.frames_destroy(&frames)
						return 1
					}
					created = true
					if !wait {
						ipc.frames_destroy(&frames)
						return 0
					}
				case .Exit:
					status, response_error := ipc.decode_exit(&frame)
					ipc.frames_destroy(&frames)
					if response_error != .None || !created do return 1
					return clamp(int(status), 0, 255)
				case .Error:
					remote_error: ipc.Remote_Error
					response_error := ipc.decode_error(&frame, &remote_error)
					if response_error == .None {
						fmt.eprintln(remote_error.message)
						ipc.remote_error_destroy(&remote_error)
					}
					ipc.frames_destroy(&frames)
					return 1
				case:
				}
			}
			ipc.frames_destroy(&frames)
			if read_error != .None && read_error != .Would_Block do return 1
		}
		if hangup {
			fmt.eprintln("server disconnected")
			return 1
		}
	}
}
