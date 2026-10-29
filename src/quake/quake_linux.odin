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

Strut_Partial :: struct {
	left, right, top, bottom: int,
	left_start_y, left_end_y: int,
	right_start_y, right_end_y: int,
	top_start_x, top_end_x: int,
	bottom_start_x, bottom_end_x: int,
}

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
	restore_focus_pending: bool,
	last_service: time.Tick,
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
		state = .Hidden, last_service = time.tick_now(),
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
	controller^ = {listener = {fd = -1, lock_fd = -1}}
}

poll_fd :: proc(controller: ^Controller) -> posix.FD {
	if controller == nil do return -1
	return controller.listener.fd
}

request :: proc(controller: ^Controller, command: Command, take_focus: bool = true) {
	if controller == nil || controller.window == nil do return
	switch command {
	case .Show, .Focus:
		// "focused" means the pointer's monitor when a hidden quake window is
		// opened. Once visible, focus/show requests must not make it follow the
		// pointer to another output.
		if controller.state == .Visible || controller.state == .Showing {
			x11.show_top_level(controller.window, take_focus)
			controller.focus_loss_pending = false
			if take_focus do controller.restore_focus_pending = false
			return
		}
		controller.geometry = monitor_geometry(controller.window, controller.options)
		if slide_enabled(controller) {
			from_y := controller.window.y
			if controller.state == .Hidden do from_y = controller.geometry.y-controller.geometry.height
			controller.animation_from_y = from_y
			controller.animation_to_y = controller.geometry.y
			controller.animation_started = time.now()
			controller.state = .Showing
			x11.configure_top_level(controller.window, controller.geometry.x, from_y, controller.geometry.width, controller.geometry.height)
			apply_animation_clip(controller, from_y)
			x11.show_top_level(controller.window, take_focus)
		} else {
			x11.clear_top_level_clip(controller.window)
			x11.configure_top_level(controller.window, controller.geometry.x, controller.geometry.y, controller.geometry.width, controller.geometry.height)
			x11.show_top_level(controller.window, take_focus)
			controller.state = .Visible
		}
		controller.focus_loss_pending = false
		if take_focus do controller.restore_focus_pending = false
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
		controller.restore_focus_pending = false
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
	if controller == nil || controller.state != .Visible do return
	if focused {
		controller.focus_loss_pending = false
		controller.restore_focus_pending = false
	} else {
		controller.focus_loss_pending = true
		controller.focus_loss_at = time.now()
	}
}

service :: proc(controller: ^Controller) -> bool {
	if controller == nil do return true
	resumed := controller.last_service != {} && time.tick_since(controller.last_service) >= 2*time.Second
	controller.last_service = time.tick_now()
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
	if controller.state == .Visible && controller.options.monitor != "focused" && time.since(controller.last_geometry_check) >= GEOMETRY_CHECK_INTERVAL {
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
			if controller.options.hide_on_focus_loss do request(controller, .Hide)
			else if x11.focused_window_is_override_redirect(controller.window) {
				x11.lower_top_level(controller.window)
				controller.restore_focus_pending = true
			}
			controller.focus_loss_pending = false
		}
	}
	if resumed && controller.state == .Visible && !x11.focus_within(controller.window) {
		controller.restore_focus_pending = true
	}
	if controller.restore_focus_pending && controller.state == .Visible &&
	   !x11.focused_window_is_override_redirect(controller.window) {
		controller.restore_focus_pending = false
		x11.show_top_level(controller.window, true)
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
	apply_animation_clip(controller, y)
	if elapsed_ms < controller.options.animation_duration_ms do return
	if controller.state == .Showing {
		x11.clear_top_level_clip(controller.window)
		controller.state = .Visible
	} else {
		x11.hide_top_level(controller.window)
		x11.clear_top_level_clip(controller.window)
		controller.state = .Hidden
	}
}

animation_clip :: proc(geometry: Rect, window_y: int) -> (top, height: int) {
	top = clamp(geometry.y-window_y, 0, geometry.height)
	bottom := clamp(geometry.y+geometry.height-window_y, 0, geometry.height)
	return top, max(0, bottom-top)
}

apply_animation_clip :: proc(controller: ^Controller, window_y: int) {
	top, height := animation_clip(controller.geometry, window_y)
	_ = x11.set_top_level_clip(controller.window, 0, top, controller.geometry.width, height)
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
	pointer_known := xlib.QueryPointer(window.display, root, &root_return, &child, &pointer_x, &pointer_y, &local_x, &local_y, &mask)
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
		if selector == "focused" && pointer_known && int(pointer_x) >= rect.x && int(pointer_x) < rect.x+rect.width && int(pointer_y) >= rect.y && int(pointer_y) < rect.y+rect.height {
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
	previous_handler := xlib.SetErrorHandler(ignore_work_area_query_error)
	defer {
		_ = xlib.Sync(window.display, false)
		_ = xlib.SetErrorHandler(previous_handler)
	}
	strut_atom := xlib.InternAtom(window.display, "_NET_WM_STRUT_PARTIAL", true)
	legacy_strut_atom := xlib.InternAtom(window.display, "_NET_WM_STRUT", true)
	type_atom := xlib.InternAtom(window.display, "_NET_WM_WINDOW_TYPE", true)
	dock_atom := xlib.InternAtom(window.display, "_NET_WM_WINDOW_TYPE_DOCK", true)
	clients_atom := xlib.InternAtom(window.display, "_NET_CLIENT_LIST", true)
	root_geometry := Rect{
		width = int(xlib.DisplayWidth(window.display, screen)),
		height = int(xlib.DisplayHeight(window.display, screen)),
	}
	area, found := collect_work_area_reservations(
		window.display, root, root, monitor, monitor, root_geometry,
		strut_atom, legacy_strut_atom, type_atom, dock_atom, 0,
	)
	client_found: bool
	area, client_found = collect_client_work_area_reservations(
		window.display, root, clients_atom, monitor, area, root_geometry,
		strut_atom, legacy_strut_atom, type_atom, dock_atom,
	)
	found = found || client_found
	// EWMH work areas are desktop-wide, so they cannot identify which output
	// owns a panel. Dock geometry and partial struts remain monitor-local.
	if found || connected_monitor_count(window, root) > 1 do return area
	return usable_area_from_workarea(window, monitor, root)
}

ignore_work_area_query_error :: proc "c" (_: ^xlib.Display, _: ^xlib.XErrorEvent) -> i32 {
	return 0
}

collect_work_area_reservations :: proc(
	display: ^xlib.Display,
	root, parent: xlib.Window,
	monitor, area, root_geometry: Rect,
	strut_atom, legacy_strut_atom, type_atom, dock_atom: xlib.Atom,
	depth: int,
) -> (Rect, bool) {
	if depth > 3 do return area, false
	result := area
	root_return, parent_return: xlib.Window
	children: [^]xlib.Window
	child_count: u32
	if xlib.QueryTree(display, parent, &root_return, &parent_return, &children, &child_count) != .Success {
		return area, false
	}
	defer if children != nil do xlib.Free(children)
	found := false
	for index in 0..<int(child_count) {
		child := children[index]
		child_found: bool
		result, child_found = apply_window_work_area_reservation(
			display, root, child, monitor, result, root_geometry,
			strut_atom, legacy_strut_atom, type_atom, dock_atom,
		)
		found = found || child_found
		nested_area, nested_found := collect_work_area_reservations(
			display, root, child, monitor, result, root_geometry,
			strut_atom, legacy_strut_atom, type_atom, dock_atom, depth+1,
		)
		result = nested_area
		found = found || nested_found
	}
	return result, found
}

collect_client_work_area_reservations :: proc(
	display: ^xlib.Display,
	root: xlib.Window,
	clients_atom: xlib.Atom,
	monitor, area, root_geometry: Rect,
	strut_atom, legacy_strut_atom, type_atom, dock_atom: xlib.Atom,
) -> (Rect, bool) {
	if clients_atom == 0 do return area, false
	actual: xlib.Atom
	format: i32
	count, after: uint
	data: rawptr
	if xlib.GetWindowProperty(display, root, clients_atom, 0, 65536, false, xlib.AnyPropertyType, &actual, &format, &count, &after, &data) != 0 || data == nil {
		return area, false
	}
	defer xlib.Free(data)
	if actual == 0 || format != 32 do return area, false
	result := area
	found := false
	windows := ([^]xlib.Window)(data)
	for index in 0..<int(count) {
		window_found: bool
		result, window_found = apply_window_work_area_reservation(
			display, root, windows[index], monitor, result, root_geometry,
			strut_atom, legacy_strut_atom, type_atom, dock_atom,
		)
		found = found || window_found
	}
	return result, found
}

apply_window_work_area_reservation :: proc(
	display: ^xlib.Display,
	root, window: xlib.Window,
	monitor, area, root_geometry: Rect,
	strut_atom, legacy_strut_atom, type_atom, dock_atom: xlib.Atom,
) -> (Rect, bool) {
	result := area
	found := false
	if strut_atom != 0 {
		if strut, ok := window_strut_partial(display, window, strut_atom); ok {
			result = apply_strut_partial(result, root_geometry, strut)
			found = true
		}
	}
	is_dock := type_atom != 0 && dock_atom != 0 && window_has_atom(display, window, type_atom, dock_atom)
	has_legacy_strut := legacy_strut_atom != 0 && window_has_cardinal_property(display, window, legacy_strut_atom, 4)
	if is_dock || has_legacy_strut {
		if dock, ok := root_window_geometry(display, root, window); ok {
			result = apply_dock_geometry(result, monitor, dock)
			found = true
		}
	}
	return result, found
}

window_has_cardinal_property :: proc(display: ^xlib.Display, window: xlib.Window, property: xlib.Atom, minimum_count: uint) -> bool {
	actual: xlib.Atom
	format: i32
	count, after: uint
	data: rawptr
	if xlib.GetWindowProperty(display, window, property, 0, int(minimum_count), false, xlib.XA_CARDINAL, &actual, &format, &count, &after, &data) != 0 || data == nil {
		return false
	}
	defer xlib.Free(data)
	return actual == xlib.XA_CARDINAL && format == 32 && count >= minimum_count
}

window_has_atom :: proc(display: ^xlib.Display, window: xlib.Window, property, expected: xlib.Atom) -> bool {
	actual: xlib.Atom
	format: i32
	count, after: uint
	data: rawptr
	if xlib.GetWindowProperty(display, window, property, 0, 32, false, xlib.XA_ATOM, &actual, &format, &count, &after, &data) != 0 || data == nil {
		return false
	}
	defer xlib.Free(data)
	if actual != xlib.XA_ATOM || format != 32 do return false
	values := ([^]xlib.Atom)(data)
	for index in 0..<int(count) {
		if values[index] == expected do return true
	}
	return false
}

root_window_geometry :: proc(display: ^xlib.Display, root, window: xlib.Window) -> (Rect, bool) {
	attributes: xlib.XWindowAttributes
	if xlib.GetWindowAttributes(display, window, &attributes) == 0 || attributes.map_state != .IsViewable {
		return {}, false
	}
	x, y: i32
	child: xlib.Window
	if !xlib.TranslateCoordinates(display, window, root, 0, 0, &x, &y, &child) do return {}, false
	return {x = int(x), y = int(y), width = int(attributes.width), height = int(attributes.height)}, true
}

apply_dock_geometry :: proc(area, monitor, dock: Rect) -> Rect {
	if area.width <= 0 || area.height <= 0 || dock.width <= 0 || dock.height <= 0 do return area
	intersection_left := max(monitor.x, dock.x)
	intersection_top := max(monitor.y, dock.y)
	intersection_right := min(monitor.x+monitor.width, dock.x+dock.width)
	intersection_bottom := min(monitor.y+monitor.height, dock.y+dock.height)
	if intersection_right <= intersection_left || intersection_bottom <= intersection_top do return area
	left, top := area.x, area.y
	right, bottom := area.x+area.width, area.y+area.height
	if dock.width >= dock.height {
		if dock.y <= monitor.y && dock.y+dock.height > monitor.y {
			top = max(top, intersection_bottom)
		} else if dock.y < monitor.y+monitor.height && dock.y+dock.height >= monitor.y+monitor.height {
			bottom = min(bottom, intersection_top)
		}
	} else {
		if dock.x <= monitor.x && dock.x+dock.width > monitor.x {
			left = max(left, intersection_right)
		} else if dock.x < monitor.x+monitor.width && dock.x+dock.width >= monitor.x+monitor.width {
			right = min(right, intersection_left)
		}
	}
	if right <= left || bottom <= top do return area
	return {x = left, y = top, width = right-left, height = bottom-top}
}

connected_monitor_count :: proc(window: ^x11.Window, root: xlib.Window) -> int {
	resources := xlib.XRRGetScreenResources(window.display, root)
	if resources == nil do return 1
	defer xlib.XRRFreeScreenResources(resources)
	count := 0
	for index in 0..<int(resources.noutput) {
		info := xlib.XRRGetOutputInfo(window.display, resources, resources.outputs[index])
		if info == nil do continue
		if info.connection == .RR_Connected && info.crtc != 0 do count += 1
		xlib.XRRFreeOutputInfo(info)
	}
	return count
}

window_strut_partial :: proc(display: ^xlib.Display, window: xlib.Window, property: xlib.Atom) -> (Strut_Partial, bool) {
	actual: xlib.Atom
	format: i32
	count, after: uint
	data: rawptr
	if xlib.GetWindowProperty(display, window, property, 0, 12, false, xlib.XA_CARDINAL, &actual, &format, &count, &after, &data) != 0 || data == nil {
		return {}, false
	}
	defer xlib.Free(data)
	if actual != xlib.XA_CARDINAL || format != 32 || count < 12 do return {}, false
	values := ([^]uint)(data)
	return {
		left = int(values[0]), right = int(values[1]), top = int(values[2]), bottom = int(values[3]),
		left_start_y = int(values[4]), left_end_y = int(values[5]),
		right_start_y = int(values[6]), right_end_y = int(values[7]),
		top_start_x = int(values[8]), top_end_x = int(values[9]),
		bottom_start_x = int(values[10]), bottom_end_x = int(values[11]),
	}, true
}

inclusive_ranges_overlap :: proc(a_start, a_end, b_start, b_end: int) -> bool {
	return a_start <= b_end && b_start <= a_end
}

apply_strut_partial :: proc(area, root: Rect, strut: Strut_Partial) -> Rect {
	if area.width <= 0 || area.height <= 0 do return area
	left, top := area.x, area.y
	right, bottom := area.x+area.width, area.y+area.height
	if strut.left > 0 && inclusive_ranges_overlap(top, bottom-1, strut.left_start_y, strut.left_end_y) {
		left = max(left, root.x+strut.left)
	}
	if strut.right > 0 && inclusive_ranges_overlap(top, bottom-1, strut.right_start_y, strut.right_end_y) {
		right = min(right, root.x+root.width-strut.right)
	}
	if strut.top > 0 && inclusive_ranges_overlap(left, right-1, strut.top_start_x, strut.top_end_x) {
		top = max(top, root.y+strut.top)
	}
	if strut.bottom > 0 && inclusive_ranges_overlap(left, right-1, strut.bottom_start_x, strut.bottom_end_x) {
		bottom = min(bottom, root.y+root.height-strut.bottom)
	}
	if right <= left || bottom <= top do return area
	return {x = left, y = top, width = right-left, height = bottom-top}
}

usable_area_from_workarea :: proc(window: ^x11.Window, monitor: Rect, root: xlib.Window) -> Rect {
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
