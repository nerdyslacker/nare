package tmux

MAX_LINE_BYTES :: 1024*1024
HANDSHAKE :: "\x1bP1000p"

Mode :: enum { Terminal, Control }

Event_Kind :: enum {
	Terminal_Data,
	Activated,
	Reply_Begin,
	Reply_Data,
	Reply_End,
	Reply_Error,
	Output,
	Extended_Output,
	Notification,
	Exit,
	Deactivated,
	Protocol_Error,
}

Notification_Kind :: enum {
	Unknown,
	Client_Detached,
	Client_Session_Changed,
	Config_Error,
	Continue,
	Layout_Change,
	Message,
	Pane_Mode_Changed,
	Paste_Buffer_Changed,
	Paste_Buffer_Deleted,
	Pause,
	Session_Changed,
	Session_Renamed,
	Session_Window_Changed,
	Sessions_Changed,
	Subscription_Changed,
	Unlinked_Window_Add,
	Unlinked_Window_Close,
	Unlinked_Window_Renamed,
	Window_Add,
	Window_Close,
	Window_Pane_Changed,
	Window_Renamed,
}

Event :: struct {
	kind: Event_Kind,
	data: [dynamic]byte,
	pane_id: int,
	window_id: int,
	session_id: int,
	age_ms: int,
	notification: Notification_Kind,
	timestamp: u64,
	command: u64,
	flags: u64,
}

Parser :: struct {
	line: [dynamic]byte,
	discarding_line: bool,
	in_block: bool,
	block_timestamp: u64,
	block_command: u64,
	block_flags: u64,
	exit_seen: bool,
}

Stream :: struct {
	mode: Mode,
	handshake_bytes: int,
	st_pending: bool,
	parser: Parser,
}

event_destroy :: proc(event: ^Event) {
	delete(event.data)
	event^ = {}
}

events_destroy :: proc(events: ^[dynamic]Event) {
	for &event in events^ do event_destroy(&event)
	delete(events^)
}

destroy :: proc(stream: ^Stream) {
	delete(stream.parser.line)
	stream^ = {}
}

feed :: proc(stream: ^Stream, input: []byte, events: ^[dynamic]Event) {
	terminal_data: [dynamic]byte
	defer delete(terminal_data)
	handshake := handshake_bytes()
	for value in input {
		if stream.mode == .Terminal {
			if value == handshake[stream.handshake_bytes] {
				stream.handshake_bytes += 1
				if stream.handshake_bytes == len(handshake) {
					flush_terminal(events, &terminal_data)
					append(events, event_base(.Activated))
					stream.handshake_bytes = 0
					stream.mode = .Control
				}
				continue
			}
			if stream.handshake_bytes > 0 {
				append(&terminal_data, ..handshake[:stream.handshake_bytes])
				stream.handshake_bytes = 0
				if value == handshake[0] {
					stream.handshake_bytes = 1
					continue
				}
			}
			append(&terminal_data, value)
			continue
		}

		flush_terminal(events, &terminal_data)
		if stream.parser.exit_seen && len(stream.parser.line) == 0 && !stream.parser.discarding_line {
			if stream.st_pending {
				stream.st_pending = false
				if value == '\\' {
					append(events, event_base(.Deactivated))
					stream.mode = .Terminal
					stream.parser.exit_seen = false
					continue
				}
				append_error(events, "invalid control-mode terminator")
				parser_feed_byte(&stream.parser, 0x1b, events)
			} else if value == 0x1b {
				stream.st_pending = true
				continue
			}
		}
		parser_feed_byte(&stream.parser, value, events)
	}
	flush_terminal(events, &terminal_data)
}

finish :: proc(stream: ^Stream, events: ^[dynamic]Event) {
	handshake := handshake_bytes()
	if stream.mode == .Terminal && stream.handshake_bytes > 0 {
		append_event(events, .Terminal_Data, handshake[:stream.handshake_bytes])
		stream.handshake_bytes = 0
	} else if stream.mode == .Control &&
	          (len(stream.parser.line) > 0 || stream.parser.discarding_line || stream.st_pending || !stream.parser.exit_seen) {
		append_error(events, "truncated control-mode stream")
	}
}

parser_feed :: proc(parser: ^Parser, input: []byte, events: ^[dynamic]Event) {
	for value in input do parser_feed_byte(parser, value, events)
}

parser_feed_byte :: proc(parser: ^Parser, value: byte, events: ^[dynamic]Event) {
	if value == '\n' {
		if parser.discarding_line {
			parser.discarding_line = false
			append_error(events, "control-mode line exceeds limit")
		} else {
			line := parser.line[:]
			if len(line) > 0 && line[len(line)-1] == '\r' do line = line[:len(line)-1]
			parse_line(parser, line, events)
		}
		clear(&parser.line)
		return
	}
	if parser.discarding_line do return
	if len(parser.line) >= MAX_LINE_BYTES {
		clear(&parser.line)
		parser.discarding_line = true
		return
	}
	append(&parser.line, value)
}

parse_line :: proc(parser: ^Parser, line: []byte, events: ^[dynamic]Event) {
	if parser.in_block {
		if has_prefix(line, "%output ") {
			parse_output(line[len("%output "):], false, events)
			return
		}
		if has_prefix(line, "%extended-output ") {
			parse_output(line[len("%extended-output "):], true, events)
			return
		}
		if notification_line_known(line) {
			parse_notification(line, events)
			return
		}
		kind := Event_Kind.Reply_Data
		if has_prefix(line, "%end ") do kind = .Reply_End
		else if has_prefix(line, "%error ") do kind = .Reply_Error
		if kind == .Reply_Data {
			append_event(events, kind, line)
			return
		}
		timestamp, command, flags, ok := parse_guard(line)
		if !ok || timestamp != parser.block_timestamp || command != parser.block_command || flags != parser.block_flags {
			append_error(events, "mismatched control-mode reply guard")
			parser.in_block = false
			return
		}
		event := event_base(kind)
		event.timestamp, event.command, event.flags = timestamp, command, flags
		append(events, event)
		parser.in_block = false
		return
	}

	if has_prefix(line, "%begin ") {
		timestamp, command, flags, ok := parse_guard(line)
		if !ok {
			append_error(events, "invalid control-mode reply guard")
			return
		}
		parser.in_block = true
		parser.block_timestamp = timestamp
		parser.block_command = command
		parser.block_flags = flags
		event := event_base(.Reply_Begin)
		event.timestamp, event.command, event.flags = timestamp, command, flags
		append(events, event)
		return
	}
	if has_prefix(line, "%output ") {
		parse_output(line[len("%output "):], false, events)
		return
	}
	if has_prefix(line, "%extended-output ") {
		parse_output(line[len("%extended-output "):], true, events)
		return
	}
	if string(line) == "%exit" || has_prefix(line, "%exit ") {
		parser.exit_seen = true
		data := line[len("%exit"):]
		if len(data) > 0 && data[0] == ' ' do data = data[1:]
		append_event(events, .Exit, data)
		return
	}
	if len(line) > 0 && line[0] == '%' {
		parse_notification(line, events)
		return
	}
	if len(line) > 0 do append_error(events, "unexpected control-mode line")
}

parse_guard :: proc(line: []byte) -> (timestamp, command, flags: u64, ok: bool) {
	cursor := 0
	_, first := next_token(line, &cursor)
	second, second_ok := next_token(line, &cursor)
	third, third_ok := next_token(line, &cursor)
	fourth, fourth_ok := next_token(line, &cursor)
	_, extra := next_token(line, &cursor)
	if !first || !second_ok || !third_ok || !fourth_ok || extra do return
	timestamp, first = parse_u64(second)
	command, second_ok = parse_u64(third)
	flags, third_ok = parse_u64(fourth)
	ok = first && second_ok && third_ok
	return
}

parse_output :: proc(line: []byte, extended: bool, events: ^[dynamic]Event) {
	cursor := 0
	pane, pane_ok := next_token(line, &cursor)
	pane_id, id_ok := parse_id(pane, '%')
	if !pane_ok || !id_ok {
		append_error(events, "invalid control-mode pane output")
		return
	}
	age := -1
	if extended {
		age_token, age_ok := next_token(line, &cursor)
		parsed_age, parsed := parse_u64(age_token)
		if !age_ok || !parsed || parsed_age > u64(max(int)) {
			append_error(events, "invalid extended-output age")
			return
		}
		age = int(parsed_age)
		found_separator := false
		for {
			token, token_ok := next_token(line, &cursor)
			if !token_ok do break
			if string(token) == ":" {found_separator = true; break}
		}
		if !found_separator {
			append_error(events, "missing extended-output separator")
			return
		}
	}
	for cursor < len(line) && line[cursor] == ' ' do cursor += 1
	decoded: [dynamic]byte
	if !decode_output(line[cursor:], &decoded) {
		delete(decoded)
		append_error(events, "invalid control-mode output escape")
		return
	}
	kind := Event_Kind.Extended_Output if extended else .Output
	event := event_base(kind)
	event.data, event.pane_id, event.age_ms = decoded, pane_id, age
	append(events, event)
}

parse_notification :: proc(line: []byte, events: ^[dynamic]Event) {
	cursor := 0
	name, _ := next_token(line, &cursor)
	event := event_base(.Notification)
	event.notification = notification_kind(name)

	valid := true
	#partial switch event.notification {
	case .Continue, .Pane_Mode_Changed, .Pause:
		token, ok := next_token(line, &cursor)
		event.pane_id, valid = parse_id(token, '%')
		valid = valid && ok
	case .Layout_Change, .Unlinked_Window_Add, .Unlinked_Window_Close, .Unlinked_Window_Renamed,
	     .Window_Add, .Window_Close, .Window_Renamed:
		token, ok := next_token(line, &cursor)
		event.window_id, valid = parse_id(token, '@')
		valid = valid && ok
	case .Session_Changed, .Session_Window_Changed:
		token, ok := next_token(line, &cursor)
		event.session_id, valid = parse_id(token, '$')
		valid = valid && ok
		if valid && event.notification == .Session_Window_Changed {
			token, ok = next_token(line, &cursor)
			event.window_id, valid = parse_id(token, '@')
			valid = valid && ok
		}
	case .Client_Session_Changed:
		_, client_ok := next_token(line, &cursor)
		token, ok := next_token(line, &cursor)
		event.session_id, valid = parse_id(token, '$')
		valid = valid && client_ok && ok
	case .Window_Pane_Changed:
		window, window_ok := next_token(line, &cursor)
		pane, pane_ok := next_token(line, &cursor)
		event.window_id, valid = parse_id(window, '@')
		pane_id, pane_valid := parse_id(pane, '%')
		event.pane_id = pane_id
		valid = valid && pane_valid && window_ok && pane_ok
	case:
	}
	if !valid {
		append_error(events, "invalid control-mode notification")
		return
	}
	append(&event.data, ..line)
	append(events, event)
}

notification_line_known :: proc(line: []byte) -> bool {
	cursor := 0
	name, ok := next_token(line, &cursor)
	return ok && notification_kind(name) != .Unknown
}

notification_kind :: proc(name: []byte) -> Notification_Kind {
	switch string(name) {
	case "%client-detached": return .Client_Detached
	case "%client-session-changed": return .Client_Session_Changed
	case "%config-error": return .Config_Error
	case "%continue": return .Continue
	case "%layout-change": return .Layout_Change
	case "%message": return .Message
	case "%pane-mode-changed": return .Pane_Mode_Changed
	case "%paste-buffer-changed": return .Paste_Buffer_Changed
	case "%paste-buffer-deleted": return .Paste_Buffer_Deleted
	case "%pause": return .Pause
	case "%session-changed": return .Session_Changed
	case "%session-renamed": return .Session_Renamed
	case "%session-window-changed": return .Session_Window_Changed
	case "%sessions-changed": return .Sessions_Changed
	case "%subscription-changed": return .Subscription_Changed
	case "%unlinked-window-add": return .Unlinked_Window_Add
	case "%unlinked-window-close": return .Unlinked_Window_Close
	case "%unlinked-window-renamed": return .Unlinked_Window_Renamed
	case "%window-add": return .Window_Add
	case "%window-close": return .Window_Close
	case "%window-pane-changed": return .Window_Pane_Changed
	case "%window-renamed": return .Window_Renamed
	case: return .Unknown
	}
}

decode_output :: proc(input: []byte, output: ^[dynamic]byte) -> bool {
	for index := 0; index < len(input); {
		if input[index] != '\\' {
			append(output, input[index])
			index += 1
			continue
		}
		if index+3 >= len(input) do return false
		value := 0
		for digit in input[index+1:index+4] {
			if digit < '0' || digit > '7' do return false
			value = value*8+int(digit-'0')
		}
		if value > 255 do return false
		append(output, byte(value))
		index += 4
	}
	return true
}

next_token :: proc(input: []byte, cursor: ^int) -> (token: []byte, ok: bool) {
	for cursor^ < len(input) && input[cursor^] == ' ' do cursor^ += 1
	if cursor^ >= len(input) do return nil, false
	start := cursor^
	for cursor^ < len(input) && input[cursor^] != ' ' do cursor^ += 1
	return input[start:cursor^], true
}

parse_u64 :: proc(input: []byte) -> (value: u64, ok: bool) {
	if len(input) == 0 do return 0, false
	for digit in input {
		if digit < '0' || digit > '9' do return 0, false
		part := u64(digit-'0')
		if value > (max(u64)-part)/10 do return 0, false
		value = value*10+part
	}
	return value, true
}

parse_id :: proc(input: []byte, prefix: byte) -> (id: int, ok: bool) {
	if len(input) < 2 || input[0] != prefix do return 0, false
	value, parsed := parse_u64(input[1:])
	if !parsed || value > u64(max(int)) do return 0, false
	return int(value), true
}

has_prefix :: proc(input: []byte, prefix: string) -> bool {
	if len(input) < len(prefix) do return false
	return string(input[:len(prefix)]) == prefix
}

append_event :: proc(events: ^[dynamic]Event, kind: Event_Kind, data: []byte) {
	event := event_base(kind)
	append(&event.data, ..data)
	append(events, event)
}

event_base :: proc(kind: Event_Kind) -> Event {
	return {kind = kind, pane_id = -1, window_id = -1, session_id = -1, age_ms = -1}
}

append_error :: proc(events: ^[dynamic]Event, message: string) {
	append_event(events, .Protocol_Error, transmute([]byte)message)
}

flush_terminal :: proc(events: ^[dynamic]Event, data: ^[dynamic]byte) {
	if len(data^) == 0 do return
	append_event(events, .Terminal_Data, data^[:])
	clear(data)
}

handshake_bytes :: proc() -> []byte {
	value: string = HANDSHAKE
	return transmute([]byte)value
}
