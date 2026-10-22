package vt

import "core:fmt"
import "core:unicode"

MAX_REPLY_BYTES :: 256 * 1024

Cursor_Style :: enum {
	Blinking_Block,
	Steady_Block,
	Blinking_Underline,
	Steady_Underline,
	Blinking_Bar,
	Steady_Bar,
}

Modes :: struct {
	autowrap: bool,
	origin: bool,
	insert: bool,
	application_cursor: bool,
	application_keypad: bool,
	bracketed_paste: bool,
	focus_reporting: bool,
	cursor_visible: bool,
	synchronized_updates: bool,
	mouse_tracking: int,
	mouse_sgr: bool,
	cursor_style: Cursor_Style,
}

Terminal :: struct {
	parser: Parser,
	main_screen: Screen,
	alternate_screen: Screen,
	using_alternate: bool,
	attributes: Attributes,
	saved_attributes: Attributes,
	modes: Modes,
	replies: [dynamic]byte,
	reply_overflow: bool,
}

terminal_init :: proc(terminal: ^Terminal, columns, rows: int, scrollback_limit: int = DEFAULT_SCROLLBACK_LINES) -> bool {
	if !screen_init(&terminal.main_screen, columns, rows, scrollback_limit) do return false
	if !screen_init(&terminal.alternate_screen, columns, rows) {
		screen_destroy(&terminal.main_screen)
		return false
	}
	terminal.modes.autowrap = true
	terminal.modes.cursor_visible = true
	return true
}

terminal_destroy :: proc(terminal: ^Terminal) {
	parser_destroy(&terminal.parser)
	screen_destroy(&terminal.main_screen)
	screen_destroy(&terminal.alternate_screen)
	delete(terminal.replies)
	terminal^ = {}
}

terminal_screen :: proc(terminal: ^Terminal) -> ^Screen {
	return &terminal.alternate_screen if terminal.using_alternate else &terminal.main_screen
}

terminal_feed :: proc(terminal: ^Terminal, data: []byte) {
	parser_feed(&terminal.parser, data, terminal_event, rawptr(terminal))
}

terminal_resize :: proc(terminal: ^Terminal, columns, rows: int) -> bool {
	main_ok := screen_resize(&terminal.main_screen, columns, rows, terminal.attributes)
	alternate_ok := screen_resize(&terminal.alternate_screen, columns, rows, terminal.attributes)
	return main_ok && alternate_ok
}

terminal_take_replies :: proc(terminal: ^Terminal) -> []byte {
	return terminal.replies[:]
}

terminal_consume_replies :: proc(terminal: ^Terminal, count: int) {
	amount := clamp(count, 0, len(terminal.replies))
	if amount == len(terminal.replies) {
		clear(&terminal.replies)
	} else if amount > 0 {
		copy(terminal.replies[:], terminal.replies[amount:])
		resize(&terminal.replies, len(terminal.replies)-amount)
	}
}

terminal_event :: proc(event: Event, user_data: rawptr) {
	terminal := (^Terminal)(user_data)
	screen := terminal_screen(terminal)
	switch event.kind {
	case .Print:
		if terminal.modes.insert do insert_cells(screen, max(1, unicode.normalized_east_asian_width(event.codepoint)), terminal.attributes)
		screen_put(screen, event.codepoint, terminal.attributes, terminal.modes.autowrap)
	case .Execute:
		handle_execute(terminal, event.control)
	case .Escape:
		handle_escape(terminal, event)
	case .CSI:
		handle_csi(terminal, event)
	case .OSC, .DCS, .APC:
	}
}

handle_execute :: proc(terminal: ^Terminal, control: byte) {
	screen := terminal_screen(terminal)
	switch control {
	case 0x08:
		screen.cursor.column = max(0, screen.cursor.column-1)
		screen.wrap_pending = false
	case 0x09:
		next := screen.columns - 1
		for column := screen.cursor.column + 1; column < screen.columns; column += 1 {
			if screen.tab_stops[column] {
				next = column
				break
			}
		}
		screen.cursor.column = next
		screen.wrap_pending = false
	case 0x0a, 0x0b, 0x0c:
		line_feed(screen, terminal.attributes)
	case 0x0d:
		screen.cursor.column = 0
		screen.wrap_pending = false
	case:
	}
}

handle_escape :: proc(terminal: ^Terminal, event: Event) {
	screen := terminal_screen(terminal)
	if event.intermediate_count > 0 && event.intermediates[0] == '#' && event.final == '8' {
		for &cell in screen.cells do cell = Cell{codepoint = 'E', width = 1, attributes = terminal.attributes}
		return
	}
	switch event.final {
	case '7':
		screen.saved_cursor = screen.cursor
		terminal.saved_attributes = terminal.attributes
	case '8':
		screen.cursor = screen.saved_cursor
		terminal.attributes = terminal.saved_attributes
		screen.wrap_pending = false
	case 'D':
		line_feed(screen, terminal.attributes)
	case 'E':
		screen.cursor.column = 0
		line_feed(screen, terminal.attributes)
	case 'H':
		screen.tab_stops[screen.cursor.column] = true
	case 'M':
		reverse_index(screen, terminal.attributes)
	case 'c':
		terminal_reset(terminal)
	case '=':
		terminal.modes.application_keypad = true
	case '>':
		terminal.modes.application_keypad = false
	case:
	}
}

handle_csi :: proc(terminal: ^Terminal, event: Event) {
	screen := terminal_screen(terminal)
	if event.intermediate_count > 0 {
		if event.intermediates[0] == '!' && event.final == 'p' do soft_reset(terminal)
		if event.intermediates[0] == ' ' && event.final == 'q' do set_cursor_style(terminal, parameter_raw(event, 0, 0))
		return
	}
	switch event.final {
	case 'A': move_cursor(screen, -parameter(event, 0, 1), 0, terminal.modes.origin)
	case 'B', 'e': move_cursor(screen, parameter(event, 0, 1), 0, terminal.modes.origin)
	case 'C', 'a': move_cursor(screen, 0, parameter(event, 0, 1), terminal.modes.origin)
	case 'D': move_cursor(screen, 0, -parameter(event, 0, 1), terminal.modes.origin)
	case 'E':
		move_cursor(screen, parameter(event, 0, 1), 0, terminal.modes.origin)
		screen.cursor.column = 0
	case 'F':
		move_cursor(screen, -parameter(event, 0, 1), 0, terminal.modes.origin)
		screen.cursor.column = 0
	case 'G', '`': screen.cursor.column = clamp(parameter(event, 0, 1)-1, 0, screen.columns-1)
	case 'd': set_cursor(terminal, parameter(event, 0, 1), screen.cursor.column+1)
	case 'H', 'f': set_cursor(terminal, parameter(event, 0, 1), parameter(event, 1, 1))
	case 'J': erase_display(screen, parameter_raw(event, 0, 0), terminal.attributes)
	case 'K': erase_line(screen, parameter_raw(event, 0, 0), terminal.attributes)
	case '@': insert_cells(screen, parameter(event, 0, 1), terminal.attributes)
	case 'P': delete_cells(screen, parameter(event, 0, 1), terminal.attributes)
	case 'X': erase_cells(screen, screen.cursor.row, screen.cursor.column, screen.cursor.column+parameter(event, 0, 1)-1, terminal.attributes)
	case 'L': insert_lines(screen, parameter(event, 0, 1), terminal.attributes)
	case 'M': delete_lines(screen, parameter(event, 0, 1), terminal.attributes)
	case 'S': scroll_up(screen, parameter(event, 0, 1), terminal.attributes)
	case 'T': scroll_down(screen, parameter(event, 0, 1), terminal.attributes)
	case 'm': apply_sgr(terminal, event)
	case 'r': set_scroll_region(terminal, event)
	case 's': screen.saved_cursor = screen.cursor
	case 'u':
		screen.cursor = screen.saved_cursor
		screen.wrap_pending = false
	case 'g': clear_tab_stop(screen, parameter_raw(event, 0, 0))
	case 'h': set_modes(terminal, event, true)
	case 'l': set_modes(terminal, event, false)
	case 'n': device_status(terminal, event)
	case 'c': device_attributes(terminal, event)
	case 't': window_status(terminal, event)
	case:
	}
}

parameter_raw :: proc(event: Event, index, default: int) -> int {
	if index >= event.parameter_count || event.parameters[index] < 0 do return default
	return event.parameters[index]
}

parameter :: proc(event: Event, index, default: int) -> int {
	value := parameter_raw(event, index, default)
	return default if value == 0 else value
}

move_cursor :: proc(screen: ^Screen, rows, columns: int, origin: bool) {
	top := screen.scroll_top if origin else 0
	bottom := screen.scroll_bottom if origin else screen.rows-1
	screen.cursor.row = clamp(screen.cursor.row+rows, top, bottom)
	screen.cursor.column = clamp(screen.cursor.column+columns, 0, screen.columns-1)
	screen.wrap_pending = false
}

set_cursor :: proc(terminal: ^Terminal, row, column: int) {
	screen := terminal_screen(terminal)
	top := screen.scroll_top if terminal.modes.origin else 0
	bottom := screen.scroll_bottom if terminal.modes.origin else screen.rows-1
	screen.cursor.row = clamp(top+row-1, top, bottom)
	screen.cursor.column = clamp(column-1, 0, screen.columns-1)
	screen.wrap_pending = false
}

erase_display :: proc(screen: ^Screen, mode: int, attributes: Attributes) {
	switch mode {
	case 0:
		erase_cells(screen, screen.cursor.row, screen.cursor.column, screen.columns-1, attributes)
		for row in screen.cursor.row+1..<screen.rows do clear_row(screen, row, attributes)
	case 1:
		for row in 0..<screen.cursor.row do clear_row(screen, row, attributes)
		erase_cells(screen, screen.cursor.row, 0, screen.cursor.column, attributes)
	case 2:
		for row in 0..<screen.rows do clear_row(screen, row, attributes)
	case 3:
		for row in screen.scrollback do delete(row)
		clear(&screen.scrollback)
		clear(&screen.scrollback_wrapped)
	case:
	}
}

erase_line :: proc(screen: ^Screen, mode: int, attributes: Attributes) {
	switch mode {
	case 0: erase_cells(screen, screen.cursor.row, screen.cursor.column, screen.columns-1, attributes)
	case 1: erase_cells(screen, screen.cursor.row, 0, screen.cursor.column, attributes)
	case 2: clear_row(screen, screen.cursor.row, attributes)
	case:
	}
}

insert_lines :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	if screen.cursor.row < screen.scroll_top || screen.cursor.row > screen.scroll_bottom do return
	old_top := screen.scroll_top
	screen.scroll_top = screen.cursor.row
	scroll_down(screen, count, attributes)
	screen.scroll_top = old_top
}

delete_lines :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	if screen.cursor.row < screen.scroll_top || screen.cursor.row > screen.scroll_bottom do return
	old_top := screen.scroll_top
	screen.scroll_top = screen.cursor.row
	scroll_up(screen, count, attributes)
	screen.scroll_top = old_top
}

set_scroll_region :: proc(terminal: ^Terminal, event: Event) {
	screen := terminal_screen(terminal)
	top := parameter(event, 0, 1) - 1
	bottom := parameter(event, 1, screen.rows) - 1
	if top < 0 || bottom >= screen.rows || top >= bottom do return
	screen.scroll_top = top
	screen.scroll_bottom = bottom
	screen.cursor = Cursor{row = top if terminal.modes.origin else 0}
	screen.wrap_pending = false
}

clear_tab_stop :: proc(screen: ^Screen, mode: int) {
	if mode == 0 {
		screen.tab_stops[screen.cursor.column] = false
	} else if mode == 3 {
		for &stop in screen.tab_stops do stop = false
	}
}

set_modes :: proc(terminal: ^Terminal, event: Event, enabled: bool) {
	for index in 0..<event.parameter_count {
		mode := event.parameters[index]
		if event.private_marker == '?' {
			switch mode {
			case 1: terminal.modes.application_cursor = enabled
			case 6:
				terminal.modes.origin = enabled
				set_cursor(terminal, 1, 1)
			case 7: terminal.modes.autowrap = enabled
			case 25: terminal.modes.cursor_visible = enabled
			case 1000, 1002, 1003: terminal.modes.mouse_tracking = mode if enabled else 0
			case 1004: terminal.modes.focus_reporting = enabled
			case 1006: terminal.modes.mouse_sgr = enabled
			case 1047, 1049: switch_alternate(terminal, enabled, mode == 1049)
			case 2004: terminal.modes.bracketed_paste = enabled
			case 2026: terminal.modes.synchronized_updates = enabled
			case:
			}
		} else if mode == 4 {
			terminal.modes.insert = enabled
		}
	}
}

switch_alternate :: proc(terminal: ^Terminal, enabled, save_cursor: bool) {
	if enabled == terminal.using_alternate do return
	if enabled {
		if save_cursor do terminal.main_screen.saved_cursor = terminal.main_screen.cursor
		screen_clear(&terminal.alternate_screen, terminal.attributes)
		terminal.using_alternate = true
	} else {
		terminal.using_alternate = false
		if save_cursor {
			terminal.main_screen.cursor = terminal.main_screen.saved_cursor
			terminal.main_screen.wrap_pending = false
		}
	}
}

device_status :: proc(terminal: ^Terminal, event: Event) {
	switch parameter_raw(event, 0, 0) {
	case 5:
		if event.private_marker == 0 do append_reply(terminal, transmute([]byte)string("\x1b[0n"))
	case 6:
		screen := terminal_screen(terminal)
		prefix := "?" if event.private_marker == '?' else ""
		response := fmt.aprintf("\x1b[%s%d;%dR", prefix, screen.cursor.row+1, screen.cursor.column+1)
		append_reply(terminal, transmute([]byte)response)
		delete(response)
	case:
	}
}

device_attributes :: proc(terminal: ^Terminal, event: Event) {
	if event.private_marker == '>' {
		append_reply(terminal, transmute([]byte)string("\x1b[>0;1;0c"))
	} else if event.private_marker == 0 {
		append_reply(terminal, transmute([]byte)string("\x1b[?62;4c"))
	}
}

window_status :: proc(terminal: ^Terminal, event: Event) {
	if parameter_raw(event, 0, 0) != 18 do return
	screen := terminal_screen(terminal)
	response := fmt.aprintf("\x1b[8;%d;%dt", screen.rows, screen.columns)
	append_reply(terminal, transmute([]byte)response)
	delete(response)
}

set_cursor_style :: proc(terminal: ^Terminal, value: int) {
	switch value {
	case 0, 1: terminal.modes.cursor_style = .Blinking_Block
	case 2: terminal.modes.cursor_style = .Steady_Block
	case 3: terminal.modes.cursor_style = .Blinking_Underline
	case 4: terminal.modes.cursor_style = .Steady_Underline
	case 5: terminal.modes.cursor_style = .Blinking_Bar
	case 6: terminal.modes.cursor_style = .Steady_Bar
	case:
	}
}

append_reply :: proc(terminal: ^Terminal, data: []byte) {
	if len(terminal.replies) + len(data) > MAX_REPLY_BYTES {
		terminal.reply_overflow = true
		return
	}
	append(&terminal.replies, ..data)
}

apply_sgr :: proc(terminal: ^Terminal, event: Event) {
	if event.parameter_count == 0 {
		terminal.attributes = {}
		return
	}
	for index := 0; index < event.parameter_count; index += 1 {
		value := event.parameters[index]
		if value < 0 do value = 0
		switch value {
		case 0: terminal.attributes = {}
		case 1: terminal.attributes.bold = true
		case 2: terminal.attributes.faint = true
		case 3: terminal.attributes.italic = true
		case 4, 21: terminal.attributes.underline = true
		case 5, 6: terminal.attributes.blink = true
		case 7: terminal.attributes.inverse = true
		case 8: terminal.attributes.hidden = true
		case 9: terminal.attributes.strikethrough = true
		case 22: terminal.attributes.bold, terminal.attributes.faint = false, false
		case 23: terminal.attributes.italic = false
		case 24: terminal.attributes.underline = false
		case 25: terminal.attributes.blink = false
		case 27: terminal.attributes.inverse = false
		case 28: terminal.attributes.hidden = false
		case 29: terminal.attributes.strikethrough = false
		case 30..=37: terminal.attributes.foreground = Color{kind = .Indexed, value = u32(value-30)}
		case 40..=47: terminal.attributes.background = Color{kind = .Indexed, value = u32(value-40)}
		case 90..=97: terminal.attributes.foreground = Color{kind = .Indexed, value = u32(value-90+8)}
		case 100..=107: terminal.attributes.background = Color{kind = .Indexed, value = u32(value-100+8)}
		case 38, 48:
			color, consumed, ok := extended_color(event, index+1)
			if ok {
				if value == 38 do terminal.attributes.foreground = color
				if value == 48 do terminal.attributes.background = color
				index += consumed
			}
		case 39: terminal.attributes.foreground = {}
		case 49: terminal.attributes.background = {}
		case:
		}
	}
}

extended_color :: proc(event: Event, start: int) -> (color: Color, consumed: int, ok: bool) {
	if start >= event.parameter_count do return
	mode := event.parameters[start]
	if mode == 5 && start+1 < event.parameter_count {
		value := event.parameters[start+1]
		if value >= 0 && value <= 255 do return Color{kind = .Indexed, value = u32(value)}, 2, true
	} else if mode == 2 && start+3 < event.parameter_count {
		r, g, b := event.parameters[start+1], event.parameters[start+2], event.parameters[start+3]
		if r >= 0 && r <= 255 && g >= 0 && g <= 255 && b >= 0 && b <= 255 {
			return Color{kind = .RGB, value = u32(r<<16 | g<<8 | b)}, 4, true
		}
	}
	return
}

soft_reset :: proc(terminal: ^Terminal) {
	terminal.attributes = {}
	terminal.modes = Modes{autowrap = true, cursor_visible = true}
	screen := terminal_screen(terminal)
	screen.scroll_top = 0
	screen.scroll_bottom = screen.rows - 1
	screen.cursor = {}
	screen.wrap_pending = false
}

terminal_reset :: proc(terminal: ^Terminal) {
	terminal.attributes = {}
	terminal.modes = Modes{autowrap = true, cursor_visible = true}
	terminal.using_alternate = false
	screen_clear(&terminal.main_screen, {})
	screen_clear(&terminal.alternate_screen, {})
}
