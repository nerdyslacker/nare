package input

Key :: enum {
	Text,
	Enter,
	Backspace,
	Tab,
	Escape,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Insert,
	Delete,
	Page_Up,
	Page_Down,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
}

Modifiers :: bit_set[Modifier]
Modifier :: enum { Shift, Alt, Control }

Mouse_Action :: enum { Press, Release, Motion }

Mouse_Event :: struct {
	action: Mouse_Action,
	button: int,
	column: int,
	row: int,
	x, y: int,
	root_x, root_y: int,
	modifiers: Modifiers,
}

encode_key :: proc(key: Key, modifiers: Modifiers, application_cursor: bool, buffer: []byte) -> []byte {
	if len(buffer) < 16 do return nil
	modifier := 1
	if .Shift in modifiers do modifier += 1
	if .Alt in modifiers do modifier += 2
	if .Control in modifiers do modifier += 4

	switch key {
	case .Enter: return copy_sequence(buffer, "\r")
	case .Backspace:
		if .Alt in modifiers do return copy_sequence(buffer, "\x1b\x7f")
		return copy_sequence(buffer, "\x7f")
	case .Tab:
		if .Shift in modifiers do return copy_sequence(buffer, "\x1b[Z")
		return copy_sequence(buffer, "\t")
	case .Escape: return copy_sequence(buffer, "\x1b")
	case .Up: return encode_cursor(buffer, 'A', modifier, application_cursor)
	case .Down: return encode_cursor(buffer, 'B', modifier, application_cursor)
	case .Right: return encode_cursor(buffer, 'C', modifier, application_cursor)
	case .Left: return encode_cursor(buffer, 'D', modifier, application_cursor)
	case .Home: return encode_cursor(buffer, 'H', modifier, application_cursor)
	case .End: return encode_cursor(buffer, 'F', modifier, application_cursor)
	case .Insert: return encode_tilde(buffer, 2, modifier)
	case .Delete: return encode_tilde(buffer, 3, modifier)
	case .Page_Up: return encode_tilde(buffer, 5, modifier)
	case .Page_Down: return encode_tilde(buffer, 6, modifier)
	case .F1: return encode_function(buffer, 'P', modifier)
	case .F2: return encode_function(buffer, 'Q', modifier)
	case .F3: return encode_function(buffer, 'R', modifier)
	case .F4: return encode_function(buffer, 'S', modifier)
	case .F5: return encode_tilde(buffer, 15, modifier)
	case .F6: return encode_tilde(buffer, 17, modifier)
	case .F7: return encode_tilde(buffer, 18, modifier)
	case .F8: return encode_tilde(buffer, 19, modifier)
	case .F9: return encode_tilde(buffer, 20, modifier)
	case .F10: return encode_tilde(buffer, 21, modifier)
	case .F11: return encode_tilde(buffer, 23, modifier)
	case .F12: return encode_tilde(buffer, 24, modifier)
	case .Text: return nil
	}
	return nil
}

encode_cursor :: proc(buffer: []byte, final: byte, modifier: int, application: bool) -> []byte {
	if modifier == 1 {
		buffer[0], buffer[1], buffer[2] = 0x1b, '[' if !application else 'O', final
		return buffer[:3]
	}
	buffer[0], buffer[1], buffer[2], buffer[3], buffer[4], buffer[5] = 0x1b, '[', '1', ';', byte('0'+modifier), final
	return buffer[:6]
}

encode_function :: proc(buffer: []byte, final: byte, modifier: int) -> []byte {
	if modifier == 1 {
		buffer[0], buffer[1], buffer[2] = 0x1b, 'O', final
		return buffer[:3]
	}
	buffer[0], buffer[1], buffer[2], buffer[3], buffer[4], buffer[5] = 0x1b, '[', '1', ';', byte('0'+modifier), final
	return buffer[:6]
}

encode_tilde :: proc(buffer: []byte, number, modifier: int) -> []byte {
	index := 0
	buffer[index], buffer[index+1] = 0x1b, '['
	index += 2
	if number >= 10 {
		buffer[index] = byte('0' + number/10)
		index += 1
	}
	buffer[index] = byte('0' + number%10)
	index += 1
	if modifier != 1 {
		buffer[index], buffer[index+1] = ';', byte('0'+modifier)
		index += 2
	}
	buffer[index] = '~'
	return buffer[:index+1]
}

copy_sequence :: proc(buffer: []byte, sequence: string) -> []byte {
	copy(buffer, transmute([]byte)sequence)
	return buffer[:len(sequence)]
}

encode_paste :: proc(data: []byte, bracketed: bool, output: ^[dynamic]byte) {
	if bracketed do append(output, ..transmute([]byte)string("\x1b[200~"))
	for value in data {
		if value != 0 do append(output, value)
	}
	if bracketed do append(output, ..transmute([]byte)string("\x1b[201~"))
}

encode_mouse :: proc(event: Mouse_Event, tracking: int, sgr: bool, buffer: []byte) -> []byte {
	if tracking == 0 || len(buffer) < 32 do return nil
	if event.action == .Motion && (tracking == 1000 || tracking == 1002 && event.button == 0) do return nil
	if event.action == .Release && (event.button == 4 || event.button == 5) do return nil
	code := mouse_button_code(event, sgr)
	if code < 0 do return nil
	if .Shift in event.modifiers do code += 4
	if .Alt in event.modifiers do code += 8
	if .Control in event.modifiers do code += 16
	if event.action == .Motion do code += 32
	column := max(1, event.column)
	row := max(1, event.row)
	if sgr {
		index := 0
		buffer[index], buffer[index+1], buffer[index+2] = 0x1b, '[', '<'
		index += 3
		index += append_decimal(buffer[index:], code)
		buffer[index] = ';'
		index += 1
		index += append_decimal(buffer[index:], column)
		buffer[index] = ';'
		index += 1
		index += append_decimal(buffer[index:], row)
		buffer[index] = 'm' if event.action == .Release else 'M'
		return buffer[:index+1]
	}
	if column > 223 || row > 223 do return nil
	buffer[0], buffer[1], buffer[2] = 0x1b, '[', 'M'
	buffer[3] = byte(code + 32)
	buffer[4] = byte(column + 32)
	buffer[5] = byte(row + 32)
	return buffer[:6]
}

mouse_button_code :: proc(event: Mouse_Event, sgr: bool) -> int {
	if event.action == .Release && !sgr do return 3
	switch event.button {
	case 1: return 0
	case 2: return 1
	case 3: return 2
	case 4: return 64
	case 5: return 65
	case 0:
		if event.action == .Motion do return 3
	case:
	}
	return -1
}

append_decimal :: proc(buffer: []byte, value: int) -> int {
	digits: [10]byte
	count := 0
	remaining := max(0, value)
	for {
		digits[count] = byte('0' + remaining%10)
		count += 1
		remaining /= 10
		if remaining == 0 do break
	}
	for index in 0..<count do buffer[index] = digits[count-index-1]
	return count
}
