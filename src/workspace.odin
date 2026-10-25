package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import config "config"
import features "features"
import keyboard "input"
import pty "pty"
import drawing "render"
import selection "selection"
import tmux "tmux"
import vt "vt"
import x11 "x11"
import xlib "vendor:x11/xlib"

Pane :: struct {
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
	display_title: string,
	local_display_title: string,
	local_tab_title: string,
	local_root_foreground: bool,
}

Split_Axis :: enum { Rows, Columns }

Tab :: struct {
	panes: [dynamic]^Pane,
	active: int,
	axis: Split_Axis,
	stacked: bool,
	custom_title: string,
	tmux_owner: ^Pane,
	tmux_window_id: int,
	tmux_title: string,
}

Tab_Bounds :: struct {
	x, width: int,
	tab_index: int,
}

Workspace :: struct {
	root: ^x11.Window,
	search_surface: x11.Window,
	search_visible: bool,
	settings: ^config.Settings,
	command: []cstring,
	tabs: [dynamic]^Tab,
	active: int,
	close_armed: bool,
	initial_font_size: int,
	tab_bounds: [dynamic]Tab_Bounds,
	tab_scroll_offset: int,
	tab_reveal_active: bool,
	renaming_tab: int,
	rename_buffer: [dynamic]byte,
	last_tab_click_timestamp: u64,
	last_click_tab: int,
	last_cursor_toggle: time.Time,
	last_privilege_check: time.Time,
}

PRIVILEGE_CHECK_INTERVAL :: 250*time.Millisecond

workspace_run :: proc(root: ^x11.Window, command: []cstring, settings: ^config.Settings) -> int {
	workspace := Workspace{
		root = root, settings = settings, command = command, initial_font_size = settings.font_size,
		renaming_tab = -1, last_click_tab = -2, last_cursor_toggle = time.now(), tab_reveal_active = true,
	}
	defer workspace_destroy(&workspace)
	x11.set_surface_colors(root, settings.theme.background, settings.ui_colors.active_border)
	created := workspace_new_tab_command(&workspace, command, true) if settings.tmux.explicit_launch else workspace_new_tab(&workspace)
	if !created {
		fmt.eprintln("could not create terminal session")
		return 1
	}
	search_surface, search_ok := x11.create_child(root, 0, 0, 1, 1)
	if search_ok {
		workspace.search_surface = search_surface
		x11.show_child(&workspace.search_surface, false)
	}
	workspace_layout(&workspace)
	workspace_refresh_privileged_tabs(&workspace, true)
	x11.set_mouse_tracking(root, 0, settings.scrollbar_enabled)
	for len(workspace.tabs) > 0 {
		for tab in workspace.tabs {
			for pane in tab.panes {
				if pane.visible do x11.set_mouse_tracking(&pane.surface, pane.terminal.modes.mouse_tracking, settings.scrollbar_enabled)
			}
		}
		for {
			event, available := x11.next_event(root)
			if !available do break
			if !workspace_event(&workspace, event) do return 0
		}
		workspace_reap(&workspace)
		if len(workspace.tabs) == 0 do break
		fds: [dynamic]posix.pollfd
		owners: [dynamic]^Pane
		append(&fds, {fd = posix.FD(x11.connection_fd(root)), events = {.IN}})
		append(&owners, nil)
		for tab in workspace.tabs {
			for pane in tab.panes {
				if pane.exited || pane.tmux_owner != nil do continue
				events: posix.Poll_Event = {.IN}
				if pane.pending_offset < len(pane.pending) do events += {.OUT}
				append(&fds, {fd = pane.process.master, events = events})
				append(&owners, pane)
			}
		}
		if posix.poll(raw_data(fds), u64(len(fds)), 50) < 0 {
			delete(fds)
			delete(owners)
			if posix.errno() == .EINTR do continue
			return 1
		}
		for index in 1..<len(fds) {
			pane := owners[index]
			if .IN in fds[index].revents || .HUP in fds[index].revents {
				if !workspace_drain(&workspace, pane) do pane.exited = true
			}
			if .OUT in fds[index].revents do workspace_write(pane)
			if .ERR in fds[index].revents || .NVAL in fds[index].revents do pane.exited = true
		}
		workspace_cursor_tick(&workspace)
		workspace_refresh_privileged_tabs(&workspace, false)
		delete(fds)
		delete(owners)
	}
	return 0
}

workspace_new_pane :: proc(workspace: ^Workspace, cwd: string = "") -> ^Pane {
	return workspace_new_pane_command(workspace, workspace.command, cwd, false)
}

workspace_new_pane_command :: proc(workspace: ^Workspace, command: []cstring, cwd: string = "", tmux_expected: bool = false) -> ^Pane {
	pane := new(Pane)
	pane.tmux_pane_id = -1
	surface, ok := x11.create_child(workspace.root, 0, 0, workspace.root.width, workspace.root.height)
	if !ok { free(pane); return nil }
	pane.surface = surface
	if drawing.init(
		&pane.renderer, &pane.surface, workspace.settings.renderer, workspace.settings.ligatures,
		workspace.settings.font, workspace.settings.font_size, workspace.settings.font_bold,
		workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
		workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
	) != .None {
		x11.destroy_child(&pane.surface); free(pane); return nil
	}
	columns, rows := x11.grid_size(&pane.surface)
	directory := cwd
	if directory == "" do directory = workspace.settings.working_directory
	process, process_error := pty.spawn(command, pty_size(columns, rows, pane.surface.width, pane.surface.height), workspace.settings.term, directory)
	if process_error != .None {
		drawing.destroy(&pane.renderer, &pane.surface); x11.destroy_child(&pane.surface); free(pane); return nil
	}
	pane.process = process
	pane.tmux_expected = tmux_expected
	if !vt.terminal_init(&pane.terminal, columns, rows, workspace.settings.scrollback_lines, workspace.settings.osc52_policy, &workspace.settings.graphics_limits) {
		pty.shutdown(&pane.process); drawing.destroy(&pane.renderer, &pane.surface); x11.destroy_child(&pane.surface); free(pane); return nil
	}
	vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
	workspace_apply_cursor(workspace, pane)
	pane.visible = true
	return pane
}

workspace_new_tmux_view :: proc(workspace: ^Workspace, owner: ^Pane, pane_id: int) -> ^Pane {
	pane := new(Pane)
	pane.tmux_owner = owner
	pane.tmux_pane_id = pane_id
	surface, ok := x11.create_child(workspace.root, 0, 0, workspace.root.width, workspace.root.height)
	if !ok {free(pane); return nil}
	pane.surface = surface
	if drawing.init(
		&pane.renderer, &pane.surface, workspace.settings.renderer, workspace.settings.ligatures,
		workspace.settings.font, workspace.settings.font_size, workspace.settings.font_bold,
		workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
		workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
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
	if pane.tmux_owner == nil {
		delete(pane.local_display_title)
		delete(pane.local_tab_title)
		delete(pane.pending)
	}
	drawing.destroy(&pane.renderer, &pane.surface)
	x11.destroy_child(&pane.surface)
	free(pane)
}

workspace_destroy :: proc(workspace: ^Workspace) {
	if workspace.search_surface.id != 0 do x11.destroy_child(&workspace.search_surface)
	for tab in workspace.tabs {
		for pane in tab.panes do pane_destroy(pane)
		delete(tab.panes)
		delete(tab.custom_title)
		delete(tab.tmux_title)
		free(tab)
	}
	delete(workspace.tabs)
	delete(workspace.tab_bounds)
	delete(workspace.rename_buffer)
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
	tab.tmux_window_id = -1
	append(&tab.panes, pane)
	append(&workspace.tabs, tab)
	workspace.active = len(workspace.tabs)-1
	workspace.tab_reveal_active = true
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
	append(&tab.panes, pane)
	tab.active = len(tab.panes)-1
	tab.axis = axis
	tab.stacked = false
	workspace_layout(workspace)
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

workspace_layout :: proc(workspace: ^Workspace) {
	root := workspace.root
	x11.set_surface_colors(root, workspace.settings.theme.background, workspace.settings.ui_colors.active_border)
	tab_bar := workspace_tab_bar_height(workspace)
	padding := workspace.settings.window.padding
	content_y := padding
	if workspace.settings.tabs.edge == .Top do content_y += tab_bar
	content_height := max(1, root.height-tab_bar-padding*2)
	content_width := max(1, root.width-padding*2)
	for tab, tab_index in workspace.tabs {
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
				if tab.axis == .Rows {
					height = max(1, content_height/count)
					y += pane_index*height
					if pane_index == count-1 do height = content_y+content_height-y
				} else {
					width = max(1, content_width/count)
					x += pane_index*width
					if pane_index == count-1 do width = padding+content_width-x
				}
			}
			changed := pane.surface.width != width || pane.surface.height != height
			border := workspace.settings.ui_colors.active_border if pane_index == tab.active else workspace.settings.ui_colors.inactive_border
			x11.set_surface_colors(&pane.surface, workspace.settings.theme.background, border, 1 if count > 1 && (tab_is_tmux(tab) || !tab.stacked) else 0)
			x11.place_child(&pane.surface, x, y, width, height)
			pane.visible = true
			if changed {
				columns, rows := x11.grid_size(&pane.surface)
				_ = drawing.resize(&pane.renderer, &pane.surface)
				_ = vt.terminal_resize(&pane.terminal, columns, rows)
				if pane.search_state.active do features.refresh(&pane.search_state, vt.terminal_screen(&pane.terminal))
				if !tab_is_tmux(tab) do _ = pty.resize(&pane.process, pty_size(columns, rows, width, height))
			}
			workspace_redraw(workspace, pane, true)
		}
	}
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
	workspace_draw_tabs(workspace)
	x11.focus_window(workspace.root)
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
	if pane == nil do return workspace.settings.font_size+10
	return pane.renderer.font.cell_height+4
}

workspace_search_bar_height :: proc(workspace: ^Workspace) -> int {
	pane := workspace_active_pane(workspace)
	if pane == nil || !pane.search_state.active do return 0
	return pane.renderer.font.cell_height+6
}

workspace_draw_tabs :: proc(workspace: ^Workspace) {
	defer workspace_draw_search_bar(workspace)
	height := workspace_tab_bar_height(workspace)
	if height == 0 do return
	labels := make([]Tab_Draw_Label, len(workspace.tabs), context.temp_allocator)
	for tab, index in workspace.tabs {
		title := workspace.settings.title
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
	draw_workspace_tab_bar(workspace.root, &pane.renderer.font, labels, &workspace.tab_bounds, y, height, colors.tab_bar_background, colors.active_tab_foreground, colors.active_tab_background, colors.inactive_tab_foreground, colors.inactive_tab_background, colors.root_tab_background, workspace.settings.tmux.active_tab_color, workspace.settings.tabs.active_bold, workspace.active, &workspace.tab_scroll_offset, workspace.tab_reveal_active)
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
		&pane.renderer.font,
		label,
		y,
		height,
		workspace.settings.ui_colors.inactive_tab_background,
		workspace.settings.ui_colors.active_tab_foreground,
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
		if workspace.settings.window.confirm_close && workspace_session_count(workspace) > 1 && !workspace.close_armed {
			workspace.close_armed = true
			x11.set_title(workspace.root, "nare - close again to confirm")
			return true
		}
		return false
	case .Resize:
		workspace.tab_reveal_active = true
		workspace_layout(workspace)
	case .Redraw:
		if event.source == workspace.root.id {
			workspace_draw_tabs(workspace)
		} else if event.source == workspace.search_surface.id {
			workspace_draw_search_bar(workspace)
		} else if pane := workspace_find_pane(workspace, event.source); pane != nil && pane.visible {
			workspace_redraw(workspace, pane, true)
		}
	case .Input:
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
		if copy_shortcut(event) { copy_selection(workspace.root, &pane.terminal, &pane.selection_state, .Clipboard); return true }
		if paste_shortcut(event) { x11.request_selection(workspace.root, .Clipboard); return true }
		encoded: [16]byte
		input := event.input
		data := input[:event.input_size]
		if event.key != .Text do data = keyboard.encode_key(event.key, event.modifiers, pane.terminal.modes.application_cursor, encoded[:])
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
			copy_selection(workspace.root, &pane.terminal, &pane.selection_state, .Clipboard)
			return true
		}
		if local_mouse && (mouse.button == 4 || mouse.button == 5) {
			if mouse.action == .Press {
				direction := 1 if mouse.button == 4 else -1
				features.scrollback_scroll(&pane.scrollback_state, vt.terminal_screen(&pane.terminal), direction)
				workspace_redraw(workspace, pane, true)
			}
			return true
		}
		if local_mouse {
			workspace_handle_selection_mouse(workspace, pane, mouse)
			if mouse.action == .Release && workspace.settings.window.copy_on_select do copy_selection(workspace.root, &pane.terminal, &pane.selection_state, .Clipboard)
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
		pane := workspace_find_pane(workspace, event.source)
		if pane == nil && event.source == workspace.root.id do pane = workspace_active_pane(workspace)
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
			if tab_is_tmux(tab) do tmux.request_kill_window(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.tmux_window_id)
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
	arrow_width := tab_arrow_width(&pane.renderer.font, workspace.root.width, height)
	new_tab_space := tab_new_tab_space_width(&pane.renderer.font, workspace.root.width)
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
	if title == "" && len(tab.panes) > 0 do title = current_window_title(&tab.panes[tab.active].terminal, workspace.settings.title)
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
	screen := vt.terminal_screen(&pane.terminal)
	previous := pane.selection_state
	position := vt.screen_position(screen, event.row-1, event.column-1)
	switch event.action {
	case .Press: selection.begin(&pane.selection_state, screen, position, vt.screen_cell_selectable(screen, position.row, position.column))
	case .Motion: selection.update(&pane.selection_state, screen, position)
	case .Release:
		selection.finish(&pane.selection_state, screen, position)
		copy_selection(workspace.root, &pane.terminal, &pane.selection_state, .Primary)
	}
	if event.action == .Motion && pane.selection_state == previous do return
	workspace_redraw(workspace, pane, false)
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
			x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.settings.title))
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

workspace_shortcut :: proc(workspace: ^Workspace, event: x11.Event) -> bool {
	tab := workspace_active_tab(workspace)
	if tab == nil do return false
	bindings := &workspace.settings.bindings
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
		x11.set_title(workspace.root, "nare - tmux reconnect is not implemented")
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
			if tmux.session_ready(&owner.tmux_session) do tmux.append_detach_command(&owner.tmux_session, &owner.pending)
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
		if event_matches(event, bindings.copy) { copy_selection(workspace.root, &tab.panes[tab.active].terminal, &tab.panes[tab.active].selection_state, .Clipboard); return true }
		if event_matches(event, bindings.paste) {x11.request_selection(workspace.root, .Clipboard); return true}
		if event_matches(event, bindings.font_increase) { workspace_font_size(workspace, workspace.settings.font_size+1); return true }
		if event_matches(event, bindings.font_decrease) { workspace_font_size(workspace, workspace.settings.font_size-1); return true }
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
			tab.panes[tab.active], tab.panes[next] = tab.panes[next], tab.panes[tab.active]
			workspace_layout(workspace)
		}
		return true
	}
	if event_matches(event, bindings.copy) { copy_selection(workspace.root, &tab.panes[tab.active].terminal, &tab.panes[tab.active].selection_state, .Clipboard); return true }
	if event_matches(event, bindings.paste) { x11.request_selection(workspace.root, .Clipboard); return true }
	if event_matches(event, bindings.font_increase) { workspace_font_size(workspace, workspace.settings.font_size+1); return true }
	if event_matches(event, bindings.font_decrease) { workspace_font_size(workspace, workspace.settings.font_size-1); return true }
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
	if new_size == workspace.settings.font_size do return
	workspace.settings.font_size = new_size
	for tab in workspace.tabs do for pane in tab.panes {
		drawing.destroy(&pane.renderer, &pane.surface)
		font_error := drawing.init(
			&pane.renderer, &pane.surface, workspace.settings.renderer, workspace.settings.ligatures,
			workspace.settings.font, new_size, workspace.settings.font_bold,
			workspace.settings.bold_font, workspace.settings.italic_font, workspace.settings.bold_italic_font,
			workspace.settings.cell_width_percent, workspace.settings.cell_height_percent,
		)
		if font_error != .None do continue
	}
	workspace_layout(workspace)
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
		x11.set_title(workspace.root, current_window_title(&tab.panes[tab.active].terminal, workspace.settings.title))
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
	pane.terminal.cursor_phase_visible = true
	workspace.last_cursor_toggle = time.now()
	if tab.active != previous && tab_is_tmux(tab) && tmux.session_ready(&tab.tmux_owner.tmux_session) {
		tmux.request_select_pane(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, pane.tmux_pane_id)
	}
	x11.focus_window(workspace.root)
	workspace_layout(workspace)
}

workspace_close_pane :: proc(workspace: ^Workspace) {
	tab := workspace_active_tab(workspace)
	if tab == nil do return
	if tab_is_tmux(tab) {
		tmux.request_kill_pane(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.panes[tab.active].tmux_pane_id)
		return
	}
	pane_destroy(tab.panes[tab.active])
	ordered_remove(&tab.panes, tab.active)
	if len(tab.panes) == 0 {
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
		tmux.request_kill_window(&tab.tmux_owner.tmux_session, &tab.tmux_owner.pending, tab.tmux_window_id)
		return
	}
	closed_active := index == workspace.active
	tab := workspace.tabs[index]
	for pane in tab.panes do pane_destroy(pane)
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

workspace_reap :: proc(workspace: ^Workspace) {
	changed := false
	for tab in workspace.tabs do for pane in tab.panes {
		if pane.tmux_owner != nil do continue
		if !pane.exited {
			if done, _ := pty.reap(&pane.process); done { pane.exited = true; pty.shutdown(&pane.process) }
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
				pane_destroy(tab.panes[pane_index])
				ordered_remove(&tab.panes, pane_index)
				changed = true
			}
			pane_index -= 1
		}
		if len(tab.panes) == 0 {
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
						x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.settings.title))
					}
					workspace_draw_tabs(workspace)
				}
				pane.terminal.title_changed = false
			}
			return result == .Would_Block
		}
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
		_ = workspace_tmux_reset_display(workspace, owner)
		tmux.request_capture(&owner.tmux_session, &owner.pending, owner.tmux_pane_id)
	}
	for index := len(workspace.tabs)-1; index >= 0; index -= 1 {
		tab := workspace.tabs[index]
		if tab.tmux_owner != owner do continue
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
		tab.tmux_owner = owner
		tab.tmux_window_id = window.id
		tab.axis = .Columns
		session_name := string(owner.tmux_session.title[:])
		window_name := string(window.name[:])
		tab.tmux_title = fmt.aprintf("%s:%s", session_name, window_name)
		for info in owner.tmux_session.panes {
			if info.window_id != window.id do continue
			pane: ^Pane
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
				tmux.request_capture(&owner.tmux_session, &owner.pending, info.id)
			}
			pane.tmux_pane_id = info.id
			append(&tab.panes, pane)
			if info.active do tab.active = len(tab.panes)-1
		}
		if len(tab.panes) == 0 {
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
		delete(tab.panes)
		delete(tab.custom_title)
		delete(tab.tmux_title)
		free(tab)
		ordered_remove(&workspace.tabs, index)
	}
	tab := new(Tab)
	tab.tmux_window_id = -1
	tab.custom_title = owner.local_tab_title
	owner.local_tab_title = ""
	owner.tmux_pane_id = -1
	append(&tab.panes, owner)
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
				workspace_tmux_mark_active_tab(workspace, pane)
				dirty = true
				workspace_draw_tabs(workspace)
			} else {
				pane.tmux_session.state = .Failed
			}
		case .Pane_Selected:
			config.replace_string(&pane.display_title, string(pane.tmux_session.title[:]))
			if !workspace_tmux_apply_selection(workspace, pane) do _ = workspace_tmux_reconcile(workspace, pane)
			title := string(pane.tmux_session.title[:])
			if title == "" do title = workspace.settings.title
			x11.set_title(workspace.root, title)
			workspace_draw_tabs(workspace)
		case .Model_Changed:
			config.replace_string(&pane.display_title, string(pane.tmux_session.title[:]))
			_ = workspace_tmux_reconcile(workspace, pane)
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
			workspace_tmux_deactivate(workspace, pane)
			workspace_tmux_restore_tab(workspace, pane)
			dirty = true
			workspace_draw_tabs(workspace)
		case .Failed:
			config.replace_string(&pane.display_title, "tmux protocol error")
			workspace_draw_tabs(workspace)
		case .None:
		}
	}
	return dirty
}

workspace_new_tmux_tab :: proc(workspace: ^Workspace, profile: ^config.Tmux_Profile, attach_last: bool) -> bool {
	if !workspace.settings.tmux.enabled do return false
	command: [dynamic]cstring
	defer command_destroy(&command)
	append_tmux_launch_command(&command, profile, attach_last)
	append(&command, nil)
	return workspace_new_tab_command(workspace, command[:], true)
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
	x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.settings.title))
}

workspace_tmux_reset_display :: proc(workspace: ^Workspace, pane: ^Pane) -> bool {
	if !pane.has_local_terminal do return false
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
