package tmux

LIST_PANES_COMMAND :: "list-panes -F '#{pane_active}\t#{pane_id}\t#{window_id}\t#{pane_width}\t#{pane_height}\t#{window_name}'\n"

Session_State :: enum { Inactive, Initial_Reply, Pane_List, Capture, Ready, Failed }
Session_Action :: enum { None, Activated, Pane_Selected, Output, Deactivated, Failed }

Session :: struct {
	stream: Stream,
	state: Session_State,
	pane_id: int,
	window_id: int,
	columns: int,
	rows: int,
	title: [dynamic]byte,
	fallback_pane_id: int,
	fallback_window_id: int,
	fallback_columns: int,
	fallback_rows: int,
	fallback_title: [dynamic]byte,
}

session_destroy :: proc(session: ^Session) {
	destroy(&session.stream)
	delete(session.title)
	delete(session.fallback_title)
	session^ = {}
}

session_handle :: proc(session: ^Session, event: ^Event, commands: ^[dynamic]byte) -> Session_Action {
	#partial switch event.kind {
	case .Activated:
		session_reset_model(session)
		session.state = .Initial_Reply
		return .Activated
	case .Reply_End, .Reply_Error:
		#partial switch session.state {
		case .Initial_Reply:
			append(commands, LIST_PANES_COMMAND)
			session.state = .Pane_List
		case .Pane_List:
			if session.pane_id < 0 do session_use_fallback(session)
			if session.pane_id < 0 {
				session.state = .Failed
				return .Failed
			}
			append_capture_command(commands, session.pane_id)
			session.state = .Capture
			return .Pane_Selected
		case .Capture:
			if event.kind == .Reply_Error {
				session.state = .Failed
				return .Failed
			}
			session.state = .Ready
		case:
		}
	case .Reply_Data:
		if session.state == .Pane_List {
			session_consider_pane(session, event.data[:])
		} else if session.state == .Capture {
			return .Output
		}
	case .Output, .Extended_Output:
		if (session.state == .Ready || session.state == .Capture) && event.pane_id == session.pane_id do return .Output
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

session_active :: proc(session: ^Session) -> bool {
	return session.state != .Inactive
}

session_ready :: proc(session: ^Session) -> bool {
	return session.state == .Ready && session.pane_id >= 0
}

append_input_commands :: proc(commands: ^[dynamic]byte, pane_id: int, data: []byte) {
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
		offset = end
	}
}

append_resize_command :: proc(commands: ^[dynamic]byte, columns, rows: int) {
	if columns <= 0 || rows <= 0 do return
	append(commands, "refresh-client -C ")
	append_decimal(commands, columns)
	append(commands, 'x')
	append_decimal(commands, rows)
	append(commands, '\n')
}

append_detach_command :: proc(commands: ^[dynamic]byte) {
	append(commands, "detach-client\n")
}

hex_digit :: proc(value: byte) -> byte {
	return value+'0' if value < 10 else value-10+'a'
}

session_reset_model :: proc(session: ^Session) {
	session.pane_id = -1
	session.window_id = -1
	session.columns = 0
	session.rows = 0
	clear(&session.title)
	session.fallback_pane_id = -1
	session.fallback_window_id = -1
	session.fallback_columns = 0
	session.fallback_rows = 0
	clear(&session.fallback_title)
}

session_consider_pane :: proc(session: ^Session, line: []byte) {
	fields: [5][]byte
	cursor := 0
	for index in 0..<len(fields) {
		field, ok := next_tab_field(line, &cursor)
		if !ok do return
		fields[index] = field
	}
	active, active_ok := parse_u64(fields[0])
	pane_id, pane_ok := parse_id(fields[1], '%')
	window_id, window_ok := parse_id(fields[2], '@')
	columns, columns_ok := parse_u64(fields[3])
	rows, rows_ok := parse_u64(fields[4])
	if !active_ok || !pane_ok || !window_ok || !columns_ok || !rows_ok ||
	   columns == 0 || rows == 0 || columns > u64(max(int)) || rows > u64(max(int)) {
		return
	}
	title := line[cursor:]
	if session.fallback_pane_id < 0 {
		session.fallback_pane_id = pane_id
		session.fallback_window_id = window_id
		session.fallback_columns = int(columns)
		session.fallback_rows = int(rows)
		append(&session.fallback_title, ..title)
	}
	if active == 0 || session.pane_id >= 0 do return
	session.pane_id = pane_id
	session.window_id = window_id
	session.columns = int(columns)
	session.rows = int(rows)
	append(&session.title, ..title)
}

session_use_fallback :: proc(session: ^Session) {
	if session.fallback_pane_id < 0 do return
	session.pane_id = session.fallback_pane_id
	session.window_id = session.fallback_window_id
	session.columns = session.fallback_columns
	session.rows = session.fallback_rows
	append(&session.title, ..session.fallback_title[:])
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

append_capture_command :: proc(commands: ^[dynamic]byte, pane_id: int) {
	append(commands, "capture-pane -p -e -t %")
	append_decimal(commands, pane_id)
	append(commands, '\n')
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
