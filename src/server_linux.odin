#+build linux

package main

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import config "config"
import ipc "ipc"
import drawing "render"
import x11 "x11"

MAX_SERVER_CLIENTS :: 64
MAX_SERVER_WINDOWS :: 64

server_stop_requested: c.int

server_stop_handler :: proc "c"(_: posix.Signal) {
	intrinsics.volatile_store(&server_stop_requested, 1)
}

Server_Client :: struct {
	connection: ipc.Connection,
	window: ^Server_Window,
	request_id: u32,
	close_after_flush: bool,
	closed: bool,
}

Server_Window :: struct {
	root: x11.Window,
	workspace: Workspace,
	command: [dynamic]cstring,
	client: ^Server_Client,
	request_id: u32,
	session_id: u64,
}

Server :: struct {
	listener: ipc.Listener,
	settings: ^config.Settings,
	clients: [dynamic]^Server_Client,
	windows: [dynamic]^Server_Window,
	font_cache: Workspace_Font_Cache,
	next_session_id: u64,
}

Server_Poll_Kind :: enum { Listener, Client, Workspace }

Server_Poll_Target :: struct {
	kind: Server_Poll_Kind,
	client: ^Server_Client,
	workspace: Workspace_Poll_Target,
}

server_queue_created :: proc(client: ^Server_Client, request_id: u32, session_id: u64) -> bool {
	encoded: [dynamic]byte
	defer delete(encoded)
	return ipc.append_created(&encoded, request_id, session_id) == .None &&
	       ipc.connection_queue_bytes(&client.connection, encoded[:]) == .None
}

server_queue_exit :: proc(client: ^Server_Client, request_id: u32, status: int) -> bool {
	encoded: [dynamic]byte
	defer delete(encoded)
	return ipc.append_exit(&encoded, request_id, i32(clamp(status, int(min(i32)), int(max(i32))))) == .None &&
	       ipc.connection_queue_bytes(&client.connection, encoded[:]) == .None
}

server_queue_error :: proc(client: ^Server_Client, request_id: u32, code: ipc.Remote_Error_Code, message: string) -> bool {
	encoded: [dynamic]byte
	defer delete(encoded)
	return ipc.append_error(&encoded, request_id, code, message) == .None &&
	       ipc.connection_queue_bytes(&client.connection, encoded[:]) == .None
}

server_window_destroy :: proc(window: ^Server_Window) {
	if window == nil do return
	if window.client != nil {
		window.client.window = nil
		window.client = nil
	}
	workspace_destroy(&window.workspace)
	x11.close(&window.root)
	command_destroy(&window.command)
	free(window)
}

server_client_destroy :: proc(client: ^Server_Client) {
	if client == nil do return
	if client.window != nil do client.window.client = nil
	ipc.connection_destroy(&client.connection)
	free(client)
}

server_destroy :: proc(server: ^Server) {
	for window in server.windows do server_window_destroy(window)
	for client in server.clients do server_client_destroy(client)
	delete(server.windows)
	delete(server.clients)
	workspace_font_cache_destroy(&server.font_cache)
	ipc.listener_close(&server.listener)
	server^ = {}
}

server_workspace_overrides :: proc(request: ^ipc.Create_Request) -> (overrides: Workspace_Overrides, ok: bool) {
	ok = true
	if request.override_font_size {
		if request.font_size < config.MIN_FONT_SIZE || request.font_size > config.MAX_FONT_SIZE do return overrides, false
		overrides.override_font_size = true
		overrides.font_size = int(request.font_size)
	}
	if request.override_renderer {
		overrides.override_renderer = true
		switch request.renderer {
		case .CPU: overrides.renderer = .CPU
		case .GPU: overrides.renderer = .GPU
		case .Auto: overrides.renderer = .Auto
		case: return overrides, false
		}
	}
	if request.override_ligatures {
		overrides.override_ligatures = true
		overrides.ligatures = request.ligatures
	}
	if request.override_title {
		overrides.override_title = true
		overrides.title = request.title
	}
	if request.ssh_host != "" {
		if !config.valid_tmux_name(request.ssh_host) do return overrides, false
		overrides.remote_host = request.ssh_host
	}
	return
}

server_launch_window :: proc(server: ^Server, client: ^Server_Client, frame: ^ipc.Frame) -> bool {
	if client.window != nil || len(server.windows) >= MAX_SERVER_WINDOWS {
		return server_queue_error(client, frame.request_id, .Server_Busy, "server window limit reached")
	}
	request: ipc.Create_Request
	defer ipc.create_request_destroy(&request)
	if ipc.decode_create(frame, &request) != .None {
		return server_queue_error(client, frame.request_id, .Invalid_Request, "invalid create request")
	}
	overrides, overrides_ok := server_workspace_overrides(&request)
	if !overrides_ok {
		return server_queue_error(client, frame.request_id, .Invalid_Request, "invalid create overrides")
	}
	window := new(Server_Window)
	for argument in request.arguments do append(&window.command, strings.clone_to_cstring(argument))
	append(&window.command, nil)
	title_value := overrides.title if overrides.override_title else server.settings.title
	title := strings.clone_to_cstring(title_value)
	root, window_error := x11.open(title, false)
	delete(title)
	if window_error != .None {
		command_destroy(&window.command)
		free(window)
		return server_queue_error(client, frame.request_id, .Launch_Failed, x11.error_string(window_error))
	}
	window.root = root
	x11.set_opacity(&window.root, server.settings.window.background_opacity)
	x11.set_decorations(&window.root, server.settings.window.decorations)
	x11.map_and_settle(&window.root)
	if !workspace_init(&window.workspace, &window.root, window.command[:], server.settings, request.working_directory, &server.font_cache, overrides) {
		x11.close(&window.root)
		command_destroy(&window.command)
		free(window)
		return server_queue_error(client, frame.request_id, .Launch_Failed, "could not create terminal session")
	}
	server.next_session_id += 1
	if server.next_session_id == 0 do server.next_session_id = 1
	window.session_id = server.next_session_id
	window.request_id = frame.request_id
	append(&server.windows, window)
	if !server_queue_created(client, frame.request_id, window.session_id) {
		ordered_remove(&server.windows, len(server.windows)-1)
		server_window_destroy(window)
		return false
	}
	client.request_id = frame.request_id
	if request.wait {
		client.window = window
		window.client = client
	} else {
		client.close_after_flush = true
	}
	return true
}

server_handle_frame :: proc(server: ^Server, client: ^Server_Client, frame: ^ipc.Frame) -> bool {
	#partial switch frame.kind {
	case .Ping:
		return ipc.connection_queue_frame(&client.connection, .Pong, frame.request_id, nil) == .None
	case .Create:
		if client.request_id != 0 {
			return server_queue_error(client, frame.request_id, .Invalid_Request, "client already created a session")
		}
		return server_launch_window(server, client, frame)
	case:
		return server_queue_error(client, frame.request_id, .Invalid_Request, "unexpected client message")
	}
}

server_accept_clients :: proc(server: ^Server) {
	for len(server.clients) < MAX_SERVER_CLIENTS {
		fd, accept_error := ipc.listener_accept(&server.listener)
		if accept_error == .Would_Block do return
		if accept_error == .Interrupted do continue
		if accept_error != .None do return
		client := new(Server_Client)
		ipc.connection_init(&client.connection, fd)
		append(&server.clients, client)
	}
}

server_client_poll :: proc(server: ^Server, client: ^Server_Client, events: posix.Poll_Event) {
	if .ERR in events || .NVAL in events do client.closed = true
	hangup := .HUP in events
	if !client.closed && .IN in events {
		frames: [dynamic]ipc.Frame
		read_error := ipc.connection_read(&client.connection, &frames)
		for &frame in frames {
			if !server_handle_frame(server, client, &frame) {
				client.closed = true
				break
			}
		}
		ipc.frames_destroy(&frames)
		if read_error != .None && read_error != .Would_Block do client.closed = true
	}
	if hangup do client.closed = true
	if !client.closed && (.OUT in events || client.close_after_flush) {
		flush_error := ipc.connection_flush(&client.connection)
		if flush_error != .None && flush_error != .Would_Block do client.closed = true
		if client.close_after_flush && client.connection.pending_offset >= len(client.connection.pending) do client.closed = true
	}
}

server_close_finished_windows :: proc(server: ^Server) {
	for index := len(server.windows)-1; index >= 0; index -= 1 {
		window := server.windows[index]
		if workspace_service(&window.workspace) do continue
		if window.client != nil {
			client := window.client
			window.client = nil
			client.window = nil
			if server_queue_exit(client, window.request_id, workspace_exit_status(&window.workspace)) {
				client.close_after_flush = true
			} else {
				client.closed = true
			}
		}
		server_window_destroy(window)
		ordered_remove(&server.windows, index)
	}
}

server_cleanup_disconnected :: proc(server: ^Server) {
	for index := len(server.windows)-1; index >= 0; index -= 1 {
		window := server.windows[index]
		if window.client == nil || !window.client.closed do continue
		server_window_destroy(window)
		ordered_remove(&server.windows, index)
	}
	for index := len(server.clients)-1; index >= 0; index -= 1 {
		client := server.clients[index]
		if !client.closed || client.window != nil do continue
		server_client_destroy(client)
		ordered_remove(&server.clients, index)
	}
}

server_run :: proc(settings: ^config.Settings, socket_path: string = "") -> int {
	listener: ipc.Listener
	listen_error: ipc.Socket_Error
	if socket_path != "" {
		listener, listen_error = ipc.listener_open(socket_path)
	} else {
		runtime_directory := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		listener, listen_error = ipc.listener_open_runtime(runtime_directory)
	}
	if listen_error != .None {
		fmt.eprintf("could not start server: %v\n", listen_error)
		return 1
	}
	server := Server{listener = listener, settings = settings}
	defer server_destroy(&server)
	intrinsics.volatile_store(&server_stop_requested, 0)
	previous_interrupt := posix.signal(.SIGINT, server_stop_handler)
	previous_terminate := posix.signal(.SIGTERM, server_stop_handler)
	defer posix.signal(.SIGINT, previous_interrupt)
	defer posix.signal(.SIGTERM, previous_terminate)
	drawing.set_theme(settings.theme)
	drawing.set_bold_is_bright(settings.bold_is_bright)
	fds: [dynamic]posix.pollfd
	targets: [dynamic]Server_Poll_Target
	workspace_fds: [dynamic]posix.pollfd
	workspace_targets: [dynamic]Workspace_Poll_Target
	defer {
		delete(fds)
		delete(targets)
		delete(workspace_fds)
		delete(workspace_targets)
	}
	for intrinsics.volatile_load(&server_stop_requested) == 0 {
		server_close_finished_windows(&server)
		server_cleanup_disconnected(&server)
		clear(&fds)
		clear(&targets)
		append(&fds, {fd = server.listener.fd, events = {.IN}})
		append(&targets, {kind = .Listener})
		for client in server.clients {
			events: posix.Poll_Event = {.IN}
			if client.connection.pending_offset < len(client.connection.pending) do events += {.OUT}
			append(&fds, {fd = client.connection.fd, events = events})
			append(&targets, {kind = .Client, client = client})
		}
		for window in server.windows {
			clear(&workspace_fds)
			clear(&workspace_targets)
			workspace_append_poll(&window.workspace, &workspace_fds, &workspace_targets)
			for index in 0..<len(workspace_fds) {
				append(&fds, workspace_fds[index])
				append(&targets, {kind = .Workspace, workspace = workspace_targets[index]})
			}
		}
		if posix.poll(raw_data(fds), u64(len(fds)), 50) < 0 {
			if posix.errno() == .EINTR do continue
			return 1
		}
		for index in 0..<len(fds) do if targets[index].kind == .Workspace {
			workspace_dispatch_poll(targets[index].workspace, fds[index].revents)
		}
		for window in server.windows do workspace_finish_cycle(&window.workspace)
		for index in 0..<len(fds) do if targets[index].kind == .Client {
			server_client_poll(&server, targets[index].client, fds[index].revents)
		}
		if .IN in fds[0].revents do server_accept_clients(&server)
	}
	return 0
}
