package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import config "config"
import features "features"
import fonts "font"
import keyboard "input"
import jobs "jobs"
import pty "pty"
import quake "quake"
import drawing "render"
import selection "selection"
import tmux "tmux"
import vt "vt"
import x11 "x11"
import xlib "vendor:x11/xlib"

Job_Registry :: jobs.Registry
Job_Reporter_Server :: jobs.Reporter_Server
Job_Reporter_Client :: jobs.Reporter_Client

Pane :: struct {
	workspace: ^Workspace,
	surface: x11.Window,
	renderer: drawing.Renderer,
	process: pty.Process,
	terminal: vt.Terminal,
	local_terminal: vt.Terminal,
	has_local_terminal: bool,
	tmux_session: tmux.Session,
	tmux_expected: bool,
	tmux_owner: ^Pane,
	tmux_pane_id: int,
	tmux_client_columns, tmux_client_rows: int,
	pending: [dynamic]byte,
	pending_offset: int,
	selection_state: selection.State,
	search_state: features.State,
	url_state: features.URL_State,
	shell_state: features.Shell_State,
	scrollback_state: features.Scrollback_State,
	scrollbar: Scrollbar_Interaction,
	osc52: OSC52_Request,
	visible: bool,
	exited: bool,
	root_foreground: bool,
	tracked_job_id: u64,
	rule_name: string,
	display_title: string,
	remote_host: string,
	local_display_title: string,
	local_tab_title: string,
	local_root_foreground: bool,
	reconnect_command: [dynamic]cstring,
	tmux_disconnected: bool,
	tmux_disconnect_pending: bool,
	tmux_detach_requested: bool,
	tmux_reconnect_disabled: bool,
	tmux_reconnecting: bool,
	tmux_job_environment_published: bool,
	tmux_reconnect_attempts: int,
	tmux_disconnected_since: time.Time,
	last_tmux_reconcile: time.Time,
}

Split_Axis :: enum { Rows, Columns }

Split_Node :: struct {
	pane: ^Pane,
	axis: Split_Axis,
	first, second: ^Split_Node,
}

Tab :: struct {
	id: u64,
	panes: [dynamic]^Pane,
	active: int,
	axis: Split_Axis,
	layout: ^Split_Node,
	stacked: bool,
	custom_title: string,
	tmux_owner: ^Pane,
	tmux_window_id: int,
	tmux_title: string,
}

split_leaf :: proc(pane: ^Pane) -> ^Split_Node {
	node := new(Split_Node)
	node.pane = pane
	return node
}

split_destroy :: proc(node: ^Split_Node) {
	if node == nil do return
	split_destroy(node.first)
	split_destroy(node.second)
	free(node)
}

split_find :: proc(node: ^Split_Node, pane: ^Pane) -> ^Split_Node {
	if node == nil do return nil
	if node.pane == pane do return node
	if found := split_find(node.first, pane); found != nil do return found
	return split_find(node.second, pane)
}

split_remove :: proc(node: ^Split_Node, pane: ^Pane) -> (root: ^Split_Node, removed: bool) {
	if node == nil do return nil, false
	if node.pane == pane {
		free(node)
		return nil, true
	}
	node.first, removed = split_remove(node.first, pane)
	if !removed do node.second, removed = split_remove(node.second, pane)
	if !removed do return node, false
	if node.first == nil || node.second == nil {
		replacement := node.second if node.first == nil else node.first
		free(node)
		return replacement, true
	}
	return node, true
}

split_bounds :: proc(node: ^Split_Node, pane: ^Pane, x, y, width, height: int) -> (int, int, int, int, bool) {
	if node == nil do return 0, 0, 0, 0, false
	if node.pane != nil do return x, y, width, height, node.pane == pane
	if node.axis == .Rows {
		first_height := height/2
		if bx, by, bw, bh, found := split_bounds(node.first, pane, x, y, width, first_height); found {
			return bx, by, bw, bh, true
		}
		return split_bounds(node.second, pane, x, y+first_height, width, height-first_height)
	}
	first_width := width/2
	if bx, by, bw, bh, found := split_bounds(node.first, pane, x, y, first_width, height); found {
		return bx, by, bw, bh, true
	}
	return split_bounds(node.second, pane, x+first_width, y, width-first_width, height)
}

Tab_Bounds :: struct {
	x, width: int,
	tab_index: int,
}

Pending_Rule_Window :: struct {
	name: string,
	started: time.Time,
}

Workspace :: struct {
	root: ^x11.Window,
	statusbar_surface: x11.Window,
	jobs_surface: x11.Window,
	search_surface: x11.Window,
	close_surface: x11.Window,
	search_visible: bool,
	jobs_visible: bool,
	jobs_selected: int,
	settings: ^config.Settings,
	command: []cstring,
	tabs: [dynamic]^Tab,
	next_tab_id: u64,
	pending_rule_windows: [dynamic]Pending_Rule_Window,
	active: int,
	close_confirmation: bool,
	initial_font_size: int,
	font_size: int,
	tab_bounds: [dynamic]Tab_Bounds,
	tab_scroll_offset: int,
	tab_reveal_active: bool,
	renaming_tab: int,
	rename_buffer: [dynamic]byte,
	last_tab_click_timestamp: u64,
	last_click_tab: int,
	last_cursor_toggle: time.Time,
	last_privilege_check: time.Time,
	scroll_redraw_source: xlib.Window,
	exit_status: int,
	exit_status_set: bool,
	font_cache: ^Workspace_Font_Cache,
	local_font_cache: Workspace_Font_Cache,
	font_entry: ^Workspace_Font_Cache_Entry,
	renderer: drawing.Kind,
	ligatures: bool,
	title: string,
	quake: ^quake.Controller,
	statusbar: Statusbar_State,
	jobs: Job_Registry,
	job_reporter: Job_Reporter_Server,
	layout_pending: bool,
	grid_resize_pending: bool,
	last_resize: time.Tick,
	normal_width, normal_height: int,
	saved_width, saved_height: int,
}

Workspace_Overrides :: struct {
	override_font_size: bool,
	font_size: int,
	override_renderer: bool,
	renderer: drawing.Kind,
	override_ligatures: bool,
	ligatures: bool,
	override_title: bool,
	title: string,
	remote_host: string,
}

Workspace_Font_Cache_Entry :: struct {
	manager: fonts.Manager,
	point_size, dpi: int,
	font, bold_font, italic_font, bold_italic_font: string,
	cell_width_percent, cell_height_percent: int,
	references: int,
}

Workspace_Font_Cache :: struct {
	entries: [dynamic]^Workspace_Font_Cache_Entry,
}

workspace_font_cache_acquire :: proc(cache: ^Workspace_Font_Cache, settings: ^config.Settings, point_size: int, dpi: f32) -> ^Workspace_Font_Cache_Entry {
	if cache == nil || settings == nil do return nil
	dpi_key := clamp(int(dpi+0.5), 1, 1000)
	for entry in cache.entries {
		if entry.point_size == point_size && entry.dpi == dpi_key && entry.font == settings.font && entry.bold_font == settings.bold_font &&
		   entry.italic_font == settings.italic_font && entry.bold_italic_font == settings.bold_italic_font &&
		   entry.cell_width_percent == settings.cell_width_percent && entry.cell_height_percent == settings.cell_height_percent {
			entry.references += 1
			return entry
		}
	}
	entry := new(Workspace_Font_Cache_Entry)
	if fonts.init(
		&entry.manager, settings.font, point_size, settings.bold_font, settings.italic_font,
		settings.bold_italic_font, settings.cell_width_percent, settings.cell_height_percent, f32(dpi_key),
	) != .None {
		free(entry)
		return nil
	}
	entry.point_size = point_size
	entry.dpi = dpi_key
	entry.font = strings.clone(settings.font)
	entry.bold_font = strings.clone(settings.bold_font)
	entry.italic_font = strings.clone(settings.italic_font)
	entry.bold_italic_font = strings.clone(settings.bold_italic_font)
	entry.cell_width_percent = settings.cell_width_percent
	entry.cell_height_percent = settings.cell_height_percent
	entry.references = 1
	append(&cache.entries, entry)
	return entry
}

workspace_font_cache_release :: proc(cache: ^Workspace_Font_Cache, entry: ^Workspace_Font_Cache_Entry) {
	if cache == nil || entry == nil do return
	entry.references -= 1
	if entry.references > 0 do return
	for candidate, index in cache.entries {
		if candidate != entry do continue
		fonts.destroy(&entry.manager)
		delete(entry.font); delete(entry.bold_font); delete(entry.italic_font); delete(entry.bold_italic_font)
		free(entry)
		unordered_remove(&cache.entries, index)
		return
	}
}

workspace_font_cache_destroy :: proc(cache: ^Workspace_Font_Cache) {
	if cache == nil do return
	for entry in cache.entries {
		fonts.destroy(&entry.manager)
		delete(entry.font); delete(entry.bold_font); delete(entry.italic_font); delete(entry.bold_italic_font)
		free(entry)
	}
	delete(cache.entries)
	cache^ = {}
}

Workspace_Poll_Kind :: enum { Window, Quake, Pane, Job_Listener, Job_Client }

Workspace_Poll_Target :: struct {
	kind: Workspace_Poll_Kind,
	workspace: ^Workspace,
	pane: ^Pane,
	job_client: ^Job_Reporter_Client,
}

PRIVILEGE_CHECK_INTERVAL :: 250*time.Millisecond
TMUX_RECONCILE_INTERVAL :: 2*time.Second
TMUX_MAX_RECONNECT_ATTEMPTS :: 8
RESIZE_SETTLE_INTERVAL :: 250*time.Millisecond

workspace_run :: proc(root: ^x11.Window, command: []cstring, settings: ^config.Settings, quake_controller: ^quake.Controller = nil) -> int {
	workspace: Workspace
	if !workspace_init(&workspace, root, command, settings, quake_controller = quake_controller) {
		fmt.eprintln("could not create terminal session")
		return 1
	}
	defer workspace_destroy(&workspace)
	fds: [dynamic]posix.pollfd
	targets: [dynamic]Workspace_Poll_Target
	defer {
		delete(fds)
		delete(targets)
	}
	for workspace_service(&workspace) {
		clear(&fds)
		clear(&targets)
		workspace_append_poll(&workspace, &fds, &targets)
		poll_timeout := 50
		if workspace.quake != nil do poll_timeout = quake.poll_timeout_ms(workspace.quake, poll_timeout)
		if posix.poll(raw_data(fds), u64(len(fds)), i32(poll_timeout)) < 0 {
			if posix.errno() == .EINTR do continue
			return 1
		}
		for index in 0..<len(fds) do workspace_dispatch_poll(targets[index], fds[index].revents)
		workspace_finish_cycle(&workspace)
	}
	return 0
}

workspace_init :: proc(
	workspace: ^Workspace,
	root: ^x11.Window,
	command: []cstring,
	settings: ^config.Settings,
	initial_cwd: string = "",
	font_cache: ^Workspace_Font_Cache = nil,
	overrides: Workspace_Overrides = {},
	quake_controller: ^quake.Controller = nil,
) -> bool {
	font_size := overrides.font_size if overrides.override_font_size else settings.font_size
	renderer := overrides.renderer if overrides.override_renderer else settings.renderer
	ligatures := overrides.ligatures if overrides.override_ligatures else settings.ligatures
	title := overrides.title if overrides.override_title else settings.title
	workspace^ = Workspace{
		root = root, settings = settings, command = command, initial_font_size = font_size, font_size = font_size,
		renaming_tab = -1, last_click_tab = -2, last_cursor_toggle = time.now(), tab_reveal_active = true,
		renderer = renderer, ligatures = ligatures, title = strings.clone(title), quake = quake_controller,
		normal_width = root.width, normal_height = root.height,
	}
	workspace.statusbar.visible = settings.statusbar.enabled
	workspace.statusbar.auto_hide_revealed = !settings.statusbar.auto_hide
	workspace.job_reporter.listener.fd = -1
	_ = jobs.reporter_open(&workspace.job_reporter, &workspace.jobs, u64(root.id))
	selected_font_cache := font_cache
	if selected_font_cache == nil do selected_font_cache = &workspace.local_font_cache
	workspace.font_cache = selected_font_cache
	workspace.font_entry = workspace_font_cache_acquire(selected_font_cache, settings, workspace.font_size, root.dpi)
	if workspace.font_entry == nil {
		jobs.reporter_close(&workspace.job_reporter)
		delete(workspace.title)
		return false
	}
	x11.set_surface_colors(root, settings.theme.background, settings.ui_colors.active_border)
	pane := workspace_new_pane_command(workspace, command, initial_cwd, settings.tmux.explicit_launch)
	if pane != nil && settings.launch_rule != "" do config.replace_string(&pane.rule_name, settings.launch_rule)
	remote_host := overrides.remote_host if overrides.remote_host != "" else settings.tmux.explicit_ssh_host
	if pane != nil && remote_host != "" do config.replace_string(&pane.remote_host, remote_host)
	created := workspace_append_new_tab(workspace, pane)
	if !created {
		jobs.reporter_close(&workspace.job_reporter)
		workspace_font_cache_release(workspace.font_cache, workspace.font_entry)
		workspace.font_entry = nil
		if workspace.font_cache == &workspace.local_font_cache do workspace_font_cache_destroy(&workspace.local_font_cache)
		delete(workspace.title)
		return false
	}
	if settings.launch_rule != "" {
		rule := config.tab_rule(settings, settings.launch_rule)
		if rule != nil && rule.track_job do pane.tracked_job_id = workspace_register_rule_job(workspace, pane, rule)
	}
	search_surface, search_ok := x11.create_child(root, 0, 0, 1, 1)
	if search_ok {
		workspace.search_surface = search_surface
		x11.show_child(&workspace.search_surface, false)
	}
	close_surface, close_ok := x11.create_child(root, 0, 0, 1, 1)
	if close_ok {
		workspace.close_surface = close_surface
		x11.show_child(&workspace.close_surface, false)
	}
	statusbar_surface, statusbar_ok := x11.create_child(root, 0, 0, 1, 1)
	if statusbar_ok {
		workspace.statusbar_surface = statusbar_surface
		x11.set_surface_colors(&workspace.statusbar_surface, settings.statusbar.background, settings.statusbar.background)
		x11.show_child(&workspace.statusbar_surface, false)
	} else {
		workspace.statusbar.visible = false
	}
	jobs_surface, jobs_ok := x11.create_child(root, 0, 0, 1, 1)
	if jobs_ok {
		workspace.jobs_surface = jobs_surface
		x11.set_surface_colors(&workspace.jobs_surface, settings.statusbar.background, settings.statusbar.accent)
		x11.show_child(&workspace.jobs_surface, false)
	}
	statusbar_tick(workspace, true)
	workspace_layout(workspace)
	workspace_capture_window_size(workspace)
	workspace_remember_window_size(workspace)
	workspace_refresh_privileged_tabs(workspace, true)
	x11.set_mouse_tracking(root, 0, settings.scrollbar_enabled || (settings.statusbar.auto_hide && workspace.statusbar.visible))
	return true
}

workspace_service :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil || len(workspace.tabs) == 0 do return false
	if workspace.quake != nil && !quake.service(workspace.quake) do return false
	pointer_tracking := workspace.settings.scrollbar_enabled || (workspace.settings.statusbar.auto_hide && workspace.statusbar.visible)
	x11.set_mouse_tracking(workspace.root, 0, pointer_tracking)
	if workspace.statusbar_surface.id != 0 do x11.set_mouse_tracking(&workspace.statusbar_surface, 0, pointer_tracking)
	for tab in workspace.tabs {
		for pane in tab.panes {
			if pane.visible do x11.set_mouse_tracking(&pane.surface, pane.terminal.modes.mouse_tracking, pointer_tracking)
		}
	}
	for {
		event, available := x11.next_event(workspace.root)
		if !available do break
		if !workspace_event(workspace, event) do return false
	}
	if workspace.layout_pending {
		workspace.layout_pending = false
		workspace_layout(workspace, !workspace.grid_resize_pending)
	}
	if workspace_resize_settled(workspace) {
		workspace.grid_resize_pending = false
		workspace_layout(workspace)
		workspace_capture_window_size(workspace)
		workspace_remember_window_size(workspace)
	}
	if workspace.scroll_redraw_source != 0 {
		if pane := workspace_find_pane(workspace, workspace.scroll_redraw_source); pane != nil && pane.visible {
			workspace_redraw(workspace, pane, true)
		}
		workspace.scroll_redraw_source = 0
	}
	workspace_reap(workspace)
	workspace_tmux_reconnect_tick(workspace)
	workspace_tmux_reconcile_tick(workspace)
	jobs.reporter_cleanup(&workspace.job_reporter)
	return len(workspace.tabs) > 0
}

workspace_append_poll :: proc(
	workspace: ^Workspace,
	fds: ^[dynamic]posix.pollfd,
	targets: ^[dynamic]Workspace_Poll_Target,
) {
	append(fds, {fd = posix.FD(x11.connection_fd(workspace.root)), events = {.IN}})
	append(targets, {kind = .Window, workspace = workspace})
	if workspace.quake != nil && quake.poll_fd(workspace.quake) >= 0 {
		append(fds, {fd = quake.poll_fd(workspace.quake), events = {.IN}})
		append(targets, {kind = .Quake, workspace = workspace})
	}
	if workspace.job_reporter.enabled {
		append(fds, {fd = workspace.job_reporter.listener.fd, events = {.IN}})
		append(targets, {kind = .Job_Listener, workspace = workspace})
		for client in workspace.job_reporter.clients {
			append(fds, {fd = client.connection.fd, events = jobs.reporter_client_events(client)})
			append(targets, {kind = .Job_Client, workspace = workspace, job_client = client})
		}
	}
	for tab in workspace.tabs {
		for pane in tab.panes {
			if pane.exited || pane.tmux_disconnected || pane.tmux_owner != nil do continue
			events: posix.Poll_Event = {.IN}
			if pane.pending_offset < len(pane.pending) do events += {.OUT}
			append(fds, {fd = pane.process.master, events = events})
			append(targets, {kind = .Pane, workspace = workspace, pane = pane})
		}
	}
}

workspace_dispatch_poll :: proc(target: Workspace_Poll_Target, events: posix.Poll_Event) {
	if target.workspace == nil do return
	switch target.kind {
	case .Job_Listener:
		if .IN in events do jobs.reporter_accept(&target.workspace.job_reporter)
		return
	case .Job_Client:
		jobs.reporter_client_poll(&target.workspace.job_reporter, target.job_client, events)
		return
	case .Window, .Quake:
		return
	case .Pane:
	}
	if target.pane == nil do return
	pane := target.pane
	if .IN in events || .HUP in events {
		if !workspace_drain(target.workspace, pane) do pane.exited = true
	}
	if .OUT in events do workspace_write(pane)
	if .ERR in events || .NVAL in events {
		if len(pane.reconnect_command) > 0 && !pane.tmux_reconnect_disabled do workspace_tmux_disconnect(target.workspace, pane)
		else do pane.exited = true
	}
}

workspace_finish_cycle :: proc(workspace: ^Workspace) {
	workspace_reconcile_job_owners(workspace)
	workspace_cursor_tick(workspace)
	workspace_refresh_privileged_tabs(workspace, false)
	statusbar_auto_hide_tick(workspace)
	statusbar_tick(workspace)
}

workspace_reconcile_job_owners :: proc(workspace: ^Workspace) {
	if workspace == nil do return
	for &job in workspace.jobs.jobs {
		if job.owner.tab != 0 do continue
		pane: ^Pane
		if tmux_owner_id, tmux_pane_id, is_tmux := jobs.tmux_reporter_identity(job.reporter); is_tmux {
			for tab in workspace.tabs do for candidate in tab.panes do if candidate.tmux_pane_id == tmux_pane_id &&
			   pane_tmux_owner(candidate).surface.id == xlib.Window(tmux_owner_id) {
				pane = candidate
				break
			}
		} else {
			pane = workspace_find_pane(workspace, xlib.Window(job.owner.pane))
		}
		if pane == nil do continue
		job.owner.pane = u64(pane.surface.id)
		if tab := workspace_tab_for_pane(workspace, pane); tab != nil do job.owner.tab = tab.id
	}
}

workspace_exit_status :: proc(workspace: ^Workspace) -> int {
	if workspace == nil || !workspace.exit_status_set do return 0
	return workspace.exit_status
}

workspace_new_pane :: proc(workspace: ^Workspace, cwd: string = "") -> ^Pane {
	return workspace_new_pane_command(workspace, workspace.command, cwd, false)
}

workspace_new_pane_command :: proc(workspace: ^Workspace, command: []cstring, cwd: string = "", tmux_expected: bool = false) -> ^Pane {
	pane := new(Pane)
	pane.workspace = workspace
	pane.tmux_pane_id = -1
	surface, ok := x11.create_child(workspace.root, 0, 0, workspace.root.width, workspace.root.height)
	if !ok { free(pane); return nil }
	pane.surface = surface
	if drawing.init(
		&pane.renderer, &pane.surface, workspace.renderer, workspace.ligatures,
		workspace.settings.font, workspace.font_size,
		workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
		workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
		&workspace.font_entry.manager,
	) != .None {
		x11.destroy_child(&pane.surface); free(pane); return nil
	}
	if len(workspace.tabs) == 0 do workspace_place_initial_pane(workspace, pane)
	columns, rows := x11.grid_size(&pane.surface)
	directory := cwd
	if directory == "" do directory = workspace.settings.working_directory
	environment: [4]pty.Environment_Variable
	process, process_error := pty.spawn(
		command, pty_size(columns, rows, pane.surface.width, pane.surface.height), workspace.settings.term, directory,
		workspace_job_environment(workspace, pane, &environment),
	)
	if process_error != .None {
		drawing.destroy(&pane.renderer, &pane.surface); x11.destroy_child(&pane.surface); free(pane); return nil
	}
	pane.process = process
	pane.tmux_expected = tmux_expected
	if tmux_expected {
		for argument in command[:len(command)-1] do append_command_argument(&pane.reconnect_command, string(argument))
		append(&pane.reconnect_command, nil)
	}
	if !vt.terminal_init(&pane.terminal, columns, rows, workspace.settings.scrollback_lines, workspace.settings.osc52_policy, &workspace.settings.graphics_limits) {
		pty.shutdown(&pane.process); drawing.destroy(&pane.renderer, &pane.surface); x11.destroy_child(&pane.surface); free(pane); return nil
	}
	vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
	workspace_apply_cursor(workspace, pane)
	pane.visible = true
	return pane
}

workspace_place_initial_pane :: proc(workspace: ^Workspace, pane: ^Pane) {
	padding := workspace.settings.window.padding
	tab_bar := 0
	if workspace.settings.tabs.enabled && workspace.settings.tabs.style != .Hidden && workspace.settings.tabs.minimum <= 1 {
		tab_bar = pane.renderer.font.cell_height+4
	}
	status_bar := 0
	if statusbar_visible(workspace) {
		status_bar = max(workspace.settings.statusbar.height, pane.renderer.font.cell_height+6)
	}
	y := padding
	if workspace.settings.tabs.edge == .Top do y += tab_bar
	if workspace.settings.statusbar.position == .Top do y += status_bar
	width := max(1, workspace.root.width-padding*2)
	height := max(1, workspace.root.height-tab_bar-status_bar-padding*2)
	x11.place_child(&pane.surface, padding, y, width, height)
}

workspace_job_environment :: proc(workspace: ^Workspace, pane: ^Pane, environment: ^[4]pty.Environment_Variable) -> []pty.Environment_Variable {
	if workspace == nil || pane == nil || environment == nil || !workspace.job_reporter.enabled do return nil
	environment[0] = {name = "NARE_JOB_SOCKET", value = workspace.job_reporter.path}
	environment[1] = {name = "NARE_JOB_TOKEN", value = workspace.job_reporter.token}
	environment[2] = {name = "NARE_JOB_REPORTER", value = fmt.tprintf("%d", pane.surface.id)}
	environment[3] = {name = "NARE_JOB_WINDOW", value = fmt.tprintf("%d", workspace.root.id)}
	return environment[:]
}

workspace_new_tmux_view :: proc(workspace: ^Workspace, owner: ^Pane, pane_id: int) -> ^Pane {
	pane := new(Pane)
	pane.workspace = workspace
	pane.tmux_owner = owner
	pane.tmux_pane_id = pane_id
	surface, ok := x11.create_child(workspace.root, 0, 0, workspace.root.width, workspace.root.height)
	if !ok {free(pane); return nil}
	pane.surface = surface
	if drawing.init(
		&pane.renderer, &pane.surface, workspace.renderer, workspace.ligatures,
		workspace.settings.font, workspace.font_size,
		workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
		workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
		&workspace.font_entry.manager,
	) != .None {
		x11.destroy_child(&pane.surface)
		free(pane)
		return nil
	}
	columns, rows := x11.grid_size(&pane.surface)
	if !vt.terminal_init(&pane.terminal, columns, rows, workspace.settings.scrollback_lines, workspace.settings.osc52_policy, &workspace.settings.graphics_limits) {
		drawing.destroy(&pane.renderer, &pane.surface)
		x11.destroy_child(&pane.surface)
		free(pane)
		return nil
	}
	vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
	workspace_apply_cursor(workspace, pane)
	return pane
}

pane_tmux_owner :: proc(pane: ^Pane) -> ^Pane {
	if pane == nil do return nil
	return pane.tmux_owner if pane.tmux_owner != nil else pane
}

tab_is_tmux :: proc(tab: ^Tab) -> bool {
	return tab != nil && tab.tmux_owner != nil
}

workspace_insert_tab :: proc(workspace: ^Workspace, index: int, tab: ^Tab) {
	insertion_index := clamp(index, 0, len(workspace.tabs))
	append(&workspace.tabs, tab)
	for cursor := len(workspace.tabs)-1; cursor > insertion_index; cursor -= 1 do workspace.tabs[cursor] = workspace.tabs[cursor-1]
	workspace.tabs[insertion_index] = tab
}

workspace_tab_for_pane :: proc(workspace: ^Workspace, target: ^Pane) -> ^Tab {
	for tab in workspace.tabs do for pane in tab.panes do if pane == target do return tab
	return nil
}

workspace_tmux_view :: proc(workspace: ^Workspace, owner: ^Pane, pane_id: int) -> ^Pane {
	for tab in workspace.tabs do if tab.tmux_owner == owner {
		for pane in tab.panes do if pane.tmux_pane_id == pane_id do return pane
	}
	return nil
}

pane_destroy :: proc(pane: ^Pane) {
	if pane == nil do return
	if pane.workspace != nil && pane.tracked_job_id != 0 do jobs.cancel(&pane.workspace.jobs, pane.tracked_job_id)
	if pane.workspace != nil do jobs.owner_lost(&pane.workspace.jobs, u64(pane.surface.id))
	if pane.tmux_owner == nil do pty.shutdown(&pane.process)
	vt.terminal_destroy(&pane.terminal)
	if pane.tmux_owner == nil {
		if pane.has_local_terminal do vt.terminal_destroy(&pane.local_terminal)
		tmux.session_destroy(&pane.tmux_session)
	}
	features.destroy(&pane.search_state)
	features.url_destroy(&pane.url_state)
	features.shell_destroy(&pane.shell_state)
	features.scrollback_destroy(&pane.scrollback_state)
	delete(pane.display_title)
	delete(pane.rule_name)
	delete(pane.remote_host)
	if pane.tmux_owner == nil {
		delete(pane.local_display_title)
		delete(pane.local_tab_title)
		delete(pane.pending)
		command_destroy(&pane.reconnect_command)
	}
	drawing.destroy(&pane.renderer, &pane.surface)
	x11.destroy_child(&pane.surface)
	free(pane)
}

workspace_destroy :: proc(workspace: ^Workspace) {
	workspace_capture_window_size(workspace)
	workspace_remember_window_size(workspace)
	if workspace.search_surface.id != 0 do x11.destroy_child(&workspace.search_surface)
	if workspace.close_surface.id != 0 do x11.destroy_child(&workspace.close_surface)
	if workspace.statusbar_surface.id != 0 do x11.destroy_child(&workspace.statusbar_surface)
	if workspace.jobs_surface.id != 0 do x11.destroy_child(&workspace.jobs_surface)
	for tab in workspace.tabs {
		for pane in tab.panes do pane_destroy(pane)
		split_destroy(tab.layout)
		delete(tab.panes)
		delete(tab.custom_title)
		delete(tab.tmux_title)
		free(tab)
	}
	delete(workspace.tabs)
	for pending in workspace.pending_rule_windows do delete(pending.name)
	delete(workspace.pending_rule_windows)
	jobs.reporter_close(&workspace.job_reporter)
	jobs.destroy(&workspace.jobs)
	delete(workspace.tab_bounds)
	delete(workspace.rename_buffer)
	delete(workspace.title)
	statusbar_destroy(&workspace.statusbar)
	workspace_font_cache_release(workspace.font_cache, workspace.font_entry)
	workspace.font_entry = nil
	if workspace.font_cache == &workspace.local_font_cache do workspace_font_cache_destroy(&workspace.local_font_cache)
	workspace.font_cache = nil
}

workspace_new_tab :: proc(workspace: ^Workspace) -> bool {
	pane := workspace_new_pane(workspace)
	return workspace_append_new_tab(workspace, pane)
}

workspace_new_tab_command :: proc(workspace: ^Workspace, command: []cstring, tmux_expected: bool = false) -> bool {
	pane := workspace_new_pane_command(workspace, command, "", tmux_expected)
	return workspace_append_new_tab(workspace, pane)
}

workspace_append_new_tab :: proc(workspace: ^Workspace, pane: ^Pane) -> bool {
	if pane == nil do return false
	tab := new(Tab)
	tab.id = workspace_next_tab_id(workspace)
	tab.tmux_window_id = -1
	append(&tab.panes, pane)
	tab.layout = split_leaf(pane)
	append(&workspace.tabs, tab)
	workspace.active = len(workspace.tabs)-1
	workspace.tab_reveal_active = true
	workspace_layout(workspace)
	return true
}

workspace_next_tab_id :: proc(workspace: ^Workspace) -> u64 {
	workspace.next_tab_id += 1
	if workspace.next_tab_id == 0 do workspace.next_tab_id = 1
	return workspace.next_tab_id
}

workspace_insert_split_pane :: proc(workspace: ^Workspace, pane: ^Pane, axis: Split_Axis) -> bool {
	if pane == nil do return false
	tab := workspace_active_tab(workspace)
	if tab == nil || tab_is_tmux(tab) {
		pane_destroy(pane)
		return false
	}
	current := tab.panes[tab.active]
	leaf := split_find(tab.layout, current)
	if leaf == nil {
		pane_destroy(pane)
		return false
	}
	leaf.pane = nil
	leaf.axis = axis
	leaf.first = split_leaf(current)
	leaf.second = split_leaf(pane)
	append(&tab.panes, pane)
	tab.active = len(tab.panes)-1
	tab.stacked = false
	workspace_layout(workspace)
	return true
}

workspace_split :: proc(workspace: ^Workspace, axis: Split_Axis) {
	tab := workspace_active_tab(workspace)
	if tab == nil do return
	current := tab.panes[tab.active]
	cwd := current.terminal.cwd_path if current.terminal.cwd_local else ""
	pane := workspace_new_pane(workspace, cwd)
	if pane == nil do return
	_ = workspace_insert_split_pane(workspace, pane, axis)
}

workspace_active_tab :: proc(workspace: ^Workspace) -> ^Tab {
	if workspace.active < 0 || workspace.active >= len(workspace.tabs) do return nil
	return workspace.tabs[workspace.active]
}

workspace_active_pane :: proc(workspace: ^Workspace) -> ^Pane {
	tab := workspace_active_tab(workspace)
	if tab == nil || len(tab.panes) == 0 do return nil
	return tab.panes[clamp(tab.active, 0, len(tab.panes)-1)]
}

workspace_find_pane :: proc(workspace: ^Workspace, id: xlib.Window) -> ^Pane {
	for tab in workspace.tabs do for pane in tab.panes do if pane.surface.id == id do return pane
	return nil
}

workspace_resize_settled :: proc(workspace: ^Workspace) -> bool {
	return workspace.grid_resize_pending &&
	       time.tick_since(workspace.last_resize) >= RESIZE_SETTLE_INTERVAL &&
	       !x11.pointer_button_down(workspace.root)
}

workspace_capture_window_size :: proc(workspace: ^Workspace) {
	if workspace == nil || workspace.root == nil || workspace.settings == nil || workspace.quake != nil ||
	   !workspace.settings.window.remember_size || x11.window_is_maximized_or_fullscreen(workspace.root) {
		return
	}
	workspace.normal_width = workspace.root.width
	workspace.normal_height = workspace.root.height
}

workspace_remember_window_size :: proc(workspace: ^Workspace) {
	if workspace == nil || workspace.settings == nil || workspace.quake != nil ||
	   !workspace.settings.window.remember_size {
		return
	}
	if workspace.normal_width == workspace.saved_width && workspace.normal_height == workspace.saved_height do return
	if config.save_window_size(workspace.settings.window, workspace.normal_width, workspace.normal_height) {
		workspace.saved_width = workspace.normal_width
		workspace.saved_height = workspace.normal_height
	}
}

workspace_layout :: proc(workspace: ^Workspace, resize_grid: bool = true) {
	workspace.layout_pending = false
	commit_grid := resize_grid
	if commit_grid && workspace.grid_resize_pending && !workspace_resize_settled(workspace) {
		commit_grid = false
	}
	if commit_grid do workspace.grid_resize_pending = false
	root := workspace.root
	x11.set_surface_colors(root, workspace.settings.theme.background, workspace.settings.ui_colors.active_border, clear = false)
	tab_bar := workspace_tab_bar_height(workspace)
	status_bar := statusbar_height(workspace)
	padding := workspace.settings.window.padding
	content_y := padding
	if workspace.settings.tabs.edge == .Top do content_y += tab_bar
	if workspace.settings.statusbar.position == .Top do content_y += status_bar
	content_height := max(1, root.height-tab_bar-status_bar-padding*2)
	content_width := max(1, root.width-padding*2)
	if workspace.statusbar_surface.id != 0 {
		if status_bar > 0 {
			status_y := tab_bar if workspace.settings.statusbar.position == .Top && workspace.settings.tabs.edge == .Top else 0
			if workspace.settings.statusbar.position == .Bottom {
				status_y = root.height-status_bar
				if workspace.settings.tabs.edge == .Bottom do status_y -= tab_bar
			}
			x11.place_child(&workspace.statusbar_surface, 0, status_y, root.width, status_bar)
		} else {
			x11.show_child(&workspace.statusbar_surface, false)
		}
	}
	for layout_index in 0..<len(workspace.tabs) {
		tab_index := workspace.active
		if layout_index > 0 {
			tab_index = layout_index-1
			if tab_index >= workspace.active do tab_index += 1
		}
		tab := workspace.tabs[tab_index]
		active_tab := tab_index == workspace.active
		count := len(tab.panes)
		tmux_columns, tmux_rows := workspace_tmux_window_size(tab)
		for pane, pane_index in tab.panes {
			visible := active_tab && (tab_is_tmux(tab) || !tab.stacked || pane_index == tab.active)
			if !visible {
				x11.show_child(&pane.surface, false)
				pane.visible = false
				continue
			}
			x, y, width, height := padding, content_y, content_width, content_height
			if tab_is_tmux(tab) {
				if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil && tmux_columns > 0 && tmux_rows > 0 {
					x = padding+content_width*info.x/tmux_columns
					y = content_y+content_height*info.y/tmux_rows
					right := padding+content_width*(info.x+info.columns)/tmux_columns
					bottom := content_y+content_height*(info.y+info.rows)/tmux_rows
					width = max(1, right-x)
					height = max(1, bottom-y)
				}
			} else if !tab.stacked && count > 1 {
				bx, by, bw, bh, found := split_bounds(tab.layout, pane, x, y, width, height)
				if found {
					x, y, width, height = bx, by, max(1, bw), max(1, bh)
				}
			}
			old_columns := vt.terminal_screen(&pane.terminal).columns
			old_rows := vt.terminal_screen(&pane.terminal).rows
			border := workspace.settings.ui_colors.active_border if pane_index == tab.active else workspace.settings.ui_colors.inactive_border
			x11.set_surface_colors(&pane.surface, workspace.settings.theme.background, border, 1 if count > 1 && (tab_is_tmux(tab) || !tab.stacked) else 0, clear = false)
			x11.place_child(&pane.surface, x, y, width, height)
			pane.visible = true
			renderer_changed := pane.renderer.cpu.width != width || pane.renderer.cpu.height != height
			if commit_grid && renderer_changed {
				_ = drawing.resize(&pane.renderer, &pane.surface)
			} else if !commit_grid && renderer_changed {
				drawing.present_cached(&pane.renderer, &pane.surface)
			}
			columns, rows := x11.grid_size(&pane.surface)
			if commit_grid && (columns != old_columns || rows != old_rows) {
				_ = vt.terminal_resize(&pane.terminal, columns, rows)
				if pane.search_state.active do features.refresh(&pane.search_state, vt.terminal_screen(&pane.terminal))
				if !tab_is_tmux(tab) {
					vt.terminal_expect_resize_prompt_redraw(&pane.terminal)
					_ = pty.resize(&pane.process, pty_size(columns, rows, width, height))
				}
			}
			workspace_redraw(workspace, pane, true)
		}
	}
	if commit_grid {
		if tab := workspace_active_tab(workspace); tab_is_tmux(tab) {
			owner := tab.tmux_owner
			pane := workspace_active_pane(workspace)
			if owner != nil && pane != nil {
				columns := max(1, content_width/max(1, pane.surface.cell_w))
				rows := max(1, content_height/max(1, pane.surface.cell_h))
				if columns != owner.tmux_client_columns || rows != owner.tmux_client_rows {
					owner.tmux_client_columns, owner.tmux_client_rows = columns, rows
					_ = pty.resize(&owner.process, pty_size(columns, rows, content_width, content_height))
					if tmux.session_ready(&owner.tmux_session) do tmux.append_resize_command(&owner.tmux_session, &owner.pending, columns, rows)
				}
			}
		}
	}
	if status_bar > 0 && workspace.statusbar_surface.id != 0 do x11.raise_child(&workspace.statusbar_surface)
	workspace_draw_tabs(workspace)
}

workspace_tmux_pane_info :: proc(owner: ^Pane, pane_id: int) -> ^tmux.Pane_Info {
	if owner == nil do return nil
	for &info in owner.tmux_session.panes do if info.id == pane_id do return &info
	return nil
}

workspace_tmux_window_size :: proc(tab: ^Tab) -> (columns, rows: int) {
	if !tab_is_tmux(tab) do return
	for pane in tab.tmux_owner.tmux_session.panes {
		if pane.window_id != tab.tmux_window_id do continue
		columns = max(columns, pane.x+pane.columns)
		rows = max(rows, pane.y+pane.rows)
	}
	return
}

workspace_tab_bar_height :: proc(workspace: ^Workspace) -> int {
	if !workspace.settings.tabs.enabled || workspace.settings.tabs.style == .Hidden || len(workspace.tabs) < workspace.settings.tabs.minimum do return 0
	pane := workspace_active_pane(workspace)
	if pane == nil do return workspace.font_size+10
	return pane.renderer.font.cell_height+4
}

workspace_search_bar_height :: proc(workspace: ^Workspace) -> int {
	pane := workspace_active_pane(workspace)
	if pane == nil || !pane.search_state.active do return 0
	return pane.renderer.font.cell_height+6
}

workspace_draw_tabs :: proc(workspace: ^Workspace) {
	defer workspace_draw_close_confirmation(workspace)
	defer workspace_draw_jobs_list(workspace)
	defer workspace_draw_search_bar(workspace)
	defer workspace_draw_statusbar(workspace)
	height := workspace_tab_bar_height(workspace)
	if height == 0 do return
	labels := make([]Tab_Draw_Label, len(workspace.tabs), context.temp_allocator)
	for tab, index in workspace.tabs {
		title := workspace.title
		active_root := false
		if tab_is_tmux(tab) && tab.tmux_title != "" do title = tab.tmux_title
		else if tab.custom_title != "" do title = tab.custom_title
		else if len(tab.panes) > 0 {
			active_pane := tab.panes[tab.active]
			active_root = active_pane.root_foreground
			if active_pane.display_title != "" do title = active_pane.display_title
			else if !active_pane.root_foreground && active_pane.terminal.title != "" do title = active_pane.terminal.title
		}
		if tab.custom_title == "" && active_root do title = root_tab_title(title)
		if tab_is_tmux(tab) && tab.tmux_owner.tmux_disconnected do title = fmt.tprintf("%s (disconnected)", title)
		else if tab_is_tmux(tab) && tab.tmux_owner.tmux_reconnecting do title = fmt.tprintf("%s (reconnecting)", title)
		if workspace.renaming_tab == index do title = fmt.tprintf("Rename: %s_", string(workspace.rename_buffer[:]))
		with_index, _ := strings.replace_all(workspace.settings.tabs.title_template, "{index}", fmt.tprintf("%d", index+1), context.temp_allocator)
		label, _ := strings.replace_all(with_index, "{title}", title, context.temp_allocator)
		if index+1 < len(workspace.tabs) do label = strings.concatenate({label, workspace.settings.tabs.separator}, context.temp_allocator)
		root := false
		for pane in tab.panes do if pane.root_foreground {root = true; break}
		labels[index] = {text = label, active = index == workspace.active, root = root, tmux = tab_is_tmux(tab)}
	}
	y := 0
	if workspace.settings.tabs.edge == .Bottom do y = workspace.root.height-height
	colors := workspace.settings.ui_colors
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	draw_workspace_tab_bar(workspace.root, pane.renderer.font, labels, &workspace.tab_bounds, y, height, colors.tab_bar_background, colors.active_tab_foreground, colors.active_tab_background, colors.inactive_tab_foreground, colors.inactive_tab_background, colors.root_tab_background, workspace.settings.tmux.active_tab_color, workspace.settings.tabs.active_bold, workspace.active, &workspace.tab_scroll_offset, workspace.tab_reveal_active)
	workspace.tab_reveal_active = false
}

workspace_draw_search_bar :: proc(workspace: ^Workspace) {
	pane := workspace_active_pane(workspace)
	if pane == nil || !pane.search_state.active {
		if workspace.search_visible && workspace.search_surface.id != 0 {
			x11.show_child(&workspace.search_surface, false)
			workspace.search_visible = false
		}
		return
	}
	match_index := 0
	if len(pane.search_state.matches) > 0 do match_index = pane.search_state.current+1
	label := fmt.tprintf("Search: %s  (%d/%d)", features.query_text(&pane.search_state), match_index, len(pane.search_state.matches))
	height := workspace_search_bar_height(workspace)
	window := &pane.surface
	y := pane.surface.height-height
	if workspace.search_surface.id != 0 {
		window = &workspace.search_surface
		x := pane.surface.x
		y = pane.surface.y+pane.surface.height-height
		x11.place_child(window, x, y, pane.surface.width, height)
		x11.raise_child(window)
		workspace.search_visible = true
		y = 0
	}
	draw_workspace_search_bar(
		window,
		pane.renderer.font,
		label,
		y,
		height,
		workspace.settings.ui_colors.inactive_tab_background,
		workspace.settings.ui_colors.active_tab_foreground,
	)
}

workspace_show_close_confirmation :: proc(workspace: ^Workspace) {
	workspace.close_confirmation = true
	workspace_draw_close_confirmation(workspace)
}

workspace_hide_close_confirmation :: proc(workspace: ^Workspace) {
	workspace.close_confirmation = false
	if workspace.close_surface.id != 0 do x11.show_child(&workspace.close_surface, false)
}

workspace_draw_close_confirmation :: proc(workspace: ^Workspace) {
	if !workspace.close_confirmation || workspace.close_surface.id == 0 do return
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	font := pane.renderer.font
	width := clamp(font.cell_width*42, 280, max(280, workspace.root.width-16))
	width = min(width, max(1, workspace.root.width-16))
	height := min(max(84, font.cell_height*3+28), max(1, workspace.root.height-16))
	x := max(0, (workspace.root.width-width)/2)
	y := max(0, (workspace.root.height-height)/2)
	x11.place_child(&workspace.close_surface, x, y, width, height)
	x11.raise_child(&workspace.close_surface)
	draw_workspace_close_dialog(
		&workspace.close_surface, font,
		workspace.settings.ui_colors.tab_bar_background,
		workspace.settings.theme.foreground,
		statusbar_active_accent(workspace),
		workspace.settings.ui_colors.active_tab_foreground,
		workspace.settings.ui_colors.inactive_tab_background,
	)
}

root_tab_title :: proc(title: string) -> string {
	at := strings.index_byte(title, '@')
	if at <= 0 || at+1 >= len(title) || !tab_title_host_character(title[at+1]) do return title
	start := at
	for start > 0 && tab_title_user_character(title[start-1]) do start -= 1
	if start == at do return title
	return strings.concatenate({title[:start], "root", title[at:]}, context.temp_allocator)
}

tab_title_user_character :: proc(character: byte) -> bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
	       character >= '0' && character <= '9' || character == '_' || character == '-' || character == '.'
}

tab_title_host_character :: proc(character: byte) -> bool {
	return tab_title_user_character(character)
}

workspace_refresh_privileged_tabs :: proc(workspace: ^Workspace, force: bool) {
	if !force && time.since(workspace.last_privilege_check) < PRIVILEGE_CHECK_INTERVAL do return
	workspace.last_privilege_check = time.now()
	changed := false
	for tab in workspace.tabs {
		for pane in tab.panes {
			if tab_is_tmux(tab) do continue
			root := !pane.exited && pty.foreground_is_root(&pane.process)
			if root != pane.root_foreground {
				pane.root_foreground = root
				changed = true
			}
		}
	}
	if changed do workspace_draw_tabs(workspace)
}

workspace_event :: proc(workspace: ^Workspace, event: x11.Event) -> bool {
	#partial switch event.kind {
	case .Close:
		if !workspace.settings.window.confirm_close do return false
		if !workspace.close_confirmation do workspace_show_close_confirmation(workspace)
		return true
	case .Resize:
		if event.dpi_changed do workspace_refresh_dpi(workspace)
		workspace_capture_window_size(workspace)
		workspace_remember_window_size(workspace)
		workspace.tab_reveal_active = true
		workspace.layout_pending = true
		workspace.grid_resize_pending = true
		workspace.last_resize = time.tick_now()
	case .Redraw:
		if event.source == workspace.root.id {
			workspace_draw_tabs(workspace)
		} else if event.source == workspace.statusbar_surface.id {
			workspace_draw_statusbar(workspace)
			workspace_draw_jobs_list(workspace)
		} else if event.source == workspace.jobs_surface.id {
			workspace_draw_jobs_list(workspace)
		} else if event.source == workspace.search_surface.id {
			workspace_draw_search_bar(workspace)
		} else if event.source == workspace.close_surface.id {
			workspace_draw_close_confirmation(workspace)
		} else if pane := workspace_find_pane(workspace, event.source); pane != nil && pane.visible && !workspace.grid_resize_pending {
			workspace_redraw(workspace, pane, true)
		}
	case .Input:
		if workspace.close_confirmation {
			if event.key == .Enter || (event.key == .Text && event.input_size == 1 && (event.input[0] == 'y' || event.input[0] == 'Y')) do return false
			if event.key == .Escape || (event.key == .Text && event.input_size == 1 && (event.input[0] == 'n' || event.input[0] == 'N')) do workspace_hide_close_confirmation(workspace)
			return true
		}
		if workspace.jobs_visible {
			workspace_jobs_list_input(workspace, event)
			return true
		}
		if workspace.renaming_tab >= 0 {
			workspace_rename_input(workspace, event)
			return true
		}
		if workspace_shortcut(workspace, event) do return true
		pane := workspace_active_pane(workspace)
		if pane == nil do return true
		pane.terminal.cursor_phase_visible = true
		workspace.last_cursor_toggle = time.now()
		if search_shortcut(event) {
			if pane.url_state.active do features.url_close(&pane.url_state)
			features.shell_close(&pane.shell_state)
			features.scrollback_close(&pane.scrollback_state)
			selection.clear(&pane.selection_state)
			features.open(&pane.search_state, vt.terminal_screen(&pane.terminal))
			workspace_redraw(workspace, pane, true)
			return true
		}
		if pane.search_state.active {
			workspace_handle_search_input(workspace, pane, event)
			return true
		}
		if rows := scrollback_shortcut(event, vt.terminal_screen(&pane.terminal).rows); rows != 0 {
			selection.clear(&pane.selection_state)
			features.scrollback_scroll(&pane.scrollback_state, vt.terminal_screen(&pane.terminal), rows)
			workspace_redraw(workspace, pane, true)
			return true
		}
		if copy_shortcut(event) { workspace_copy_selection(workspace, pane, .Clipboard); return true }
		if paste_shortcut(event) { x11.request_selection(workspace.root, .Clipboard); return true }
		encoded: [16]byte
		input := event.input
		data := input[:event.input_size]
		if event.key != .Text do data = keyboard.encode_key(event.key, event.modifiers, pane.terminal.modes.application_cursor, encoded[:])
		vt.terminal_input(&pane.terminal, data)
		owner := pane_tmux_owner(pane)
		if owner != nil && tmux.session_active(&owner.tmux_session) {
			if tmux.session_ready(&owner.tmux_session) {
				target := pane.tmux_pane_id if pane.tmux_pane_id >= 0 else owner.tmux_session.pane_id
				if event.key == .Text && .Alt in event.modifiers do tmux.append_input_commands(&owner.tmux_session, &owner.pending, target, {0x1b})
				tmux.append_input_commands(&owner.tmux_session, &owner.pending, target, data)
			}
			return true
		}
		if event.key == .Text && .Alt in event.modifiers do queue_input(&pane.pending, pane.pending_offset, {0x1b})
		queue_input(&pane.pending, pane.pending_offset, data)
	case .Mouse:
		workspace_clear_scrollbar_hover(workspace, event.source)
		if workspace.close_confirmation {
			if event.source == workspace.close_surface.id && event.mouse.action == .Press && event.mouse.button == 1 {
				button_y := workspace.close_surface.height-workspace_active_pane(workspace).renderer.font.cell_height-12
				if event.mouse.y >= button_y {
					if event.mouse.x < workspace.close_surface.width/2 do return false
					workspace_hide_close_confirmation(workspace)
				}
			}
			return true
		}
		pointer_y := event.mouse.y
		if pointer_pane := workspace_find_pane(workspace, event.source); pointer_pane != nil do pointer_y += pointer_pane.surface.y
		if event.source == workspace.statusbar_surface.id do pointer_y += workspace.statusbar_surface.y
		if event.source == workspace.jobs_surface.id do pointer_y += workspace.jobs_surface.y
		if statusbar_auto_hide_pointer(workspace, pointer_y) do return true
		if event.source == workspace.jobs_surface.id && statusbar_jobs_mouse(workspace, event.mouse) do return true
		if event.source == workspace.statusbar_surface.id && statusbar_mouse(workspace, event.mouse) do return true
		if workspace.jobs_visible && event.mouse.action == .Press {
			workspace_toggle_jobs_list(workspace)
			return true
		}
		if event.source == workspace.root.id && workspace_tab_bar_mouse(workspace, event.mouse, event.timestamp) do return true
		pane := workspace_find_pane(workspace, event.source)
		if pane == nil do return true
		if event.mouse.action == .Press do workspace_focus_pane(workspace, pane)
		mouse := event.mouse
		mouse.column = max(1, mouse.x/pane.surface.cell_w+1)
		mouse.row = max(1, mouse.y/pane.surface.cell_h+1)
		local_mouse := pane.terminal.modes.mouse_tracking == 0 || .Shift in mouse.modifiers
		if workspace.settings.scrollbar_enabled && !pane.search_state.active && !pane.url_state.active && !pane.shell_state.active {
			handled, scrolled, visual_changed := handle_scrollbar_mouse(&pane.surface, &pane.terminal, &pane.scrollback_state, &pane.scrollbar, mouse)
			if handled {
				if scrolled do selection.clear(&pane.selection_state)
				if scrolled || visual_changed {
					workspace_redraw(workspace, pane, true)
				}
				return true
			}
		}
		if local_mouse && mouse.action == .Press && mouse.button == 2 {
			if tab := workspace_active_tab(workspace); tab_is_tmux(tab) {
				owner := tab.tmux_owner
				if .Shift in mouse.modifiers do tmux.request_kill_pane(&owner.tmux_session, &owner.pending, pane.tmux_pane_id)
				else do tmux.request_split(&owner.tmux_session, &owner.pending, false, pane.tmux_pane_id)
			} else {
				if .Shift in mouse.modifiers do workspace_close_pane(workspace)
				else do workspace_split(workspace, .Rows)
			}
			return true
		}
		if local_mouse && mouse.action == .Press && mouse.button == 3 {
			workspace_copy_selection(workspace, pane, .Clipboard)
			return true
		}
		if local_mouse && (mouse.button == 4 || mouse.button == 5) {
			if mouse.action == .Press {
				if pane.terminal.using_alternate && pane.terminal.modes.alternate_scroll && .Shift not_in mouse.modifiers {
					encoded: [16]byte
					key := keyboard.Key.Up if mouse.button == 4 else keyboard.Key.Down
					data := keyboard.encode_key(key, {}, pane.terminal.modes.application_cursor, encoded[:])
					owner := pane_tmux_owner(pane)
					for _ in 0..<3 {
						if owner != nil && tmux.session_ready(&owner.tmux_session) {
							tmux.append_input_commands(&owner.tmux_session, &owner.pending, pane.tmux_pane_id, data)
						} else if owner == pane && !tmux.session_active(&pane.tmux_session) {
							queue_input(&pane.pending, pane.pending_offset, data)
						}
					}
					return true
				}
				direction := 1 if mouse.button == 4 else -1
				previous_offset := pane.scrollback_state.offset
				features.scrollback_scroll(&pane.scrollback_state, vt.terminal_screen(&pane.terminal), direction)
				if pane.scrollback_state.offset != previous_offset {
					selection.clear(&pane.selection_state)
					workspace.scroll_redraw_source = pane.surface.id
				}
			}
			return true
		}
		if local_mouse {
			workspace_handle_selection_mouse(workspace, pane, mouse)
			if mouse.action == .Release && workspace.settings.window.copy_on_select do workspace_copy_selection(workspace, pane, .Clipboard)
		} else {
			encoded: [32]byte
			data := keyboard.encode_mouse(mouse, pane.terminal.modes.mouse_tracking, pane.terminal.modes.mouse_sgr, encoded[:])
			owner := pane_tmux_owner(pane)
			if owner != nil && tmux.session_ready(&owner.tmux_session) do tmux.append_input_commands(&owner.tmux_session, &owner.pending, pane.tmux_pane_id, data)
			else if owner == pane && !tmux.session_active(&pane.tmux_session) do queue_input(&pane.pending, pane.pending_offset, data)
		}
	case .Paste:
		pane := workspace_active_pane(workspace)
		if pane != nil {
			if pane.osc52.active {
				vt.terminal_reply_osc52(&pane.terminal, pane.osc52.selection, x11.take_paste(workspace.root))
				pane.osc52.active = false
				process_osc52_actions(workspace.root, &pane.terminal, &pane.osc52)
			} else {
				paste: [dynamic]byte
				keyboard.encode_paste(x11.take_paste(workspace.root), pane.terminal.modes.bracketed_paste, &paste)
				vt.terminal_input(&pane.terminal, paste[:])
				owner := pane_tmux_owner(pane)
				if owner != nil && tmux.session_ready(&owner.tmux_session) do tmux.append_input_commands(&owner.tmux_session, &owner.pending, pane.tmux_pane_id, paste[:])
				else if owner == pane && !tmux.session_active(&pane.tmux_session) do queue_input(&pane.pending, pane.pending_offset, paste[:])
				delete(paste)
			}
		}
		x11.consume_paste(workspace.root)
	case .Paste_Failed:
		if pane := workspace_active_pane(workspace); pane != nil && pane.osc52.active {
			pane.osc52.active = false
			process_osc52_actions(workspace.root, &pane.terminal, &pane.osc52)
		}
	case .Focus:
		if workspace.quake != nil do quake.note_focus(workspace.quake, event.focused)
		pane := workspace_find_pane(workspace, event.source)
		if pane == nil && event.source == workspace.root.id do pane = workspace_active_pane(workspace)
		if event.focused && pane != nil {
			pane.terminal.cursor_phase_visible = true
			workspace.last_cursor_toggle = time.now()
			if pane.visible && !workspace.grid_resize_pending do workspace_redraw(workspace, pane, true)
		}
		if pane != nil && pane.terminal.modes.focus_reporting {
			sequence := "\x1b[I" if event.focused else "\x1b[O"
			owner := pane_tmux_owner(pane)
			if owner != nil && tmux.session_ready(&owner.tmux_session) do tmux.append_input_commands(&owner.tmux_session, &owner.pending, pane.tmux_pane_id, transmute([]byte)sequence)
			else if owner == pane && !tmux.session_active(&pane.tmux_session) do queue_input(&pane.pending, pane.pending_offset, transmute([]byte)sequence)
		}
	case:
	}
	return true
}

workspace_tab_bar_mouse :: proc(workspace: ^Workspace, mouse: keyboard.Mouse_Event, timestamp: u64) -> bool {
	height := workspace_tab_bar_height(workspace)
	if height <= 0 do return false
	y := 0
	if workspace.settings.tabs.edge == .Bottom do y = workspace.root.height-height
	if mouse.y < y || mouse.y >= y+height do return false
	if mouse.action != .Press do return true
	index := workspace_tab_at(workspace, mouse.x)
	if index == TAB_HIT_LEFT || index == TAB_HIT_RIGHT {
		if mouse.button == 1 {
			page := workspace_tab_page_width(workspace)
			workspace.tab_scroll_offset += -page if index == TAB_HIT_LEFT else page
			workspace.tab_scroll_offset = max(0, workspace.tab_scroll_offset)
			workspace.tab_reveal_active = false
			workspace_draw_tabs(workspace)
		}
		return true
	}
	if mouse.button == 4 || mouse.button == 5 {
		workspace_switch_tab(workspace, -1 if mouse.button == 4 else 1)
		return true
	}
	if mouse.button == 2 {
		if index >= 0 {
			tab := workspace.tabs[index]
			if tab_is_tmux(tab) && tab.tmux_owner.tmux_disconnected do workspace_remove_tmux_group(workspace, tab.tmux_owner)
			else if tab_is_tmux(tab) do tmux.request_kill_window(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.tmux_window_id)
			else do workspace_close_tab(workspace, index)
		}
		return true
	}
	if mouse.button != 1 do return true
	double_click := index == workspace.last_click_tab && timestamp >= workspace.last_tab_click_timestamp && timestamp-workspace.last_tab_click_timestamp <= 350
	workspace.last_tab_click_timestamp = timestamp
	workspace.last_click_tab = index
	if index >= 0 {
		workspace_select_tab(workspace, index)
		if double_click {
			workspace_begin_rename(workspace, index)
		}
	} else if double_click {
		_ = workspace_new_tab(workspace)
	} else {
		workspace_draw_tabs(workspace)
	}
	return true
}

workspace_tab_at :: proc(workspace: ^Workspace, x: int) -> int {
	for bound in workspace.tab_bounds {
		if x >= bound.x && x < bound.x+bound.width do return bound.tab_index
	}
	return TAB_HIT_EMPTY
}

workspace_tab_page_width :: proc(workspace: ^Workspace) -> int {
	height := workspace_tab_bar_height(workspace)
	pane := workspace_active_pane(workspace)
	if height <= 0 || pane == nil do return max(1, workspace.root.width)
	arrow_width := tab_arrow_width(pane.renderer.font, workspace.root.width, height)
	new_tab_space := tab_new_tab_space_width(pane.renderer.font, workspace.root.width)
	return max(1, workspace.root.width-arrow_width*2-new_tab_space)
}

workspace_begin_rename :: proc(workspace: ^Workspace, index: int) {
	if index < 0 || index >= len(workspace.tabs) do return
	workspace.renaming_tab = index
	workspace.tab_reveal_active = true
	clear(&workspace.rename_buffer)
	tab := workspace.tabs[index]
	title := tab.custom_title
	if tab_is_tmux(tab) do title = tab.tmux_title
	if title == "" && len(tab.panes) > 0 do title = current_window_title(&tab.panes[tab.active].terminal, workspace.title)
	append(&workspace.rename_buffer, ..transmute([]byte)title)
	x11.focus_window(workspace.root)
	workspace_draw_tabs(workspace)
}

workspace_rename_input :: proc(workspace: ^Workspace, event: x11.Event) {
	if workspace.renaming_tab < 0 || workspace.renaming_tab >= len(workspace.tabs) {
		workspace.renaming_tab = -1
		return
	}
	#partial switch event.key {
	case .Enter:
		tab := workspace.tabs[workspace.renaming_tab]
		if tab_is_tmux(tab) {
			tmux.request_rename_window(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.tmux_window_id, workspace.rename_buffer[:])
		} else {
			config.replace_string(&tab.custom_title, string(workspace.rename_buffer[:]))
		}
		workspace.renaming_tab = -1
		clear(&workspace.rename_buffer)
		workspace_layout(workspace)
	case .Escape:
		workspace.renaming_tab = -1
		clear(&workspace.rename_buffer)
		workspace_layout(workspace)
	case .Backspace:
		if len(workspace.rename_buffer) > 0 {
			new_length := len(workspace.rename_buffer)-1
			for new_length > 0 && workspace.rename_buffer[new_length]&0xc0 == 0x80 do new_length -= 1
			resize(&workspace.rename_buffer, new_length)
			workspace.tab_reveal_active = true
			workspace_draw_tabs(workspace)
		}
	case .Text:
		if event.input_size > 0 && len(workspace.rename_buffer)+event.input_size <= 256 {
			input := event.input
			append(&workspace.rename_buffer, ..input[:event.input_size])
			workspace.tab_reveal_active = true
			workspace_draw_tabs(workspace)
		}
	case:
	}
}

workspace_handle_selection_mouse :: proc(workspace: ^Workspace, pane: ^Pane, event: keyboard.Mouse_Event) {
	if event.button != 1 do return
	screen := workspace_selection_screen(pane)
	previous := pane.selection_state
	position := vt.screen_position(screen, event.row-1, event.column-1)
	switch event.action {
	case .Press: selection.begin(&pane.selection_state, screen, position, vt.screen_cell_selectable(screen, position.row, position.column))
	case .Motion: selection.update(&pane.selection_state, screen, position)
	case .Release:
		selection.finish(&pane.selection_state, screen, position)
		workspace_copy_selection(workspace, pane, .Primary)
	}
	if event.action == .Motion && pane.selection_state == previous do return
	workspace_redraw(workspace, pane, false)
}

workspace_selection_screen :: proc(pane: ^Pane) -> ^vt.Screen {
	if pane == nil do return nil
	if view := features.scrollback_view_screen(&pane.scrollback_state); view != nil do return view
	return vt.terminal_screen(&pane.terminal)
}

workspace_copy_selection :: proc(workspace: ^Workspace, pane: ^Pane, kind: x11.Selection_Kind) {
	if workspace == nil || pane == nil do return
	copy_selection(workspace.root, &pane.terminal, &pane.selection_state, kind, workspace_selection_screen(pane))
}

workspace_handle_search_input :: proc(workspace: ^Workspace, pane: ^Pane, event: x11.Event) {
	screen := vt.terminal_screen(&pane.terminal)
	#partial switch event.key {
	case .Escape:
		features.close(&pane.search_state)
		tab := workspace_active_tab(workspace)
		if tab_is_tmux(tab) && tab.tmux_title != "" {
			x11.set_title(workspace.root, tab.tmux_title)
		} else {
			x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.title))
		}
	case .Enter:
		if .Shift in event.modifiers do features.previous(&pane.search_state, screen)
		else do features.next(&pane.search_state, screen)
	case .Backspace:
		features.backspace(&pane.search_state, screen)
	case .Text:
		input := event.input
		data := input[:event.input_size]
		if len(data) > 0 && data[0] >= 0x20 && data[0] != 0x7f do features.append_query(&pane.search_state, screen, data)
	case:
	}
	workspace_redraw(workspace, pane, true)
}

workspace_scrollbar :: proc(workspace: ^Workspace, pane: ^Pane) -> drawing.Scrollbar {
	if !workspace.settings.scrollbar_enabled do return {}
	return {
		history_rows = len(vt.terminal_screen(&pane.terminal).scrollback),
		offset = pane.scrollback_state.offset,
		hovered = pane.scrollbar.hovered || pane.scrollbar.dragging,
		track_color = workspace.settings.ui_colors.inactive_tab_background,
	}
}

workspace_redraw :: proc(workspace: ^Workspace, pane: ^Pane, force: bool) {
	if workspace.grid_resize_pending do return
	scrollbar := workspace_scrollbar(workspace, pane)
	cursor_visible := pane.terminal.modes.cursor_visible
	if pane != workspace_active_pane(workspace) do pane.terminal.modes.cursor_visible = false
	defer pane.terminal.modes.cursor_visible = cursor_visible
	redraw(
		&pane.renderer,
		&pane.surface,
		&pane.terminal,
		&pane.selection_state,
		&pane.search_state,
		&pane.url_state,
		force,
		&pane.shell_state,
		&pane.scrollback_state,
		workspace.settings.scrollbar_enabled,
		&scrollbar,
	)
	if pane == workspace_active_pane(workspace) && pane.search_state.active do workspace_draw_search_bar(workspace)
}

workspace_clear_scrollbar_hover :: proc(workspace: ^Workspace, source: xlib.Window) {
	for tab in workspace.tabs {
		for pane in tab.panes {
			if pane.surface.id == source || !pane.scrollbar.hovered || pane.scrollbar.dragging do continue
			pane.scrollbar.hovered = false
			if pane.visible {
				workspace_redraw(workspace, pane, true)
			}
		}
	}
}

workspace_focus_rule_instance :: proc(workspace: ^Workspace, rule: ^config.Tab_Rule) -> bool {
	for tab, tab_index in workspace.tabs {
		for pane, pane_index in tab.panes {
			if pane.exited || pane.rule_name != rule.name do continue
			tab.active = pane_index
			workspace_select_tab(workspace, tab_index)
			return true
		}
	}
	if rule.target == .New_Window && x11.focus_rule_instance(workspace.root, rule.name) {
		workspace_clear_pending_rule_window(workspace, rule.name)
		return true
	}
	return false
}

workspace_clear_pending_rule_window :: proc(workspace: ^Workspace, name: string) {
	for index := len(workspace.pending_rule_windows)-1; index >= 0; index -= 1 {
		if workspace.pending_rule_windows[index].name != name do continue
		delete(workspace.pending_rule_windows[index].name)
		unordered_remove(&workspace.pending_rule_windows, index)
	}
}

workspace_rule_window_pending :: proc(workspace: ^Workspace, name: string) -> bool {
	for index := len(workspace.pending_rule_windows)-1; index >= 0; index -= 1 {
		pending := &workspace.pending_rule_windows[index]
		if time.since(pending.started) < 2*time.Second {
			if pending.name == name do return true
			continue
		}
		delete(pending.name)
		unordered_remove(&workspace.pending_rule_windows, index)
	}
	return false
}

workspace_rule_new_window :: proc(workspace: ^Workspace, rule: ^config.Tab_Rule, rule_command: []cstring) -> bool {
	if len(os.args) == 0 do return false
	command: [dynamic]cstring
	defer command_destroy(&command)
	append_command_argument(&command, os.args[0])
	for index := 1; index < len(os.args); index += 1 {
		argument := os.args[index]
		if argument == "-e" do break
		if argument == "--config" {
			if index+1 < len(os.args) {
				append_command_argument(&command, argument)
				index += 1
				append_command_argument(&command, os.args[index])
			}
			continue
		}
		if argument == "--no-config" || strings.has_prefix(argument, "--config=") {
			append_command_argument(&command, argument)
			continue
		}
	}
	if rule.working_directory != "" do append_command_argument(&command, fmt.tprintf("--working-directory=%s", rule.working_directory))
	if rule.title != "" do append_command_argument(&command, fmt.tprintf("--title=%s", rule.title))
	append_command_argument(&command, fmt.tprintf("--rule-instance=%s", rule.name))
	append_command_argument(&command, "-e")
	for argument in rule_command[:len(rule_command)-1] do append_command_argument(&command, string(argument))
	append(&command, nil)
	if pty.spawn_detached(command[:]) != .None do return false
	append(&workspace.pending_rule_windows, Pending_Rule_Window{name = strings.clone(rule.name), started = time.now()})
	return true
}

workspace_invoke_tab_rule :: proc(workspace: ^Workspace, rule: ^config.Tab_Rule) -> bool {
	if rule == nil do return false
	if rule.reuse == .Focus && workspace_focus_rule_instance(workspace, rule) do return true
	if rule.target == .New_Window && rule.reuse == .Focus && workspace_rule_window_pending(workspace, rule.name) do return true
	command: [dynamic]cstring
	defer command_destroy(&command)
	if !append_command_line(&command, rule.command) do return false
	append(&command, nil)
	if rule.target == .New_Window do return workspace_rule_new_window(workspace, rule, command[:])

	active_tab := workspace_active_tab(workspace)
	target := rule.target
	if tab_is_tmux(active_tab) do target = .New_Tab
	pane := workspace_new_pane_command(workspace, command[:], rule.working_directory, false)
	if pane == nil do return false
	config.replace_string(&pane.rule_name, rule.name)
	if rule.title != "" do config.replace_string(&pane.display_title, rule.title)
	launched := false
	switch target {
	case .New_Tab:
		launched = workspace_append_new_tab(workspace, pane)
	case .New_Pane_Horizontal:
		launched = workspace_insert_split_pane(workspace, pane, .Rows)
	case .New_Pane_Vertical:
		launched = workspace_insert_split_pane(workspace, pane, .Columns)
	case .New_Window:
		pane_destroy(pane)
		return false
	}
	if launched && rule.track_job do pane.tracked_job_id = workspace_register_rule_job(workspace, pane, rule)
	return launched
}

workspace_shortcut :: proc(workspace: ^Workspace, event: x11.Event) -> bool {
	tab := workspace_active_tab(workspace)
	if tab == nil do return false
	bindings := &workspace.settings.bindings
	if event_matches(event, bindings.reload_config) {
		_ = workspace_reload_config(workspace)
		return true
	}
	if event_matches(event, bindings.toggle_statusbar) {
		workspace.statusbar.visible = !workspace.statusbar.visible
		if !workspace.statusbar.visible {
			if workspace.statusbar.sample_thread != nil do _ = statusbar_harvest_sample(&workspace.statusbar)
		}
		workspace.statusbar.auto_hide_revealed = !workspace.settings.statusbar.auto_hide
		workspace.statusbar.auto_hide_pending = false
		if workspace.statusbar.visible {
			if workspace.settings.statusbar.auto_hide {
				workspace.statusbar.auto_hide_revealed = true
				workspace.statusbar.auto_hide_pending = true
				workspace.statusbar.auto_hide_left_at = time.now()
			}
			statusbar_tick(workspace, true)
		}
		workspace_layout(workspace)
		return true
	}
	if event_matches(event, bindings.show_jobs) {
		workspace_toggle_jobs_list(workspace)
		return true
	}
	for &binding in workspace.settings.tab_rule_bindings {
		if !event_matches(event, binding.chord) do continue
		rule := config.tab_rule(workspace.settings, binding.rule)
		if rule != nil && !workspace_invoke_tab_rule(workspace, rule) do x11.set_title(workspace.root, "nare - named tab launch failed")
		return true
	}
	if event_matches(event, bindings.tmux_new_tab) {
		_ = workspace_new_tmux_tab(workspace, nil, false)
		return true
	}
	if event_matches(event, bindings.tmux_attach_last) {
		_ = workspace_new_tmux_tab(workspace, nil, true)
		return true
	}
	if event_matches(event, bindings.tmux_new_window) {
		_ = workspace_new_tmux_window(workspace, nil, false)
		return true
	}
	if event_matches(event, bindings.tmux_reconnect) {
		if tab_is_tmux(tab) {
			if tab.tmux_owner.tmux_disconnected {
				tab.tmux_owner.tmux_reconnect_attempts = 0
				_ = workspace_tmux_reconnect(workspace, tab.tmux_owner)
			} else {
				tmux.request_refresh(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending)
			}
		}
		return true
	}
	for &binding in workspace.settings.tmux_profile_bindings {
		if !event_matches(event, binding.chord) do continue
		profile := config.tmux_profile(workspace.settings, binding.profile)
		if profile != nil && config.tmux_profile_target(workspace.settings, profile) == .New_Tab {
			_ = workspace_new_tmux_tab(workspace, profile, false)
		} else if profile != nil {
			_ = workspace_new_tmux_window(workspace, profile, false)
		}
		return true
	}
	if tab_is_tmux(tab) {
		pane := tab.panes[tab.active]
		owner := tab.tmux_owner
		if event_matches(event, bindings.tmux_detach) {
			if tmux.session_ready(&owner.tmux_session) {
				owner.tmux_detach_requested = true
				tmux.append_detach_command(&owner.tmux_session, &owner.pending)
			}
			return true
		}
		if event_matches(event, bindings.previous_tab) { workspace_switch_tab(workspace, -1); return true }
		if event_matches(event, bindings.next_tab) { workspace_switch_tab(workspace, 1); return true }
		if event_matches(event, bindings.new_tab) {tmux.request_new_window(&owner.tmux_session, &owner.pending); return true}
		if event_matches(event, bindings.split_horizontal) {tmux.request_split(&owner.tmux_session, &owner.pending, false, pane.tmux_pane_id); return true}
		if event_matches(event, bindings.split_vertical) {tmux.request_split(&owner.tmux_session, &owner.pending, true, pane.tmux_pane_id); return true}
		if event_matches(event, bindings.close_pane) {tmux.request_kill_pane(&owner.tmux_session, &owner.pending, pane.tmux_pane_id); return true}
		if event_matches(event, bindings.focus_left) {tmux.request_focus(&owner.tmux_session, &owner.pending, 'L', pane.tmux_pane_id); return true}
		if event_matches(event, bindings.focus_right) {tmux.request_focus(&owner.tmux_session, &owner.pending, 'R', pane.tmux_pane_id); return true}
		if event_matches(event, bindings.focus_up) {tmux.request_focus(&owner.tmux_session, &owner.pending, 'U', pane.tmux_pane_id); return true}
		if event_matches(event, bindings.focus_down) {tmux.request_focus(&owner.tmux_session, &owner.pending, 'D', pane.tmux_pane_id); return true}
		if event_matches(event, bindings.swap_pane) {tmux.request_swap_pane(&owner.tmux_session, &owner.pending, pane.tmux_pane_id); return true}
		if event_matches(event, bindings.copy) { workspace_copy_selection(workspace, tab.panes[tab.active], .Clipboard); return true }
		if event_matches(event, bindings.paste) {x11.request_selection(workspace.root, .Clipboard); return true}
		if event_matches(event, bindings.font_increase) { workspace_font_size(workspace, workspace.font_size+1); return true }
		if event_matches(event, bindings.font_decrease) { workspace_font_size(workspace, workspace.font_size-1); return true }
		if event_matches(event, bindings.font_reset) { workspace_font_size(workspace, workspace.initial_font_size); return true }
		if event_matches(event, bindings.move_tab_left) {workspace_move_tab(workspace, -1); return true}
		if event_matches(event, bindings.move_tab_right) {workspace_move_tab(workspace, 1); return true}
		if event_matches(event, bindings.toggle_stack) {x11.set_title(workspace.root, "nare - tmux stack layout is not supported"); return true}
		return false
	}
	if event_matches(event, bindings.split_horizontal) { workspace_split(workspace, .Rows); return true }
	if event_matches(event, bindings.split_vertical) { workspace_split(workspace, .Columns); return true }
	if event_matches(event, bindings.new_tab) { _ = workspace_new_tab(workspace); return true }
	if event_matches(event, bindings.close_pane) { workspace_close_pane(workspace); return true }
	if event_matches(event, bindings.previous_tab) { workspace_switch_tab(workspace, -1); return true }
	if event_matches(event, bindings.next_tab) { workspace_switch_tab(workspace, 1); return true }
	if event_matches(event, bindings.move_tab_left) { workspace_move_tab(workspace, -1); return true }
	if event_matches(event, bindings.move_tab_right) { workspace_move_tab(workspace, 1); return true }
	if event_matches(event, bindings.focus_left) || event_matches(event, bindings.focus_up) { workspace_focus_delta(workspace, -1); return true }
	if event_matches(event, bindings.focus_right) || event_matches(event, bindings.focus_down) { workspace_focus_delta(workspace, 1); return true }
	if event_matches(event, bindings.toggle_stack) { tab.stacked = !tab.stacked; workspace_layout(workspace); return true }
	if event_matches(event, bindings.swap_pane) {
		if len(tab.panes) > 1 {
			next := (tab.active+1)%len(tab.panes)
			active_leaf := split_find(tab.layout, tab.panes[tab.active])
			next_leaf := split_find(tab.layout, tab.panes[next])
			if active_leaf != nil && next_leaf != nil do active_leaf.pane, next_leaf.pane = next_leaf.pane, active_leaf.pane
			workspace_layout(workspace)
		}
		return true
	}
	if event_matches(event, bindings.copy) { workspace_copy_selection(workspace, tab.panes[tab.active], .Clipboard); return true }
	if event_matches(event, bindings.paste) { x11.request_selection(workspace.root, .Clipboard); return true }
	if event_matches(event, bindings.font_increase) { workspace_font_size(workspace, workspace.font_size+1); return true }
	if event_matches(event, bindings.font_decrease) { workspace_font_size(workspace, workspace.font_size-1); return true }
	if event_matches(event, bindings.font_reset) { workspace_font_size(workspace, workspace.initial_font_size); return true }
	if event.key != .Text || event.input_size != 1 || .Alt not_in event.modifiers do return false
	character := event.input[0]
	if character >= '1' && character <= '8' {
		index := int(character-'1')
		if index < len(workspace.tabs) do workspace_select_tab(workspace, index)
		return true
	}
	return false
}

workspace_reload_config :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil || workspace.settings == nil || workspace.settings.config_path == "" {
		fmt.eprintln("nare: configuration reload is unavailable without a configuration file")
		return false
	}
	path := strings.clone(workspace.settings.config_path)
	defer delete(path)
	fresh: config.Settings
	config.settings_init(&fresh)
	defer config.settings_destroy(&fresh)
	config.replace_string(&fresh.config_path, path)
	result := config.load(&fresh, path)
	if result.error != .None {
		if result.line > 0 do fmt.eprintf("nare: %s:%d: %s\n", path, result.line, config.error_string(result.error))
		else do fmt.eprintf("nare: %s: %s\n", path, config.error_string(result.error))
		return false
	}

	// These values describe the current launch rather than reloadable preferences.
	config.replace_string(&fresh.working_directory, workspace.settings.working_directory)
	config.replace_string(&fresh.launch_rule, workspace.settings.launch_rule)
	fresh.tmux.explicit_launch = workspace.settings.tmux.explicit_launch
	config.replace_string(&fresh.tmux.explicit_ssh_host, workspace.settings.tmux.explicit_ssh_host)

	render_changed := workspace.renderer != fresh.renderer || workspace.ligatures != fresh.ligatures ||
	                  workspace.font_size != fresh.font_size || workspace.settings.font != fresh.font ||
	                  workspace.settings.bold_font != fresh.bold_font || workspace.settings.italic_font != fresh.italic_font ||
	                  workspace.settings.bold_italic_font != fresh.bold_italic_font ||
	                  workspace.settings.cell_width_percent != fresh.cell_width_percent ||
	                  workspace.settings.cell_height_percent != fresh.cell_height_percent
	new_entry := workspace.font_entry
	if render_changed {
		new_entry = workspace_font_cache_acquire(workspace.font_cache, &fresh, fresh.font_size, workspace.root.dpi)
		if new_entry == nil {
			fmt.eprintln("nare: could not load configured fonts")
			return false
		}
	}

	old_entry := workspace.font_entry
	config.settings_destroy(workspace.settings)
	workspace.settings^ = fresh
	fresh = {}
	workspace.renderer = workspace.settings.renderer
	workspace.ligatures = workspace.settings.ligatures
	workspace.initial_font_size = workspace.settings.font_size
	workspace.font_size = workspace.settings.font_size
	config.replace_string(&workspace.title, workspace.settings.title)
	drawing.set_theme(workspace.settings.theme)
	drawing.set_bold_is_bright(workspace.settings.bold_is_bright)
	x11.set_opacity(workspace.root, workspace.settings.window.background_opacity)
	x11.set_decorations(workspace.root, workspace.settings.window.decorations)
	x11.set_surface_colors(workspace.root, workspace.settings.theme.background, workspace.settings.ui_colors.active_border, clear = false)
	if workspace.statusbar_surface.id != 0 {
		x11.set_surface_colors(
			&workspace.statusbar_surface, workspace.settings.statusbar.background,
			workspace.settings.statusbar.background, clear = false,
		)
	}
	if workspace.jobs_surface.id != 0 {
		x11.set_surface_colors(
			&workspace.jobs_surface, workspace.settings.statusbar.background,
			workspace.settings.statusbar.accent, clear = false,
		)
	}
	workspace.statusbar.visible = workspace.settings.statusbar.enabled
	workspace.statusbar.auto_hide_revealed = !workspace.settings.statusbar.auto_hide
	workspace.statusbar.auto_hide_pending = false
	workspace.statusbar.module_mask_ready = false
	if !workspace.statusbar.visible && workspace.statusbar.sample_thread != nil do _ = statusbar_harvest_sample(&workspace.statusbar)
	statusbar_render_cache_invalidate(&workspace.statusbar.render_cache)

	if render_changed {
		workspace.font_entry = new_entry
		for tab in workspace.tabs do for pane in tab.panes {
			drawing.destroy(&pane.renderer, &pane.surface)
			_ = drawing.init(
				&pane.renderer, &pane.surface, workspace.renderer, workspace.ligatures,
				workspace.settings.font, workspace.font_size,
				workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
				workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
				&workspace.font_entry.manager,
			)
		}
		workspace_font_cache_release(workspace.font_cache, old_entry)
	}
	for tab in workspace.tabs do for pane in tab.panes {
		pane.terminal.main_screen.scrollback_limit = workspace.settings.scrollback_lines
		pane.terminal.osc52_policy = workspace.settings.osc52_policy
		workspace_apply_cursor(workspace, pane)
	}
	statusbar_tick(workspace, true)
	workspace_layout(workspace)
	return true
}

event_matches :: proc(event: x11.Event, chord: string) -> bool {
	want_shift := strings.contains(chord, "shift+")
	want_alt := strings.contains(chord, "alt+")
	want_control := strings.contains(chord, "control+") || strings.contains(chord, "ctrl+")
	if (.Shift in event.modifiers) != want_shift || (.Alt in event.modifiers) != want_alt || (.Control in event.modifiers) != want_control do return false
	separator := strings.last_index_byte(chord, '+')
	key := chord
	if separator >= 0 do key = chord[separator+1:]
	switch key {
	case "enter": return event.key == .Enter
	case "left": return event.key == .Left
	case "right": return event.key == .Right
	case "up": return event.key == .Up
	case "down": return event.key == .Down
	case "equal": return event.key == .Text && event.input_size == 1 && (event.input[0] == '=' || event.input[0] == '+')
	case "minus": return event.key == .Text && event.input_size == 1 && (event.input[0] == '-' || event.input[0] == '_')
	case:
		if len(key) != 1 || event.key != .Text || event.input_size != 1 do return false
		actual := event.input[0]
		if want_control && actual >= 1 && actual <= 26 do actual = 'a'+actual-1
		if actual >= 'A' && actual <= 'Z' do actual += 'a'-'A'
		return actual == key[0]
	}
}

workspace_font_size :: proc(workspace: ^Workspace, size: int) {
	new_size := clamp(size, config.MIN_FONT_SIZE, config.MAX_FONT_SIZE)
	if new_size == workspace.font_size do return
	new_entry := workspace_font_cache_acquire(workspace.font_cache, workspace.settings, new_size, workspace.root.dpi)
	if new_entry == nil do return
	statusbar_render_cache_invalidate(&workspace.statusbar.render_cache)
	old_entry := workspace.font_entry
	workspace.font_entry = new_entry
	workspace.font_size = new_size
	for tab in workspace.tabs do for pane in tab.panes {
		drawing.destroy(&pane.renderer, &pane.surface)
		font_error := drawing.init(
			&pane.renderer, &pane.surface, workspace.renderer, workspace.ligatures,
			workspace.settings.font, new_size,
			workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
			workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
			&new_entry.manager,
		)
		if font_error != .None do continue
	}
	workspace_font_cache_release(workspace.font_cache, old_entry)
	workspace_layout(workspace)
}

workspace_refresh_dpi :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil || workspace.font_entry == nil do return false
	dpi_key := clamp(int(workspace.root.dpi+0.5), 1, 1000)
	if workspace.font_entry.dpi == dpi_key do return false
	new_entry := workspace_font_cache_acquire(workspace.font_cache, workspace.settings, workspace.font_size, workspace.root.dpi)
	if new_entry == nil do return false
	old_entry := workspace.font_entry
	workspace.font_entry = new_entry
	statusbar_render_cache_invalidate(&workspace.statusbar.render_cache)
	for tab in workspace.tabs do for pane in tab.panes {
		pane.surface.dpi = workspace.root.dpi
		drawing.destroy(&pane.renderer, &pane.surface)
		if drawing.init(
			&pane.renderer, &pane.surface, workspace.renderer, workspace.ligatures,
			workspace.settings.font, workspace.font_size,
			workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
			workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
			&new_entry.manager,
		) == .None {
			vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
		}
	}
	workspace.search_surface.dpi = workspace.root.dpi
	workspace.close_surface.dpi = workspace.root.dpi
	workspace.statusbar_surface.dpi = workspace.root.dpi
	workspace.jobs_surface.dpi = workspace.root.dpi
	workspace_font_cache_release(workspace.font_cache, old_entry)
	return true
}

workspace_apply_cursor :: proc(workspace: ^Workspace, pane: ^Pane) {
	blink := workspace.settings.cursor.blink
	switch workspace.settings.cursor.shape {
	case .Block: pane.terminal.modes.cursor_style = .Blinking_Block if blink else .Steady_Block
	case .Beam: pane.terminal.modes.cursor_style = .Blinking_Bar if blink else .Steady_Bar
	case .Underline: pane.terminal.modes.cursor_style = .Blinking_Underline if blink else .Steady_Underline
	}
	pane.terminal.cursor_phase_visible = true
	pane.terminal.cursor_beam_width = workspace.settings.cursor.beam_width
	pane.terminal.cursor_underline_height = workspace.settings.cursor.underline_height
}

workspace_switch_tab :: proc(workspace: ^Workspace, delta: int) {
	if len(workspace.tabs) == 0 do return
	workspace_select_tab(workspace, (workspace.active+delta+len(workspace.tabs))%len(workspace.tabs))
}

workspace_select_tab :: proc(workspace: ^Workspace, index: int) {
	if index < 0 || index >= len(workspace.tabs) do return
	workspace.active = index
	workspace.tab_reveal_active = true
	tab := workspace.tabs[index]
	if tab_is_tmux(tab) && tmux.session_ready(&tab.tmux_owner.tmux_session) && tab.tmux_owner.tmux_session.window_id != tab.tmux_window_id {
		tmux.request_select_window(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.tmux_window_id)
	}
	if tab_is_tmux(tab) && tab.tmux_title != "" {
		x11.set_title(workspace.root, tab.tmux_title)
	} else if len(tab.panes) > 0 {
		x11.set_title(workspace.root, current_window_title(&tab.panes[tab.active].terminal, workspace.title))
	}
	workspace_layout(workspace)
}

workspace_move_tab :: proc(workspace: ^Workspace, delta: int) {
	if len(workspace.tabs) < 2 do return
	target := clamp(workspace.active+delta, 0, len(workspace.tabs)-1)
	workspace.tabs[workspace.active], workspace.tabs[target] = workspace.tabs[target], workspace.tabs[workspace.active]
	workspace.active = target
	workspace.tab_reveal_active = true
	workspace_layout(workspace)
}

workspace_focus_delta :: proc(workspace: ^Workspace, delta: int) {
	tab := workspace_active_tab(workspace)
	if tab == nil || len(tab.panes) == 0 do return
	tab.active = (tab.active+delta+len(tab.panes))%len(tab.panes)
	tab.panes[tab.active].terminal.cursor_phase_visible = true
	workspace.last_cursor_toggle = time.now()
	if tab_is_tmux(tab) do tmux.request_select_pane(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.panes[tab.active].tmux_pane_id)
	workspace_layout(workspace)
}

workspace_focus_pane :: proc(workspace: ^Workspace, pane: ^Pane) {
	tab := workspace_active_tab(workspace)
	if tab == nil do return
	previous := tab.active
	found := false
	for candidate, index in tab.panes do if candidate == pane {tab.active = index; found = true; break}
	if !found do return
	changed := tab.active != previous
	if changed {
		pane.terminal.cursor_phase_visible = true
		workspace.last_cursor_toggle = time.now()
		if tab_is_tmux(tab) && tmux.session_ready(&tab.tmux_owner.tmux_session) {
			tmux.request_select_pane(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, pane.tmux_pane_id)
		}
	}
	x11.focus_window(workspace.root)
	if changed do workspace_layout(workspace)
}

workspace_close_pane :: proc(workspace: ^Workspace) {
	tab := workspace_active_tab(workspace)
	if tab == nil do return
	if tab_is_tmux(tab) {
		tmux.request_kill_pane(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.panes[tab.active].tmux_pane_id)
		return
	}
	closing := tab.panes[tab.active]
	tab.layout, _ = split_remove(tab.layout, closing)
	pane_destroy(closing)
	ordered_remove(&tab.panes, tab.active)
	if len(tab.panes) == 0 {
		split_destroy(tab.layout)
		delete(tab.panes); delete(tab.custom_title); delete(tab.tmux_title); free(tab)
		ordered_remove(&workspace.tabs, workspace.active)
		workspace.active = clamp(workspace.active, 0, max(0, len(workspace.tabs)-1))
	} else {
		tab.active = clamp(tab.active, 0, len(tab.panes)-1)
	}
	workspace.tab_reveal_active = true
	workspace_layout(workspace)
}

workspace_close_tab :: proc(workspace: ^Workspace, index: int) {
	if index < 0 || index >= len(workspace.tabs) do return
	if tab_is_tmux(workspace.tabs[index]) {
		tab := workspace.tabs[index]
		if tab.tmux_owner.tmux_disconnected {
			workspace_remove_tmux_group(workspace, tab.tmux_owner)
			return
		}
		tmux.request_kill_window(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.tmux_window_id)
		return
	}
	closed_active := index == workspace.active
	tab := workspace.tabs[index]
	for pane in tab.panes do pane_destroy(pane)
	split_destroy(tab.layout)
	delete(tab.panes)
	delete(tab.custom_title)
	delete(tab.tmux_title)
	free(tab)
	ordered_remove(&workspace.tabs, index)
	if workspace.renaming_tab == index do workspace.renaming_tab = -1
	else if workspace.renaming_tab > index do workspace.renaming_tab -= 1
	if workspace.active > index do workspace.active -= 1
	workspace.active = clamp(workspace.active, 0, max(0, len(workspace.tabs)-1))
	workspace.tab_reveal_active = closed_active
	if len(workspace.tabs) > 0 do workspace_layout(workspace)
}

workspace_cursor_tick :: proc(workspace: ^Workspace) {
	if !workspace.settings.cursor.blink do return
	interval := time.Duration(workspace.settings.cursor.blink_interval_ms)*time.Millisecond
	if time.since(workspace.last_cursor_toggle) < interval do return
	workspace.last_cursor_toggle = time.now()
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	style := pane.terminal.modes.cursor_style
	blinking := style == .Blinking_Block || style == .Blinking_Underline || style == .Blinking_Bar
	if !blinking do return
	pane.terminal.cursor_phase_visible = !pane.terminal.cursor_phase_visible
	workspace_redraw(workspace, pane, false)
}

workspace_session_count :: proc(workspace: ^Workspace) -> int {
	count := 0
	for tab in workspace.tabs do count += len(tab.panes)
	return count
}

workspace_record_exit :: proc(workspace: ^Workspace, pane: ^Pane) {
	if pane == nil || pane.tmux_owner != nil do return
	code := pty.exit_code(&pane.process)
	workspace.exit_status = code
	workspace.exit_status_set = true
	if pane.tracked_job_id != 0 do jobs.finish(&workspace.jobs, pane.tracked_job_id, code, pty.termination_signal(&pane.process))
}

workspace_register_rule_job :: proc(workspace: ^Workspace, pane: ^Pane, rule: ^config.Tab_Rule) -> u64 {
	if workspace == nil || pane == nil || rule == nil do return 0
	label := rule.job_name if rule.job_name != "" else rule.name
	tab := workspace_tab_for_pane(workspace, pane)
	owner := jobs.Owner{window = u64(workspace.root.id), pane = u64(pane.surface.id)}
	if tab != nil do owner.tab = tab.id
	return jobs.register(&workspace.jobs, .Nare_Launch, owner, label, rule.name, int(pane.process.child))
}

workspace_reap :: proc(workspace: ^Workspace) {
	changed := false
	for tab in workspace.tabs do for pane in tab.panes {
		if pane.tmux_owner != nil do continue
		if pane.tmux_disconnected do continue
		if !pane.exited {
			if done, _ := pty.reap(&pane.process); done {
				workspace_record_exit(workspace, pane)
				if len(pane.reconnect_command) > 0 && !pane.tmux_reconnect_disabled do workspace_tmux_disconnect(workspace, pane)
				else {pane.exited = true; pty.shutdown(&pane.process)}
			}
		}
	}
	for tab in workspace.tabs {
		if tab.tmux_owner != nil && tab.tmux_owner.exited {
			workspace_remove_tmux_group(workspace, tab.tmux_owner)
			changed = true
			break
		}
	}
	tab_index := len(workspace.tabs)-1
	for tab_index >= 0 {
		tab := workspace.tabs[tab_index]
		if tab_is_tmux(tab) {tab_index -= 1; continue}
		pane_index := len(tab.panes)-1
		for pane_index >= 0 {
			if tab.panes[pane_index].exited {
				exited := tab.panes[pane_index]
				tab.layout, _ = split_remove(tab.layout, exited)
				pty.shutdown(&exited.process)
				workspace_record_exit(workspace, exited)
				pane_destroy(exited)
				ordered_remove(&tab.panes, pane_index)
				changed = true
			}
			pane_index -= 1
		}
		if len(tab.panes) == 0 {
			split_destroy(tab.layout)
			delete(tab.panes)
			delete(tab.custom_title)
			delete(tab.tmux_title)
			free(tab)
			ordered_remove(&workspace.tabs, tab_index)
			if workspace.active > tab_index do workspace.active -= 1
			else if workspace.active == tab_index do workspace.tab_reveal_active = true
		} else {
			tab.active = clamp(tab.active, 0, len(tab.panes)-1)
		}
		tab_index -= 1
	}
	if len(workspace.tabs) > 0 {
		workspace.active = clamp(workspace.active, 0, len(workspace.tabs)-1)
		if changed do workspace_layout(workspace)
	}
}

workspace_remove_tmux_group :: proc(workspace: ^Workspace, owner: ^Pane) {
	owner_destroyed := false
	for index := len(workspace.tabs)-1; index >= 0; index -= 1 {
		tab := workspace.tabs[index]
		if tab.tmux_owner != owner do continue
		for pane in tab.panes {
			if pane == owner {
				if !owner_destroyed {pane_destroy(owner); owner_destroyed = true}
			} else {
				pane_destroy(pane)
			}
		}
		split_destroy(tab.layout)
		delete(tab.panes)
		delete(tab.custom_title)
		delete(tab.tmux_title)
		free(tab)
		ordered_remove(&workspace.tabs, index)
	}
	workspace.active = clamp(workspace.active, 0, max(0, len(workspace.tabs)-1))
}

workspace_drain :: proc(workspace: ^Workspace, pane: ^Pane) -> bool {
	buffer: [16*1024]byte
	dirty := false
	for {
		count, result := pty.read(&pane.process, buffer[:])
		switch result {
		case .Data:
			dirty = workspace_feed_pty(workspace, pane, buffer[:count]) || dirty
		case .Would_Block, .End, .Failed:
			vt.terminal_finish_resize_prompt_redraw(&pane.terminal)
			if !tmux.session_active(&pane.tmux_session) do queue_terminal_replies(&pane.pending, pane.pending_offset, &pane.terminal)
			if dirty {
				features.scrollback_refresh(&pane.scrollback_state, vt.terminal_screen(&pane.terminal))
				if pane.search_state.active do features.refresh(&pane.search_state, vt.terminal_screen(&pane.terminal))
				if pane.visible do workspace_redraw(workspace, pane, false)
				if pane.terminal.title_changed && !tmux.session_active(&pane.tmux_session) {
					pane.root_foreground = pty.foreground_is_root(&pane.process)
					if !pane.root_foreground && pane.terminal.title != "" {
						config.replace_string(&pane.display_title, pane.terminal.title)
					}
					if pane == workspace_active_pane(workspace) {
						x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.title))
					}
					workspace_draw_tabs(workspace)
				}
				pane.terminal.title_changed = false
			}
			if pane.tmux_disconnect_pending || result != .Would_Block && len(pane.reconnect_command) > 0 && !pane.tmux_reconnect_disabled {
				workspace_tmux_disconnect(workspace, pane)
				return true
			}
			return result == .Would_Block
		}
	}
}

workspace_tmux_disconnect :: proc(workspace: ^Workspace, owner: ^Pane) {
	if owner == nil || owner.tmux_disconnected do return
	pty.shutdown(&owner.process)
	tmux.session_disconnect(&owner.tmux_session)
	clear(&owner.pending)
	owner.pending_offset = 0
	owner.exited = false
	owner.tmux_disconnected = true
	owner.tmux_reconnecting = false
	owner.tmux_job_environment_published = false
	owner.tmux_disconnect_pending = false
	owner.tmux_disconnected_since = time.now()
	workspace_draw_tabs(workspace)
}

workspace_tmux_reconnect_delay :: proc(attempt: int) -> time.Duration {
	shift := clamp(attempt, 0, 4)
	return time.Duration(250*(1<<uint(shift)))*time.Millisecond
}

workspace_tmux_reconnect :: proc(workspace: ^Workspace, owner: ^Pane) -> bool {
	if owner == nil || !owner.tmux_disconnected || len(owner.reconnect_command) < 2 do return false
	columns := max(1, owner.tmux_client_columns)
	rows := max(1, owner.tmux_client_rows)
	if columns == 1 || rows == 1 do columns, rows = x11.grid_size(&owner.surface)
	environment: [4]pty.Environment_Variable
	process, err := pty.spawn(
		owner.reconnect_command[:],
		pty_size(columns, rows, owner.surface.width, owner.surface.height),
		workspace.settings.term,
		workspace.settings.working_directory,
		workspace_job_environment(workspace, owner, &environment),
	)
	owner.tmux_reconnect_attempts += 1
	owner.tmux_disconnected_since = time.now()
	if err != .None {
		workspace_draw_tabs(workspace)
		return false
	}
	owner.process = process
	owner.exited = false
	owner.tmux_disconnected = false
	owner.tmux_reconnecting = true
	owner.tmux_job_environment_published = false
	owner.tmux_disconnect_pending = false
	owner.tmux_reconnect_disabled = false
	tmux.session_reset_transport(&owner.tmux_session)
	workspace_draw_tabs(workspace)
	return true
}

workspace_tmux_reconnect_tick :: proc(workspace: ^Workspace) {
	if !workspace.settings.tmux.auto_reconnect do return
	for tab in workspace.tabs do for owner in tab.panes {
		if owner.tmux_owner != nil || !owner.tmux_disconnected || owner.tmux_reconnect_disabled ||
		   owner.tmux_reconnect_attempts >= TMUX_MAX_RECONNECT_ATTEMPTS || len(owner.reconnect_command) < 2 {
			continue
		}
		if time.since(owner.tmux_disconnected_since) < workspace_tmux_reconnect_delay(owner.tmux_reconnect_attempts) do continue
		_ = workspace_tmux_reconnect(workspace, owner)
	}
}

workspace_tmux_reconcile_tick :: proc(workspace: ^Workspace) {
	for tab in workspace.tabs do for owner in tab.panes {
		if owner.tmux_owner != nil || owner.tmux_disconnected || !tmux.session_ready(&owner.tmux_session) do continue
		if time.since(owner.last_tmux_reconcile) < TMUX_RECONCILE_INTERVAL do continue
		owner.last_tmux_reconcile = time.now()
		tmux.request_refresh(&owner.tmux_session, &owner.pending)
	}
}

workspace_tmux_mark_active_tab :: proc(workspace: ^Workspace, owner: ^Pane) {
	tab := workspace_tab_for_pane(workspace, owner)
	if tab == nil do return
	tab.tmux_owner = owner
	tab.tmux_window_id = -1
	owner.local_tab_title = tab.custom_title
	tab.custom_title = ""
}

workspace_tmux_apply_selection :: proc(workspace: ^Workspace, owner: ^Pane) -> bool {
	group_tabs := 0
	group_panes := 0
	group_active := false
	for tab, index in workspace.tabs do if tab.tmux_owner == owner {
		group_tabs += 1
		group_panes += len(tab.panes)
		if index == workspace.active do group_active = true
	}
	if group_tabs != len(owner.tmux_session.windows) || group_panes != len(owner.tmux_session.panes) do return false
	for info in owner.tmux_session.panes do if workspace_tmux_view(workspace, owner, info.id) == nil do return false
	for window in owner.tmux_session.windows {
		found := false
		for tab in workspace.tabs do if tab.tmux_owner == owner && tab.tmux_window_id == window.id {found = true; break}
		if !found do return false
	}
	for tab, index in workspace.tabs do if tab.tmux_owner == owner {
		for pane, pane_index in tab.panes {
			info := workspace_tmux_pane_info(owner, pane.tmux_pane_id)
			if info != nil && info.active do tab.active = pane_index
		}
		if group_active && tab.tmux_window_id == owner.tmux_session.window_id do workspace.active = index
	}
	workspace.tab_reveal_active = group_active
	workspace_layout(workspace)
	return true
}

workspace_tmux_reconcile :: proc(workspace: ^Workspace, owner: ^Pane) -> bool {
	if owner == nil || len(owner.tmux_session.windows) == 0 do return false
	old_panes: [dynamic]^Pane
	defer delete(old_panes)
	window_order: [dynamic]int
	defer delete(window_order)
	window_positions: [dynamic]int
	defer delete(window_positions)
	active_was_group := false
	previous_active := workspace_active_tab(workspace)
	for tab, index in workspace.tabs do if tab.tmux_owner == owner {
		if index == workspace.active do active_was_group = true
		if tab.tmux_window_id >= 0 {
			append(&window_order, tab.tmux_window_id)
			append(&window_positions, index)
		}
		for pane in tab.panes {
			found := false
			for old in old_panes do if old == pane {found = true; break}
			if !found do append(&old_panes, pane)
		}
	}
	for window in owner.tmux_session.windows {
		found := false
		for id in window_order do if id == window.id {found = true; break}
		if !found {
			append(&window_order, window.id)
			append(&window_positions, len(workspace.tabs))
		}
	}
	owner_pane_exists := false
	for info in owner.tmux_session.panes do if info.id == owner.tmux_pane_id {owner_pane_exists = true; break}
	if !owner_pane_exists {
		owner.tmux_pane_id = owner.tmux_session.pane_id
		if !owner.tmux_reconnecting {
			_ = workspace_tmux_reset_display(workspace, owner)
			tmux.request_capture(&owner.tmux_session, &owner.pending, owner.tmux_pane_id)
		}
	}
	for index := len(workspace.tabs)-1; index >= 0; index -= 1 {
		tab := workspace.tabs[index]
		if tab.tmux_owner != owner do continue
		split_destroy(tab.layout)
		delete(tab.panes)
		delete(tab.custom_title)
		delete(tab.tmux_title)
		free(tab)
		ordered_remove(&workspace.tabs, index)
	}
	used := make([]bool, len(old_panes), context.temp_allocator)
	new_tabs: [dynamic]^Tab
	defer delete(new_tabs)
	for window_id in window_order {
		window := tmux.session_find_window(&owner.tmux_session, window_id)
		if window == nil do continue
		tab := new(Tab)
		tab.id = workspace_next_tab_id(workspace)
		tab.tmux_owner = owner
		tab.tmux_window_id = window.id
		tab.axis = .Columns
		session_name := string(owner.tmux_session.title[:])
		window_name := string(window.name[:])
		tab.tmux_title = fmt.aprintf("%s:%s", session_name, window_name)
		for info in owner.tmux_session.panes {
			if info.window_id != window.id do continue
			pane: ^Pane
			created := false
			for old, old_index in old_panes do if old == owner && !used[old_index] && old.tmux_pane_id == info.id {
				pane = owner
				used[old_index] = true
				break
			}
			for old, old_index in old_panes {
				if pane != nil do break
				if !used[old_index] && old.tmux_pane_id == info.id {
					pane = old
					used[old_index] = true
					break
				}
			}
			if pane == nil {
				pane = workspace_new_tmux_view(workspace, owner, info.id)
				if pane == nil do continue
				created = true
			}
			pane.tmux_pane_id = info.id
			if created {
				tmux.request_capture(&owner.tmux_session, &owner.pending, info.id)
			} else if owner.tmux_reconnecting {
				_ = workspace_tmux_reset_display(workspace, pane)
				tmux.request_capture(&owner.tmux_session, &owner.pending, info.id)
			}
			append(&tab.panes, pane)
			if info.active do tab.active = len(tab.panes)-1
		}
		if len(tab.panes) == 0 {
			split_destroy(tab.layout)
			delete(tab.tmux_title)
			free(tab)
			continue
		}
		append(&new_tabs, tab)
	}
	for pane, index in old_panes {
		if used[index] do continue
		if pane == owner do continue
		pane_destroy(pane)
	}
	for tab, offset in new_tabs {
		position := len(workspace.tabs)
		if offset < len(window_positions) do position = window_positions[offset]
		workspace_insert_tab(workspace, position, tab)
	}
	if len(new_tabs) == 0 do return false
	if active_was_group {
		for tab, index in workspace.tabs do if tab.tmux_owner == owner && tab.tmux_window_id == owner.tmux_session.window_id {
			workspace.active = index
			break
		}
	} else if previous_active != nil {
		for tab, index in workspace.tabs do if tab == previous_active {workspace.active = index; break}
	}
	workspace.active = clamp(workspace.active, 0, len(workspace.tabs)-1)
	workspace.tab_reveal_active = active_was_group
	workspace_layout(workspace)
	return true
}

workspace_tmux_restore_tab :: proc(workspace: ^Workspace, owner: ^Pane) {
	insertion := len(workspace.tabs)
	was_active := false
	for tab, index in workspace.tabs do if tab.tmux_owner == owner {
		insertion = min(insertion, index)
		if index == workspace.active do was_active = true
	}
	for index := len(workspace.tabs)-1; index >= 0; index -= 1 {
		tab := workspace.tabs[index]
		if tab.tmux_owner != owner do continue
		for pane in tab.panes do if pane != owner do pane_destroy(pane)
		split_destroy(tab.layout)
		delete(tab.panes)
		delete(tab.custom_title)
		delete(tab.tmux_title)
		free(tab)
		ordered_remove(&workspace.tabs, index)
	}
	tab := new(Tab)
	tab.id = workspace_next_tab_id(workspace)
	tab.tmux_window_id = -1
	tab.custom_title = owner.local_tab_title
	owner.local_tab_title = ""
	owner.tmux_pane_id = -1
	append(&tab.panes, owner)
	tab.layout = split_leaf(owner)
	workspace_insert_tab(workspace, insertion, tab)
	if was_active do workspace.active = insertion
	workspace.active = clamp(workspace.active, 0, len(workspace.tabs)-1)
	workspace.tab_reveal_active = was_active
	workspace_layout(workspace)
}

workspace_feed_pty :: proc(workspace: ^Workspace, pane: ^Pane, data: []byte) -> bool {
	if !workspace.settings.tmux.enabled || (!workspace.settings.tmux.auto_detect && !pane.tmux_expected) {
		selection.clear(&pane.selection_state)
		vt.terminal_feed(&pane.terminal, data)
		process_osc52_actions(workspace.root, &pane.terminal, &pane.osc52)
		return true
	}
	events: [dynamic]tmux.Event
	defer tmux.events_destroy(&events)
	tmux.feed(&pane.tmux_session.stream, data, &events)
	dirty := false
	for &event in events {
		if event.kind == .Terminal_Data {
			selection.clear(&pane.selection_state)
			vt.terminal_feed(&pane.terminal, event.data[:])
			process_osc52_actions(workspace.root, &pane.terminal, &pane.osc52)
			dirty = true
			continue
		}
		action := tmux.session_handle(&pane.tmux_session, &event, &pane.pending)
		switch action {
		case .Activated:
			if workspace_tmux_activate(workspace, pane) {
				if !pane.tmux_reconnecting do workspace_tmux_mark_active_tab(workspace, pane)
				dirty = true
				workspace_draw_tabs(workspace)
			} else {
				pane.tmux_session.state = .Failed
			}
		case .Capabilities_Changed:
			workspace_draw_tabs(workspace)
		case .Pane_Selected:
			workspace_tmux_publish_job_environment(workspace, pane)
			config.replace_string(&pane.display_title, string(pane.tmux_session.title[:]))
			if pane.tmux_reconnecting || !workspace_tmux_apply_selection(workspace, pane) do _ = workspace_tmux_reconcile(workspace, pane)
			pane.tmux_reconnecting = false
			pane.tmux_disconnected = false
			pane.tmux_reconnect_attempts = 0
			pane.last_tmux_reconcile = time.now()
			title := string(pane.tmux_session.title[:])
			if title == "" do title = workspace.title
			x11.set_title(workspace.root, title)
			workspace_draw_tabs(workspace)
		case .Model_Changed:
			workspace_tmux_publish_job_environment(workspace, pane)
			config.replace_string(&pane.display_title, string(pane.tmux_session.title[:]))
			_ = workspace_tmux_reconcile(workspace, pane)
			pane.tmux_reconnecting = false
			pane.tmux_disconnected = false
			pane.tmux_reconnect_attempts = 0
			pane.last_tmux_reconcile = time.now()
		case .Title_Changed:
			config.replace_string(&pane.display_title, string(pane.tmux_session.title[:]))
			_ = workspace_tmux_reconcile(workspace, pane)
			x11.set_title(workspace.root, pane.display_title)
			workspace_draw_tabs(workspace)
		case .Output:
			target := workspace_tmux_view(workspace, pane, event.pane_id)
			if target != nil {
				selection.clear(&target.selection_state)
				if event.kind == .Reply_Data {
					screen := vt.terminal_screen(&target.terminal)
					screen.cursor.row = clamp(event.capture_row, 0, screen.rows-1)
					screen.cursor.column = 0
					screen.wrap_pending = false
				}
				vt.terminal_feed(&target.terminal, event.data[:])
				process_osc52_actions(workspace.root, &target.terminal, &target.osc52)
				features.scrollback_refresh(&target.scrollback_state, vt.terminal_screen(&target.terminal))
				if target.search_state.active do features.refresh(&target.search_state, vt.terminal_screen(&target.terminal))
				if target.visible && target != pane do workspace_redraw(workspace, target, false)
				dirty = target == pane || dirty
			}
		case .Capture_Complete:
			target := workspace_tmux_view(workspace, pane, event.pane_id)
			info := workspace_tmux_pane_info(pane, event.pane_id)
			if target != nil && info != nil {
				screen := vt.terminal_screen(&target.terminal)
				screen.cursor.row = clamp(info.cursor_row, 0, screen.rows-1)
				screen.cursor.column = clamp(info.cursor_column, 0, screen.columns-1)
				screen.wrap_pending = false
				if target.visible do workspace_redraw(workspace, target, true)
			}
		case .Deactivated:
			if pane.tmux_detach_requested {
				pane.tmux_detach_requested = false
				pane.tmux_reconnect_disabled = true
				workspace_tmux_deactivate(workspace, pane)
				workspace_tmux_restore_tab(workspace, pane)
				dirty = true
				workspace_draw_tabs(workspace)
			} else if len(pane.reconnect_command) > 0 {
				pane.tmux_disconnect_pending = true
			} else {
				workspace_tmux_deactivate(workspace, pane)
				workspace_tmux_restore_tab(workspace, pane)
				dirty = true
				workspace_draw_tabs(workspace)
			}
		case .Command_Error:
			x11.set_title(workspace.root, "nare - tmux command failed")
			tmux.request_refresh(&pane.tmux_session, &pane.pending)
		case .Failed:
			if len(pane.reconnect_command) > 0 {
				pane.tmux_disconnect_pending = true
			} else {
				config.replace_string(&pane.display_title, "tmux protocol error")
				workspace_draw_tabs(workspace)
			}
		case .None:
		}
	}
	return dirty
}

workspace_tmux_publish_job_environment :: proc(workspace: ^Workspace, owner: ^Pane) {
	if workspace == nil || owner == nil || owner.tmux_job_environment_published || owner.remote_host != "" ||
	   !workspace.job_reporter.enabled || !tmux.session_ready(&owner.tmux_session) {
		return
	}
	owner_id := fmt.tprintf("%d", owner.surface.id)
	window_id := fmt.tprintf("%d", workspace.root.id)
	ok := tmux.append_environment_command(&owner.tmux_session, &owner.pending, "NARE_JOB_SOCKET", workspace.job_reporter.path)
	ok = tmux.append_environment_command(&owner.tmux_session, &owner.pending, "NARE_JOB_TOKEN", workspace.job_reporter.token) && ok
	ok = tmux.append_environment_command(&owner.tmux_session, &owner.pending, "NARE_JOB_TMUX_OWNER", owner_id) && ok
	ok = tmux.append_environment_command(&owner.tmux_session, &owner.pending, "NARE_JOB_WINDOW", window_id) && ok
	owner.tmux_job_environment_published = ok
}

workspace_new_tmux_tab :: proc(workspace: ^Workspace, profile: ^config.Tmux_Profile, attach_last: bool) -> bool {
	if !workspace.settings.tmux.enabled do return false
	command: [dynamic]cstring
	defer command_destroy(&command)
	append_tmux_launch_command(&command, profile, attach_last)
	append(&command, nil)
	pane := workspace_new_pane_command(workspace, command[:], "", true)
	if pane != nil && profile != nil && profile.ssh_host != "" do config.replace_string(&pane.remote_host, profile.ssh_host)
	return workspace_append_new_tab(workspace, pane)
}

workspace_new_tmux_window :: proc(workspace: ^Workspace, profile: ^config.Tmux_Profile, attach_last: bool) -> bool {
	if !workspace.settings.tmux.enabled || len(os.args) == 0 || attach_last do return false
	command: [dynamic]cstring
	defer command_destroy(&command)
	append_command_argument(&command, os.args[0])
	for index := 1; index < len(os.args); index += 1 {
		argument := os.args[index]
		if argument == "-e" do break
		if argument == "--tmux" {
			if index+1 < len(os.args) && !strings.has_prefix(os.args[index+1], "-") do index += 1
			continue
		}
		if argument == "--tmux-profile" || argument == "--ssh" || argument == "--session" {
			index += 1
			continue
		}
		if strings.has_prefix(argument, "--tmux-profile=") || strings.has_prefix(argument, "--ssh=") ||
		   strings.has_prefix(argument, "--session=") || argument == "--new-tab" || argument == "--new-window" {
			continue
		}
		append_command_argument(&command, argument)
	}
	append_command_argument(&command, "--tmux")
	if profile != nil && profile.session != "" do append_command_argument(&command, profile.session)
	if profile != nil && profile.ssh_host != "" {
		append_command_argument(&command, "--ssh")
		append_command_argument(&command, profile.ssh_host)
	}
	append_command_argument(&command, "--new-window")
	append(&command, nil)
	return pty.spawn_detached(command[:]) == .None
}

append_tmux_launch_command :: proc(command: ^[dynamic]cstring, profile: ^config.Tmux_Profile, attach_last: bool) {
	if profile != nil && profile.ssh_host != "" {
		append_command_argument(command, "ssh")
		append_command_argument(command, "-t")
		append_command_argument(command, profile.ssh_host)
	}
	append_command_argument(command, "tmux")
	append_command_argument(command, "-CC")
	if attach_last {
		append_command_argument(command, "attach-session")
	} else {
		append_command_argument(command, "new-session")
		append_command_argument(command, "-A")
		if profile != nil && profile.session != "" {
			append_command_argument(command, "-s")
			append_command_argument(command, profile.session)
		}
	}
}

append_command_argument :: proc(command: ^[dynamic]cstring, argument: string) {
	append(command, strings.clone_to_cstring(argument))
}

workspace_tmux_activate :: proc(workspace: ^Workspace, pane: ^Pane) -> bool {
	if pane.has_local_terminal do return true
	pane.local_terminal = pane.terminal
	vt.terminal_rebind(&pane.local_terminal)
	pane.terminal = {}
	pane.has_local_terminal = true
	pane.local_display_title = pane.display_title
	pane.display_title = ""
	pane.local_root_foreground = pane.root_foreground
	pane.root_foreground = false
	columns, rows := x11.grid_size(&pane.surface)
	if !vt.terminal_init(&pane.terminal, columns, rows, workspace.settings.scrollback_lines, workspace.settings.osc52_policy, &workspace.settings.graphics_limits) {
		pane.terminal = pane.local_terminal
		vt.terminal_rebind(&pane.terminal)
		pane.local_terminal = {}
		pane.has_local_terminal = false
		pane.display_title = pane.local_display_title
		pane.local_display_title = ""
		pane.root_foreground = pane.local_root_foreground
		return false
	}
	vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
	workspace_apply_cursor(workspace, pane)
	workspace_reset_view_state(pane)
	return true
}

workspace_tmux_deactivate :: proc(workspace: ^Workspace, pane: ^Pane) {
	if !pane.has_local_terminal do return
	vt.terminal_destroy(&pane.terminal)
	pane.terminal = pane.local_terminal
	vt.terminal_rebind(&pane.terminal)
	pane.local_terminal = {}
	pane.has_local_terminal = false
	delete(pane.display_title)
	pane.display_title = pane.local_display_title
	pane.local_display_title = ""
	pane.root_foreground = pane.local_root_foreground
	workspace_reset_view_state(pane)
	x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.title))
}

workspace_tmux_reset_display :: proc(workspace: ^Workspace, pane: ^Pane) -> bool {
	columns, rows := x11.grid_size(&pane.surface)
	replacement: vt.Terminal
	if !vt.terminal_init(&replacement, columns, rows, workspace.settings.scrollback_lines, workspace.settings.osc52_policy, &workspace.settings.graphics_limits) do return false
	vt.terminal_destroy(&pane.terminal)
	pane.terminal = replacement
	vt.terminal_rebind(&pane.terminal)
	vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
	workspace_apply_cursor(workspace, pane)
	workspace_reset_view_state(pane)
	return true
}

workspace_reset_view_state :: proc(pane: ^Pane) {
	selection.clear(&pane.selection_state)
	features.destroy(&pane.search_state)
	features.url_destroy(&pane.url_state)
	features.shell_destroy(&pane.shell_state)
	features.scrollback_destroy(&pane.scrollback_state)
	pane.scrollbar = {}
	pane.osc52 = {}
}

workspace_write :: proc(pane: ^Pane) {
	if pane.pending_offset >= len(pane.pending) do return
	count, result := pty.write(&pane.process, pane.pending[pane.pending_offset:])
	if result == .Data {
		pane.pending_offset += count
		if pane.pending_offset == len(pane.pending) { clear(&pane.pending); pane.pending_offset = 0 }
	} else if result == .Failed do pane.exited = true
}
