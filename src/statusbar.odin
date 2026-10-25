package main

import c "core:c"
import libc "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import config "config"
import vt "vt"

Statusbar_State :: struct {
	visible: bool,
	clock, battery, resource: string,
	last_clock, last_battery, last_resource: time.Time,
	cpu_total, cpu_idle: u64,
	cpu_ready: bool,
}

statusbar_destroy :: proc(state: ^Statusbar_State) {
	delete(state.clock)
	delete(state.battery)
	delete(state.resource)
	state^ = {}
}

statusbar_visible :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil || !workspace.statusbar.visible do return false
	return workspace.quake == nil || workspace.settings.statusbar.show_in_quake
}

statusbar_height :: proc(workspace: ^Workspace) -> int {
	return workspace.settings.statusbar.height if statusbar_visible(workspace) else 0
}

statusbar_has_module :: proc(settings: ^config.Statusbar_Settings, wanted: config.Status_Module) -> bool {
	for module in settings.left do if module == wanted do return true
	for module in settings.center do if module == wanted do return true
	for module in settings.right do if module == wanted do return true
	return false
}

statusbar_tick :: proc(workspace: ^Workspace, force: bool = false) {
	if !statusbar_visible(workspace) do return
	settings := &workspace.settings.statusbar
	now := time.now()
	changed := false
	if statusbar_has_module(settings, .Clock) && (force || time.since(workspace.statusbar.last_clock) >= time.Duration(settings.clock_update_ms)*time.Millisecond) {
		workspace.statusbar.last_clock = now
		changed = statusbar_update_clock(&workspace.statusbar, settings.clock_format) || changed
	}
	if statusbar_has_module(settings, .Battery) && (force || time.since(workspace.statusbar.last_battery) >= time.Duration(settings.battery_update_ms)*time.Millisecond) {
		workspace.statusbar.last_battery = now
		changed = statusbar_update_battery(&workspace.statusbar) || changed
	}
	if statusbar_has_module(settings, .Resource) && (force || time.since(workspace.statusbar.last_resource) >= time.Duration(settings.resource_update_ms)*time.Millisecond) {
		workspace.statusbar.last_resource = now
		changed = statusbar_update_resources(&workspace.statusbar) || changed
	}
	if changed && !force do workspace_draw_statusbar(workspace)
}

statusbar_update_clock :: proc(state: ^Statusbar_State, format: string) -> bool {
	format_c, format_error := strings.clone_to_cstring(format, context.temp_allocator)
	if format_error != nil do return false
	now := libc.time(nil)
	local := libc.localtime(&now)
	if local == nil do return statusbar_replace(&state.clock, "")
	buffer: [128]c.char
	count := libc.strftime(&buffer[0], len(buffer), format_c, local)
	if count == 0 do return statusbar_replace(&state.clock, "")
	return statusbar_replace(&state.clock, string(cstring(&buffer[0])))
}

statusbar_update_battery :: proc(state: ^Statusbar_State) -> bool {
	entries, directory_error := os.read_directory_by_path("/sys/class/power_supply", -1, context.temp_allocator)
	if directory_error != nil do return statusbar_replace(&state.battery, "")
	for entry in entries {
		base := fmt.tprintf("/sys/class/power_supply/%s", entry.name)
		type_data, type_error := os.read_entire_file(fmt.tprintf("%s/type", base), context.temp_allocator)
		if type_error != nil || strings.trim_space(string(type_data)) != "Battery" do continue
		capacity_data, capacity_error := os.read_entire_file(fmt.tprintf("%s/capacity", base), context.temp_allocator)
		if capacity_error != nil do continue
		capacity, ok := strconv.parse_int(strings.trim_space(string(capacity_data)))
		if !ok || capacity < 0 || capacity > 100 do continue
		status_data, _ := os.read_entire_file(fmt.tprintf("%s/status", base), context.temp_allocator)
		status := strings.trim_space(string(status_data))
		marker := ""
		if status == "Charging" do marker = "+"
		else if status == "Discharging" do marker = "-"
		return statusbar_replace(&state.battery, fmt.tprintf("BAT %d%%%s", capacity, marker))
	}
	return statusbar_replace(&state.battery, "")
}

statusbar_update_resources :: proc(state: ^Statusbar_State) -> bool {
	cpu_percent, cpu_ok := statusbar_cpu_percent(state)
	ram_percent, ram_ok := statusbar_ram_percent()
	storage_percent, storage_ok := statusbar_storage_percent()
	value := ""
	if cpu_ok && ram_ok && storage_ok {
		value = fmt.tprintf("CPU %d%% RAM %d%% STORAGE %d%%", cpu_percent, ram_percent, storage_percent)
	} else if ram_ok && storage_ok {
		value = fmt.tprintf("RAM %d%% STORAGE %d%%", ram_percent, storage_percent)
	}
	return statusbar_replace(&state.resource, value)
}

statusbar_cpu_percent :: proc(state: ^Statusbar_State) -> (int, bool) {
	data, err := os.read_entire_file("/proc/stat", context.temp_allocator)
	if err != nil do return 0, false
	line := string(data)
	if newline := strings.index_byte(line, '\n'); newline >= 0 do line = line[:newline]
	cursor := 3
	total, idle := u64(0), u64(0)
	field := 0
	for {
		for cursor < len(line) && (line[cursor] == ' ' || line[cursor] == '\t') do cursor += 1
		if cursor >= len(line) do break
		start := cursor
		for cursor < len(line) && line[cursor] >= '0' && line[cursor] <= '9' do cursor += 1
		if start == cursor do break
		value, ok := strconv.parse_u64(line[start:cursor])
		if !ok do return 0, false
		total += value
		if field == 3 || field == 4 do idle += value
		field += 1
	}
	if field < 4 do return 0, false
	if !state.cpu_ready {
		state.cpu_total, state.cpu_idle, state.cpu_ready = total, idle, true
		return 0, false
	}
	delta_total := total-state.cpu_total if total >= state.cpu_total else 0
	delta_idle := idle-state.cpu_idle if idle >= state.cpu_idle else 0
	state.cpu_total, state.cpu_idle = total, idle
	if delta_total == 0 do return 0, false
	busy := delta_total-delta_idle if delta_total >= delta_idle else 0
	return clamp(int(busy*100/delta_total), 0, 100), true
}

statusbar_ram_percent :: proc() -> (int, bool) {
	data, err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if err != nil do return 0, false
	total, available := u64(0), u64(0)
	remaining := string(data)
	for remaining != "" {
		line := remaining
		if newline := strings.index_byte(remaining, '\n'); newline >= 0 {
			line, remaining = remaining[:newline], remaining[newline+1:]
		} else do remaining = ""
		if strings.has_prefix(line, "MemTotal:") do total = statusbar_first_u64(line[len("MemTotal:"):])
		else if strings.has_prefix(line, "MemAvailable:") do available = statusbar_first_u64(line[len("MemAvailable:"):])
	}
	if total == 0 || available > total do return 0, false
	return int((total-available)*100/total), true
}

statusbar_first_u64 :: proc(value: string) -> u64 {
	start := 0
	for start < len(value) && (value[start] == ' ' || value[start] == '\t') do start += 1
	end := start
	for end < len(value) && value[end] >= '0' && value[end] <= '9' do end += 1
	if start == end do return 0
	result, ok := strconv.parse_u64(value[start:end])
	return result if ok else 0
}

statusbar_storage_percent :: proc() -> (int, bool) {
	info: posix.statvfs_t
	if posix.statvfs("/", &info) != .OK do return 0, false
	total := u64(info.f_blocks)
	available := u64(info.f_bavail)
	if total == 0 || available > total do return 0, false
	return int((total-available)*100/total), true
}

statusbar_replace :: proc(target: ^string, value: string) -> bool {
	if target^ == value do return false
	config.replace_string(target, value)
	return true
}

statusbar_group_text :: proc(workspace: ^Workspace, modules: []config.Status_Module) -> string {
	output := make([dynamic]byte, 0, 128, context.temp_allocator)
	for module in modules {
		value := statusbar_module_text(workspace, module)
		if value == "" do continue
		if len(output) > 0 do append(&output, ..transmute([]byte)workspace.settings.statusbar.separator)
		append(&output, ..transmute([]byte)value)
	}
	return string(output[:])
}

statusbar_module_text :: proc(workspace: ^Workspace, module: config.Status_Module) -> string {
	tab := workspace_active_tab(workspace)
	pane := workspace_active_pane(workspace)
	if tab == nil || pane == nil do return ""
	switch module {
	case .Mode: return "tmux" if tab_is_tmux(tab) else "local"
	case .Session:
		if tab_is_tmux(tab) && len(tab.tmux_owner.tmux_session.title) > 0 do return statusbar_sanitize(string(tab.tmux_owner.tmux_session.title[:]))
		if tab.custom_title != "" do return statusbar_sanitize(tab.custom_title)
		if pane.display_title != "" do return statusbar_sanitize(pane.display_title)
		if pane.terminal.title != "" do return statusbar_sanitize(pane.terminal.title)
		return statusbar_sanitize(workspace.title)
	case .Size:
		screen := vt.terminal_screen(&pane.terminal)
		return fmt.tprintf("%dx%d", screen.columns, screen.rows)
	case .Tabs: return fmt.tprintf("%d/%d", workspace.active+1, len(workspace.tabs))
	case .Clock: return workspace.statusbar.clock
	case .Battery: return workspace.statusbar.battery
	case .Resource: return workspace.statusbar.resource
	}
	return ""
}

statusbar_sanitize :: proc(value: string) -> string {
	output := make([dynamic]byte, 0, min(128, len(value)), context.temp_allocator)
	remaining := value
	for remaining != "" {
		codepoint, width := utf8.decode_rune_in_string(remaining)
		if width <= 0 do break
		remaining = remaining[width:]
		if codepoint == utf8.RUNE_ERROR && width == 1 do continue
		if codepoint < 0x20 || codepoint == 0x7f do continue
		encoded, encoded_width := utf8.encode_rune(codepoint)
		if len(output)+encoded_width > 128 do break
		append(&output, ..encoded[:encoded_width])
	}
	return string(output[:])
}

workspace_draw_statusbar :: proc(workspace: ^Workspace) {
	if !statusbar_visible(workspace) do return
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	settings := &workspace.settings.statusbar
	tab_height := workspace_tab_bar_height(workspace)
	y := tab_height if settings.position == .Top && workspace.settings.tabs.edge == .Top else 0
	if settings.position == .Bottom {
		y = workspace.root.height-settings.height
		if workspace.settings.tabs.edge == .Bottom do y -= tab_height
	}
	left := statusbar_group_text(workspace, settings.left[:])
	center := statusbar_group_text(workspace, settings.center[:])
	right := statusbar_group_text(workspace, settings.right[:])
	draw_workspace_statusbar(workspace.root, pane.renderer.font, left, center, right, y, settings.height, settings.background, settings.foreground, settings.accent)
}
