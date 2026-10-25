#+build linux

package quake

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"
import ipc "../ipc"
import x11 "../x11"
import xlib "vendor:x11/xlib"

State :: enum { Hidden, Showing, Visible, Hiding }
Command :: enum byte { Show = 1, Hide, Toggle, Focus }
Horizontal_Align :: enum { Left, Center, Right }
Animation :: enum { None, Slide, Fade }

Rect :: struct { x, y, width, height: int }

Options :: struct {
	monitor: string,
	width_percent, height_percent: int,
	horizontal_align: Horizontal_Align,
	x_offset, y_offset: int,
	hide_on_focus_loss: bool,
	animation: Animation,
	animation_duration_ms: int,
}

Controller :: struct {
	window: ^x11.Window,
	listener: ipc.Listener,
	clients: [dynamic]posix.FD,
	options: Options,
	state: State,
	focus_loss_pending: bool,
	focus_loss_at: time.Time,
	last_geometry_check: time.Time,
	geometry: Rect,
	animation_from_y, animation_to_y: int,
	animation_started: time.Time,
}

MAX_CLIENTS :: 32
FOCUS_LOSS_DELAY :: 180*time.Millisecond
GEOMETRY_CHECK_INTERVAL :: 1*time.Second

endpoint_path :: proc() -> (path: string, ok: bool) {
	display := os.get_env("DISPLAY", context.temp_allocator)
	if display == "" do display = ":0"
	hash: u64 = 14695981039346656037
	for octet in transmute([]byte)display { hash = (hash ~ u64(octet))*1099511628211 }
	name := fmt.aprintf("nare-quake-%d-%016x.sock", posix.geteuid(), hash)
	defer delete(name)
	runtime := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime != "" {
		probe, probe_error := ipc.runtime_socket_path(runtime)
		if probe_error == .None {
			delete(probe)
			separator := "" if runtime[len(runtime)-1] == '/' else "/"
			return fmt.aprintf("%s%s%s", runtime, separator, name), true
		}
	}
	return fmt.aprintf("/tmp/%s", name), true
}

send_command :: proc(command: Command) -> bool {
	path, ok := endpoint_path()
	defer if path != "" do delete(path)
	if !ok do return false
	fd, socket_error := ipc.connect_socket(path)
	if socket_error != .None do return false
	defer posix.close(fd)
	payload := [1]byte{byte(command)}
	for {
		written := posix.send(fd, &payload[0], 1, {.NOSIGNAL})
		if written == 1 do break
		if written < 0 && posix.errno() == .EINTR do continue
		if written < 0 && posix.errno() == .EAGAIN {
			poll_fd := posix.pollfd{fd = fd, events = {.OUT}}
			if posix.poll(&poll_fd, 1, 1000) <= 0 do return false
			continue
		}
		return false
	}
	poll_fd := posix.pollfd{fd = fd, events = {.IN}}
	if posix.poll(&poll_fd, 1, 1000) <= 0 do return false
	reply: byte
	return posix.recv(fd, &reply, 1, {}) == 1 && reply == 1
}

open :: proc(controller: ^Controller, window: ^x11.Window, options: Options, visible: bool) -> ipc.Socket_Error {
	path, ok := endpoint_path()
	defer if path != "" do delete(path)
	if !ok do return .Invalid_Path
	listener, socket_error := ipc.listener_open(path)
	if socket_error != .None do return socket_error
	controller^ = {
		window = window, listener = listener, options = options,
		state = .Hidden,
	}
	controller.geometry = monitor_geometry(window, options)
	x11.configure_top_level(window, controller.geometry.x, controller.geometry.y, controller.geometry.width, controller.geometry.height)
	if visible do request(controller, .Show)
	return .None
}

close :: proc(controller: ^Controller) {
	for fd in controller.clients do _ = posix.close(fd)
	delete(controller.clients)
	ipc.listener_close(&controller.listener)
	controller^ = {listener = {fd = -1}}
}

poll_fd :: proc(controller: ^Controller) -> posix.FD {
	if controller == nil do return -1
	return controller.listener.fd
}

request :: proc(controller: ^Controller, command: Command, take_focus: bool = true) {
	if controller == nil || controller.window == nil do return
	switch command {
	case .Show, .Focus:
		controller.geometry = monitor_geometry(controller.window, controller.options)
		if slide_enabled(controller) {
			from_y := controller.window.y
			if controller.state == .Hidden do from_y = controller.geometry.y-controller.geometry.height
			controller.animation_from_y = from_y
			controller.animation_to_y = controller.geometry.y
			controller.animation_started = time.now()
			controller.state = .Showing
			x11.configure_top_level(controller.window, controller.geometry.x, from_y, controller.geometry.width, controller.geometry.height)
			x11.show_top_level(controller.window, take_focus)
		} else {
			x11.configure_top_level(controller.window, controller.geometry.x, controller.geometry.y, controller.geometry.width, controller.geometry.height)
			x11.show_top_level(controller.window, take_focus)
			controller.state = .Visible
		}
		controller.focus_loss_pending = false
	case .Hide:
		if controller.state == .Hidden do return
		if slide_enabled(controller) {
			controller.animation_from_y = controller.window.y
			controller.animation_to_y = controller.geometry.y-controller.geometry.height
			controller.animation_started = time.now()
			controller.state = .Hiding
		} else {
			x11.hide_top_level(controller.window)
			controller.state = .Hidden
		}
		controller.focus_loss_pending = false
	case .Toggle:
		if next_state(controller.state, command) == .Visible do request(controller, .Show, take_focus)
		else do request(controller, .Hide, take_focus)
	}
}

next_state :: proc(state: State, command: Command) -> State {
	switch command {
	case .Show, .Focus: return .Visible
	case .Hide: return .Hidden
	case .Toggle:
		if state == .Hidden || state == .Hiding do return .Visible
		return .Hidden
	}
	return state
}

note_focus :: proc(controller: ^Controller, focused: bool) {
	if controller == nil || !controller.options.hide_on_focus_loss || controller.state != .Visible do return
	if focused {
		controller.focus_loss_pending = false
	} else {
		controller.focus_loss_pending = true
		controller.focus_loss_at = time.now()
	}
}

service :: proc(controller: ^Controller) -> bool {
	if controller == nil do return true
	for len(controller.clients) < MAX_CLIENTS {
		fd, accept_error := ipc.listener_accept(&controller.listener)
		if accept_error == .Would_Block do break
		if accept_error == .Interrupted do continue
		if accept_error != .None do break
		append(&controller.clients, fd)
	}
	for index := len(controller.clients)-1; index >= 0; index -= 1 {
		fd := controller.clients[index]
		command_byte: byte
		count := posix.recv(fd, &command_byte, 1, {})
		if count < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) do continue
		valid := count == 1 && command_byte >= byte(Command.Show) && command_byte <= byte(Command.Focus)
		if valid do request(controller, Command(command_byte))
		reply := byte(1 if valid else 0)
		_ = posix.send(fd, &reply, 1, {.NOSIGNAL})
		_ = posix.close(fd)
		unordered_remove(&controller.clients, index)
	}
	service_animation(controller)
	if controller.state == .Visible && time.since(controller.last_geometry_check) >= GEOMETRY_CHECK_INTERVAL {
		controller.last_geometry_check = time.now()
		geometry := monitor_geometry(controller.window, controller.options)
		if geometry != controller.geometry {
			controller.geometry = geometry
			x11.configure_top_level(controller.window, geometry.x, geometry.y, geometry.width, geometry.height)
		}
	}
	if controller.focus_loss_pending && time.since(controller.focus_loss_at) >= FOCUS_LOSS_DELAY {
		if x11.focus_within(controller.window) {
			controller.focus_loss_pending = false
		} else if !x11.pointer_button_down(controller.window) {
			request(controller, .Hide)
		}
	}
	return true
}

slide_enabled :: proc(controller: ^Controller) -> bool {
	return controller.options.animation == .Slide && controller.options.animation_duration_ms > 0
}

animation_position :: proc(from, to, elapsed_ms, duration_ms: int) -> int {
	if duration_ms <= 0 || elapsed_ms >= duration_ms do return to
	if elapsed_ms <= 0 do return from
	return from+(to-from)*elapsed_ms/duration_ms
}

service_animation :: proc(controller: ^Controller) {
	if controller.state != .Showing && controller.state != .Hiding do return
	elapsed_ms := int(time.since(controller.animation_started)/time.Millisecond)
	y := animation_position(controller.animation_from_y, controller.animation_to_y, elapsed_ms, controller.options.animation_duration_ms)
	x11.configure_top_level(controller.window, controller.geometry.x, y, controller.geometry.width, controller.geometry.height)
	if elapsed_ms < controller.options.animation_duration_ms do return
	if controller.state == .Showing {
		controller.state = .Visible
	} else {
		x11.hide_top_level(controller.window)
		controller.state = .Hidden
	}
}

poll_timeout_ms :: proc(controller: ^Controller, fallback: int = 50) -> int {
	if controller != nil && (controller.state == .Showing || controller.state == .Hiding) do return min(fallback, 16)
	return fallback
}

calculate_geometry :: proc(area: Rect, width_percent, height_percent: int, alignment: Horizontal_Align, x_offset, y_offset: int) -> Rect {
	if area.width <= 0 || area.height <= 0 do return {width = 1, height = 1}
	width := clamp(area.width*clamp(width_percent, 10, 100)/100, 1, area.width)
	height := clamp(area.height*clamp(height_percent, 10, 100)/100, 1, area.height)
	x := area.x
	switch alignment {
	case .Left:
	case .Center: x += (area.width-width)/2
	case .Right: x += area.width-width
	}
	x = clamp(x+x_offset, area.x, area.x+area.width-width)
	y := clamp(area.y+y_offset, area.y, area.y+area.height-height)
	return {x = x, y = y, width = width, height = height}
}

monitor_geometry :: proc(window: ^x11.Window, options: Options) -> Rect {
	area := selected_monitor(window, options.monitor)
	area = usable_area(window, area)
	return calculate_geometry(area, options.width_percent, options.height_percent, options.horizontal_align, options.x_offset, options.y_offset)
}

selected_monitor :: proc(window: ^x11.Window, selector: string) -> Rect {
	screen := xlib.DefaultScreen(window.display)
	root := xlib.RootWindow(window.display, screen)
	fallback := Rect{width = int(xlib.DisplayWidth(window.display, screen)), height = int(xlib.DisplayHeight(window.display, screen))}
	resources := xlib.XRRGetScreenResources(window.display, root)
	if resources == nil do return fallback
	defer xlib.XRRFreeScreenResources(resources)
	pointer_x, pointer_y: i32
	root_return, child: xlib.Window
	local_x, local_y: i32
	mask: xlib.KeyMask
	_ = xlib.QueryPointer(window.display, root, &root_return, &child, &pointer_x, &pointer_y, &local_x, &local_y, &mask)
	focused: xlib.Window
	revert: xlib.FocusRevert
	xlib.GetInputFocus(window.display, &focused, &revert)
	attributes: xlib.XWindowAttributes
	focus_x, focus_y: i32
	translated_child: xlib.Window
	if focused != 0 && xlib.GetWindowAttributes(window.display, focused, &attributes) != 0 &&
	   xlib.TranslateCoordinates(window.display, focused, root, 0, 0, &focus_x, &focus_y, &translated_child) {
		pointer_x = focus_x+i32(attributes.width/2)
		pointer_y = focus_y+i32(attributes.height/2)
	}
	first: Rect
	primary: Rect
	for output_index in 0..<int(resources.noutput) {
		info := xlib.XRRGetOutputInfo(window.display, resources, resources.outputs[output_index])
		if info == nil do continue
		if info.connection != .RR_Connected || info.crtc == 0 {
			xlib.XRRFreeOutputInfo(info)
			continue
		}
		crtc := xlib.XRRGetCrtcInfo(window.display, resources, info.crtc)
		if crtc == nil { xlib.XRRFreeOutputInfo(info); continue }
		rect := Rect{x = int(crtc.x), y = int(crtc.y), width = int(crtc.width), height = int(crtc.height)}
		name := string(info.name)
		if first.width == 0 do first = rect
		if selector == name {
			xlib.XRRFreeCrtcInfo(crtc); xlib.XRRFreeOutputInfo(info)
			return rect
		}
		if selector == "focused" && int(pointer_x) >= rect.x && int(pointer_x) < rect.x+rect.width && int(pointer_y) >= rect.y && int(pointer_y) < rect.y+rect.height {
			xlib.XRRFreeCrtcInfo(crtc); xlib.XRRFreeOutputInfo(info)
			return rect
		}
		xlib.XRRFreeCrtcInfo(crtc)
		xlib.XRRFreeOutputInfo(info)
	}
	monitor_count: i32
	monitors := xlib.XRRGetMonitors(window.display, root, true, &monitor_count)
	if monitors != nil {
		for index in 0..<int(monitor_count) {
			if monitors[index].primary {
				primary = {x = int(monitors[index].x), y = int(monitors[index].y), width = int(monitors[index].width), height = int(monitors[index].height)}
				break
			}
		}
		xlib.Free(monitors)
	}
	if primary.width > 0 do return primary
	if first.width > 0 do return first
	return fallback
}

usable_area :: proc(window: ^x11.Window, monitor: Rect) -> Rect {
	screen := xlib.DefaultScreen(window.display)
	root := xlib.RootWindow(window.display, screen)
	workarea_atom := xlib.InternAtom(window.display, "_NET_WORKAREA", true)
	desktop_atom := xlib.InternAtom(window.display, "_NET_CURRENT_DESKTOP", true)
	if workarea_atom == 0 do return monitor
	desktop := uint(0)
	if desktop_atom != 0 {
		actual: xlib.Atom; format: i32; count, after: uint; data: rawptr
		if xlib.GetWindowProperty(window.display, root, desktop_atom, 0, 1, false, xlib.XA_CARDINAL, &actual, &format, &count, &after, &data) == 0 && data != nil {
			if format == 32 && count == 1 do desktop = ([^]uint)(data)[0]
			xlib.Free(data)
		}
	}
	actual: xlib.Atom; format: i32; count, after: uint; data: rawptr
	offset := int(desktop)*4
	if xlib.GetWindowProperty(window.display, root, workarea_atom, int(offset), 4, false, xlib.XA_CARDINAL, &actual, &format, &count, &after, &data) != 0 || data == nil do return monitor
	defer xlib.Free(data)
	if format != 32 || count < 4 do return monitor
	values := ([^]uint)(data)
	work := Rect{x = int(values[0]), y = int(values[1]), width = int(values[2]), height = int(values[3])}
	x1, y1 := max(monitor.x, work.x), max(monitor.y, work.y)
	x2, y2 := min(monitor.x+monitor.width, work.x+work.width), min(monitor.y+monitor.height, work.y+work.height)
	if x2 <= x1 || y2 <= y1 do return monitor
	return {x = x1, y = y1, width = x2-x1, height = y2-y1}
}
