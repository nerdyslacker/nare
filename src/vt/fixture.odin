package vt

import "base:runtime"
import "core:encoding/hex"
import "core:strings"

MAX_FIXTURE_CASES :: 4096
MAX_FIXTURE_CHUNKS_PER_CASE :: 4096
MAX_FIXTURE_EXPECTATIONS_PER_CASE :: 8192
MAX_FIXTURE_CHUNK_BYTES :: 1024 * 1024

Fixture_Error :: enum {
	None,
	Missing_Header,
	Unexpected_Header,
	Unknown_Directive,
	Nested_Case,
	Directive_Outside_Case,
	Empty_Case_Name,
	Empty_Case,
	Unclosed_Case,
	Invalid_Hex,
	Limit_Exceeded,
}

Fixture_Case :: struct {
	name:     string,
	chunks:   [dynamic][]byte,
	expected: [dynamic]string,
}

Fixture :: struct {
	cases: [dynamic]Fixture_Case,
}

fixture_destroy :: proc(fixture: ^Fixture, allocator: runtime.Allocator = context.allocator) {
	for &test_case in fixture.cases {
		delete(test_case.name, allocator)
		for chunk in test_case.chunks {
			delete(chunk, allocator)
		}
		for event in test_case.expected {
			delete(event, allocator)
		}
		delete(test_case.chunks)
		delete(test_case.expected)
	}
	delete(fixture.cases)
	fixture^ = {}
}

fixture_load :: proc(
	data: string,
	allocator: runtime.Allocator = context.allocator,
) -> (fixture: Fixture, err: Fixture_Error, error_line: int) {
	context.allocator = allocator
	header_seen := false
	case_open := false
	line_number := 0
	remaining := data

	for raw_line in strings.split_lines_iterator(&remaining) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}

		if !header_seen {
			if line != "nare-vt-fixture-v1" {
				return fixture, .Missing_Header, line_number
			}
			header_seen = true
			continue
		}

		if line == "nare-vt-fixture-v1" {
			return fixture, .Unexpected_Header, line_number
		}

		if strings.has_prefix(line, "case ") {
			if case_open {
				return fixture, .Nested_Case, line_number
			}
			if len(fixture.cases) >= MAX_FIXTURE_CASES {
				return fixture, .Limit_Exceeded, line_number
			}
			name := strings.trim_space(line[len("case "):])
			if name == "" {
				return fixture, .Empty_Case_Name, line_number
			}
			append(&fixture.cases, Fixture_Case{name = strings.clone(name)})
			case_open = true
			continue
		}

		if line == "end" {
			if !case_open {
				return fixture, .Directive_Outside_Case, line_number
			}
			current := &fixture.cases[len(fixture.cases)-1]
			if len(current.chunks) == 0 || len(current.expected) == 0 {
				return fixture, .Empty_Case, line_number
			}
			case_open = false
			continue
		}

		if !case_open {
			return fixture, .Directive_Outside_Case, line_number
		}

		current := &fixture.cases[len(fixture.cases)-1]
		if strings.has_prefix(line, "feed ") {
			if len(current.chunks) >= MAX_FIXTURE_CHUNKS_PER_CASE {
				return fixture, .Limit_Exceeded, line_number
			}
			hex_text := strings.trim_space(line[len("feed "):])
			if len(hex_text) > MAX_FIXTURE_CHUNK_BYTES * 2 {
				return fixture, .Limit_Exceeded, line_number
			}
			chunk, ok := hex.decode(transmute([]byte)hex_text)
			if !ok {
				delete(chunk)
				return fixture, .Invalid_Hex, line_number
			}
			append(&current.chunks, chunk)
			continue
		}

		if strings.has_prefix(line, "expect ") {
			if len(current.expected) >= MAX_FIXTURE_EXPECTATIONS_PER_CASE {
				return fixture, .Limit_Exceeded, line_number
			}
			event := strings.trim_space(line[len("expect "):])
			if event == "" {
				return fixture, .Unknown_Directive, line_number
			}
			append(&current.expected, strings.clone(event))
			continue
		}

		return fixture, .Unknown_Directive, line_number
	}

	if !header_seen {
		return fixture, .Missing_Header, line_number
	}
	if case_open {
		return fixture, .Unclosed_Case, line_number
	}
	return fixture, .None, 0
}

fixture_error_string :: proc(err: Fixture_Error) -> string {
	switch err {
	case .None:                       return "none"
	case .Missing_Header:             return "missing header"
	case .Unexpected_Header:          return "unexpected header"
	case .Unknown_Directive:          return "unknown directive"
	case .Nested_Case:                return "nested case"
	case .Directive_Outside_Case:     return "directive outside case"
	case .Empty_Case_Name:            return "empty case name"
	case .Empty_Case:                 return "case needs feed and expect directives"
	case .Unclosed_Case:              return "unclosed case"
	case .Invalid_Hex:                return "invalid hexadecimal input"
	case .Limit_Exceeded:             return "fixture limit exceeded"
	}
	return "unknown error"
}
