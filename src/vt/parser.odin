package vt

MAX_PARAMETERS :: 32
MAX_INTERMEDIATES :: 4
MAX_OSC_BYTES :: 1024 * 1024
MAX_DCS_BYTES :: 4 * 1024 * 1024
MAX_APC_BYTES :: 4 * 1024 * 1024

Parser_State :: enum {
	Ground,
	Escape,
	Escape_Intermediate,
	CSI_Entry,
	CSI_Parameter,
	CSI_Intermediate,
	CSI_Ignore,
	OSC_String,
	DCS_String,
	APC_String,
	String_Escape,
}

Event_Kind :: enum { Print, Execute, Escape, CSI, OSC, DCS, APC }
String_Terminator :: enum { None, Bell, ST }

Event :: struct {
	kind: Event_Kind,
	codepoint: rune,
	control: byte,
	final: byte,
	private_marker: byte,
	parameters: [MAX_PARAMETERS]int,
	parameter_count: int,
	intermediates: [MAX_INTERMEDIATES]byte,
	intermediate_count: int,
	data: []byte,
	terminator: String_Terminator,
}

Event_Handler :: #type proc(event: Event, user_data: rawptr)

Parser :: struct {
	state: Parser_State,
	string_state: Parser_State,
	parameters: [MAX_PARAMETERS]int,
	parameter_count: int,
	parameter_value: int,
	parameter_active: bool,
	private_marker: byte,
	intermediates: [MAX_INTERMEDIATES]byte,
	intermediate_count: int,
	string_data: [dynamic]byte,
	string_discarded: bool,
	utf8_value: rune,
	utf8_minimum: rune,
	utf8_remaining: u8,
}

parser_destroy :: proc(parser: ^Parser) {
	delete(parser.string_data)
	parser^ = {}
}

parser_reset :: proc(parser: ^Parser) {
	clear(&parser.string_data)
	parser.state = .Ground
	parser.string_state = .Ground
	parser.parameter_count = 0
	parser.parameter_active = false
	parser.private_marker = 0
	parser.intermediate_count = 0
	parser.string_discarded = false
	parser.utf8_remaining = 0
}

parser_feed :: proc(parser: ^Parser, data: []byte, handler: Event_Handler, user_data: rawptr = nil) {
	for value in data do consume(parser, value, handler, user_data)
}

consume :: proc(parser: ^Parser, value: byte, handler: Event_Handler, user_data: rawptr) {
	if parser.state == .Ground {
		consume_ground(parser, value, handler, user_data)
		return
	}
	if value == 0x18 || value == 0x1a {
		emit_execute(value, handler, user_data)
		parser.state = .Ground
		return
	}
	if value == 0x1b && parser.state != .String_Escape {
		if parser.state == .OSC_String || parser.state == .DCS_String || parser.state == .APC_String {
			parser.string_state = parser.state
			parser.state = .String_Escape
		} else {
			parser.state = .Escape
		}
		return
	}

	switch parser.state {
	case .Escape:
		consume_escape(parser, value, handler, user_data)
	case .Escape_Intermediate:
		if value >= 0x20 && value <= 0x2f {
			push_intermediate(parser, value)
		} else if value >= 0x30 && value <= 0x7e {
			emit_control_event(parser, .Escape, value, handler, user_data)
			parser.state = .Ground
		}
	case .CSI_Entry, .CSI_Parameter, .CSI_Intermediate, .CSI_Ignore:
		consume_csi(parser, value, handler, user_data)
	case .OSC_String, .DCS_String, .APC_String:
		if parser.state == .OSC_String && value == 0x07 {
			emit_string(parser, .Bell, handler, user_data)
		} else {
			append_string_byte(parser, value)
		}
	case .String_Escape:
		if value == '\\' {
			emit_string(parser, .ST, handler, user_data)
		} else {
			append_string_byte(parser, 0x1b)
			parser.state = parser.string_state
			consume(parser, value, handler, user_data)
		}
	case .Ground:
	}
}

consume_ground :: proc(parser: ^Parser, value: byte, handler: Event_Handler, user_data: rawptr) {
	if parser.utf8_remaining > 0 {
		if value & 0xc0 == 0x80 {
			parser.utf8_value = (parser.utf8_value << 6) | rune(value & 0x3f)
			parser.utf8_remaining -= 1
			if parser.utf8_remaining == 0 {
				codepoint := parser.utf8_value
				if codepoint < parser.utf8_minimum || codepoint > 0x10ffff || codepoint >= 0xd800 && codepoint <= 0xdfff {
					codepoint = 0xfffd
				}
				emit_print(codepoint, handler, user_data)
			}
			return
		}
		parser.utf8_remaining = 0
		emit_print(0xfffd, handler, user_data)
		consume_ground(parser, value, handler, user_data)
		return
	}

	if value == 0x1b {
		parser.state = .Escape
	} else if value < 0x20 || value == 0x7f {
		emit_execute(value, handler, user_data)
	} else if value < 0x80 {
		emit_print(rune(value), handler, user_data)
	} else if value >= 0xc2 && value <= 0xdf {
		parser.utf8_value = rune(value & 0x1f)
		parser.utf8_minimum = 0x80
		parser.utf8_remaining = 1
	} else if value >= 0xe0 && value <= 0xef {
		parser.utf8_value = rune(value & 0x0f)
		parser.utf8_minimum = 0x800
		parser.utf8_remaining = 2
	} else if value >= 0xf0 && value <= 0xf4 {
		parser.utf8_value = rune(value & 0x07)
		parser.utf8_minimum = 0x10000
		parser.utf8_remaining = 3
	} else {
		emit_print(0xfffd, handler, user_data)
	}
}

consume_escape :: proc(parser: ^Parser, value: byte, handler: Event_Handler, user_data: rawptr) {
	reset_control(parser)
	switch value {
	case '[':
		parser.state = .CSI_Entry
	case ']':
		begin_string(parser, .OSC_String)
	case 'P':
		begin_string(parser, .DCS_String)
	case '_':
		begin_string(parser, .APC_String)
	case 0x20..=0x2f:
		push_intermediate(parser, value)
		parser.state = .Escape_Intermediate
	case 0x30..=0x7e:
		emit_control_event(parser, .Escape, value, handler, user_data)
		parser.state = .Ground
	case:
		parser.state = .Ground
	}
}

consume_csi :: proc(parser: ^Parser, value: byte, handler: Event_Handler, user_data: rawptr) {
	if parser.state == .CSI_Ignore {
		if value >= 0x40 && value <= 0x7e do parser.state = .Ground
		return
	}
	if value >= '0' && value <= '9' && parser.state != .CSI_Intermediate {
		parser.state = .CSI_Parameter
		parser.parameter_active = true
		digit := int(value - '0')
		if parser.parameter_value > 100000 {
			parser.state = .CSI_Ignore
		} else {
			parser.parameter_value = parser.parameter_value * 10 + digit
		}
		return
	}
	if (value == ';' || value == ':') && parser.state != .CSI_Intermediate {
		if !push_parameter(parser) do parser.state = .CSI_Ignore
		return
	}
	if value >= 0x3c && value <= 0x3f && parser.state == .CSI_Entry && parser.private_marker == 0 {
		parser.private_marker = value
		return
	}
	if value >= 0x20 && value <= 0x2f {
		if parser.parameter_active || parser.parameter_count > 0 do _ = push_parameter(parser)
		if !push_intermediate(parser, value) {
			parser.state = .CSI_Ignore
		} else {
			parser.state = .CSI_Intermediate
		}
		return
	}
	if value >= 0x40 && value <= 0x7e {
		if parser.parameter_active || parser.parameter_count > 0 do _ = push_parameter(parser)
		emit_control_event(parser, .CSI, value, handler, user_data)
		parser.state = .Ground
		return
	}
	if value < 0x20 do emit_execute(value, handler, user_data)
}

reset_control :: proc(parser: ^Parser) {
	parser.parameter_count = 0
	parser.parameter_value = 0
	parser.parameter_active = false
	parser.private_marker = 0
	parser.intermediate_count = 0
}

push_parameter :: proc(parser: ^Parser) -> bool {
	if parser.parameter_count >= MAX_PARAMETERS do return false
	value := parser.parameter_value if parser.parameter_active else -1
	parser.parameters[parser.parameter_count] = value
	parser.parameter_count += 1
	parser.parameter_value = 0
	parser.parameter_active = false
	return true
}

push_intermediate :: proc(parser: ^Parser, value: byte) -> bool {
	if parser.intermediate_count >= MAX_INTERMEDIATES do return false
	parser.intermediates[parser.intermediate_count] = value
	parser.intermediate_count += 1
	return true
}

begin_string :: proc(parser: ^Parser, state: Parser_State) {
	clear(&parser.string_data)
	parser.string_discarded = false
	parser.state = state
}

string_limit :: proc(state: Parser_State) -> int {
	#partial switch state {
	case .OSC_String: return MAX_OSC_BYTES
	case .DCS_String: return MAX_DCS_BYTES
	case .APC_String: return MAX_APC_BYTES
	case: return 0
	}
}

append_string_byte :: proc(parser: ^Parser, value: byte) {
	if parser.string_discarded do return
	if len(parser.string_data) >= string_limit(parser.state) {
		parser.string_discarded = true
		clear(&parser.string_data)
		return
	}
	append(&parser.string_data, value)
}

emit_string :: proc(parser: ^Parser, terminator: String_Terminator, handler: Event_Handler, user_data: rawptr) {
	if !parser.string_discarded {
		kind: Event_Kind
		#partial switch parser.string_state if parser.state == .String_Escape else parser.state {
		case .OSC_String: kind = .OSC
		case .DCS_String: kind = .DCS
		case .APC_String: kind = .APC
		case: unreachable()
		}
		handler(Event{kind = kind, data = parser.string_data[:], terminator = terminator}, user_data)
	}
	clear(&parser.string_data)
	parser.string_discarded = false
	parser.state = .Ground
}

emit_print :: proc(codepoint: rune, handler: Event_Handler, user_data: rawptr) {
	handler(Event{kind = .Print, codepoint = codepoint}, user_data)
}

emit_execute :: proc(control: byte, handler: Event_Handler, user_data: rawptr) {
	handler(Event{kind = .Execute, control = control}, user_data)
}

emit_control_event :: proc(parser: ^Parser, kind: Event_Kind, final: byte, handler: Event_Handler, user_data: rawptr) {
	event := Event{
		kind = kind,
		final = final,
		private_marker = parser.private_marker,
		parameter_count = parser.parameter_count,
		intermediate_count = parser.intermediate_count,
	}
	copy(event.parameters[:], parser.parameters[:parser.parameter_count])
	copy(event.intermediates[:], parser.intermediates[:parser.intermediate_count])
	handler(event, user_data)
}
