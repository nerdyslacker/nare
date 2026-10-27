package main

import c "core:c"
import libc "core:c/libc"
import sha1 "core:crypto/legacy/sha1"
import endian "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import config "config"
import keyboard "input"
import jobs "jobs"
import pty "pty"
import vt "vt"
import x11 "x11"
import xlib "vendor:x11/xlib"

foreign import status_libc "system:c"
foreign status_libc {
	posix_spawn_file_actions_init :: proc(actions: rawptr) -> c.int ---
	posix_spawn_file_actions_destroy :: proc(actions: rawptr) -> c.int ---
	posix_spawn_file_actions_addclose :: proc(actions: rawptr, fd: c.int) -> c.int ---
	posix_spawn_file_actions_adddup2 :: proc(actions: rawptr, fd, new_fd: c.int) -> c.int ---
}

Statusbar_Spawn_Actions :: struct #align(8) {storage: [128]byte}

MAX_GIT_INDEX_BYTES :: 16 * 1024 * 1024
MAX_GIT_INDEX_ENTRIES :: 4096
MAX_GIT_HASH_BYTES :: 32 * 1024 * 1024
GIT_STATUS_TIMEOUT_MS :: 1500
MAX_STATUSBAR_CWD_BYTES :: 4096
STATUSBAR_SERVICE_INTERVAL :: 100*time.Millisecond

Statusbar_Sample_Job :: struct {
	battery_requested, resource_requested, git_requested, command_requested: bool,
	battery: [64]byte,
	battery_length: int,
	resource: [128]byte,
	resource_length: int,
	git: [128]byte,
	git_length: int,
	command: [128]byte,
	command_length: int,
	cwd: [MAX_STATUSBAR_CWD_BYTES]byte,
	cwd_length: int,
	command_pid: int,
	cpu_total, cpu_idle: u64,
	cpu_ready: bool,
}

Statusbar_State :: struct {
	visible: bool,
	auto_hide_revealed, auto_hide_pending: bool,
	auto_hide_left_at: time.Time,
	module_mask: u32,
	module_mask_ready: bool,
	last_service: time.Tick,
	service_calls, updates, worker_jobs, draw_requests: u64,
	render_cache: Statusbar_Render_Cache,
	clock, battery, resource, local_host, cwd, cwd_source, git, command, jobs_text: string,
	last_clock, last_cwd, last_git, last_command, last_battery, last_resource, last_jobs, last_job_prune: time.Time,
	last_job_revision: u64,
	expanded_job_count: int,
	cwd_pane, git_pane, command_pane: ^Pane,
	cwd_local: bool,
	cpu_total, cpu_idle: u64,
	cpu_ready: bool,
	sample_job: ^Statusbar_Sample_Job,
	sample_thread: ^thread.Thread,
}

statusbar_destroy :: proc(state: ^Statusbar_State) {
	if os.get_env("NARE_STATUSBAR_PROFILE", context.temp_allocator) == "1" {
		fmt.eprintf(
			"nare statusbar: service=%d updates=%d workers=%d draws=%d raster=%d present=%d images=%d\n",
			state.service_calls, state.updates, state.worker_jobs, state.draw_requests,
			state.render_cache.rasterizations, state.render_cache.presentations, state.render_cache.image_allocations,
		)
	}
	if state.sample_thread != nil do thread.destroy(state.sample_thread)
	if state.sample_job != nil do free(state.sample_job)
	statusbar_render_cache_destroy(&state.render_cache)
	delete(state.clock)
	delete(state.battery)
	delete(state.resource)
	delete(state.local_host)
	delete(state.cwd)
	delete(state.cwd_source)
	delete(state.git)
	delete(state.command)
	delete(state.jobs_text)
	state^ = {}
}

statusbar_visible :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil || !workspace.statusbar.visible do return false
	if workspace.settings.statusbar.auto_hide && !workspace.statusbar.auto_hide_revealed do return false
	return workspace.quake == nil || workspace.settings.statusbar.show_in_quake
}

statusbar_height :: proc(workspace: ^Workspace) -> int {
	return statusbar_render_height(workspace) if statusbar_visible(workspace) else 0
}

statusbar_render_height :: proc(workspace: ^Workspace) -> int {
	return statusbar_row_height(workspace)
}

statusbar_row_height :: proc(workspace: ^Workspace) -> int {
	height := workspace.settings.statusbar.height
	if pane := workspace_active_pane(workspace); pane != nil do height = max(height, pane.renderer.font.cell_height+6)
	return height
}

statusbar_expanded_job_count :: proc(workspace: ^Workspace) -> int {
	if workspace == nil || !workspace.jobs_visible do return 0
	visible := statusbar_visible_jobs(workspace)
	if len(visible) == 0 do return 0
	row_height := statusbar_row_height(workspace)
	reserved := workspace_tab_bar_height(workspace)+workspace.settings.window.padding*2+row_height+12
	available_rows := max(0, (workspace.root.height-reserved)/max(1, row_height))
	return min(len(visible), min(workspace.settings.statusbar.jobs.max_visible, available_rows))
}

statusbar_auto_hide_pointer :: proc(workspace: ^Workspace, pointer_y: int) -> bool {
	settings := &workspace.settings.statusbar
	state := &workspace.statusbar
	_ = statusbar_sync_expanded_jobs(workspace)
	if !settings.auto_hide || !state.visible do return false
	if workspace.quake != nil && !settings.show_in_quake do return false
	tab_height := workspace_tab_bar_height(workspace)
	top_offset := tab_height if settings.position == .Top && workspace.settings.tabs.edge == .Top else 0
	bottom_offset := tab_height if settings.position == .Bottom && workspace.settings.tabs.edge == .Bottom else 0
	bar_height := statusbar_render_height(workspace)
	bar_y := top_offset if settings.position == .Top else workspace.root.height-bottom_offset-bar_height
	if state.auto_hide_revealed {
		if pointer_y >= bar_y && pointer_y < bar_y+bar_height {
			state.auto_hide_pending = false
		} else if !state.auto_hide_pending {
			state.auto_hide_pending = true
			state.auto_hide_left_at = time.now()
		}
		return false
	}
	hotspot := 3
	reveal := pointer_y >= top_offset && pointer_y < top_offset+hotspot
	if settings.position == .Bottom {
		boundary := workspace.root.height-bottom_offset
		reveal = pointer_y >= boundary-hotspot && pointer_y < boundary
	}
	if !reveal do return false
	state.auto_hide_revealed = true
	state.auto_hide_pending = false
	statusbar_tick(workspace, true)
	workspace_layout(workspace)
	return true
}

statusbar_auto_hide_tick :: proc(workspace: ^Workspace) {
	settings := &workspace.settings.statusbar
	state := &workspace.statusbar
	if workspace.jobs_visible || !settings.auto_hide || !state.visible || !state.auto_hide_revealed || !state.auto_hide_pending do return
	if time.since(state.auto_hide_left_at) < time.Duration(settings.auto_hide_delay_ms)*time.Millisecond do return
	state.auto_hide_revealed = false
	state.auto_hide_pending = false
	workspace_layout(workspace)
}

statusbar_module_bit :: proc(module: config.Status_Module) -> u32 {
	return u32(1)<<u32(module)
}

statusbar_module_mask :: proc(settings: ^config.Statusbar_Settings) -> u32 {
	mask: u32
	for module in settings.left do mask |= statusbar_module_bit(module)
	for module in settings.center do mask |= statusbar_module_bit(module)
	for module in settings.right do mask |= statusbar_module_bit(module)
	return mask
}

statusbar_tick :: proc(workspace: ^Workspace, force: bool = false) {
	statusbar_jobs_maintenance(workspace)
	_ = statusbar_sync_expanded_jobs(workspace)
	if !statusbar_visible(workspace) do return
	settings := &workspace.settings.statusbar
	state := &workspace.statusbar
	if !state.module_mask_ready {
		state.module_mask = statusbar_module_mask(settings)
		state.module_mask_ready = true
	}
	poll_mask := statusbar_module_bit(.Clock) | statusbar_module_bit(.Cwd) | statusbar_module_bit(.Git) |
	             statusbar_module_bit(.Command) | statusbar_module_bit(.Battery) | statusbar_module_bit(.Resource) |
	             statusbar_module_bit(.Jobs)
	if !force && state.sample_thread == nil && state.module_mask&poll_mask == 0 do return
	if !force && state.sample_thread == nil && state.last_service != {} && time.tick_since(state.last_service) < STATUSBAR_SERVICE_INTERVAL do return
	state.last_service = time.tick_now()
	state.service_calls += 1
	mask := state.module_mask
	now := time.now()
	changed := statusbar_harvest_sample(state)
	if statusbar_module_bit(.Clock)&mask != 0 && (force || time.since(state.last_clock) >= time.Duration(settings.clock_update_ms)*time.Millisecond) {
		workspace.statusbar.last_clock = now
		changed = statusbar_update_clock(&workspace.statusbar, settings.clock_format) || changed
	}
	if statusbar_module_bit(.Cwd)&mask != 0 && (force || time.since(state.last_cwd) >= time.Duration(settings.cwd_update_ms)*time.Millisecond) {
		workspace.statusbar.last_cwd = now
		changed = statusbar_update_cwd(workspace) || changed
	}
	jobs_due := statusbar_module_bit(.Jobs)&mask != 0 && settings.jobs.enabled &&
	            (force || state.last_job_revision != workspace.jobs.revision || time.since(state.last_jobs) >= time.Second)
	if jobs_due {
		state.last_jobs = now
		state.last_job_revision = workspace.jobs.revision
		changed = statusbar_replace(&state.jobs_text, statusbar_jobs_text(workspace)) || changed
	}
	battery_due := statusbar_module_bit(.Battery)&mask != 0 && (force || time.since(state.last_battery) >= time.Duration(settings.battery_update_ms)*time.Millisecond)
	resource_due := statusbar_module_bit(.Resource)&mask != 0 && (force || time.since(state.last_resource) >= time.Duration(settings.resource_update_ms)*time.Millisecond)
	git_due := statusbar_module_bit(.Git)&mask != 0 && (force || state.git_pane != workspace_active_pane(workspace) || time.since(state.last_git) >= time.Duration(settings.git_update_ms)*time.Millisecond)
	command_due := statusbar_module_bit(.Command)&mask != 0 && (force || state.command_pane != workspace_active_pane(workspace) || time.since(state.last_command) >= time.Duration(settings.command_update_ms)*time.Millisecond)
	if workspace.statusbar.sample_thread == nil && (battery_due || resource_due || git_due || command_due) {
		git_request := false
		command_request := false
		command_pid := 0
		pane := workspace_active_pane(workspace)
		tab := workspace_active_tab(workspace)
		if git_due {
			changed = statusbar_update_cwd(workspace) || changed
			if workspace.statusbar.git_pane != pane do changed = statusbar_replace(&workspace.statusbar.git, "") || changed
			workspace.statusbar.git_pane = pane
			git_request = pane != nil && workspace.statusbar.cwd_local && workspace.statusbar.cwd_source != "" && len(workspace.statusbar.cwd_source) <= 4096
			if !git_request do changed = statusbar_replace(&workspace.statusbar.git, "") || changed
		}
		if command_due {
			if workspace.statusbar.command_pane != pane do changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			workspace.statusbar.command_pane = pane
			owner := pane_tmux_owner(pane)
			if tab_is_tmux(tab) {
				value := ""
				if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil do value = statusbar_sanitize(string(info.current_command[:]))
				changed = statusbar_replace(&workspace.statusbar.command, value) || changed
			} else if owner != nil && owner.remote_host != "" {
				changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			} else if pane != nil {
				pid, ok := pty.foreground_pid(&pane.process)
				if ok do command_request, command_pid = true, pid
				else do changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			} else {
				changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			}
		}
		started := statusbar_start_sample(&workspace.statusbar, battery_due, resource_due, git_request, command_request, workspace.statusbar.cwd_source, command_pid)
		if started do state.worker_jobs += 1
		if started || (!battery_due && !resource_due && !git_request && !command_request) {
			if battery_due do workspace.statusbar.last_battery = now
			if resource_due do workspace.statusbar.last_resource = now
			if git_due do workspace.statusbar.last_git = now
			if command_due do workspace.statusbar.last_command = now
		}
	}
	if changed do state.updates += 1
	if changed && !force do workspace_draw_statusbar(workspace)
	if changed && workspace.jobs_visible do workspace_draw_jobs_list(workspace)
}

statusbar_sync_expanded_jobs :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil do return false
	expanded_count := statusbar_expanded_job_count(workspace)
	if workspace.jobs_visible && expanded_count == 0 do workspace.jobs_visible = false
	if workspace.statusbar.expanded_job_count == expanded_count do return false
	workspace.statusbar.expanded_job_count = expanded_count
	if expanded_count == 0 {
		if workspace.jobs_surface.id != 0 do x11.show_child(&workspace.jobs_surface, false)
	} else {
		workspace_draw_jobs_list(workspace)
	}
	return true
}

statusbar_jobs_maintenance :: proc(workspace: ^Workspace) {
	if workspace == nil || time.since(workspace.statusbar.last_job_prune) < time.Second do return
	workspace.statusbar.last_job_prune = time.now()
	settings := &workspace.settings.statusbar.jobs
	_ = jobs.prune(
		&workspace.jobs,
		time.Duration(settings.completed_timeout_seconds)*time.Second,
		time.Duration(settings.failed_timeout_seconds)*time.Second,
	)
}

statusbar_jobs_text :: proc(workspace: ^Workspace) -> string {
	settings := &workspace.settings.statusbar.jobs
	if !settings.enabled do return ""
	visible := statusbar_visible_jobs(workspace)
	if len(visible) == 0 do return ""
	if len(visible) > 1 do return statusbar_job_counts_text(statusbar_job_counts(visible))
	return statusbar_job_text(visible[0], settings, false)
}

Statusbar_Job_Counts :: struct {running, succeeded, failed, cancelled: int}

statusbar_job_counts :: proc(visible: []^jobs.Job) -> Statusbar_Job_Counts {
	counts: Statusbar_Job_Counts
	for job in visible {
		switch job.state {
		case .Starting, .Running: counts.running += 1
		case .Succeeded: counts.succeeded += 1
		case .Failed, .Unknown: counts.failed += 1
		case .Cancelled: counts.cancelled += 1
		}
	}
	return counts
}

statusbar_job_counts_text :: proc(counts: Statusbar_Job_Counts) -> string {
	output := make([dynamic]byte, 0, 48, context.temp_allocator)
	statusbar_append_job_count(&output, "RUN", counts.running)
	statusbar_append_job_count(&output, "OK", counts.succeeded)
	statusbar_append_job_count(&output, "ERR", counts.failed)
	statusbar_append_job_count(&output, "CANCEL", counts.cancelled)
	return string(output[:])
}

statusbar_append_job_count :: proc(output: ^[dynamic]byte, label: string, count: int) {
	if count <= 0 do return
	if len(output) > 0 do append(output, ' ', ' ')
	append(output, ..transmute([]byte)fmt.tprintf("%s %d", label, count))
}

statusbar_visible_jobs :: proc(workspace: ^Workspace) -> []^jobs.Job {
	settings := &workspace.settings.statusbar.jobs
	visible := make([dynamic]^jobs.Job, 0, len(workspace.jobs.jobs), context.temp_allocator)
	if settings.sort == .Running_First {
		for index := len(workspace.jobs.jobs)-1; index >= 0; index -= 1 {
			job := &workspace.jobs.jobs[index]
			if (job.state == .Starting || job.state == .Running) && statusbar_job_visible(job, settings) do append(&visible, job)
		}
		for index := len(workspace.jobs.jobs)-1; index >= 0; index -= 1 {
			job := &workspace.jobs.jobs[index]
			if job.state != .Starting && job.state != .Running && statusbar_job_visible(job, settings) do append(&visible, job)
		}
	} else {
		for index := len(workspace.jobs.jobs)-1; index >= 0; index -= 1 {
			job := &workspace.jobs.jobs[index]
			if statusbar_job_visible(job, settings) do append(&visible, job)
		}
	}
	return visible[:]
}

statusbar_job_visible :: proc(job: ^jobs.Job, settings: ^config.Statusbar_Jobs_Settings) -> bool {
	if job == nil || settings == nil do return false
	switch job.state {
	case .Starting, .Running: return true
	case .Succeeded, .Cancelled: return settings.show_completed
	case .Failed, .Unknown: return settings.show_failed
	}
	return false
}

statusbar_job_text :: proc(job: ^jobs.Job, settings: ^config.Statusbar_Jobs_Settings, include_message: bool = true) -> string {
	prefix := "RUN"
	suffix := ""
	switch job.state {
	case .Starting: prefix = "START"
	case .Running:
	case .Succeeded: prefix = "OK"
	case .Failed:
		prefix = "ERR"
		if job.signal > 0 do suffix = fmt.tprintf(" (signal %d)", job.signal)
		else do suffix = fmt.tprintf(" (exit %d)", job.exit_code)
	case .Cancelled: prefix = "CANCEL"
	case .Unknown: prefix = "UNKNOWN"
	}
	if job.cancel_requested && (job.state == .Starting || job.state == .Running) do prefix = "STOP"
	progress := ""
	if settings.show_progress && job.progress >= 0 do progress = fmt.tprintf(" %d%%", job.progress)
	elapsed := ""
	if settings.show_elapsed {
		seconds := max(0, int(jobs.elapsed(job)/time.Second))
		if seconds >= 3600 do elapsed = fmt.tprintf(" %d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60)
		else do elapsed = fmt.tprintf(" %02d:%02d", seconds/60, seconds%60)
	}
	label := statusbar_sanitize(job.label)
	if include_message && job.message != "" do label = fmt.tprintf("%s: %s", label, statusbar_sanitize(job.message))
	return fmt.tprintf("%s %s%s%s%s", prefix, label, progress, suffix, elapsed)
}

workspace_toggle_jobs_list :: proc(workspace: ^Workspace) {
	if workspace == nil || !workspace.settings.statusbar.jobs.enabled || !workspace.statusbar.visible do return
	if !workspace.jobs_visible && len(statusbar_visible_jobs(workspace)) == 0 do return
	was_visible := workspace.jobs_visible
	workspace.jobs_visible = !was_visible
	workspace.jobs_selected = 0
	if workspace.jobs_visible {
		workspace.statusbar.auto_hide_revealed = true
		workspace.statusbar.auto_hide_pending = false
	}
	workspace.statusbar.expanded_job_count = statusbar_expanded_job_count(workspace)
	if workspace.jobs_visible {
		workspace_draw_jobs_list(workspace)
		x11.focus_child(&workspace.jobs_surface)
	} else if workspace.jobs_surface.id != 0 {
		x11.show_child(&workspace.jobs_surface, false)
		x11.focus_window(workspace.root)
	}
}

workspace_jobs_list_input :: proc(workspace: ^Workspace, event: x11.Event) {
	visible := statusbar_visible_jobs(workspace)
	if event_matches(event, workspace.settings.bindings.show_jobs) || event.key == .Escape {
		workspace_toggle_jobs_list(workspace)
		return
	}
	if len(visible) == 0 do return
	if event.key == .Up do workspace.jobs_selected = max(0, workspace.jobs_selected-1)
	else if event.key == .Down do workspace.jobs_selected = min(len(visible)-1, workspace.jobs_selected+1)
	else if event.key == .Delete {
		job := visible[clamp(workspace.jobs_selected, 0, len(visible)-1)]
		if (job.state == .Running || job.state == .Starting) && job.pid > 0 {
			signal := posix.Signal.SIGINT
			if job.cancel_attempts == 1 do signal = .SIGTERM
			else if job.cancel_attempts >= 2 do signal = .SIGKILL
			stopped := posix.killpg(posix.pid_t(job.pid), signal) == .OK
			if !stopped do stopped = posix.kill(posix.pid_t(job.pid), signal) == .OK
			if stopped {
				_ = jobs.request_cancel(&workspace.jobs, job.id)
				statusbar_tick(workspace, true)
			}
		}
		workspace_draw_jobs_list(workspace)
		return
	} else if event.key == .Enter {
		job := visible[clamp(workspace.jobs_selected, 0, len(visible)-1)]
		workspace_focus_job_owner(workspace, job)
		workspace_toggle_jobs_list(workspace)
		return
	} else do return
	workspace_draw_jobs_list(workspace)
}

workspace_focus_job_owner :: proc(workspace: ^Workspace, job: ^jobs.Job) {
	if workspace == nil || job == nil || job.owner.window != u64(workspace.root.id) do return
	pane := workspace_find_pane(workspace, xlib.Window(job.owner.pane))
	if pane == nil do return
	for tab, tab_index in workspace.tabs {
		for candidate, pane_index in tab.panes {
			if candidate != pane do continue
			tab.active = pane_index
			workspace_select_tab(workspace, tab_index)
			return
		}
	}
}

workspace_draw_jobs_list :: proc(workspace: ^Workspace) {
	if workspace == nil || workspace.jobs_surface.id == 0 || !workspace.jobs_visible || !statusbar_visible(workspace) do return
	visible := statusbar_visible_jobs(workspace)
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	shown := statusbar_expanded_job_count(workspace)
	if shown == 0 do return
	workspace.jobs_selected = clamp(workspace.jobs_selected, 0, max(0, len(visible)-1))
	start := statusbar_expanded_job_start(workspace, len(visible), shown)
	settings := &workspace.settings.statusbar
	style := settings.module_styles[int(config.Status_Module.Jobs)]
	foreground := settings.foreground
	background := settings.background
	if style.foreground_set do foreground = style.foreground
	if style.background_set do background = style.background
	rows := make([]Statusbar_Draw_Module, shown, context.temp_allocator)
	for index in 0..<shown {
		job := visible[start+index]
		row_background := background
		if job.state == .Succeeded do row_background = settings.jobs.success_background
		else if job.state == .Failed || job.state == .Unknown do row_background = settings.jobs.failure_background
		rows[index] = {text = statusbar_job_text(job, &settings.jobs), foreground = foreground, background = row_background, jobs = true}
	}
	row_height := statusbar_row_height(workspace)
	width := min(max(280, workspace.root.width*3/4), max(1, workspace.root.width-24))
	height := max(row_height*2, row_height*(shown+1))
	x := max(0, (workspace.root.width-width)/2)
	y := workspace.statusbar_surface.y-height-6
	if settings.position == .Top do y = workspace.statusbar_surface.y+workspace.statusbar_surface.height+6
	y = clamp(y, 0, max(0, workspace.root.height-height))
	x11.place_child(&workspace.jobs_surface, x, y, width, height)
	x11.raise_child(&workspace.jobs_surface)
	draw_workspace_jobs_popup(
		&workspace.jobs_surface, pane.renderer.font, rows, workspace.jobs_selected-start,
		row_height, background, foreground, statusbar_active_accent(workspace),
		workspace.settings.ui_colors.inactive_tab_background,
	)
}

statusbar_jobs_mouse :: proc(workspace: ^Workspace, mouse: keyboard.Mouse_Event) -> bool {
	if workspace == nil || !workspace.jobs_visible do return false
	if mouse.action != .Press || mouse.button != 1 do return true
	shown := statusbar_expanded_job_count(workspace)
	visible := statusbar_visible_jobs(workspace)
	if shown <= 0 || len(visible) == 0 do return true
	index := mouse.y/max(1, statusbar_row_height(workspace))-1
	if index < 0 || index >= shown do return true
	start := statusbar_expanded_job_start(workspace, len(visible), shown)
	workspace.jobs_selected = start+index
	workspace_focus_job_owner(workspace, visible[workspace.jobs_selected])
	workspace_toggle_jobs_list(workspace)
	return true
}

statusbar_expanded_job_start :: proc(workspace: ^Workspace, total, shown: int) -> int {
	if workspace == nil || shown <= 0 || total <= shown do return 0
	return clamp(workspace.jobs_selected-shown+1, 0, total-shown)
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

statusbar_collect_battery :: proc() -> string {
	entries, directory_error := os.read_directory_by_path("/sys/class/power_supply", -1, context.temp_allocator)
	if directory_error != nil do return ""
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
		return fmt.tprintf("BAT %d%%%s", capacity, marker)
	}
	return ""
}

statusbar_collect_resources :: proc(job: ^Statusbar_Sample_Job) -> string {
	cpu_percent, cpu_ok := statusbar_cpu_percent(job)
	ram_percent, ram_ok := statusbar_ram_percent()
	storage_percent, storage_ok := statusbar_storage_percent()
	if cpu_ok && ram_ok && storage_ok {
		return fmt.tprintf("CPU %d%% RAM %d%% STORAGE %d%%", cpu_percent, ram_percent, storage_percent)
	} else if ram_ok && storage_ok {
		return fmt.tprintf("RAM %d%% STORAGE %d%%", ram_percent, storage_percent)
	}
	return ""
}

statusbar_start_sample :: proc(state: ^Statusbar_State, battery, resource, git, command: bool, cwd: string, command_pid: int) -> bool {
	if !battery && !resource && !git && !command do return false
	job := new(Statusbar_Sample_Job)
	if job == nil do return false
	job.battery_requested = battery
	job.resource_requested = resource
	job.git_requested = git
	job.command_requested = command
	job.command_pid = command_pid
	if git do statusbar_copy_sample(job.cwd[:], &job.cwd_length, cwd)
	job.cpu_total = state.cpu_total
	job.cpu_idle = state.cpu_idle
	job.cpu_ready = state.cpu_ready
	worker := thread.create_and_start_with_data(rawptr(job), statusbar_sample_worker, nil, .Low, false, "nare-status")
	if worker == nil {
		free(job)
		return false
	}
	state.sample_job = job
	state.sample_thread = worker
	return true
}

statusbar_sample_worker :: proc(data: rawptr) {
	job := cast(^Statusbar_Sample_Job)data
	if job.battery_requested do statusbar_copy_sample(job.battery[:], &job.battery_length, statusbar_collect_battery())
	if job.resource_requested do statusbar_copy_sample(job.resource[:], &job.resource_length, statusbar_collect_resources(job))
	if job.git_requested do statusbar_copy_sample(job.git[:], &job.git_length, statusbar_collect_git(string(job.cwd[:job.cwd_length])))
	if job.command_requested do statusbar_copy_sample(job.command[:], &job.command_length, statusbar_collect_command(job.command_pid))
}

statusbar_copy_sample :: proc(buffer: []byte, length: ^int, value: string) {
	count := min(len(buffer), len(value))
	copy(buffer[:count], transmute([]byte)value[:count])
	length^ = count
}

statusbar_harvest_sample :: proc(state: ^Statusbar_State) -> bool {
	if state.sample_thread == nil || !thread.is_done(state.sample_thread) do return false
	thread.destroy(state.sample_thread)
	job := state.sample_job
	state.sample_thread = nil
	state.sample_job = nil
	if job == nil do return false
	defer free(job)
	changed := false
	if job.battery_requested do changed = statusbar_replace(&state.battery, string(job.battery[:job.battery_length])) || changed
	if job.resource_requested {
		state.cpu_total = job.cpu_total
		state.cpu_idle = job.cpu_idle
		state.cpu_ready = job.cpu_ready
		changed = statusbar_replace(&state.resource, string(job.resource[:job.resource_length])) || changed
	}
	if job.git_requested do changed = statusbar_replace(&state.git, statusbar_sanitize(string(job.git[:job.git_length]))) || changed
	if job.command_requested do changed = statusbar_replace(&state.command, statusbar_sanitize(string(job.command[:job.command_length]))) || changed
	return changed
}

statusbar_update_cwd :: proc(workspace: ^Workspace) -> bool {
	state := &workspace.statusbar
	tab := workspace_active_tab(workspace)
	pane := workspace_active_pane(workspace)
	state.cwd_pane = pane
	if tab == nil || pane == nil do return statusbar_set_cwd(state, "", false)
	owner := pane_tmux_owner(pane)
	remote := owner != nil && owner.remote_host != ""

	if tab_is_tmux(tab) {
		if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil && len(info.current_path) > 0 {
			pane.terminal.cwd_changed = false
			return statusbar_set_cwd(state, string(info.current_path[:]), !remote)
		}
	}
	if pane.terminal.cwd_path != "" {
		pane.terminal.cwd_changed = false
		return statusbar_set_cwd(state, pane.terminal.cwd_path, !remote)
	}
	if remote do return statusbar_set_cwd(state, "", false)
	cwd, ok := pty.foreground_cwd(&pane.process)
	if !ok do return statusbar_set_cwd(state, "", false)
	defer delete(cwd)
	return statusbar_set_cwd(state, cwd, true)
}

statusbar_set_cwd :: proc(state: ^Statusbar_State, value: string, local: bool) -> bool {
	display_value := value
	if local && value != "" {
		home := os.get_env("HOME", context.temp_allocator)
		for len(home) > 1 && home[len(home)-1] == '/' do home = home[:len(home)-1]
		if home != "" && value == home {
			display_value = "~"
		} else if home != "" && len(value) > len(home) && strings.has_prefix(value, home) && value[len(home)] == '/' {
			display_value = fmt.tprintf("~%s", value[len(home):])
		}
	}
	changed := statusbar_replace(&state.cwd, statusbar_sanitize(display_value))
	source := value
	if len(source) > MAX_STATUSBAR_CWD_BYTES do source = ""
	if state.cwd_source != source do config.replace_string(&state.cwd_source, source)
	state.cwd_local = local && source != ""
	return changed
}

statusbar_collect_command :: proc(pid: int) -> string {
	if pid <= 0 do return ""
	path_buffer: [64]byte
	path := fmt.bprintf(path_buffer[:], "/proc/%d/comm", pid)
	return strings.trim_space(statusbar_read_small(path))
}

statusbar_collect_git :: proc(cwd: string) -> string {
	git_dir, worktree, found := statusbar_find_git(cwd)
	if !found do return ""
	head_path, head_error := filepath.join({git_dir, "HEAD"}, context.temp_allocator)
	if head_error != nil do return ""
	head := strings.trim_space(statusbar_read_small(head_path))
	label := ""
	if strings.has_prefix(head, "ref: refs/heads/") {
		branch := head[len("ref: refs/heads/"):]
		if branch != "" do label = fmt.tprintf("git:%s", branch)
	} else if len(head) >= 8 && statusbar_is_hex(head) {
		label = fmt.tprintf("git:%s", head[:8])
	}
	if label == "" do return ""
	dirty, known := statusbar_git_complete_dirty(cwd)
	if !known do dirty, known = statusbar_git_tracked_dirty(git_dir, worktree)
	if known && dirty do return fmt.tprintf("%s*", label)
	return label
}

statusbar_git_complete_dirty :: proc(cwd: string) -> (dirty, known: bool) {
	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK do return false, false
	for &fd in pipe_fds {
		if fd > 2 do continue
		duplicate := posix.fcntl(fd, .DUPFD_CLOEXEC, 3)
		if duplicate < 0 {
			_ = posix.close(pipe_fds[0])
			_ = posix.close(pipe_fds[1])
			return false, false
		}
		_ = posix.close(fd)
		fd = posix.FD(duplicate)
	}
	defer posix.close(pipe_fds[0])
	defer posix.close(pipe_fds[1])
	_ = posix.fcntl(pipe_fds[0], .SETFD, posix.FD_CLOEXEC)
	_ = posix.fcntl(pipe_fds[1], .SETFD, posix.FD_CLOEXEC)

	actions: Statusbar_Spawn_Actions
	if posix_spawn_file_actions_init(rawptr(&actions)) != 0 do return false, false
	defer posix_spawn_file_actions_destroy(rawptr(&actions))
	if posix_spawn_file_actions_adddup2(rawptr(&actions), c.int(pipe_fds[1]), 1) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), c.int(pipe_fds[0])) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), c.int(pipe_fds[1])) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), 0) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), 2) != 0 {
		return false, false
	}
	cwd_c, cwd_error := strings.clone_to_cstring(cwd, context.temp_allocator)
	if cwd_error != nil do return false, false
	argv := [12]cstring{
		"git", "-C", cwd_c, "--no-optional-locks", "-c", "core.fsmonitor=false",
		"status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none", "--", nil,
	}
	child: posix.pid_t
	if posix.posix_spawnp(&child, "git", rawptr(&actions), nil, &argv[0], posix.environ) != .NONE do return false, false
	_ = posix.close(pipe_fds[1])
	pipe_fds[1] = -1
	start := time.tick_now()
	status: c.int
	for time.tick_since(start) < GIT_STATUS_TIMEOUT_MS*time.Millisecond {
		poll_fd := posix.pollfd{fd = pipe_fds[0], events = {.IN}}
		poll_result := posix.poll(&poll_fd, 1, 50)
		if poll_result > 0 && (.IN in poll_fd.revents) {
			value: byte
			if posix.read(pipe_fds[0], &value, 1) > 0 {
				_ = posix.kill(child, .SIGKILL)
				_ = posix.waitpid(child, &status, {})
				return true, true
			}
		}
		waited := posix.waitpid(child, &status, {.NOHANG})
		if waited == child {
			return false, posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
		}
		if waited < 0 do return false, false
	}
	_ = posix.kill(child, .SIGKILL)
	_ = posix.waitpid(child, &status, {})
	return false, false
}

statusbar_find_git :: proc(cwd: string) -> (git_dir, worktree: string, found: bool) {
	if cwd == "" || cwd[0] != '/' do return
	current := cwd
	for _ in 0..<64 {
		dot_git, join_error := filepath.join({current, ".git"}, context.temp_allocator)
		if join_error != nil do return
		if os.is_directory(dot_git) {
			git_dir = dot_git
		} else if marker := strings.trim_space(statusbar_read_small(dot_git)); strings.has_prefix(marker, "gitdir:") {
			target := strings.trim_space(marker[len("gitdir:"):])
			if filepath.is_abs(target) {
				git_dir = target
			} else {
				git_dir, join_error = filepath.join({filepath.dir(dot_git), target}, context.temp_allocator)
				if join_error != nil do return
			}
		}
		if git_dir != "" do return git_dir, current, true
		parent := filepath.dir(current)
		if parent == current do break
		current = parent
	}
	return
}

statusbar_git_tracked_dirty :: proc(git_dir, worktree: string) -> (dirty, known: bool) {
	config_dir := git_dir
	common_path, common_error := filepath.join({git_dir, "commondir"}, context.temp_allocator)
	if common_error == nil {
		common := strings.trim_space(statusbar_read_small(common_path))
		if common != "" {
			if filepath.is_abs(common) {
				config_dir = common
			} else if resolved, resolve_error := filepath.join({git_dir, common}, context.temp_allocator); resolve_error == nil {
				config_dir = resolved
			}
		}
	}
	config_path, config_error := filepath.join({config_dir, "config"}, context.temp_allocator)
	if config_error != nil do return false, false
	config_data := statusbar_read_small(config_path)
	if statusbar_git_uses_sha256(config_data) do return false, false
	index_path, index_error := filepath.join({git_dir, "index"}, context.temp_allocator)
	if index_error != nil do return false, false
	index, index_ok := statusbar_read_bounded(index_path, MAX_GIT_INDEX_BYTES)
	if !index_ok || len(index) < 12+sha1.DIGEST_SIZE || string(index[:4]) != "DIRC" do return false, false
	version := endian.unchecked_get_u32be(index[4:8])
	entry_count := endian.unchecked_get_u32be(index[8:12])
	if (version != 2 && version != 3) || entry_count > MAX_GIT_INDEX_ENTRIES do return false, false
	cursor := 12
	hashed_bytes := 0
	for _ in 0..<int(entry_count) {
		entry_start := cursor
		if cursor+62 > len(index)-sha1.DIGEST_SIZE do return false, false
		mtime_seconds := endian.unchecked_get_u32be(index[cursor+8:cursor+12])
		mtime_nanos := endian.unchecked_get_u32be(index[cursor+12:cursor+16])
		mode := endian.unchecked_get_u32be(index[cursor+24:cursor+28])
		size := endian.unchecked_get_u32be(index[cursor+36:cursor+40])
		expected_hash := index[cursor+40:cursor+60]
		flags := endian.unchecked_get_u16be(index[cursor+60:cursor+62])
		cursor += 62
		if version == 3 && flags&0x4000 != 0 {
			if cursor+2 > len(index)-sha1.DIGEST_SIZE do return false, false
			cursor += 2
		}
		path_start := cursor
		for cursor < len(index)-sha1.DIGEST_SIZE && index[cursor] != 0 do cursor += 1
		if cursor >= len(index)-sha1.DIGEST_SIZE do return false, false
		path := string(index[path_start:cursor])
		if path == "" || path[0] == '/' || path == ".." || strings.has_prefix(path, "../") || strings.contains(path, "/../") do return false, false
		cursor += 1
		entry_size := cursor-entry_start
		cursor += (8-entry_size%8)%8
		if cursor > len(index)-sha1.DIGEST_SIZE do return false, false
		if mode&0o170000 == 0o160000 do continue
		full_path, join_error := filepath.join({worktree, path}, context.temp_allocator)
		if join_error != nil do return false, false
		info, stat_error := os.lstat(full_path, context.temp_allocator)
		if stat_error != nil do return true, true
		mtime := time.to_unix_nanoseconds(info.modification_time)
		executable := .Execute_User in info.mode
		index_executable := mode&0o111 != 0
		type_matches := (mode&0o170000 == 0o120000 && info.type == .Symlink) || (mode&0o170000 == 0o100000 && info.type == .Regular)
		stat_matches := type_matches && u64(max(0, info.size)) == u64(size) && u64(max(0, mtime/1e9)) == u64(mtime_seconds) && u64(max(0, mtime%1e9)) == u64(mtime_nanos) && executable == index_executable
		if stat_matches do continue
		matches, hash_ok := statusbar_git_blob_matches(full_path, info, expected_hash, &hashed_bytes)
		if !hash_ok || !matches do return true, true
	}
	return false, true
}

statusbar_read_small :: proc(path: string) -> string {
	data, ok := statusbar_read_bounded(path, 4096)
	return string(data) if ok else ""
}

statusbar_read_bounded :: proc(path: string, limit: int) -> ([]byte, bool) {
	file, open_error := os.open(path)
	if open_error != nil do return nil, false
	defer os.close(file)
	capacity := limit+1
	expected_size := i64(-1)
	if info, stat_error := os.stat(path, context.temp_allocator); stat_error == nil && info.type == .Regular && info.size > 0 {
		if info.size > i64(limit) do return nil, false
		expected_size = info.size
		capacity = int(info.size)+1
	}
	buffer := make([]byte, capacity, context.temp_allocator)
	total := 0
	for total < len(buffer) {
		count, read_error := os.read(file, buffer[total:])
		if count > 0 do total += count
		if read_error != nil || count == 0 do break
	}
	if total > limit || (expected_size >= 0 && i64(total) != expected_size) do return nil, false
	return buffer[:total], true
}

statusbar_git_uses_sha256 :: proc(config_data: string) -> bool {
	remaining := config_data
	for remaining != "" {
		line := remaining
		if newline := strings.index_byte(remaining, '\n'); newline >= 0 {
			line, remaining = remaining[:newline], remaining[newline+1:]
		} else do remaining = ""
		line = strings.trim_space(line)
		separator := strings.index_byte(line, '=')
		if separator < 0 do continue
		key := strings.trim_space(line[:separator])
		value := strings.trim_space(line[separator+1:])
		if strings.to_lower(key, context.temp_allocator) == "objectformat" && strings.to_lower(value, context.temp_allocator) == "sha256" do return true
	}
	return false
}

statusbar_git_blob_matches :: proc(path: string, info: os.File_Info, expected: []byte, hashed_bytes: ^int) -> (bool, bool) {
	data: []byte
	if info.type == .Symlink {
		target, link_error := os.read_link(path, context.temp_allocator)
		if link_error != nil do return false, false
		data = transmute([]byte)target
	} else if info.type == .Regular {
		if info.size < 0 || info.size > MAX_GIT_HASH_BYTES-i64(hashed_bytes^) do return false, false
		contents, read_ok := statusbar_read_bounded(path, int(info.size))
		if !read_ok do return false, false
		data = contents
	} else do return false, true
	if len(data) > MAX_GIT_HASH_BYTES-hashed_bytes^ do return false, false
	hashed_bytes^ += len(data)
	header_buffer: [64]byte
	header := fmt.bprintf(header_buffer[:], "blob %d%c", len(data), byte(0))
	ctx: sha1.Context
	digest: [sha1.DIGEST_SIZE]byte
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)header)
	sha1.update(&ctx, data)
	sha1.final(&ctx, digest[:])
	if len(expected) != len(digest) do return false, false
	for value, index in digest do if value != expected[index] do return false, true
	return true, true
}

statusbar_is_hex :: proc(value: string) -> bool {
	for byte in transmute([]byte)value {
		if !((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F')) do return false
	}
	return value != ""
}

statusbar_cpu_percent :: proc(job: ^Statusbar_Sample_Job) -> (int, bool) {
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
	if !job.cpu_ready {
		job.cpu_total, job.cpu_idle, job.cpu_ready = total, idle, true
		return 0, false
	}
	delta_total := total-job.cpu_total if total >= job.cpu_total else 0
	delta_idle := idle-job.cpu_idle if idle >= job.cpu_idle else 0
	job.cpu_total, job.cpu_idle = total, idle
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

statusbar_group_modules :: proc(workspace: ^Workspace, modules: []config.Status_Module) -> []Statusbar_Draw_Module {
	result := make([dynamic]Statusbar_Draw_Module, 0, len(modules), context.temp_allocator)
	settings := &workspace.settings.statusbar
	for module in modules {
		value := statusbar_module_text(workspace, module)
		if value == "" do continue
		style := settings.module_styles[int(module)]
		foreground := settings.foreground
		background := settings.background
		if style.foreground_set do foreground = style.foreground
		if style.background_set do background = style.background
		if module == .Jobs && settings.module_blocks {
			visible := statusbar_visible_jobs(workspace)
			if len(visible) > 1 {
				counts := statusbar_job_counts(visible)
				first := true
				if counts.running > 0 {
					text := fmt.tprintf("RUN %d", counts.running)
					if first {text = statusbar_join_label(style.label, text); first = false}
					append(&result, {text = text, foreground = foreground, background = background, jobs = true})
				}
				if counts.succeeded > 0 {
					text := fmt.tprintf("OK %d", counts.succeeded)
					if first {text = statusbar_join_label(style.label, text); first = false}
					append(&result, {text = text, foreground = foreground, background = settings.jobs.success_background, jobs = true})
				}
				if counts.failed > 0 {
					text := fmt.tprintf("ERR %d", counts.failed)
					if first {text = statusbar_join_label(style.label, text); first = false}
					append(&result, {text = text, foreground = foreground, background = settings.jobs.failure_background, jobs = true})
				}
				if counts.cancelled > 0 {
					text := fmt.tprintf("CANCEL %d", counts.cancelled)
					if first {text = statusbar_join_label(style.label, text); first = false}
					append(&result, {text = text, foreground = foreground, background = background, jobs = true})
				}
			} else if len(visible) == 1 {
				job := visible[0]
				job_background := background
				if job.state == .Succeeded do job_background = settings.jobs.success_background
				else if job.state == .Failed || job.state == .Unknown do job_background = settings.jobs.failure_background
				append(&result, {text = value, foreground = foreground, background = job_background, jobs = true})
			}
			continue
		}
		append(&result, {text = value, foreground = foreground, background = background, jobs = module == .Jobs})
	}
	return result[:]
}

statusbar_module_group_key :: proc(modules: []Statusbar_Draw_Module) -> string {
	output := make([dynamic]byte, 0, len(modules)*32, context.temp_allocator)
	for module in modules {
		part := fmt.tprintf("%08x:%08x:%d:%s\x00", module.foreground, module.background, module.jobs, module.text)
		append(&output, ..transmute([]byte)part)
	}
	return string(output[:])
}

statusbar_mouse :: proc(workspace: ^Workspace, mouse: keyboard.Mouse_Event) -> bool {
	if workspace == nil || !statusbar_visible(workspace) do return false
	height := statusbar_render_height(workspace)
	y := 0
	if mouse.y < y || mouse.y >= y+height do return false
	row_height := statusbar_row_height(workspace)
	compact_y := y
	cache := &workspace.statusbar.render_cache
	if mouse.y >= compact_y && mouse.y < compact_y+row_height && mouse.action == .Press && mouse.button == 1 && cache.jobs_hit_valid &&
	   mouse.x >= cache.jobs_hit_left && mouse.x < cache.jobs_hit_right {
		workspace_toggle_jobs_list(workspace)
	} else if workspace.jobs_visible && mouse.action == .Press && mouse.button == 1 {
		workspace_toggle_jobs_list(workspace)
	}
	return true
}

statusbar_module_text :: proc(workspace: ^Workspace, module: config.Status_Module) -> string {
	tab := workspace_active_tab(workspace)
	pane := workspace_active_pane(workspace)
	if tab == nil || pane == nil do return ""
	owner := pane_tmux_owner(pane)
	remote := owner != nil && owner.remote_host != ""
	label := workspace.settings.statusbar.module_styles[int(module)].label
	switch module {
	case .Mode:
		value := "tmux+ssh" if tab_is_tmux(tab) && remote else "tmux" if tab_is_tmux(tab) else "ssh" if remote else "local"
		return statusbar_join_label(label, value)
	case .Session:
		value := workspace.title
		if tab_is_tmux(tab) && len(tab.tmux_owner.tmux_session.title) > 0 do value = string(tab.tmux_owner.tmux_session.title[:])
		else if tab.custom_title != "" do value = tab.custom_title
		else if pane.display_title != "" do value = pane.display_title
		else if pane.terminal.title != "" do value = pane.terminal.title
		return statusbar_join_label(label, statusbar_sanitize(value))
	case .Host:
		value := statusbar_sanitize(owner.remote_host) if remote else statusbar_local_hostname(&workspace.statusbar)
		return statusbar_join_label(label, value)
	case .Cwd:
		if workspace.statusbar.cwd_pane != pane || pane.terminal.cwd_changed do statusbar_update_cwd(workspace)
		return statusbar_join_label(label, workspace.statusbar.cwd)
	case .Git:
		if workspace.statusbar.git_pane != pane do return ""
		value := workspace.statusbar.git
		if strings.has_prefix(value, "git:") do value = value[len("git:"):]
		return statusbar_join_label(label, value)
	case .Command:
		if tab_is_tmux(tab) {
			if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil do return statusbar_join_label(label, statusbar_sanitize(string(info.current_command[:])))
			return ""
		}
		if workspace.statusbar.command_pane != pane do return ""
		return statusbar_join_label(label, workspace.statusbar.command)
	case .Size:
		screen := vt.terminal_screen(&pane.terminal)
		return statusbar_join_label(label, fmt.tprintf("%dx%d", screen.columns, screen.rows))
	case .Tabs: return statusbar_join_label(label, fmt.tprintf("%d/%d", workspace.active+1, len(workspace.tabs)))
	case .Clock: return statusbar_join_label(label, workspace.statusbar.clock)
	case .Battery:
		value := workspace.statusbar.battery
		if strings.has_prefix(value, "BAT ") do value = value[len("BAT "):]
		return statusbar_join_label(label, value)
	case .Resource:
		value := statusbar_resource_text(workspace.statusbar.resource, &workspace.settings.statusbar)
		return statusbar_join_label(label, value)
	case .Zoom:
		value := "100%"
		if workspace.initial_font_size > 0 do value = fmt.tprintf("%d%%", (workspace.font_size*100+workspace.initial_font_size/2)/workspace.initial_font_size)
		return statusbar_join_label(label, value)
	case .Jobs: return statusbar_join_label(label, workspace.statusbar.jobs_text)
	}
	return ""
}

statusbar_join_label :: proc(label, value: string) -> string {
	if value == "" do return ""
	clean_label := statusbar_sanitize(label)
	if clean_label == "" do return value
	// A regular space occupies a full terminal cell in a monospace font. Nerd
	// Font symbols already include their own side bearings, so adding that cell
	// makes the icon look detached and perceptually smaller than its value.
	if statusbar_symbol_label(clean_label) do return fmt.tprintf("%s%s", clean_label, value)
	last := clean_label[len(clean_label)-1]
	if last == ' ' || last == '\t' || last == ':' || last == '/' || last == '#' || last == '@' do return fmt.tprintf("%s%s", clean_label, value)
	return fmt.tprintf("%s %s", clean_label, value)
}

statusbar_symbol_label :: proc(label: string) -> bool {
	if label == "" do return false
	remaining := label
	found := false
	for remaining != "" {
		codepoint, width := utf8.decode_rune_in_string(remaining)
		if width <= 0 || codepoint == utf8.RUNE_ERROR && width == 1 do return false
		remaining = remaining[width:]
		is_symbol := codepoint >= 0xe000 && codepoint <= 0xe00a ||
		             codepoint >= 0xe0a0 && codepoint <= 0xe0d7 ||
		             codepoint >= 0xe200 && codepoint <= 0xe2a9 ||
		             codepoint >= 0xe300 && codepoint <= 0xe3e3 ||
		             codepoint >= 0xe5fa && codepoint <= 0xe6b7 ||
		             codepoint >= 0xe700 && codepoint <= 0xe8ef ||
		             codepoint >= 0xea60 && codepoint <= 0xec1e ||
		             codepoint >= 0xed00 && codepoint <= 0xf533 ||
		             codepoint >= 0xf0001 && codepoint <= 0xf1af0
		if !is_symbol do return false
		found = true
	}
	return found
}

statusbar_find_text :: proc(value, needle: string) -> int {
	if len(needle) == 0 do return 0
	if len(needle) > len(value) do return -1
	for index in 0..=len(value)-len(needle) do if value[index:index+len(needle)] == needle do return index
	return -1
}

statusbar_resource_text :: proc(value: string, settings: ^config.Statusbar_Settings) -> string {
	if value == "" || settings == nil do return value
	ram_at := statusbar_find_text(value, " RAM ")
	storage_at := statusbar_find_text(value, " STORAGE ")
	if strings.has_prefix(value, "CPU ") && ram_at > 4 && storage_at > ram_at+5 {
		cpu := statusbar_join_label(settings.resource_cpu_label, value[4:ram_at])
		ram := statusbar_join_label(settings.resource_ram_label, value[ram_at+5:storage_at])
		storage := statusbar_join_label(settings.resource_storage_label, value[storage_at+9:])
		return fmt.tprintf("%s %s %s", cpu, ram, storage)
	}
	if strings.has_prefix(value, "RAM ") && storage_at > 4 {
		ram := statusbar_join_label(settings.resource_ram_label, value[4:storage_at])
		storage := statusbar_join_label(settings.resource_storage_label, value[storage_at+9:])
		return fmt.tprintf("%s %s", ram, storage)
	}
	return value
}

statusbar_local_hostname :: proc(state: ^Statusbar_State) -> string {
	if state.local_host != "" do return state.local_host
	buffer: [256]c.char
	if posix.gethostname(&buffer[0], len(buffer)) != .OK do return ""
	buffer[len(buffer)-1] = 0
	value := statusbar_sanitize(string(cstring(&buffer[0])))
	if value != "" do config.replace_string(&state.local_host, value)
	return state.local_host
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
	if workspace.statusbar_surface.id == 0 || !statusbar_visible(workspace) do return
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	settings := &workspace.settings.statusbar
	workspace.statusbar.draw_requests += 1
	font := pane.renderer.font
	height := statusbar_render_height(workspace)
	row_height := statusbar_row_height(workspace)
	y := 0
	row_y := 0
	left, center, right: string
	left_modules := statusbar_group_modules(workspace, settings.left[:])
	center_modules := statusbar_group_modules(workspace, settings.center[:])
	right_modules := statusbar_group_modules(workspace, settings.right[:])
	if settings.module_blocks {
		left = statusbar_module_group_key(left_modules)
		center = statusbar_module_group_key(center_modules)
		right = statusbar_module_group_key(right_modules)
	} else {
		left = statusbar_group_text(workspace, settings.left[:])
		center = statusbar_group_text(workspace, settings.center[:])
		right = statusbar_group_text(workspace, settings.right[:])
	}
	draw_workspace_statusbar(
		&workspace.statusbar.render_cache, &workspace.statusbar_surface, font,
		left, center, right, left_modules, center_modules, right_modules,
		settings.separator,
		settings.module_blocks, settings.border, y, height, row_y, row_height,
		settings.background, settings.foreground, statusbar_active_accent(workspace),
	)
}

statusbar_active_accent :: proc(workspace: ^Workspace) -> u32 {
	tab := workspace_active_tab(workspace)
	if tab == nil do return workspace.settings.statusbar.accent
	for pane in tab.panes do if pane.root_foreground do return workspace.settings.ui_colors.root_tab_background
	if tab_is_tmux(tab) do return workspace.settings.tmux.active_tab_color
	return workspace.settings.ui_colors.active_tab_background
}
