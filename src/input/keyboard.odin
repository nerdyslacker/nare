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
	Left_Shift,
	Left_Control,
	Left_Alt,
	Left_Super,
	Right_Shift,
	Right_Control,
	Right_Alt,
	Right_Super,
	Caps_Lock,
	Num_Lock,
}

Modifiers :: bit_set[Modifier]
Modifier :: enum { Shift, Alt, Control, Super, Hyper, Meta, Caps_Lock, Num_Lock }

Key_Action :: enum { Press, Repeat, Release }

KITTY_DISAMBIGUATE :: u8(1)
KITTY_REPORT_EVENTS :: u8(2)
KITTY_ALTERNATE_KEYS :: u8(4)
KITTY_ALL_KEYS :: u8(8)
KITTY_ASSOCIATED_TEXT :: u8(16)

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

	#partial switch key {
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

encode_key_event :: proc(
	key: Key,
	modifiers: Modifiers,
	action: Key_Action,
	codepoint, shifted_codepoint: rune,
	text: []byte,
	flags: u8,
	application_cursor: bool,
	buffer: []byte,
) -> (data: []byte, escape_encoded: bool) {
	if len(buffer) < 512 do return
	report_events := flags & KITTY_REPORT_EVENTS != 0
	all_keys := flags & KITTY_ALL_KEYS != 0
	if action == .Release && (!report_events || !all_keys && (key == .Text || key == .Enter || key == .Tab || key == .Backspace)) do return
	if key == .Text {
		escape_encoded = all_keys || flags & KITTY_DISAMBIGUATE != 0 && (.Alt in modifiers || .Control in modifiers)
		if !escape_encoded do return text, false
		key_codepoint := codepoint
		if key_codepoint == 0 {
			for value in string(text) { key_codepoint = value; break }
		}
		return encode_kitty_key(buffer, key_codepoint, shifted_codepoint, modifiers, action, text, flags), true
	}
	code := kitty_key_code(key)
	if code != 0 && (all_keys || key == .Escape && flags & KITTY_DISAMBIGUATE != 0) {
		return encode_kitty_key(buffer, code, 0, modifiers, action, nil, flags), true
	}
	modifier := kitty_modifier(modifiers)
	event_type := int(action)+1
	switch key {
	case .Enter: return copy_sequence(buffer, "\r"), false
	case .Backspace:
		if .Alt in modifiers do return copy_sequence(buffer, "\x1b\x7f"), true
		return copy_sequence(buffer, "\x7f"), false
	case .Tab:
		if .Shift in modifiers do return copy_sequence(buffer, "\x1b[Z"), true
		return copy_sequence(buffer, "\t"), false
	case .Escape: return copy_sequence(buffer, "\x1b"), true
	case .Up: return encode_cursor(buffer, 'A', modifier, application_cursor, event_type, report_events), true
	case .Down: return encode_cursor(buffer, 'B', modifier, application_cursor, event_type, report_events), true
	case .Right: return encode_cursor(buffer, 'C', modifier, application_cursor, event_type, report_events), true
	case .Left: return encode_cursor(buffer, 'D', modifier, application_cursor, event_type, report_events), true
	case .Home: return encode_cursor(buffer, 'H', modifier, application_cursor, event_type, report_events), true
	case .End: return encode_cursor(buffer, 'F', modifier, application_cursor, event_type, report_events), true
	case .Insert: return encode_tilde(buffer, 2, modifier, event_type, report_events), true
	case .Delete: return encode_tilde(buffer, 3, modifier, event_type, report_events), true
	case .Page_Up: return encode_tilde(buffer, 5, modifier, event_type, report_events), true
	case .Page_Down: return encode_tilde(buffer, 6, modifier, event_type, report_events), true
	case .F1: return encode_function(buffer, 'P', modifier, event_type, report_events), true
	case .F2: return encode_function(buffer, 'Q', modifier, event_type, report_events), true
	case .F3: return encode_function(buffer, 'R', modifier, event_type, report_events), true
	case .F4: return encode_function(buffer, 'S', modifier, event_type, report_events), true
	case .F5: return encode_tilde(buffer, 15, modifier, event_type, report_events), true
	case .F6: return encode_tilde(buffer, 17, modifier, event_type, report_events), true
	case .F7: return encode_tilde(buffer, 18, modifier, event_type, report_events), true
	case .F8: return encode_tilde(buffer, 19, modifier, event_type, report_events), true
	case .F9: return encode_tilde(buffer, 20, modifier, event_type, report_events), true
	case .F10: return encode_tilde(buffer, 21, modifier, event_type, report_events), true
	case .F11: return encode_tilde(buffer, 23, modifier, event_type, report_events), true
	case .F12: return encode_tilde(buffer, 24, modifier, event_type, report_events), true
	case .Text, .Left_Shift, .Left_Control, .Left_Alt, .Left_Super, .Right_Shift, .Right_Control, .Right_Alt, .Right_Super, .Caps_Lock, .Num_Lock: return
	}
	return
}

kitty_key_code :: proc(key: Key) -> rune {
	#partial switch key {
	case .Escape: return 27
	case .Enter: return 13
	case .Tab: return 9
	case .Backspace: return 127
	case .Caps_Lock: return 57358
	case .Num_Lock: return 57360
	case .Left_Shift: return 57441
	case .Left_Control: return 57442
	case .Left_Alt: return 57443
	case .Left_Super: return 57444
	case .Right_Shift: return 57447
	case .Right_Control: return 57448
	case .Right_Alt: return 57449
	case .Right_Super: return 57450
	case: return 0
	}
}

kitty_modifier :: proc(modifiers: Modifiers) -> int {
	value := 1
	if .Shift in modifiers do value += 1
	if .Alt in modifiers do value += 2
	if .Control in modifiers do value += 4
	if .Super in modifiers do value += 8
	if .Hyper in modifiers do value += 16
	if .Meta in modifiers do value += 32
	if .Caps_Lock in modifiers do value += 64
	if .Num_Lock in modifiers do value += 128
	return value
}

encode_kitty_key :: proc(buffer: []byte, codepoint, shifted_codepoint: rune, modifiers: Modifiers, action: Key_Action, text: []byte, flags: u8) -> []byte {
	index := 0
	buffer[index], buffer[index+1] = 0x1b, '['
	index += 2
	index += append_decimal(buffer[index:], int(max(0, codepoint)))
	if flags & KITTY_ALTERNATE_KEYS != 0 && .Shift in modifiers && shifted_codepoint > 0 {
		buffer[index] = ':'
		index += 1
		index += append_decimal(buffer[index:], int(shifted_codepoint))
	}
	buffer[index] = ';'
	index += 1
	index += append_decimal(buffer[index:], kitty_modifier(modifiers))
	if flags & KITTY_REPORT_EVENTS != 0 {
		buffer[index] = ':'
		index += 1
		index += append_decimal(buffer[index:], int(action)+1)
	}
	if flags & KITTY_ASSOCIATED_TEXT != 0 && flags & KITTY_ALL_KEYS != 0 && len(text) > 0 {
		text_start := index
		buffer[index] = ';'
		index += 1
		first := true
		for value in string(text) {
			if value < 0x20 || value >= 0x7f && value <= 0x9f do continue
			if !first { buffer[index] = ':'; index += 1 }
			index += append_decimal(buffer[index:], int(value))
			first = false
		}
		if first do index = text_start
	}
	buffer[index] = 'u'
	return buffer[:index+1]
}

encode_cursor :: proc(buffer: []byte, final: byte, modifier: int, application: bool, event_type: int = 1, report_event: bool = false) -> []byte {
	if modifier == 1 && !report_event {
		buffer[0], buffer[1], buffer[2] = 0x1b, '[' if !application else 'O', final
		return buffer[:3]
	}
	index := 4
	buffer[0], buffer[1], buffer[2], buffer[3] = 0x1b, '[', '1', ';'
	index += append_decimal(buffer[index:], modifier)
	if report_event { buffer[index] = ':'; index += 1; index += append_decimal(buffer[index:], event_type) }
	buffer[index] = final
	return buffer[:index+1]
}

encode_function :: proc(buffer: []byte, final: byte, modifier: int, event_type: int = 1, report_event: bool = false) -> []byte {
	if modifier == 1 && !report_event {
		buffer[0], buffer[1], buffer[2] = 0x1b, 'O', final
		return buffer[:3]
	}
	return encode_cursor(buffer, final, modifier, false, event_type, report_event)
}

encode_tilde :: proc(buffer: []byte, number, modifier: int, event_type: int = 1, report_event: bool = false) -> []byte {
	index := 0
	buffer[index], buffer[index+1] = 0x1b, '['
	index += 2
	if number >= 10 {
		buffer[index] = byte('0' + number/10)
		index += 1
	}
	buffer[index] = byte('0' + number%10)
	index += 1
	if modifier != 1 || report_event {
		buffer[index] = ';'
		index += 1
		index += append_decimal(buffer[index:], modifier)
		if report_event { buffer[index] = ':'; index += 1; index += append_decimal(buffer[index:], event_type) }
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
