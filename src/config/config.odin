package config

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import drawing "../render"
import graphics "../graphics"
import vt "../vt"

MAX_CONFIG_BYTES :: 64 * 1024
MIN_FONT_SIZE :: 6
MAX_FONT_SIZE :: 96
MAX_SCROLLBACK_LINES :: 1_000_000
MAX_TERM_BYTES :: 64

Tab_Edge :: enum { Top, Bottom }
Tab_Style :: enum { Separator, Hidden }
Cursor_Shape :: enum { Block, Beam, Underline }

Window_Settings :: struct {
	background_opacity: f32,
	padding: int,
	decorations: bool,
	confirm_close: bool,
	audio_bell: bool,
	copy_on_select: bool,
}

Tab_Settings :: struct {
	enabled: bool,
	edge: Tab_Edge,
	style: Tab_Style,
	separator: string,
	minimum: int,
	title_template: string,
	active_bold: bool,
}

UI_Colors :: struct {
	url: u32,
	active_border: u32,
	inactive_border: u32,
	bell_border: u32,
	active_tab_foreground: u32,
	active_tab_background: u32,
	inactive_tab_foreground: u32,
	inactive_tab_background: u32,
	tab_bar_background: u32,
}

Bindings :: struct {
	new_tab, previous_tab, next_tab: string,
	close_pane, split_horizontal, split_vertical: string,
	focus_left, focus_right, focus_up, focus_down: string,
	toggle_stack, swap_pane, move_tab_left, move_tab_right: string,
	copy, paste, font_increase, font_decrease, font_reset: string,
}

Cursor_Settings :: struct {
	shape: Cursor_Shape,
	blink: bool,
	blink_interval_ms: int,
	beam_width: int,
	underline_height: int,
}

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
	bold_font: string,
	italic_font: string,
	bold_italic_font: string,
	font_size: int,
	font_bold: bool,
	cell_width_percent: int,
	cell_height_percent: int,
	title: string,
	url_opener: string,
	shell_output_pipe: string,
	term: string,
	working_directory: string,
	scrollback_lines: int,
	osc52_policy: vt.OSC52_Policy,
	graphics_limits: graphics.Limits,
	theme: drawing.Theme,
	ui_colors: UI_Colors,
	window: Window_Settings,
	tabs: Tab_Settings,
	bindings: Bindings,
	cursor: Cursor_Settings,
}

settings_init :: proc(settings: ^Settings) {
	settings.renderer = .Auto
	settings.ligatures = true
	settings.font = strings.clone("monospace")
	settings.bold_font = strings.clone("auto")
	settings.italic_font = strings.clone("auto")
	settings.bold_italic_font = strings.clone("auto")
	settings.font_size = 16
	settings.font_bold = false
	settings.cell_width_percent = 100
	settings.cell_height_percent = 100
	settings.title = strings.clone("nare")
	settings.url_opener = strings.clone("xdg-open")
	settings.shell_output_pipe = strings.clone("")
	settings.term = strings.clone("xterm-256color")
	settings.working_directory = strings.clone("")
	settings.scrollback_lines = 10000
	settings.osc52_policy = .Disabled
	settings.graphics_limits = graphics.limits_default()
	settings.theme = drawing.DEFAULT_THEME
	settings.ui_colors = {
		url = 0x4fc3d9,
		active_border = 0x9c49fc,
		inactive_border = 0x334b68,
		bell_border = 0xff6b7a,
		active_tab_foreground = 0xfffdfd,
		active_tab_background = 0x9c49fc,
		inactive_tab_foreground = 0xb9c7da,
		inactive_tab_background = 0x071c33,
		tab_bar_background = 0x011224,
	}
	settings.window = {
		background_opacity = 1,
		padding = 0,
		decorations = true,
		confirm_close = false,
		audio_bell = false,
		copy_on_select = false,
	}
	settings.tabs.enabled = true
	settings.tabs.edge = .Top
	settings.tabs.style = .Separator
	settings.tabs.separator = strings.clone(" | ")
	settings.tabs.minimum = 2
	settings.tabs.title_template = strings.clone("{index}: {title}")
	settings.tabs.active_bold = true
	settings.bindings = {
		new_tab = strings.clone("alt+t"),
		previous_tab = strings.clone("alt+left"),
		next_tab = strings.clone("alt+right"),
		close_pane = strings.clone("alt+w"),
		split_horizontal = strings.clone("alt+enter"),
		split_vertical = strings.clone("alt+shift+enter"),
		focus_left = strings.clone("alt+shift+left"),
		focus_right = strings.clone("alt+shift+right"),
		focus_up = strings.clone("alt+up"),
		focus_down = strings.clone("alt+down"),
		toggle_stack = strings.clone("alt+shift+z"),
		swap_pane = strings.clone("alt+shift+equal"),
		move_tab_left = strings.clone("alt+control+shift+left"),
		move_tab_right = strings.clone("alt+control+shift+right"),
		copy = strings.clone("alt+c"),
		paste = strings.clone("alt+v"),
		font_increase = strings.clone("alt+equal"),
		font_decrease = strings.clone("alt+minus"),
		font_reset = strings.clone("alt+0"),
	}
	settings.cursor = {shape = .Block, blink = true, blink_interval_ms = 500, beam_width = 2, underline_height = 2}
}

settings_destroy :: proc(settings: ^Settings) {
	delete(settings.font)
	delete(settings.bold_font)
	delete(settings.italic_font)
	delete(settings.bold_italic_font)
	delete(settings.title)
	delete(settings.url_opener)
	delete(settings.shell_output_pipe)
	delete(settings.term)
	delete(settings.working_directory)
	delete(settings.tabs.separator)
	delete(settings.tabs.title_template)
	destroy_bindings(&settings.bindings)
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
			if section != "main" && section != "scrollback" && section != "url" && section != "shell" && section != "security" && section != "graphics" && section != "window" && section != "tabs" && section != "colors" && section != "bindings" && section != "cursor" {
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
		case "bold-font":
			if value == "" do return .Invalid_Value
			replace_string(&settings.bold_font, value)
		case "italic-font":
			if value == "" do return .Invalid_Value
			replace_string(&settings.italic_font, value)
		case "bold-italic-font":
			if value == "" do return .Invalid_Value
			replace_string(&settings.bold_italic_font, value)
		case "font-size":
			parsed, ok := strconv.parse_f32(value)
			size := int(parsed+0.5)
			if !ok || size < MIN_FONT_SIZE || size > MAX_FONT_SIZE do return .Invalid_Value
			settings.font_size = size
		case "font-bold":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.font_bold = parsed
		case "cell-width-percent":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 50 || parsed > 300 do return .Invalid_Value
			settings.cell_width_percent = parsed
		case "cell-height-percent":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 50 || parsed > 300 do return .Invalid_Value
			settings.cell_height_percent = parsed
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
	} else if section == "shell" {
		switch key {
		case "output-pipe":
			if value == "" do return .Invalid_Value
			replace_string(&settings.shell_output_pipe, value)
		case "term":
			if !valid_term(value) do return .Invalid_Value
			replace_string(&settings.term, value)
		case "working-directory":
			if value == "" || !os.is_directory(value) do return .Invalid_Value
			replace_string(&settings.working_directory, value)
		case: return .Unknown_Key
		}
	} else if section == "security" {
		if key != "osc52" do return .Unknown_Key
		switch value {
		case "disabled": settings.osc52_policy = .Disabled
		case "copy-enabled": settings.osc52_policy = .Copy
		case "paste-enabled": settings.osc52_policy = .Paste
		case "enabled": settings.osc52_policy = .Enabled
		case: return .Invalid_Value
		}
	} else if section == "graphics" {
		switch key {
		case "cache-size-mib":
			parsed, ok := parse_mebibytes(value, 1)
			if !ok do return .Invalid_Value
			settings.graphics_limits.cache_bytes = parsed
		case "kitty-cache-size-mib":
			parsed, ok := parse_mebibytes(value, 0)
			if !ok do return .Invalid_Value
			settings.graphics_limits.kitty_cache_bytes = parsed
		case "sixel-cache-size-mib":
			parsed, ok := parse_mebibytes(value, 0)
			if !ok do return .Invalid_Value
			settings.graphics_limits.sixel_cache_bytes = parsed
		case "iterm2-cache-size-mib":
			parsed, ok := parse_mebibytes(value, 0)
			if !ok do return .Invalid_Value
			settings.graphics_limits.iterm2_cache_bytes = parsed
		case "max-images":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed <= 0 || parsed > graphics.MAX_ACTIVE_IMAGES do return .Invalid_Value
			settings.graphics_limits.max_images = parsed
		case "max-placements":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed <= 0 || parsed > graphics.MAX_ACTIVE_PLACEMENTS do return .Invalid_Value
			settings.graphics_limits.max_placements = parsed
		case "max-image-dimension":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed <= 0 || parsed > graphics.MAX_IMAGE_DIMENSION do return .Invalid_Value
			settings.graphics_limits.max_image_dimension = parsed
		case "max-image-pixels":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed <= 0 || parsed > graphics.MAX_IMAGE_PIXELS do return .Invalid_Value
			settings.graphics_limits.max_image_pixels = parsed
		case "max-image-size-mib":
			parsed, ok := parse_mebibytes(value, 1)
			if !ok || parsed > graphics.MAX_IMAGE_BYTES do return .Invalid_Value
			settings.graphics_limits.max_image_bytes = parsed
		case "max-sixel-repeat":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed <= 0 || parsed > graphics.MAX_SIXEL_REPEAT do return .Invalid_Value
			settings.graphics_limits.max_sixel_repeat = parsed
		case "max-sixel-colors":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed <= 0 || parsed > graphics.MAX_SIXEL_COLORS do return .Invalid_Value
			settings.graphics_limits.max_sixel_colors = parsed
		case: return .Unknown_Key
		}
	} else if section == "window" {
		switch key {
		case "background-opacity":
			parsed, ok := strconv.parse_f32(value)
			if !ok || parsed < 0 || parsed > 1 do return .Invalid_Value
			settings.window.background_opacity = parsed
		case "padding":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 0 || parsed > 128 do return .Invalid_Value
			settings.window.padding = parsed
		case "decorations":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.window.decorations = parsed
		case "confirm-close":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.window.confirm_close = parsed
		case "audio-bell":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.window.audio_bell = parsed
		case "copy-on-select":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.window.copy_on_select = parsed
		case "enabled-layouts":
			if value != "splits,stack" && value != "stack,splits" && value != "splits" && value != "stack" do return .Invalid_Value
		case: return .Unknown_Key
		}
	} else if section == "tabs" {
		switch key {
		case "enabled":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.tabs.enabled = parsed
		case "edge":
			switch value {
			case "top": settings.tabs.edge = .Top
			case "bottom": settings.tabs.edge = .Bottom
			case: return .Invalid_Value
			}
		case "style":
			switch value {
			case "separator": settings.tabs.style = .Separator
			case "hidden": settings.tabs.style = .Hidden
			case: return .Invalid_Value
			}
		case "separator":
			parsed, ok := parse_string(value)
			if !ok do return .Invalid_Value
			replace_string(&settings.tabs.separator, parsed)
		case "minimum":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 1 || parsed > 64 do return .Invalid_Value
			settings.tabs.minimum = parsed
		case "title-template":
			parsed, ok := parse_string(value)
			if !ok || parsed == "" do return .Invalid_Value
			replace_string(&settings.tabs.title_template, parsed)
		case "active-font-style":
			switch value {
			case "bold": settings.tabs.active_bold = true
			case "normal": settings.tabs.active_bold = false
			case: return .Invalid_Value
			}
		case: return .Unknown_Key
		}
	} else if section == "colors" {
		parsed, ok := parse_color(value)
		if !ok do return .Invalid_Value
		switch key {
		case "foreground": settings.theme.foreground = parsed
		case "background": settings.theme.background = parsed
		case "selection-foreground": settings.theme.selection_foreground = parsed
		case "selection-background": settings.theme.selection_background = parsed
		case "cursor": settings.theme.cursor = parsed
		case "cursor-text": settings.theme.cursor_text = parsed
		case "url": settings.ui_colors.url = parsed
		case "active-border": settings.ui_colors.active_border = parsed
		case "inactive-border": settings.ui_colors.inactive_border = parsed
		case "bell-border": settings.ui_colors.bell_border = parsed
		case "active-tab-foreground": settings.ui_colors.active_tab_foreground = parsed
		case "active-tab-background": settings.ui_colors.active_tab_background = parsed
		case "inactive-tab-foreground": settings.ui_colors.inactive_tab_foreground = parsed
		case "inactive-tab-background": settings.ui_colors.inactive_tab_background = parsed
		case "tab-bar-background": settings.ui_colors.tab_bar_background = parsed
		case:
			if len(key) < 6 || key[:5] != "color" do return .Unknown_Key
			index, index_ok := strconv.parse_int(key[5:])
			if !index_ok || index < 0 || index >= len(settings.theme.ansi) do return .Unknown_Key
			settings.theme.ansi[index] = parsed
		}
	} else if section == "bindings" {
		if !valid_chord(value) do return .Invalid_Value
		switch key {
		case "new-tab": replace_string(&settings.bindings.new_tab, value)
		case "previous-tab": replace_string(&settings.bindings.previous_tab, value)
		case "next-tab": replace_string(&settings.bindings.next_tab, value)
		case "close-pane": replace_string(&settings.bindings.close_pane, value)
		case "split-horizontal": replace_string(&settings.bindings.split_horizontal, value)
		case "split-vertical": replace_string(&settings.bindings.split_vertical, value)
		case "focus-left": replace_string(&settings.bindings.focus_left, value)
		case "focus-right": replace_string(&settings.bindings.focus_right, value)
		case "focus-up": replace_string(&settings.bindings.focus_up, value)
		case "focus-down": replace_string(&settings.bindings.focus_down, value)
		case "toggle-stack": replace_string(&settings.bindings.toggle_stack, value)
		case "swap-pane": replace_string(&settings.bindings.swap_pane, value)
		case "move-tab-left": replace_string(&settings.bindings.move_tab_left, value)
		case "move-tab-right": replace_string(&settings.bindings.move_tab_right, value)
		case "copy": replace_string(&settings.bindings.copy, value)
		case "paste": replace_string(&settings.bindings.paste, value)
		case "font-increase": replace_string(&settings.bindings.font_increase, value)
		case "font-decrease": replace_string(&settings.bindings.font_decrease, value)
		case "font-reset": replace_string(&settings.bindings.font_reset, value)
		case: return .Unknown_Key
		}
	} else if section == "cursor" {
		switch key {
		case "shape":
			switch value {
			case "block": settings.cursor.shape = .Block
			case "beam", "bar": settings.cursor.shape = .Beam
			case "underline": settings.cursor.shape = .Underline
			case: return .Invalid_Value
			}
		case "blink":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.cursor.blink = parsed
		case "blink-interval-ms":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 100 || parsed > 5000 do return .Invalid_Value
			settings.cursor.blink_interval_ms = parsed
		case "beam-width":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 1 || parsed > 16 do return .Invalid_Value
			settings.cursor.beam_width = parsed
		case "underline-height":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 1 || parsed > 16 do return .Invalid_Value
			settings.cursor.underline_height = parsed
		case: return .Unknown_Key
		}
	} else {
		return .Unknown_Section
	}
	return .None
}

valid_chord :: proc(value: string) -> bool {
	if value == "" || len(value) > 64 do return false
	for character in value {
		if character >= 'a' && character <= 'z' do continue
		if character >= '0' && character <= '9' do continue
		if character == '+' || character == '-' do continue
		return false
	}
	return true
}

destroy_bindings :: proc(bindings: ^Bindings) {
	delete(bindings.new_tab); delete(bindings.previous_tab); delete(bindings.next_tab)
	delete(bindings.close_pane); delete(bindings.split_horizontal); delete(bindings.split_vertical)
	delete(bindings.focus_left); delete(bindings.focus_right); delete(bindings.focus_up); delete(bindings.focus_down)
	delete(bindings.toggle_stack); delete(bindings.swap_pane); delete(bindings.move_tab_left); delete(bindings.move_tab_right)
	delete(bindings.copy); delete(bindings.paste); delete(bindings.font_increase); delete(bindings.font_decrease); delete(bindings.font_reset)
	bindings^ = {}
}

parse_string :: proc(value: string) -> (string, bool) {
	if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'')) {
		return value[1:len(value)-1], true
	}
	return value, value != ""
}

parse_color :: proc(value: string) -> (u32, bool) {
	text := value
	if strings.has_prefix(text, "#") do text = text[1:]
	if len(text) != 6 do return 0, false
	parsed_bytes := 0
	parsed, ok := strconv.parse_u64(text, 16, &parsed_bytes)
	if !ok || parsed_bytes != len(text) do return 0, false
	return u32(parsed), true
}

parse_mebibytes :: proc(value: string, minimum: int) -> (int, bool) {
	parsed, ok := strconv.parse_int(value)
	maximum := graphics.MAX_CACHE_BYTES/(1024*1024)
	if !ok || parsed < minimum || parsed > maximum do return 0, false
	return parsed*1024*1024, true
}

valid_term :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) > MAX_TERM_BYTES do return false
	for character in value {
		if character >= 'a' && character <= 'z' do continue
		if character >= 'A' && character <= 'Z' do continue
		if character >= '0' && character <= '9' do continue
		if character == '-' || character == '_' || character == '.' || character == '+' do continue
		return false
	}
	return true
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
