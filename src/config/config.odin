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
MAX_STARTUP_COMMAND_BYTES :: 4096
MAX_TMUX_PROFILES :: 32
MAX_TMUX_PROFILE_BINDINGS :: 64
MAX_TAB_RULES :: 64
MAX_TAB_RULE_BINDINGS :: 64

Tab_Edge :: enum { Top, Bottom }
Tab_Style :: enum { Separator, Hidden }
Cursor_Shape :: enum { Block, Beam, Underline }
Tmux_Target :: enum { New_Tab, New_Window }
Tab_Rule_Target :: enum { New_Tab, New_Pane_Horizontal, New_Pane_Vertical, New_Window }
Tab_Rule_Reuse :: enum { Always_New, Focus }
Quake_Horizontal_Align :: enum { Left, Center, Right }
Quake_Animation :: enum { None, Slide, Fade }
Status_Position :: enum { Top, Bottom }
Status_Module :: enum { Mode, Session, Host, Cwd, Git, Command, Size, Tabs, Clock, Battery, Resource, Zoom, Jobs }
STATUS_MODULE_COUNT :: int(Status_Module.Jobs)+1
Jobs_Sort :: enum { Running_First, Newest }
Jobs_Scope :: enum { Window }

Status_Module_Style :: struct {
	foreground, background: u32,
	foreground_set, background_set: bool,
	label: string,
}

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
	root_tab_background: u32,
	tab_bar_background: u32,
}

Bindings :: struct {
	new_tab, previous_tab, next_tab: string,
	close_pane, split_horizontal, split_vertical: string,
	focus_left, focus_right, focus_up, focus_down: string,
	toggle_stack, swap_pane, move_tab_left, move_tab_right: string,
	copy, paste, font_increase, font_decrease, font_reset: string,
	tmux_new_tab, tmux_new_window, tmux_attach_last: string,
	tmux_detach, tmux_reconnect: string,
	toggle_statusbar, show_jobs, reload_config: string,
}

Statusbar_Jobs_Settings :: struct {
	enabled: bool,
	max_visible: int,
	show_elapsed, show_completed, show_failed, show_progress: bool,
	completed_timeout_seconds, failed_timeout_seconds: int,
	success_background, failure_background: u32,
	sort: Jobs_Sort,
	scope: Jobs_Scope,
}

Statusbar_Settings :: struct {
	enabled: bool,
	position: Status_Position,
	height: int,
	left, center, right: [dynamic]Status_Module,
	separator: string,
	show_in_quake, border, module_blocks, auto_hide: bool,
	background, foreground, accent: u32,
	module_styles: [STATUS_MODULE_COUNT]Status_Module_Style,
	resource_cpu_label, resource_ram_label, resource_storage_label: string,
	cwd_full_path: bool,
	cwd_depth_marker: string,
	clock_format: string,
	jobs: Statusbar_Jobs_Settings,
	auto_hide_delay_ms: int,
	clock_update_ms, cwd_update_ms, git_update_ms, command_update_ms, battery_update_ms, resource_update_ms: int,
}

Quake_Settings :: struct {
	enabled: bool,
	monitor: string,
	width_percent, height_percent: int,
	horizontal_align: Quake_Horizontal_Align,
	x_offset, y_offset: int,
	hide_on_focus_loss: bool,
	start_hidden: bool,
	animation: Quake_Animation,
	animation_duration_ms: int,
	keep_above: bool,
	skip_taskbar: bool,
}

Tmux_Profile :: struct {
	name: string,
	ssh_host: string,
	session: string,
	target: Tmux_Target,
	target_set: bool,
}

Tmux_Profile_Binding :: struct {
	profile: string,
	chord: string,
}

Tab_Rule :: struct {
	name, command, working_directory, title, job_name: string,
	target: Tab_Rule_Target,
	reuse: Tab_Rule_Reuse,
	track_job: bool,
	source_line, command_line: int,
}

Tab_Rule_Binding :: struct {
	rule, chord: string,
	source_line: int,
}

Cursor_Settings :: struct {
	shape: Cursor_Shape,
	blink: bool,
	blink_interval_ms: int,
	beam_width: int,
	underline_height: int,
}

Tmux_Settings :: struct {
	enabled: bool,
	auto_detect: bool,
	default_target: Tmux_Target,
	active_tab_color: u32,
	auto_reconnect: bool,
	explicit_launch: bool,
	explicit_ssh_host: string,
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
	bold_is_bright: bool,
	cell_width_percent: int,
	cell_height_percent: int,
	title: string,
	url_opener: string,
	shell_output_pipe: string,
	startup_command: string,
	term: string,
	working_directory: string,
	launch_rule: string,
	scrollback_lines: int,
	scrollbar_enabled: bool,
	osc52_policy: vt.OSC52_Policy,
	graphics_limits: graphics.Limits,
	theme: drawing.Theme,
	ui_colors: UI_Colors,
	window: Window_Settings,
	tabs: Tab_Settings,
	bindings: Bindings,
	cursor: Cursor_Settings,
	tmux: Tmux_Settings,
	quake: Quake_Settings,
	statusbar: Statusbar_Settings,
	tmux_profiles: [dynamic]Tmux_Profile,
	tmux_profile_bindings: [dynamic]Tmux_Profile_Binding,
	tab_rules: [dynamic]Tab_Rule,
	tab_rule_bindings: [dynamic]Tab_Rule_Binding,
	config_path: string,
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
	settings.bold_is_bright = false
	settings.cell_width_percent = 100
	settings.cell_height_percent = 100
	settings.title = strings.clone("nare")
	settings.url_opener = strings.clone("xdg-open")
	settings.shell_output_pipe = strings.clone("")
	settings.startup_command = strings.clone("")
	settings.term = strings.clone("xterm-256color")
	settings.working_directory = strings.clone("")
	settings.scrollback_lines = 10000
	settings.scrollbar_enabled = true
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
		root_tab_background = 0xff6b7a,
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
		tmux_new_tab = strings.clone("alt+control+t"),
		tmux_new_window = strings.clone("alt+control+n"),
		tmux_attach_last = strings.clone("alt+control+a"),
		tmux_detach = strings.clone("alt+control+d"),
		tmux_reconnect = strings.clone("alt+control+r"),
		toggle_statusbar = strings.clone("alt+shift+b"),
		show_jobs = strings.clone("alt+shift+j"),
		reload_config = strings.clone("alt+shift+r"),
	}
	settings.statusbar = {
		position = .Bottom, height = 24, separator = strings.clone(" | "), show_in_quake = true, border = true,
		background = 0x071c33, foreground = 0xb9c7da, accent = 0x13ba19,
		clock_format = strings.clone("%H:%M"), auto_hide_delay_ms = 600, clock_update_ms = 1000, cwd_update_ms = 2000,
		git_update_ms = 2000, command_update_ms = 1000,
		battery_update_ms = 5000, resource_update_ms = 2000,
	}
	settings.statusbar.module_styles[int(Status_Module.Git)].label = strings.clone("git:")
	settings.statusbar.module_styles[int(Status_Module.Battery)].label = strings.clone("BAT")
	settings.statusbar.module_styles[int(Status_Module.Clock)].label = strings.clone("")
	settings.statusbar.module_styles[int(Status_Module.Jobs)].label = strings.clone("")
	settings.statusbar.cwd_full_path = true
	settings.statusbar.cwd_depth_marker = strings.clone("..")
	settings.statusbar.resource_cpu_label = strings.clone("CPU")
	settings.statusbar.resource_ram_label = strings.clone("RAM")
	settings.statusbar.resource_storage_label = strings.clone("STORAGE")
	settings.statusbar.jobs = {
		enabled = true, max_visible = 3, show_elapsed = true, show_completed = true,
		show_failed = true, show_progress = true, completed_timeout_seconds = 10,
		failed_timeout_seconds = 30, success_background = 0x237a4b, failure_background = 0xa83246,
		sort = .Running_First, scope = .Window,
	}
	append(&settings.statusbar.left, .Mode, .Session)
	append(&settings.statusbar.right, .Resource, .Battery, .Size, .Clock)
	settings.cursor = {shape = .Block, blink = true, blink_interval_ms = 500, beam_width = 2, underline_height = 2}
	settings.tmux = {enabled = true, auto_detect = true, default_target = .New_Tab, active_tab_color = 0x13ba19, auto_reconnect = true}
	settings.quake = {
		monitor = strings.clone("focused"), width_percent = 100, height_percent = 40,
		horizontal_align = .Center, animation = .Slide, animation_duration_ms = 140,
		keep_above = true, skip_taskbar = true,
	}
}

settings_destroy :: proc(settings: ^Settings) {
	delete(settings.font)
	delete(settings.bold_font)
	delete(settings.italic_font)
	delete(settings.bold_italic_font)
	delete(settings.title)
	delete(settings.url_opener)
	delete(settings.shell_output_pipe)
	delete(settings.startup_command)
	delete(settings.term)
	delete(settings.working_directory)
	delete(settings.launch_rule)
	delete(settings.config_path)
	delete(settings.quake.monitor)
	delete(settings.tabs.separator)
	delete(settings.tabs.title_template)
	delete(settings.statusbar.left)
	delete(settings.statusbar.center)
	delete(settings.statusbar.right)
	delete(settings.statusbar.separator)
	delete(settings.statusbar.clock_format)
	delete(settings.statusbar.resource_cpu_label)
	delete(settings.statusbar.resource_ram_label)
	delete(settings.statusbar.resource_storage_label)
	delete(settings.statusbar.cwd_depth_marker)
	for &style in settings.statusbar.module_styles do delete(style.label)
	delete(settings.tmux.explicit_ssh_host)
	destroy_bindings(&settings.bindings)
	for &profile in settings.tmux_profiles do destroy_tmux_profile(&profile)
	delete(settings.tmux_profiles)
	for &binding in settings.tmux_profile_bindings {
		delete(binding.profile)
		delete(binding.chord)
	}
	delete(settings.tmux_profile_bindings)
	for &rule in settings.tab_rules do destroy_tab_rule(&rule)
	delete(settings.tab_rules)
	for &binding in settings.tab_rule_bindings {
		delete(binding.rule)
		delete(binding.chord)
	}
	delete(settings.tab_rule_bindings)
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
			if section != "main" && section != "scrollback" && section != "url" && section != "shell" && section != "security" && section != "graphics" && section != "window" && section != "tabs" && section != "colors" && section != "bindings" && section != "cursor" && section != "tmux" && section != "quake" && section != "statusbar" && section != "statusbar.jobs" && !status_module_section(section) && !tmux_profile_section(section) && !tab_rule_section(section) {
				return {error = .Unknown_Section, line = line_number}
			}
			if tmux_profile_section(section) {
				name := section[len("tmux.profile."):]
				if !valid_tmux_name(name) || ensure_tmux_profile(settings, name) == nil do return {error = .Invalid_Value, line = line_number}
			}
			if tab_rule_section(section) {
				name := section[len("tab."):]
				if !valid_tmux_name(name) || tab_rule(settings, name) != nil do return {error = .Invalid_Value, line = line_number}
				rule := ensure_tab_rule(settings, name)
				if rule == nil do return {error = .Invalid_Value, line = line_number}
				rule.source_line = line_number
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
		if tab_rule_section(section) && key == "command" {
			tab_rule(settings, section[len("tab."):]).command_line = line_number
		} else if section == "bindings" && strings.has_prefix(key, "tab.") {
			for &binding in settings.tab_rule_bindings do if binding.rule == key[len("tab."):] {binding.source_line = line_number; break}
		}
	}
	for binding in settings.tmux_profile_bindings {
		if tmux_profile(settings, binding.profile) == nil do return {error = .Invalid_Value, line = line_number}
	}
	for rule in settings.tab_rules {
		if rule.command == "" || !valid_command_line(rule.command) {
			return {error = .Invalid_Value, line = rule.command_line if rule.command_line > 0 else rule.source_line}
		}
	}
	for binding in settings.tab_rule_bindings {
		if tab_rule(settings, binding.rule) == nil || shortcut_conflicts(settings, binding.chord, binding.rule) do return {error = .Invalid_Value, line = binding.source_line}
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
		case "bold-is-bright":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.bold_is_bright = parsed
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
		switch key {
		case "lines":
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 0 || parsed > MAX_SCROLLBACK_LINES do return .Invalid_Value
			settings.scrollback_lines = parsed
		case "scrollbar":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.scrollbar_enabled = parsed
		case: return .Unknown_Key
		}
	} else if section == "url" {
		if key != "opener" do return .Unknown_Key
		if value == "" do return .Invalid_Value
		replace_string(&settings.url_opener, value)
	} else if section == "shell" {
		switch key {
		case "startup-command":
			if len(value) > MAX_STARTUP_COMMAND_BYTES do return .Invalid_Value
			replace_string(&settings.startup_command, value)
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
		case "root-tab-background": settings.ui_colors.root_tab_background = parsed
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
		case "font-increase", "zoom-in": replace_string(&settings.bindings.font_increase, value)
		case "font-decrease", "zoom-out": replace_string(&settings.bindings.font_decrease, value)
		case "font-reset", "zoom-reset": replace_string(&settings.bindings.font_reset, value)
		case "tmux-new-tab": replace_string(&settings.bindings.tmux_new_tab, value)
		case "tmux-new-window": replace_string(&settings.bindings.tmux_new_window, value)
		case "tmux-attach-last": replace_string(&settings.bindings.tmux_attach_last, value)
		case "tmux-detach": replace_string(&settings.bindings.tmux_detach, value)
		case "tmux-reconnect": replace_string(&settings.bindings.tmux_reconnect, value)
		case "toggle-statusbar": replace_string(&settings.bindings.toggle_statusbar, value)
		case "show-jobs": replace_string(&settings.bindings.show_jobs, value)
		case "reload-config": replace_string(&settings.bindings.reload_config, value)
		case:
			if strings.has_prefix(key, "tmux-profile.") {
				name := key[len("tmux-profile."):]
				if !valid_tmux_name(name) || !set_tmux_profile_binding(settings, name, value) do return .Invalid_Value
			} else if strings.has_prefix(key, "tab.") {
				name := key[len("tab."):]
				if !valid_tmux_name(name) || !set_tab_rule_binding(settings, name, value) do return .Invalid_Value
			} else {
				return .Unknown_Key
			}
		}
	} else if section == "statusbar" {
		switch key {
		case "enabled":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.statusbar.enabled = parsed
		case "position":
			switch value {
			case "top": settings.statusbar.position = .Top
			case "bottom": settings.statusbar.position = .Bottom
			case: return .Invalid_Value
			}
		case "height":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 16 || parsed > 128 do return .Invalid_Value
			settings.statusbar.height = parsed
		case "left": if !parse_status_modules(&settings.statusbar.left, value) do return .Invalid_Value
		case "center": if !parse_status_modules(&settings.statusbar.center, value) do return .Invalid_Value
		case "right": if !parse_status_modules(&settings.statusbar.right, value) do return .Invalid_Value
		case "separator":
			parsed, ok := parse_string(value); if !ok || len(parsed) > 32 do return .Invalid_Value
			replace_string(&settings.statusbar.separator, parsed)
		case "border":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.statusbar.border = parsed
		case "module-style":
			switch value {
			case "plain": settings.statusbar.module_blocks = false
			case "blocks": settings.statusbar.module_blocks = true
			case: return .Invalid_Value
			}
		case "auto-hide":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.statusbar.auto_hide = parsed
		case "auto-hide-delay-ms":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 0 || parsed > 10000 do return .Invalid_Value
			settings.statusbar.auto_hide_delay_ms = parsed
		case "show-in-quake":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.statusbar.show_in_quake = parsed
		case "background", "foreground", "accent":
			parsed, ok := parse_color(value); if !ok do return .Invalid_Value
			if key == "background" do settings.statusbar.background = parsed
			else if key == "foreground" do settings.statusbar.foreground = parsed
			else do settings.statusbar.accent = parsed
		case: return .Unknown_Key
		}
	} else if section == "statusbar.jobs" {
		style := &settings.statusbar.module_styles[int(Status_Module.Jobs)]
		switch key {
		case "label":
			parsed, ok := parse_string(value); if !ok || len(parsed) > 64 do return .Invalid_Value
			replace_string(&style.label, parsed)
		case "enabled":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.statusbar.jobs.enabled = parsed
		case "max-visible":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 1 || parsed > 16 do return .Invalid_Value
			settings.statusbar.jobs.max_visible = parsed
		case "show-elapsed", "show-completed", "show-failed", "show-progress":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			if key == "show-elapsed" do settings.statusbar.jobs.show_elapsed = parsed
			else if key == "show-completed" do settings.statusbar.jobs.show_completed = parsed
			else if key == "show-failed" do settings.statusbar.jobs.show_failed = parsed
			else do settings.statusbar.jobs.show_progress = parsed
		case "completed-timeout", "failed-timeout":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 0 || parsed > 86400 do return .Invalid_Value
			if key == "completed-timeout" do settings.statusbar.jobs.completed_timeout_seconds = parsed
			else do settings.statusbar.jobs.failed_timeout_seconds = parsed
		case "sort":
			switch value {
			case "running-first": settings.statusbar.jobs.sort = .Running_First
			case "newest": settings.statusbar.jobs.sort = .Newest
			case: return .Invalid_Value
			}
		case "scope":
			if value != "window" do return .Invalid_Value
			settings.statusbar.jobs.scope = .Window
		case "foreground", "background", "success-background", "failure-background":
			parsed, ok := parse_color(value); if !ok do return .Invalid_Value
			if key == "foreground" {style.foreground = parsed; style.foreground_set = true}
			else if key == "background" {style.background = parsed; style.background_set = true}
			else if key == "success-background" do settings.statusbar.jobs.success_background = parsed
			else do settings.statusbar.jobs.failure_background = parsed
		case: return .Unknown_Key
		}
	} else if status_module_section(section) {
		module, _ := status_module_from_name(section[len("statusbar."):])
		style := &settings.statusbar.module_styles[int(module)]
		switch key {
		case "full-path":
			if module != .Cwd do return .Unknown_Key
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.statusbar.cwd_full_path = parsed
		case "depth-marker":
			if module != .Cwd do return .Unknown_Key
			parsed, ok := parse_string(value); if !ok || len(parsed) == 0 || len(parsed) > 32 do return .Invalid_Value
			replace_string(&settings.statusbar.cwd_depth_marker, parsed)
		case "label":
			parsed, ok := parse_string(value); if !ok || len(parsed) > 64 do return .Invalid_Value
			replace_string(&style.label, parsed)
		case "cpu-label", "ram-label", "storage-label":
			if module != .Resource do return .Unknown_Key
			parsed, ok := parse_string(value); if !ok || len(parsed) > 64 do return .Invalid_Value
			if key == "cpu-label" do replace_string(&settings.statusbar.resource_cpu_label, parsed)
			else if key == "ram-label" do replace_string(&settings.statusbar.resource_ram_label, parsed)
			else do replace_string(&settings.statusbar.resource_storage_label, parsed)
		case "foreground", "background":
			parsed, ok := parse_color(value); if !ok do return .Invalid_Value
			if key == "foreground" {
				style.foreground = parsed
				style.foreground_set = true
			} else {
				style.background = parsed
				style.background_set = true
			}
		case "format":
			if module != .Clock do return .Unknown_Key
			parsed, ok := parse_string(value); if !ok || len(parsed) > 128 do return .Invalid_Value
			replace_string(&settings.statusbar.clock_format, parsed)
		case "update-ms":
			parsed, ok := strconv.parse_int(value)
			minimum := 250 if module == .Clock else 500
			if !ok || parsed < minimum || parsed > 60000 do return .Invalid_Value
			#partial switch module {
			case .Clock: settings.statusbar.clock_update_ms = parsed
			case .Cwd: settings.statusbar.cwd_update_ms = parsed
			case .Git: settings.statusbar.git_update_ms = parsed
			case .Command: settings.statusbar.command_update_ms = parsed
			case .Battery: settings.statusbar.battery_update_ms = parsed
			case .Resource: settings.statusbar.resource_update_ms = parsed
			case: return .Unknown_Key
			}
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
	} else if section == "quake" {
		switch key {
		case "enabled":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.quake.enabled = parsed
		case "monitor":
			if !valid_quake_monitor(value) do return .Invalid_Value
			replace_string(&settings.quake.monitor, value)
		case "position": if value != "top" do return .Invalid_Value
		case "width-percent":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 10 || parsed > 100 do return .Invalid_Value
			settings.quake.width_percent = parsed
		case "height-percent":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 10 || parsed > 100 do return .Invalid_Value
			settings.quake.height_percent = parsed
		case "horizontal-align":
			switch value {
			case "left": settings.quake.horizontal_align = .Left
			case "center": settings.quake.horizontal_align = .Center
			case "right": settings.quake.horizontal_align = .Right
			case: return .Invalid_Value
			}
		case "x-offset":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < -10000 || parsed > 10000 do return .Invalid_Value
			settings.quake.x_offset = parsed
		case "y-offset":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < -10000 || parsed > 10000 do return .Invalid_Value
			settings.quake.y_offset = parsed
		case "hide-on-focus-loss":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.quake.hide_on_focus_loss = parsed
		case "start-hidden":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.quake.start_hidden = parsed
		case "animation":
			switch value {
			case "none": settings.quake.animation = .None
			case "slide": settings.quake.animation = .Slide
			case "fade": settings.quake.animation = .Fade
			case: return .Invalid_Value
			}
		case "animation-duration-ms":
			parsed, ok := strconv.parse_int(value); if !ok || parsed < 0 || parsed > 2000 do return .Invalid_Value
			settings.quake.animation_duration_ms = parsed
		case "keep-above":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.quake.keep_above = parsed
		case "skip-taskbar":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			settings.quake.skip_taskbar = parsed
		case: return .Unknown_Key
		}
	} else if section == "tmux" {
		switch key {
		case "enabled":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.tmux.enabled = parsed
		case "auto-detect":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.tmux.auto_detect = parsed
		case "default-target":
			switch value {
			case "new-tab": settings.tmux.default_target = .New_Tab
			case "new-window": settings.tmux.default_target = .New_Window
			case: return .Invalid_Value
			}
		case "active-tab-color":
			parsed, ok := parse_color(value)
			if !ok do return .Invalid_Value
			settings.tmux.active_tab_color = parsed
		case "auto-reconnect":
			parsed, ok := parse_bool(value)
			if !ok do return .Invalid_Value
			settings.tmux.auto_reconnect = parsed
		case: return .Unknown_Key
		}
	} else if tmux_profile_section(section) {
		name := section[len("tmux.profile."):]
		profile := ensure_tmux_profile(settings, name)
		if profile == nil do return .Invalid_Value
		switch key {
		case "ssh-host":
			if !valid_tmux_name(value) do return .Invalid_Value
			replace_string(&profile.ssh_host, value)
		case "session":
			if !valid_tmux_name(value) do return .Invalid_Value
			replace_string(&profile.session, value)
		case "target":
			switch value {
			case "new-tab": profile.target = .New_Tab
			case "new-window": profile.target = .New_Window
			case: return .Invalid_Value
			}
			profile.target_set = true
		case: return .Unknown_Key
		}
	} else if tab_rule_section(section) {
		name := section[len("tab."):]
		rule := tab_rule(settings, name)
		if rule == nil do return .Invalid_Value
		switch key {
		case "command":
			parsed, ok := parse_string(value)
			if !ok || len(parsed) > MAX_STARTUP_COMMAND_BYTES do return .Invalid_Value
			replace_string(&rule.command, parsed)
		case "working-directory":
			parsed, ok := parse_string(value)
			if !ok || !set_rule_working_directory(rule, parsed) do return .Invalid_Value
		case "title":
			parsed, ok := parse_string(value)
			if !ok || len(parsed) > 256 do return .Invalid_Value
			replace_string(&rule.title, parsed)
		case "target":
			switch value {
			case "new-tab": rule.target = .New_Tab
			case "new-pane-horizontal": rule.target = .New_Pane_Horizontal
			case "new-pane-vertical": rule.target = .New_Pane_Vertical
			case "new-window": rule.target = .New_Window
			case: return .Invalid_Value
			}
		case "reuse":
			switch value {
			case "always-new": rule.reuse = .Always_New
			case "focus": rule.reuse = .Focus
			case: return .Invalid_Value
			}
		case "track-job":
			parsed, ok := parse_bool(value); if !ok do return .Invalid_Value
			rule.track_job = parsed
		case "job-name":
			parsed, ok := parse_string(value)
			if !ok || len(parsed) > 128 do return .Invalid_Value
			replace_string(&rule.job_name, parsed)
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
	delete(bindings.tmux_new_tab); delete(bindings.tmux_new_window); delete(bindings.tmux_attach_last)
	delete(bindings.tmux_detach); delete(bindings.tmux_reconnect)
	delete(bindings.toggle_statusbar); delete(bindings.show_jobs); delete(bindings.reload_config)
	bindings^ = {}
}

parse_status_modules :: proc(target: ^[dynamic]Status_Module, value: string) -> bool {
	parsed: [dynamic]Status_Module
	defer delete(parsed)
	remaining := value
	for remaining != "" {
		separator := strings.index_byte(remaining, ',')
		name := remaining
		if separator >= 0 {
			name = remaining[:separator]
			remaining = remaining[separator+1:]
		} else {
			remaining = ""
		}
		name = strings.trim_space(name)
		module, found := status_module_from_name(name)
		if !found do return false
		append(&parsed, module)
	}
	clear(target)
	append(target, ..parsed[:])
	return true
}

status_module_from_name :: proc(name: string) -> (Status_Module, bool) {
	switch name {
	case "mode": return .Mode, true
	case "session": return .Session, true
	case "host": return .Host, true
	case "cwd": return .Cwd, true
	case "git": return .Git, true
	case "command": return .Command, true
	case "size": return .Size, true
	case "tabs": return .Tabs, true
	case "clock": return .Clock, true
	case "battery": return .Battery, true
	case "resource", "resources": return .Resource, true
	case "zoom": return .Zoom, true
	case "jobs": return .Jobs, true
	}
	return {}, false
}

status_module_section :: proc(section: string) -> bool {
	if section == "statusbar.jobs" || !strings.has_prefix(section, "statusbar.") do return false
	_, found := status_module_from_name(section[len("statusbar."):])
	return found
}

valid_quake_monitor :: proc(value: string) -> bool {
	if value == "focused" || value == "primary" do return true
	if value == "" || len(value) > 128 do return false
	for character in value {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
		   (character >= '0' && character <= '9') || character == '-' || character == '_' || character == '.' {
			continue
		}
		return false
	}
	return true
}

tmux_profile :: proc(settings: ^Settings, name: string) -> ^Tmux_Profile {
	for &profile in settings.tmux_profiles do if profile.name == name do return &profile
	return nil
}

tmux_profile_target :: proc(settings: ^Settings, profile: ^Tmux_Profile) -> Tmux_Target {
	if profile != nil && profile.target_set do return profile.target
	return settings.tmux.default_target
}

ensure_tmux_profile :: proc(settings: ^Settings, name: string) -> ^Tmux_Profile {
	if profile := tmux_profile(settings, name); profile != nil do return profile
	if len(settings.tmux_profiles) >= MAX_TMUX_PROFILES do return nil
	append(&settings.tmux_profiles, Tmux_Profile{name = strings.clone(name)})
	return &settings.tmux_profiles[len(settings.tmux_profiles)-1]
}

set_tmux_profile_binding :: proc(settings: ^Settings, name, chord: string) -> bool {
	for &binding in settings.tmux_profile_bindings {
		if binding.profile == name {
			replace_string(&binding.chord, chord)
			return true
		}
	}
	if len(settings.tmux_profile_bindings) >= MAX_TMUX_PROFILE_BINDINGS do return false
	append(&settings.tmux_profile_bindings, Tmux_Profile_Binding{profile = strings.clone(name), chord = strings.clone(chord)})
	return true
}

tab_rule :: proc(settings: ^Settings, name: string) -> ^Tab_Rule {
	for &rule in settings.tab_rules do if rule.name == name do return &rule
	return nil
}

ensure_tab_rule :: proc(settings: ^Settings, name: string) -> ^Tab_Rule {
	if len(settings.tab_rules) >= MAX_TAB_RULES do return nil
	append(&settings.tab_rules, Tab_Rule{name = strings.clone(name)})
	return &settings.tab_rules[len(settings.tab_rules)-1]
}

set_tab_rule_binding :: proc(settings: ^Settings, name, chord: string) -> bool {
	for binding in settings.tab_rule_bindings do if binding.rule == name do return false
	if len(settings.tab_rule_bindings) >= MAX_TAB_RULE_BINDINGS do return false
	append(&settings.tab_rule_bindings, Tab_Rule_Binding{rule = strings.clone(name), chord = strings.clone(chord)})
	return true
}

set_rule_working_directory :: proc(rule: ^Tab_Rule, value: string) -> bool {
	if value == "~" || strings.has_prefix(value, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return false
		expanded := strings.concatenate({home, value[1:]})
		if !os.is_directory(expanded) {
			delete(expanded)
			return false
		}
		replace_string(&rule.working_directory, expanded)
		delete(expanded)
		return true
	} else if strings.has_prefix(value, "~") {
		return false
	}
	if !os.is_directory(value) do return false
	replace_string(&rule.working_directory, value)
	return true
}

tab_rule_section :: proc(section: string) -> bool {
	return strings.has_prefix(section, "tab.") && len(section) > len("tab.")
}

shortcut_conflicts :: proc(settings: ^Settings, chord, rule_name: string) -> bool {
	b := &settings.bindings
	if chord == b.new_tab || chord == b.previous_tab || chord == b.next_tab ||
	   chord == b.close_pane || chord == b.split_horizontal || chord == b.split_vertical ||
	   chord == b.focus_left || chord == b.focus_right || chord == b.focus_up || chord == b.focus_down ||
	   chord == b.toggle_stack || chord == b.swap_pane || chord == b.move_tab_left || chord == b.move_tab_right ||
	   chord == b.copy || chord == b.paste || chord == b.font_increase || chord == b.font_decrease || chord == b.font_reset ||
	   chord == b.tmux_new_tab || chord == b.tmux_new_window || chord == b.tmux_attach_last ||
	   chord == b.tmux_detach || chord == b.tmux_reconnect || chord == b.toggle_statusbar || chord == b.show_jobs ||
	   chord == b.reload_config {
		return true
	}
	for binding in settings.tmux_profile_bindings do if binding.chord == chord do return true
	for binding in settings.tab_rule_bindings do if binding.rule != rule_name && binding.chord == chord do return true
	return false
}

tmux_profile_section :: proc(section: string) -> bool {
	return strings.has_prefix(section, "tmux.profile.") && len(section) > len("tmux.profile.")
}

destroy_tab_rule :: proc(rule: ^Tab_Rule) {
	delete(rule.name)
	delete(rule.command)
	delete(rule.working_directory)
	delete(rule.title)
	delete(rule.job_name)
	rule^ = {}
}

valid_tmux_name :: proc(value: string) -> bool {
	if value == "" || len(value) > 128 || value[0] == '-' do return false
	for character in value {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
		   character >= '0' && character <= '9' || character == '_' || character == '-' || character == '.' {
			continue
		}
		return false
	}
	return true
}

destroy_tmux_profile :: proc(profile: ^Tmux_Profile) {
	delete(profile.name)
	delete(profile.ssh_host)
	delete(profile.session)
	profile^ = {}
}

parse_string :: proc(value: string) -> (string, bool) {
	if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'')) {
		return value[1:len(value)-1], true
	}
	return value, value != ""
}

valid_command_line :: proc(line: string) -> bool {
	quote: byte
	escaped := false
	started := false
	arguments := 0
	for character in transmute([]byte)line {
		if character == 0 do return false
		if escaped {
			escaped = false
			started = true
			continue
		}
		if quote != 0 {
			if character == quote do quote = 0
			else if character == '\\' && quote == '"' do escaped = true
			started = true
			continue
		}
		switch character {
		case '\\': escaped = true; started = true
		case '\'', '"': quote = character; started = true
		case ' ', '\t', '\r', '\n':
			if started {arguments += 1; started = false}
		case: started = true
		}
	}
	if escaped || quote != 0 do return false
	if started do arguments += 1
	return arguments > 0
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
