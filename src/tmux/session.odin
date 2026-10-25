package tmux

LIST_PANES_COMMAND :: "list-panes -s -F '#{session_id}\t#{session_name}\t#{window_active}\t#{window_id}\t#{window_index}\t#{window_name}\t#{window_layout}\t#{pane_active}\t#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}\t.'\n"

Session_State :: enum { Inactive, Initial_Reply, Capabilities, Pane_List, Capture, Ready, Disconnected, Failed }
Session_Action :: enum { None, Activated, Capabilities_Changed, Model_Changed, Pane_Selected, Capture_Complete, Command_Error, Title_Changed, Output, Deactivated, Failed }
Reply_Purpose :: enum { Ignored, Initial, Capabilities, Pane_List, Capture }

Pane_Info :: struct {
	id: int,
	window_id: int,
	x, y: int,
	columns, rows: int,
	cursor_column, cursor_row: int,
	active: bool,
}

Window_Info :: struct {
	id: int,
	index: int,
	active: bool,
	name: [dynamic]byte,
	layout: [dynamic]byte,
}

Session :: struct {
	stream: Stream,
	state: Session_State,
	pane_id: int,
	window_id: int,
	columns: int,
	rows: int,
	title: [dynamic]byte,
	version: [dynamic]byte,
	version_major, version_minor: int,
	session_id: int,
	windows: [dynamic]Window_Info,
	panes: [dynamic]Pane_Info,
	previous_pane_id: int,
	fallback_pane_id: int,
	fallback_window_id: int,
	fallback_columns: int,
	fallback_rows: int,
	fallback_title: [dynamic]byte,
	fallback_session_id: int,
	reply_queue: [dynamic]Reply_Purpose,
	reply_pane_ids: [dynamic]int,
	reply_offset: int,
	active_reply: Reply_Purpose,
	active_capture_pane_id: int,
	active_capture_row: int,
	capability_data: [dynamic]byte,
	previous_model_signature: [dynamic]byte,
	model_signature_scratch: [dynamic]byte,
	previous_model_valid: bool,
	reply_open: bool,
	refresh_queued: bool,
}

session_destroy :: proc(session: ^Session) {
	destroy(&session.stream)
	session_clear_model(session)
	delete(session.title)
	delete(session.version)
	delete(session.capability_data)
	delete(session.previous_model_signature)
	delete(session.model_signature_scratch)
	delete(session.fallback_title)
	delete(session.windows)
	delete(session.panes)
	delete(session.reply_queue)
	delete(session.reply_pane_ids)
	session^ = {}
}

session_handle :: proc(session: ^Session, event: ^Event, commands: ^[dynamic]byte) -> Session_Action {
	#partial switch event.kind {
	case .Activated:
		session.previous_pane_id = -1
		session.previous_model_valid = false
		session_reset_model(session)
		clear(&session.reply_queue)
		clear(&session.reply_pane_ids)
		session.reply_offset = 0
		session.reply_open = false
		session.refresh_queued = false
		session.state = .Initial_Reply
		return .Activated
	case .Reply_Begin:
		if session.reply_open {
			session.state = .Failed
			return .Failed
		}
		session.reply_open = true
		if session.state == .Initial_Reply {
			session.active_reply = .Initial
		} else {
			session.active_reply, session.active_capture_pane_id = session_take_reply(session)
		}
		if session.active_reply == .Pane_List {
			session.previous_pane_id = session.pane_id
			session.previous_model_valid = session.pane_id >= 0
			session_model_signature(session, &session.previous_model_signature)
			session_reset_model(session)
			session.state = .Pane_List
			session.refresh_queued = false
		} else if session.active_reply == .Capture {
			session.state = .Capture
			session.active_capture_row = 0
		}
	case .Reply_End, .Reply_Error:
		purpose := session.active_reply
		session.reply_open = false
		session.active_reply = .Ignored
		#partial switch purpose {
		case .Initial:
			session_queue_capabilities(session, commands)
			session.state = .Capabilities
		case .Capabilities:
			session_apply_capabilities(session)
			session_queue_pane_list(session, commands)
			session.state = .Pane_List
			return .Capabilities_Changed
		case .Pane_List:
			if session.pane_id < 0 do session_use_fallback(session)
			if session.pane_id < 0 {
				session.state = .Failed
				return .Failed
			}
			session_model_signature(session, &session.model_signature_scratch)
			if session.previous_model_valid && session_signatures_equal(
				session.previous_model_signature[:],
				session.model_signature_scratch[:],
			) {
				session.state = .Ready
				return .None
			}
			if session.pane_id == session.previous_pane_id {
				session.state = .Ready
				return .Model_Changed
			}
			session.state = .Ready
			return .Pane_Selected
		case .Capture:
			if event.kind == .Reply_Error {
				session.state = .Ready
				return .Command_Error
			}
			session.state = .Ready
			event.pane_id = session.active_capture_pane_id
			return .Capture_Complete
		case .Ignored:
			if event.kind == .Reply_Error do return .Command_Error
		case:
		}
	case .Reply_Data:
		if session.active_reply == .Capabilities {
			if len(session.capability_data) == 0 do append(&session.capability_data, ..event.data[:])
		} else if session.active_reply == .Pane_List {
			session_consider_pane(session, event.data[:])
		} else if session.active_reply == .Capture {
			event.pane_id = session.active_capture_pane_id
			event.capture_row = session.active_capture_row
			session.active_capture_row += 1
			return .Output
		}
	case .Output, .Extended_Output:
		if session.state != .Inactive && session.state != .Failed && event.pane_id >= 0 do return .Output
	case .Notification:
		if event.notification == .Session_Renamed && event.session_id == session.session_id {
			name := notification_trailing_value(event.data[:], 2)
			if len(name) > 0 {
				clear(&session.title)
				append(&session.title, ..name)
				return .Title_Changed
			}
		}
		changed_pane := event.notification == .Window_Pane_Changed && event.pane_id != session.pane_id
		changed_window := event.notification == .Session_Window_Changed && event.window_id != session.window_id
		model_notification := event.notification == .Layout_Change || event.notification == .Window_Add ||
		                      event.notification == .Window_Close || event.notification == .Window_Renamed
		if session.state == .Ready && (changed_pane || changed_window || model_notification) {
			session_queue_pane_list(session, commands)
		}
	case .Deactivated:
		session_reset_model(session)
		session.state = .Inactive
		return .Deactivated
	case .Protocol_Error:
		session.state = .Failed
		return .Failed
	case:
	}
	return .None
}

session_disconnect :: proc(session: ^Session) {
	destroy(&session.stream)
	clear(&session.reply_queue)
	clear(&session.reply_pane_ids)
	clear(&session.capability_data)
	session.reply_offset = 0
	session.reply_open = false
	session.refresh_queued = false
	session.state = .Disconnected
}

session_reset_transport :: proc(session: ^Session) {
	destroy(&session.stream)
	clear(&session.reply_queue)
	clear(&session.reply_pane_ids)
	clear(&session.capability_data)
	session.reply_offset = 0
	session.reply_open = false
	session.refresh_queued = false
	session.state = .Inactive
}

session_active :: proc(session: ^Session) -> bool {
	return session.state != .Inactive && session.state != .Disconnected && session.state != .Failed
}

session_ready :: proc(session: ^Session) -> bool {
	return session.state == .Ready && session.pane_id >= 0
}

request_refresh :: proc(session: ^Session, commands: ^[dynamic]byte) {
	if session_ready(session) do session_queue_pane_list(session, commands)
}

append_input_commands :: proc(session: ^Session, commands: ^[dynamic]byte, pane_id: int, data: []byte) {
	if pane_id < 0 do return
	for offset := 0; offset < len(data); {
		end := min(len(data), offset+256)
		append(commands, "send-keys -H -t %")
		append_decimal(commands, pane_id)
		for value in data[offset:end] {
			append(commands, ' ')
			append(commands, hex_digit(value>>4), hex_digit(value&0xf))
		}
		append(commands, '\n')
		session_queue_reply(session, .Ignored, -1)
		offset = end
	}
}

append_resize_command :: proc(session: ^Session, commands: ^[dynamic]byte, columns, rows: int) {
	if columns <= 0 || rows <= 0 do return
	append(commands, "refresh-client -C ")
	append_decimal(commands, columns)
	append(commands, 'x')
	append_decimal(commands, rows)
	append(commands, '\n')
	session_queue_reply(session, .Ignored, -1)
}

append_detach_command :: proc(session: ^Session, commands: ^[dynamic]byte) {
	append(commands, "detach-client\n")
	session_queue_reply(session, .Ignored, -1)
}

request_new_window :: proc(session: ^Session, commands: ^[dynamic]byte) {
	if !session_ready(session) do return
	append(commands, "new-window\n")
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_split :: proc(session: ^Session, commands: ^[dynamic]byte, horizontal: bool, pane_id: int = -1) {
	if !session_ready(session) do return
	target := pane_id if pane_id >= 0 else session.pane_id
	append(commands, "split-window ")
	append(commands, "-h" if horizontal else "-v")
	append_target_command(commands, target)
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_kill_pane :: proc(session: ^Session, commands: ^[dynamic]byte, pane_id: int = -1) {
	if !session_ready(session) do return
	target := pane_id if pane_id >= 0 else session.pane_id
	append(commands, "kill-pane")
	append_target_command(commands, target)
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_focus :: proc(session: ^Session, commands: ^[dynamic]byte, direction: byte, pane_id: int = -1) {
	if !session_ready(session) do return
	target := pane_id if pane_id >= 0 else session.pane_id
	append(commands, "select-pane -")
	append(commands, direction)
	append_target_command(commands, target)
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_swap_pane :: proc(session: ^Session, commands: ^[dynamic]byte, pane_id: int = -1) {
	if !session_ready(session) do return
	target := pane_id if pane_id >= 0 else session.pane_id
	append(commands, "swap-pane -D")
	append_target_command(commands, target)
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_select_window :: proc(session: ^Session, commands: ^[dynamic]byte, window_id: int) {
	if !session_ready(session) || window_id < 0 do return
	append(commands, "select-window -t @")
	append_decimal(commands, window_id)
	append(commands, '\n')
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_select_pane :: proc(session: ^Session, commands: ^[dynamic]byte, pane_id: int) {
	if !session_ready(session) || pane_id < 0 do return
	append(commands, "select-pane -t %")
	append_decimal(commands, pane_id)
	append(commands, '\n')
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_kill_window :: proc(session: ^Session, commands: ^[dynamic]byte, window_id: int) {
	if !session_ready(session) || window_id < 0 do return
	if window_id == session.window_id {
		for window in session.windows {
			if window.id == window_id do continue
			append(commands, "select-window -t @")
			append_decimal(commands, window.id)
			append(commands, '\n')
			session_queue_reply(session, .Ignored, -1)
			break
		}
	}
	append(commands, "kill-window -t @")
	append_decimal(commands, window_id)
	append(commands, '\n')
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

request_rename_window :: proc(session: ^Session, commands: ^[dynamic]byte, window_id: int, name: []byte) {
	if !session_ready(session) || window_id < 0 || len(name) == 0 do return
	append(commands, "rename-window -t @")
	append_decimal(commands, window_id)
	append(commands, " -- \"")
	for value in name {
		append(commands, '\\')
		append(commands, byte(value/64)+'0', byte(value/8%8)+'0', byte(value%8)+'0')
	}
	append(commands, '\"', '\n')
	session_queue_reply(session, .Ignored, -1)
	session_queue_pane_list(session, commands)
}

append_target_command :: proc(commands: ^[dynamic]byte, pane_id: int) {
	append(commands, " -t %")
	append_decimal(commands, pane_id)
	append(commands, '\n')
}

hex_digit :: proc(value: byte) -> byte {
	return value+'0' if value < 10 else value-10+'a'
}

session_reset_model :: proc(session: ^Session) {
	session_clear_model(session)
	session.pane_id = -1
	session.window_id = -1
	session.columns = 0
	session.rows = 0
	session.session_id = -1
	clear(&session.title)
	session.fallback_pane_id = -1
	session.fallback_window_id = -1
	session.fallback_columns = 0
	session.fallback_rows = 0
	session.fallback_session_id = -1
	clear(&session.fallback_title)
}

session_queue_capabilities :: proc(session: ^Session, commands: ^[dynamic]byte) {
	clear(&session.capability_data)
	append(commands, "display-message -p '#{version}'\n")
	session_queue_reply(session, .Capabilities, -1)
}

session_apply_capabilities :: proc(session: ^Session) {
	clear(&session.version)
	append(&session.version, ..session.capability_data[:])
	session.version_major, session.version_minor = 0, 0
	index := 0
	for index < len(session.version) && (session.version[index] < '0' || session.version[index] > '9') do index += 1
	for index < len(session.version) && session.version[index] >= '0' && session.version[index] <= '9' {
		session.version_major = session.version_major*10+int(session.version[index]-'0')
		index += 1
	}
	if index < len(session.version) && session.version[index] == '.' {
		index += 1
		for index < len(session.version) && session.version[index] >= '0' && session.version[index] <= '9' {
			session.version_minor = session.version_minor*10+int(session.version[index]-'0')
			index += 1
		}
	}
}

session_consider_pane :: proc(session: ^Session, line: []byte) {
	fields: [15][]byte
	cursor := 0
	for index in 0..<len(fields) {
		field, ok := next_tab_field(line, &cursor)
		if !ok do return
		fields[index] = field
	}
	session_id, session_ok := parse_id(fields[0], '$')
	window_active, window_active_ok := parse_u64(fields[2])
	window_id, window_ok := parse_id(fields[3], '@')
	window_index, window_index_ok := parse_u64(fields[4])
	pane_active, pane_active_ok := parse_u64(fields[7])
	pane_id, pane_ok := parse_id(fields[8], '%')
	x, x_ok := parse_u64(fields[9])
	y, y_ok := parse_u64(fields[10])
	columns, columns_ok := parse_u64(fields[11])
	rows, rows_ok := parse_u64(fields[12])
	cursor_column, cursor_column_ok := parse_u64(fields[13])
	cursor_row, cursor_row_ok := parse_u64(fields[14])
	if !session_ok || !window_active_ok || !window_ok || !window_index_ok || !pane_active_ok || !pane_ok ||
	   !x_ok || !y_ok || !columns_ok || !rows_ok || !cursor_column_ok || !cursor_row_ok ||
	   columns == 0 || rows == 0 ||
	   window_index > u64(max(int)) || x > u64(max(int)) || y > u64(max(int)) ||
	   columns > u64(max(int)) || rows > u64(max(int)) || cursor_column > u64(max(int)) ||
	   cursor_row > u64(max(int)) {
		return
	}
	if session.session_id < 0 {
		session.session_id = session_id
		append(&session.title, ..fields[1])
	}
	window := session_find_window(session, window_id)
	if window == nil {
		append(&session.windows, Window_Info{id = window_id, index = int(window_index), active = window_active != 0})
		window = &session.windows[len(session.windows)-1]
		append(&window.name, ..fields[5])
		append(&window.layout, ..fields[6])
	}
	append(&session.panes, Pane_Info{
		id = pane_id, window_id = window_id, x = int(x), y = int(y), columns = int(columns), rows = int(rows), active = pane_active != 0,
		cursor_column = int(cursor_column), cursor_row = int(cursor_row),
	})
	if session.fallback_pane_id < 0 {
		session.fallback_pane_id = pane_id
		session.fallback_window_id = window_id
		session.fallback_columns = int(columns)
		session.fallback_rows = int(rows)
		session.fallback_session_id = session_id
		append(&session.fallback_title, ..fields[1])
	}
	if window_active == 0 || pane_active == 0 || session.pane_id >= 0 do return
	session.pane_id = pane_id
	session.window_id = window_id
	session.columns = int(columns)
	session.rows = int(rows)
	session.session_id = session_id
}

session_clear_model :: proc(session: ^Session) {
	for &window in session.windows {
		delete(window.name)
		delete(window.layout)
	}
	clear(&session.windows)
	clear(&session.panes)
	clear(&session.title)
}

session_find_window :: proc(session: ^Session, id: int) -> ^Window_Info {
	for &window in session.windows do if window.id == id do return &window
	return nil
}

// Cursor coordinates are intentionally excluded: pane output already updates the
// display, and cursor-only changes must not rebuild the native pane layout.
session_model_signature :: proc(session: ^Session, output: ^[dynamic]byte) {
	clear(output)
	session_signature_int(output, session.session_id)
	session_signature_int(output, session.window_id)
	session_signature_int(output, session.pane_id)
	session_signature_bytes(output, session.title[:])
	session_signature_int(output, len(session.windows))
	for window in session.windows {
		session_signature_int(output, window.id)
		session_signature_int(output, window.index)
		append(output, byte(1) if window.active else byte(0))
		session_signature_bytes(output, window.name[:])
		session_signature_bytes(output, window.layout[:])
	}
	session_signature_int(output, len(session.panes))
	for pane in session.panes {
		session_signature_int(output, pane.id)
		session_signature_int(output, pane.window_id)
		session_signature_int(output, pane.x)
		session_signature_int(output, pane.y)
		session_signature_int(output, pane.columns)
		session_signature_int(output, pane.rows)
		append(output, byte(1) if pane.active else byte(0))
	}
}

session_signature_int :: proc(output: ^[dynamic]byte, value: int) {
	append_decimal(output, value)
	append(output, ':')
}

session_signature_bytes :: proc(output: ^[dynamic]byte, value: []byte) {
	append_decimal(output, len(value))
	append(output, ':')
	append(output, ..value)
}

session_signatures_equal :: proc(left, right: []byte) -> bool {
	if len(left) != len(right) do return false
	for value, index in left {
		if value != right[index] do return false
	}
	return true
}

session_use_fallback :: proc(session: ^Session) {
	if session.fallback_pane_id < 0 do return
	session.pane_id = session.fallback_pane_id
	session.window_id = session.fallback_window_id
	session.columns = session.fallback_columns
	session.rows = session.fallback_rows
	session.session_id = session.fallback_session_id
	if len(session.title) == 0 do append(&session.title, ..session.fallback_title[:])
}

next_tab_field :: proc(input: []byte, cursor: ^int) -> (field: []byte, ok: bool) {
	if cursor^ >= len(input) do return nil, false
	start := cursor^
	for cursor^ < len(input) && input[cursor^] != '\t' do cursor^ += 1
	if cursor^ >= len(input) do return nil, false
	field = input[start:cursor^]
	cursor^ += 1
	return field, true
}

session_queue_capture :: proc(session: ^Session, commands: ^[dynamic]byte, pane_id: int) {
	request_capture(session, commands, pane_id)
}

request_capture :: proc(session: ^Session, commands: ^[dynamic]byte, pane_id: int) {
	if pane_id < 0 do return
	append(commands, "capture-pane -p -e -t %")
	append_decimal(commands, pane_id)
	append(commands, '\n')
	session_queue_reply(session, .Capture, pane_id)
}

session_queue_pane_list :: proc(session: ^Session, commands: ^[dynamic]byte) {
	if session.refresh_queued do return
	append(commands, LIST_PANES_COMMAND)
	session_queue_reply(session, .Pane_List, -1)
	session.refresh_queued = true
}

session_queue_reply :: proc(session: ^Session, purpose: Reply_Purpose, pane_id: int) {
	append(&session.reply_queue, purpose)
	append(&session.reply_pane_ids, pane_id)
}

session_take_reply :: proc(session: ^Session) -> (Reply_Purpose, int) {
	if session.reply_offset >= len(session.reply_queue) do return .Ignored, -1
	purpose := session.reply_queue[session.reply_offset]
	pane_id := session.reply_pane_ids[session.reply_offset]
	session.reply_offset += 1
	if session.reply_offset == len(session.reply_queue) {
		clear(&session.reply_queue)
		clear(&session.reply_pane_ids)
		session.reply_offset = 0
	}
	return purpose, pane_id
}

notification_trailing_value :: proc(line: []byte, skip: int) -> []byte {
	cursor := 0
	for _ in 0..<skip {
		_, ok := next_token(line, &cursor)
		if !ok do return nil
	}
	for cursor < len(line) && line[cursor] == ' ' do cursor += 1
	return line[cursor:]
}

append_decimal :: proc(output: ^[dynamic]byte, value: int) {
	if value == 0 {append(output, '0'); return}
	buffer: [32]byte
	index := len(buffer)
	remaining := value
	for remaining > 0 {
		index -= 1
		buffer[index] = byte(remaining%10)+'0'
		remaining /= 10
	}
	append(output, ..buffer[index:])
}
