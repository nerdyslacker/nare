package config

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import drawing "../render"
import vt "../vt"

MAX_CONFIG_BYTES :: 64 * 1024
MIN_FONT_SIZE :: 6
MAX_FONT_SIZE :: 96
MAX_SCROLLBACK_LINES :: 1_000_000

Error :: enum {
	None,
	File,
	Too_Large,
	Syntax,
	Unknown_Section,
	Unknown_Key,
	Invalid_Value,
}

Result :: struct {
	error: Error,
	line: int,
}

Settings :: struct {
	renderer: drawing.Kind,
	ligatures: bool,
	font: string,
	font_size: int,
	title: string,
	url_opener: string,
	scrollback_lines: int,
	osc52_policy: vt.OSC52_Policy,
}

settings_init :: proc(settings: ^Settings) {
	settings.renderer = .CPU
	settings.ligatures = true
	settings.font = strings.clone("monospace")
	settings.font_size = 16
	settings.title = strings.clone("nare")
	settings.url_opener = strings.clone("xdg-open")
	settings.scrollback_lines = 10000
	settings.osc52_policy = .Disabled
}

settings_destroy :: proc(settings: ^Settings) {
	delete(settings.font)
	delete(settings.title)
	delete(settings.url_opener)
	settings^ = {}
}

default_path :: proc() -> string {
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if base != "" do return fmt.aprintf("%s/nare/nare.conf", base)
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" do return fmt.aprintf("%s/.config/nare/nare.conf", home)
	return ""
}

load :: proc(settings: ^Settings, path: string, missing_ok: bool = false) -> Result {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		if missing_ok && stat_error == .Not_Exist do return {}
		return {error = .File}
	}
	if info.size < 0 || info.size > MAX_CONFIG_BYTES do return {error = .Too_Large}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil do return {error = .File}
	defer delete(data)
	return parse(settings, string(data))
}

parse :: proc(settings: ^Settings, contents: string) -> Result {
	remaining := contents
	section := "main"
	line_number := 0
	for {
		line, ok := strings.split_lines_iterator(&remaining)
		if !ok do break
		line_number += 1
		line = strings.trim_space(line)
		if line == "" || line[0] == '#' || line[0] == ';' do continue
		if line[0] == '[' {
			if len(line) < 3 || line[len(line)-1] != ']' do return {error = .Syntax, line = line_number}
			section = strings.trim_space(line[1:len(line)-1])
			if section != "main" && section != "scrollback" && section != "url" && section != "security" {
				return {error = .Unknown_Section, line = line_number}
			}
			continue
		}
		separator := strings.index_byte(line, '=')
		if separator <= 0 do return {error = .Syntax, line = line_number}
		key := strings.trim_space(line[:separator])
		value := strings.trim_space(line[separator+1:])
		if key == "" do return {error = .Syntax, line = line_number}
		if result := apply(settings, section, key, value); result != .None {
			return {error = result, line = line_number}
		}
	}
	return {}
}

apply :: proc(settings: ^Settings, section, key, value: string) -> Error {
	if section == "main" {
		switch key {
		case "renderer":
			switch value {
			case "cpu": settings.renderer = .CPU
			case "gpu": settings.renderer = .GPU
			case "auto": settings.renderer = .Auto
			case: return .Invalid_Value
			}
		case "font":
			if value == "" do return .Invalid_Value
			replace_string(&settings.font, value)
		case "font-size":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < MIN_FONT_SIZE || parsed > MAX_FONT_SIZE do return .Invalid_Value
			settings.font_size = parsed
		case "ligatures":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.ligatures = parsed
		case "title":
			if value == "" do return .Invalid_Value
			replace_string(&settings.title, value)
		case: return .Unknown_Key
		}
	} else if section == "scrollback" {
		if key != "lines" do return .Unknown_Key
		parsed, ok := strconv.parse_int(value)
		if !ok || parsed < 0 || parsed > MAX_SCROLLBACK_LINES do return .Invalid_Value
		settings.scrollback_lines = parsed
	} else if section == "url" {
		if key != "opener" do return .Unknown_Key
		if value == "" do return .Invalid_Value
		replace_string(&settings.url_opener, value)
	} else if section == "security" {
		if key != "osc52" do return .Unknown_Key
		switch value {
		case "disabled": settings.osc52_policy = .Disabled
		case "copy-enabled": settings.osc52_policy = .Copy
		case "paste-enabled": settings.osc52_policy = .Paste
		case "enabled": settings.osc52_policy = .Enabled
		case: return .Invalid_Value
		}
	} else {
		return .Unknown_Section
	}
	return .None
}

parse_bool :: proc(value: string) -> (bool, bool) {
	switch value {
	case "true", "yes", "on": return true, true
	case "false", "no", "off": return false, true
	case: return false, false
	}
}

replace_string :: proc(target: ^string, value: string) {
	replacement := strings.clone(value)
	delete(target^)
	target^ = replacement
}

error_string :: proc(error: Error) -> string {
	switch error {
	case .None: return "none"
	case .File: return "could not read config file"
	case .Too_Large: return "config file exceeds 64 KiB"
	case .Syntax: return "invalid config syntax"
	case .Unknown_Section: return "unknown config section"
	case .Unknown_Key: return "unknown config key"
	case .Invalid_Value: return "invalid config value"
	}
	return "unknown config error"
}
