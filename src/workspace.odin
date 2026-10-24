package main

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import config "config"
import features "features"
import keyboard "input"
import pty "pty"
import drawing "render"
import selection "selection"
import vt "vt"
import x11 "x11"
import xlib "vendor:x11/xlib"

Pane :: struct {
	surface: x11.Window,
	renderer: drawing.Renderer,
	process: pty.Process,
	terminal: vt.Terminal,
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
}

Split_Axis :: enum { Rows, Columns }

Tab :: struct {
	panes: [dynamic]^Pane,
	active: int,
	axis: Split_Axis,
	stacked: bool,
	custom_title: string,
}

Tab_Bounds :: struct {
	x, width: int,
	tab_index: int,
}

Workspace :: struct {
	root: ^x11.Window,
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
}

workspace_run :: proc(root: ^x11.Window, command: []cstring, settings: ^config.Settings) -> int {
	workspace := Workspace{
		root = root, settings = settings, command = command, initial_font_size = settings.font_size,
		renaming_tab = -1, last_click_tab = -2, last_cursor_toggle = time.now(), tab_reveal_active = true,
	}
	defer workspace_destroy(&workspace)
	x11.set_surface_colors(root, settings.theme.background, settings.ui_colors.active_border)
	if !workspace_new_tab(&workspace) {
		fmt.eprintln("could not create terminal session")
		return 1
	}
	workspace_layout(&workspace)
	for len(workspace.tabs) > 0 {
		if pane := workspace_active_pane(&workspace); pane != nil do x11.set_mouse_tracking(&pane.surface, pane.terminal.modes.mouse_tracking)
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
				if pane.exited do continue
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
		delete(fds)
		delete(owners)
	}
	return 0
}

workspace_new_pane :: proc(workspace: ^Workspace, cwd: string = "") -> ^Pane {
	pane := new(Pane)
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
	process, process_error := pty.spawn(workspace.command, pty_size(columns, rows, pane.surface.width, pane.surface.height), workspace.settings.term, directory)
	if process_error != .None {
		drawing.destroy(&pane.renderer, &pane.surface); x11.destroy_child(&pane.surface); free(pane); return nil
	}
	pane.process = process
	if !vt.terminal_init(&pane.terminal, columns, rows, workspace.settings.scrollback_lines, workspace.settings.osc52_policy, &workspace.settings.graphics_limits) {
		pty.shutdown(&pane.process); drawing.destroy(&pane.renderer, &pane.surface); x11.destroy_child(&pane.surface); free(pane); return nil
	}
	vt.terminal_set_cell_size(&pane.terminal, pane.surface.cell_w, pane.surface.cell_h)
	workspace_apply_cursor(workspace, pane)
	pane.visible = true
	return pane
}

pane_destroy :: proc(pane: ^Pane) {
	if pane == nil do return
	pty.shutdown(&pane.process)
	vt.terminal_destroy(&pane.terminal)
	features.destroy(&pane.search_state)
	features.url_destroy(&pane.url_state)
	features.shell_destroy(&pane.shell_state)
	features.scrollback_destroy(&pane.scrollback_state)
	delete(pane.pending)
	drawing.destroy(&pane.renderer, &pane.surface)
	x11.destroy_child(&pane.surface)
	free(pane)
}

workspace_destroy :: proc(workspace: ^Workspace) {
	for tab in workspace.tabs {
		for pane in tab.panes do pane_destroy(pane)
		delete(tab.panes)
		delete(tab.custom_title)
		free(tab)
	}
	delete(workspace.tabs)
	delete(workspace.tab_bounds)
	delete(workspace.rename_buffer)
}

workspace_new_tab :: proc(workspace: ^Workspace) -> bool {
	pane := workspace_new_pane(workspace)
	if pane == nil do return false
	tab := new(Tab)
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
		for pane, pane_index in tab.panes {
			visible := active_tab && (!tab.stacked || pane_index == tab.active)
			if !visible {
				x11.show_child(&pane.surface, false)
				pane.visible = false
				continue
			}
			x, y, width, height := padding, content_y, content_width, content_height
			if !tab.stacked && count > 1 {
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
			x11.set_surface_colors(&pane.surface, workspace.settings.theme.background, border, 1 if count > 1 && !tab.stacked else 0)
			x11.place_child(&pane.surface, x, y, width, height)
			pane.visible = true
			if changed {
				columns, rows := x11.grid_size(&pane.surface)
				_ = drawing.resize(&pane.renderer, &pane.surface)
				_ = vt.terminal_resize(&pane.terminal, columns, rows)
				_ = pty.resize(&pane.process, pty_size(columns, rows, width, height))
			}
			drawing.draw(&pane.renderer, &pane.surface, &pane.terminal, true, &pane.selection_state, nil, {history_rows = len(vt.terminal_screen(&pane.terminal).scrollback)})
		}
	}
	workspace_draw_tabs(workspace)
	if pane := workspace_active_pane(workspace); pane != nil do x11.focus_child(&pane.surface)
}

workspace_tab_bar_height :: proc(workspace: ^Workspace) -> int {
	if !workspace.settings.tabs.enabled || workspace.settings.tabs.style == .Hidden || len(workspace.tabs) < workspace.settings.tabs.minimum do return 0
	pane := workspace_active_pane(workspace)
	if pane == nil do return workspace.settings.font_size+10
	return pane.renderer.font.cell_height+4
}

workspace_draw_tabs :: proc(workspace: ^Workspace) {
	height := workspace_tab_bar_height(workspace)
	if height == 0 do return
	labels := make([]Tab_Draw_Label, len(workspace.tabs), context.temp_allocator)
	for tab, index in workspace.tabs {
		title := workspace.settings.title
		if tab.custom_title != "" do title = tab.custom_title
		else if len(tab.panes) > 0 && tab.panes[tab.active].terminal.title != "" do title = tab.panes[tab.active].terminal.title
		if workspace.renaming_tab == index do title = fmt.tprintf("Rename: %s_", string(workspace.rename_buffer[:]))
		with_index, _ := strings.replace_all(workspace.settings.tabs.title_template, "{index}", fmt.tprintf("%d", index+1), context.temp_allocator)
		label, _ := strings.replace_all(with_index, "{title}", title, context.temp_allocator)
		if index+1 < len(workspace.tabs) do label = strings.concatenate({label, workspace.settings.tabs.separator}, context.temp_allocator)
		labels[index] = {text = label, active = index == workspace.active}
	}
	y := 0
	if workspace.settings.tabs.edge == .Bottom do y = workspace.root.height-height
	colors := workspace.settings.ui_colors
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	draw_workspace_tab_bar(workspace.root, &pane.renderer.font, labels, &workspace.tab_bounds, y, height, colors.tab_bar_background, colors.active_tab_foreground, colors.active_tab_background, colors.inactive_tab_foreground, colors.inactive_tab_background, workspace.settings.tabs.active_bold, workspace.active, &workspace.tab_scroll_offset, workspace.tab_reveal_active)
	workspace.tab_reveal_active = false
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
		} else if pane := workspace_find_pane(workspace, event.source); pane != nil && pane.visible {
			drawing.draw(&pane.renderer, &pane.surface, &pane.terminal, true, &pane.selection_state, nil, {history_rows = len(vt.terminal_screen(&pane.terminal).scrollback)})
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
		if rows := scrollback_shortcut(event, vt.terminal_screen(&pane.terminal).rows); rows != 0 {
			selection.clear(&pane.selection_state)
			features.scrollback_scroll(&pane.scrollback_state, vt.terminal_screen(&pane.terminal), rows)
			redraw(&pane.renderer, &pane.surface, &pane.terminal, &pane.selection_state, &pane.search_state, &pane.url_state, true, &pane.shell_state, &pane.scrollback_state)
			return true
		}
		if copy_shortcut(event) { copy_selection(workspace.root, &pane.terminal, &pane.selection_state, .Clipboard); return true }
		if paste_shortcut(event) { x11.request_selection(workspace.root, .Clipboard); return true }
		encoded: [16]byte
		input := event.input
		data := input[:event.input_size]
		if event.key != .Text do data = keyboard.encode_key(event.key, event.modifiers, pane.terminal.modes.application_cursor, encoded[:])
		else if .Alt in event.modifiers do queue_input(&pane.pending, pane.pending_offset, {0x1b})
		queue_input(&pane.pending, pane.pending_offset, data)
	case .Mouse:
		if event.source == workspace.root.id && workspace_tab_bar_mouse(workspace, event.mouse, event.timestamp) do return true
		pane := workspace_find_pane(workspace, event.source)
		if pane == nil do return true
		workspace_focus_pane(workspace, pane)
		mouse := event.mouse
		mouse.column = max(1, mouse.x/pane.surface.cell_w+1)
		mouse.row = max(1, mouse.y/pane.surface.cell_h+1)
		local_mouse := pane.terminal.modes.mouse_tracking == 0 || .Shift in mouse.modifiers
		if local_mouse && mouse.action == .Press && mouse.button == 2 {
			if .Shift in mouse.modifiers do workspace_close_pane(workspace)
			else do workspace_split(workspace, .Rows)
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
				redraw(&pane.renderer, &pane.surface, &pane.terminal, &pane.selection_state, &pane.search_state, &pane.url_state, true, &pane.shell_state, &pane.scrollback_state)
			}
			return true
		}
		if local_mouse {
			workspace_handle_selection_mouse(workspace.root, pane, mouse)
			if mouse.action == .Release && workspace.settings.window.copy_on_select do copy_selection(workspace.root, &pane.terminal, &pane.selection_state, .Clipboard)
		} else {
			encoded: [32]byte
			data := keyboard.encode_mouse(mouse, pane.terminal.modes.mouse_tracking, pane.terminal.modes.mouse_sgr, encoded[:])
			queue_input(&pane.pending, pane.pending_offset, data)
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
				queue_input(&pane.pending, pane.pending_offset, paste[:])
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
		if pane := workspace_find_pane(workspace, event.source); pane != nil && pane.terminal.modes.focus_reporting {
			sequence := "\x1b[I" if event.focused else "\x1b[O"
			queue_input(&pane.pending, pane.pending_offset, transmute([]byte)sequence)
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
		if index >= 0 do workspace_close_tab(workspace, index)
		return true
	}
	if mouse.button != 1 do return true
	double_click := index == workspace.last_click_tab && timestamp >= workspace.last_tab_click_timestamp && timestamp-workspace.last_tab_click_timestamp <= 350
	workspace.last_tab_click_timestamp = timestamp
	workspace.last_click_tab = index
	if index >= 0 {
		workspace.active = index
		workspace.tab_reveal_active = true
		if double_click {
			workspace_begin_rename(workspace, index)
		} else {
			workspace_layout(workspace)
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
	return max(1, workspace.root.width-arrow_width*2)
}

workspace_begin_rename :: proc(workspace: ^Workspace, index: int) {
	if index < 0 || index >= len(workspace.tabs) do return
	workspace.renaming_tab = index
	workspace.tab_reveal_active = true
	clear(&workspace.rename_buffer)
	tab := workspace.tabs[index]
	title := tab.custom_title
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
		config.replace_string(&tab.custom_title, string(workspace.rename_buffer[:]))
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

workspace_handle_selection_mouse :: proc(root: ^x11.Window, pane: ^Pane, event: keyboard.Mouse_Event) {
	if event.button != 1 do return
	screen := vt.terminal_screen(&pane.terminal)
	position := vt.screen_position(screen, event.row-1, event.column-1)
	switch event.action {
	case .Press: selection.begin(&pane.selection_state, screen, position)
	case .Motion: selection.update(&pane.selection_state, screen, position)
	case .Release:
		selection.finish(&pane.selection_state, screen, position)
		copy_selection(root, &pane.terminal, &pane.selection_state, .Primary)
	}
	drawing.draw(&pane.renderer, &pane.surface, &pane.terminal, false, &pane.selection_state, nil, {history_rows = len(screen.scrollback)})
}

workspace_shortcut :: proc(workspace: ^Workspace, event: x11.Event) -> bool {
	tab := workspace_active_tab(workspace)
	if tab == nil do return false
	bindings := &workspace.settings.bindings
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
		if index < len(workspace.tabs) { workspace.active = index; workspace.tab_reveal_active = true; workspace_layout(workspace) }
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
	workspace.active = (workspace.active+delta+len(workspace.tabs))%len(workspace.tabs)
	workspace.tab_reveal_active = true
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
	workspace_layout(workspace)
}

workspace_focus_pane :: proc(workspace: ^Workspace, pane: ^Pane) {
	tab := workspace_active_tab(workspace)
	if tab == nil do return
	for candidate, index in tab.panes do if candidate == pane { tab.active = index; break }
	x11.focus_child(&pane.surface)
}

workspace_close_pane :: proc(workspace: ^Workspace) {
	tab := workspace_active_tab(workspace)
	if tab == nil do return
	pane_destroy(tab.panes[tab.active])
	ordered_remove(&tab.panes, tab.active)
	if len(tab.panes) == 0 {
		delete(tab.panes); delete(tab.custom_title); free(tab)
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
	closed_active := index == workspace.active
	tab := workspace.tabs[index]
	for pane in tab.panes do pane_destroy(pane)
	delete(tab.panes)
	delete(tab.custom_title)
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
	for tab, tab_index in workspace.tabs do for pane in tab.panes {
		style := pane.terminal.modes.cursor_style
		blinking := style == .Blinking_Block || style == .Blinking_Underline || style == .Blinking_Bar
		if !blinking do continue
		pane.terminal.cursor_phase_visible = !pane.terminal.cursor_phase_visible
		if tab_index == workspace.active && (!tab.stacked || tab.panes[tab.active] == pane) {
			drawing.draw(&pane.renderer, &pane.surface, &pane.terminal, false, &pane.selection_state, nil, {history_rows = len(vt.terminal_screen(&pane.terminal).scrollback)})
		}
	}
}

workspace_session_count :: proc(workspace: ^Workspace) -> int {
	count := 0
	for tab in workspace.tabs do count += len(tab.panes)
	return count
}

workspace_reap :: proc(workspace: ^Workspace) {
	changed := false
	for tab in workspace.tabs do for pane in tab.panes {
		if !pane.exited {
			if done, _ := pty.reap(&pane.process); done { pane.exited = true; pty.shutdown(&pane.process) }
		}
	}
	tab_index := len(workspace.tabs)-1
	for tab_index >= 0 {
		tab := workspace.tabs[tab_index]
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

workspace_drain :: proc(workspace: ^Workspace, pane: ^Pane) -> bool {
	buffer: [16*1024]byte
	dirty := false
	for {
		count, result := pty.read(&pane.process, buffer[:])
		switch result {
		case .Data:
			selection.clear(&pane.selection_state)
			vt.terminal_feed(&pane.terminal, buffer[:count])
			process_osc52_actions(workspace.root, &pane.terminal, &pane.osc52)
			dirty = true
		case .Would_Block, .End, .Failed:
			queue_terminal_replies(&pane.pending, pane.pending_offset, &pane.terminal)
			if dirty {
				features.scrollback_refresh(&pane.scrollback_state, vt.terminal_screen(&pane.terminal))
				if pane.visible do drawing.draw(&pane.renderer, &pane.surface, &pane.terminal, false, &pane.selection_state, nil, {history_rows = len(vt.terminal_screen(&pane.terminal).scrollback)})
				if pane == workspace_active_pane(workspace) && pane.terminal.title_changed {
					x11.set_title(workspace.root, current_window_title(&pane.terminal, workspace.settings.title))
					workspace_draw_tabs(workspace)
				}
				pane.terminal.title_changed = false
			}
			return result == .Would_Block
		}
	}
}

workspace_write :: proc(pane: ^Pane) {
	if pane.pending_offset >= len(pane.pending) do return
	count, result := pty.write(&pane.process, pane.pending[pane.pending_offset:])
	if result == .Data {
		pane.pending_offset += count
		if pane.pending_offset == len(pane.pending) { clear(&pane.pending); pane.pending_offset = 0 }
	} else if result == .Failed do pane.exited = true
}
