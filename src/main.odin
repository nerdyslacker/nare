package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import config "config"
import features "features"
import keyboard "input"
import pty "pty"
import drawing "render"
import selection "selection"
import vt "vt"
import x11 "x11"

MAX_PENDING_INPUT :: x11.MAX_SELECTION_BYTES + 64 * 1024

main :: proc() {
	os.exit(app_main())
}

app_main :: proc() -> int {
	options, command, command_err := command_from_args(os.args[1:])
	defer config.settings_destroy(&options)
	if command_err != "" {
		fmt.eprintln(command_err)
		delete(command_err)
		return 2
	}
	defer command_destroy(&command)

	title := strings.clone_to_cstring(options.title)
	defer delete(title)
	window, window_err := x11.open(title)
	if window_err != .None {
		fmt.eprintln(x11.error_string(window_err))
		return 1
	}
	defer x11.close(&window)
	renderer: drawing.Renderer
	if render_error := drawing.init(&renderer, &window, options.renderer, options.ligatures, options.font, options.font_size); render_error != .None {
		fmt.eprintln(drawing.error_string(render_error))
		return 1
	}
	defer drawing.destroy(&renderer, &window)

	columns, rows := x11.grid_size(&window)
	process, process_err := pty.spawn(command[:], pty_size(columns, rows, window.width, window.height), options.term)
	if process_err != .None {
		fmt.eprintln(pty.error_string(process_err))
		return 1
	}
	defer pty.shutdown(&process)
	terminal: vt.Terminal
	if !vt.terminal_init(&terminal, columns, rows, options.scrollback_lines, options.osc52_policy) {
		fmt.eprintln("could not initialize terminal")
		return 1
	}
	vt.terminal_set_cell_size(&terminal, window.cell_w, window.cell_h)
	defer vt.terminal_destroy(&terminal)
	return run(&window, &process, &terminal, &renderer, options.url_opener, options.shell_output_pipe, options.title)
}

command_from_args :: proc(args: []string) -> (options: config.Settings, command: [dynamic]cstring, err: string) {
	config.settings_init(&options)
	for argument in args {
		if argument == "-e" do break
		if argument == "-h" || argument == "--help" do return options, command, strings.clone(usage())
	}
	config_path, explicit_config, no_config, config_arg_ok := config_argument(args)
	if !config_arg_ok do return options, command, strings.clone(usage())
	if !no_config {
		path := strings.clone(config_path) if explicit_config else config.default_path()
		defer if path != "" do delete(path)
		if path != "" {
			result := config.load(&options, path, !explicit_config)
			if result.error != .None {
				if result.line > 0 {
					return options, command, fmt.aprintf("%s:%d: %s", path, result.line, config.error_string(result.error))
				}
				return options, command, fmt.aprintf("%s: %s", path, config.error_string(result.error))
			}
		}
	}
	command_args: []string
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch argument {
		case "-h", "--help": return options, command, strings.clone(usage())
		case "--config": index += 1
		case "--no-config":
		case "-e":
			if index+1 >= len(args) do return options, command, strings.clone(usage())
			command_args = args[index+1:]
			index = len(args)
		case:
			config_result := apply_argument(&options, argument)
			if config_result == .Unknown_Key && strings.has_prefix(argument, "--config=") do continue
			if config_result != .None do return options, command, strings.clone(usage())
		}
	}
	if len(command_args) == 0 {
		shell := os.get_env("SHELL", context.temp_allocator)
		if shell == "" do shell = "/bin/sh"
		append(&command, strings.clone_to_cstring(shell))
	} else {
		for arg in command_args do append(&command, strings.clone_to_cstring(arg))
	}
	append(&command, nil)
	return options, command, ""
}

config_argument :: proc(args: []string) -> (path: string, explicit, disabled, ok: bool) {
	ok = true
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		if argument == "-e" do break
		if argument == "--no-config" {
			disabled = true
			explicit = false
			path = ""
		} else if argument == "--config" {
			if index+1 >= len(args) || args[index+1] == "" do return "", false, false, false
			index += 1
			path = args[index]
			explicit = true
			disabled = false
		} else if strings.has_prefix(argument, "--config=") {
			path = argument[len("--config="):]
			if path == "" do return "", false, false, false
			explicit = true
			disabled = false
		}
	}
	return
}

apply_argument :: proc(options: ^config.Settings, argument: string) -> config.Error {
	if strings.has_prefix(argument, "--renderer=") {
		return config.apply(options, "main", "renderer", argument[len("--renderer="):])
	} else if strings.has_prefix(argument, "--font=") {
		return config.apply(options, "main", "font", argument[len("--font="):])
	} else if strings.has_prefix(argument, "--font-size=") {
		return config.apply(options, "main", "font-size", argument[len("--font-size="):])
	} else if strings.has_prefix(argument, "--ligatures=") {
		return config.apply(options, "main", "ligatures", argument[len("--ligatures="):])
	} else if strings.has_prefix(argument, "--title=") {
		return config.apply(options, "main", "title", argument[len("--title="):])
	} else if strings.has_prefix(argument, "--scrollback-lines=") {
		return config.apply(options, "scrollback", "lines", argument[len("--scrollback-lines="):])
	} else if strings.has_prefix(argument, "--url-opener=") {
		return config.apply(options, "url", "opener", argument[len("--url-opener="):])
	} else if strings.has_prefix(argument, "--osc52=") {
		return config.apply(options, "security", "osc52", argument[len("--osc52="):])
	} else if strings.has_prefix(argument, "--output-pipe=") {
		return config.apply(options, "shell", "output-pipe", argument[len("--output-pipe="):])
	} else if strings.has_prefix(argument, "--term=") {
		return config.apply(options, "shell", "term", argument[len("--term="):])
	}
	return .Unknown_Key
}

usage :: proc() -> string {
	return "usage: nare [--config=PATH|--no-config] [--renderer=cpu|gpu|auto] [--font=FAMILY] [--font-size=PIXELS] [--ligatures=true|false] [--title=TITLE] [--scrollback-lines=COUNT] [--url-opener=COMMAND] [--output-pipe=COMMAND] [--term=NAME] [--osc52=disabled|copy-enabled|paste-enabled|enabled] [-e COMMAND [ARG...]]"
}

OSC52_Request :: struct {
	active: bool,
	selection: vt.OSC52_Selection,
}

command_destroy :: proc(command: ^[dynamic]cstring) {
	for arg in command^ {
		if arg != nil do delete(arg)
	}
	delete(command^)
}

pty_size :: proc(columns, rows, width, height: int) -> pty.Size {
	return {
		rows = u16(clamp(rows, 1, int(max(u16)))),
		columns = u16(clamp(columns, 1, int(max(u16)))),
		width = u16(clamp(width, 1, int(max(u16)))),
		height = u16(clamp(height, 1, int(max(u16)))),
	}
}

run :: proc(
	window: ^x11.Window,
	process: ^pty.Process,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	url_opener: string,
	output_pipe: string,
	base_title: string,
) -> int {
	pending: [dynamic]byte
	defer delete(pending)
	pending_offset := 0
	selection_state: selection.State
	search_state: features.State
	defer features.destroy(&search_state)
	url_state: features.URL_State
	defer features.url_destroy(&url_state)
	shell_state: features.Shell_State
	defer features.shell_destroy(&shell_state)
	osc52_request: OSC52_Request
	running := true
	close_requested := false

	for running {
		x11.set_mouse_tracking(window, terminal.modes.mouse_tracking)
		for {
			event, available := x11.next_event(window)
			if !available do break
			#partial switch event.kind {
			case .Close:
				close_requested = true
				running = false
			case .Redraw:
				redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true, &shell_state)
			case .Resize:
				selection.clear(&selection_state)
				columns, rows := x11.grid_size(window)
				if !drawing.resize(renderer, window) ||
				   !vt.terminal_resize(terminal, columns, rows) ||
				   pty.resize(process, pty_size(columns, rows, event.width, event.height)) != .None {
					fmt.eprintln("could not resize PTY")
					running = false
				} else {
					if search_state.active do features.refresh(&search_state, vt.terminal_screen(terminal))
					if url_state.active do features.url_refresh(&url_state, terminal)
					if shell_state.active do features.shell_refresh(&shell_state, vt.terminal_screen(terminal))
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true, &shell_state)
				}
			case .Input:
				if prompt_previous_shortcut(event) || prompt_next_shortcut(event) {
					if search_state.active do features.close(&search_state)
					if url_state.active do features.url_close(&url_state)
					selection.clear(&selection_state)
					if prompt_previous_shortcut(event) {
						features.shell_previous(&shell_state, vt.terminal_screen(terminal))
					} else {
						features.shell_next(&shell_state, vt.terminal_screen(terminal))
					}
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true, &shell_state)
					continue
				}
				if url_shortcut(event) {
					if search_state.active do features.close(&search_state)
					features.shell_close(&shell_state)
					selection.clear(&selection_state)
					features.url_open(&url_state, terminal)
					update_url_title(window, terminal, base_title, &url_state)
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true, &shell_state)
					continue
				}
				if search_shortcut(event) {
					if url_state.active do features.url_close(&url_state)
					features.shell_close(&shell_state)
					selection.clear(&selection_state)
					features.open(&search_state, vt.terminal_screen(terminal))
					update_search_title(window, terminal, base_title, &search_state)
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true, &shell_state)
					continue
				}
				if url_state.active {
					handle_url_input(window, terminal, renderer, &selection_state, &search_state, &url_state, url_opener, base_title, event)
					continue
				}
				if search_state.active {
					handle_search_input(window, terminal, renderer, &selection_state, &search_state, &url_state, base_title, event)
					continue
				}
				if shell_state.active && copy_output_shortcut(event) {
					output, ok := features.shell_selected_output(&shell_state, vt.terminal_screen(terminal))
					if ok do _ = x11.own_selection(window, .Clipboard, transmute([]byte)output)
					delete(output)
					continue
				}
				if shell_state.active && pipe_output_shortcut(event) {
					output, ok := features.shell_selected_output(&shell_state, vt.terminal_screen(terminal))
					if ok && output_pipe != "" && !features.pipe_output(output_pipe, transmute([]byte)output) {
						fmt.eprintln("could not launch output pipe")
					}
					delete(output)
					continue
				}
				if shell_state.active {
					features.shell_close(&shell_state)
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true, &shell_state)
					if event.key == .Escape do continue
				}
				if copy_shortcut(event) {
					copy_selection(window, terminal, &selection_state, .Clipboard)
					continue
				}
				if paste_shortcut(event) {
					if !osc52_request.active do x11.request_selection(window, .Clipboard)
					continue
				}
				if event.key == .Insert && .Shift in event.modifiers {
					if !osc52_request.active do x11.request_selection(window, .Primary)
					continue
				}
				encoded: [16]byte
				data := event.input[:event.input_size]
				if event.key != .Text {
					data = keyboard.encode_key(event.key, event.modifiers, terminal.modes.application_cursor, encoded[:])
				} else if .Alt in event.modifiers {
					queue_input(&pending, pending_offset, {0x1b})
				}
				queue_input(&pending, pending_offset, data)
			case .Focus:
				if terminal.modes.focus_reporting {
					sequence := "\x1b[I" if event.focused else "\x1b[O"
					queue_input(&pending, pending_offset, transmute([]byte)sequence)
				}
			case .Mouse:
				mode_closed := false
				if search_state.active {
					features.close(&search_state)
					mode_closed = true
				}
				if url_state.active {
					features.url_close(&url_state)
					mode_closed = true
				}
				if shell_state.active {
					features.shell_close(&shell_state)
					mode_closed = true
				}
				if mode_closed do restore_window_title(window, terminal, base_title)
				if terminal.modes.mouse_tracking == 0 || .Shift in event.mouse.modifiers {
					handle_selection_mouse(window, terminal, renderer, &selection_state, event.mouse)
				} else {
					encoded: [32]byte
					data := keyboard.encode_mouse(event.mouse, terminal.modes.mouse_tracking, terminal.modes.mouse_sgr, encoded[:])
					queue_input(&pending, pending_offset, data)
				}
			case .Paste:
				if osc52_request.active {
					vt.terminal_reply_osc52(terminal, osc52_request.selection, x11.take_paste(window))
					osc52_request.active = false
					process_osc52_actions(window, terminal, &osc52_request)
				} else {
					paste: [dynamic]byte
					keyboard.encode_paste(x11.take_paste(window), terminal.modes.bracketed_paste, &paste)
					queue_input(&pending, pending_offset, paste[:])
					delete(paste)
				}
				x11.consume_paste(window)
			case .Paste_Failed:
				if osc52_request.active {
					osc52_request.active = false
					process_osc52_actions(window, terminal, &osc52_request)
				}
			case:
			}
		}
		if !running do break
		queue_terminal_replies(&pending, pending_offset, terminal)

		if done, reap_err := pty.reap(process); reap_err != .None {
			fmt.eprintln(pty.error_string(reap_err))
			return 1
		} else if done {
			break
		}

		pty_events: posix.Poll_Event = {.IN}
		if pending_offset < len(pending) do pty_events += {.OUT}
		fds := [2]posix.pollfd{
			{fd = posix.FD(x11.connection_fd(window)), events = {.IN}},
			{fd = process.master, events = pty_events},
		}
		_ = vt.terminal_expire_kitty_transfer(terminal)
		poll_timeout := vt.terminal_kitty_timeout_ms(terminal)
		if posix.poll(&fds[0], len(fds), i32(poll_timeout)) < 0 {
			if posix.errno() == .EINTR do continue
			fmt.eprintln("poll failed")
			return 1
		}
		_ = vt.terminal_expire_kitty_transfer(terminal)

		if .IN in fds[1].revents || .HUP in fds[1].revents {
			if !drain_pty(window, process, terminal, renderer, &selection_state, &search_state, &url_state, &shell_state, &osc52_request, base_title) do running = false
			queue_terminal_replies(&pending, pending_offset, terminal)
		}
		if .OUT in fds[1].revents && pending_offset < len(pending) {
			count, result := pty.write(process, pending[pending_offset:])
			switch result {
			case .Data:
				pending_offset += count
				if pending_offset == len(pending) {
					clear(&pending)
					pending_offset = 0
				}
			case .Failed:
				fmt.eprintln("PTY write failed")
				running = false
			case .Would_Block:
			}
		}
		if .ERR in fds[1].revents || .NVAL in fds[1].revents do running = false
	}

	pty.shutdown(process)
	if close_requested do return 0
	return pty.exit_code(process)
}

search_shortcut :: proc(event: x11.Event) -> bool {
	if event.key != .Text || .Control not_in event.modifiers || .Shift not_in event.modifiers do return false
	return event.input_size == 1 && (event.input[0] == 0x06 || event.input[0] == 'f' || event.input[0] == 'F')
}

url_shortcut :: proc(event: x11.Event) -> bool {
	if event.key != .Text || .Control not_in event.modifiers || .Shift not_in event.modifiers do return false
	return event.input_size == 1 && (event.input[0] == 0x15 || event.input[0] == 'u' || event.input[0] == 'U')
}

prompt_previous_shortcut :: proc(event: x11.Event) -> bool {
	return event.key == .Up && .Control in event.modifiers && .Shift in event.modifiers
}

prompt_next_shortcut :: proc(event: x11.Event) -> bool {
	return event.key == .Down && .Control in event.modifiers && .Shift in event.modifiers
}

copy_output_shortcut :: proc(event: x11.Event) -> bool {
	if event.key != .Text || .Control not_in event.modifiers || .Shift not_in event.modifiers do return false
	return event.input_size == 1 && (event.input[0] == 0x0f || event.input[0] == 'o' || event.input[0] == 'O')
}

pipe_output_shortcut :: proc(event: x11.Event) -> bool {
	if event.key != .Text || .Control not_in event.modifiers || .Shift not_in event.modifiers do return false
	return event.input_size == 1 && (event.input[0] == 0x10 || event.input[0] == 'p' || event.input[0] == 'P')
}

handle_url_input :: proc(
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	selection_state: ^selection.State,
	search_state: ^features.State,
	state: ^features.URL_State,
	opener: string,
	base_title: string,
	event: x11.Event,
) {
	if event.key == .Escape {
		features.url_close(state)
		restore_window_title(window, terminal, base_title)
		redraw(renderer, window, terminal, selection_state, search_state, state, true)
		return
	}
	if event.key != .Text || event.input_size != 1 do return
	url := features.url_for_hint(state, event.input[0])
	if url == "" do return
	if .Shift in event.modifiers {
		_ = x11.own_selection(window, .Clipboard, transmute([]byte)url)
	} else if !features.open_url(opener, url) {
		fmt.eprintln("could not launch URL opener")
	}
	features.url_close(state)
	restore_window_title(window, terminal, base_title)
	redraw(renderer, window, terminal, selection_state, search_state, state, true)
}

update_url_title :: proc(window: ^x11.Window, terminal: ^vt.Terminal, base_title: string, state: ^features.URL_State) {
	title := fmt.aprintf("%s - urls: %d (key opens, Shift+key copies)", current_window_title(terminal, base_title), len(state.links))
	defer delete(title)
	x11.set_title(window, title)
}

handle_search_input :: proc(
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	selection_state: ^selection.State,
	state: ^features.State,
	url_state: ^features.URL_State,
	base_title: string,
	event: x11.Event,
) {
	screen := vt.terminal_screen(terminal)
	#partial switch event.key {
	case .Escape:
		features.close(state)
		restore_window_title(window, terminal, base_title)
	case .Enter:
		if .Shift in event.modifiers {
			features.previous(state, screen)
		} else {
			features.next(state, screen)
		}
	case .Backspace:
		features.backspace(state, screen)
	case .Text:
		input := event.input
		data := input[:event.input_size]
		if len(data) > 0 && (data[0] >= 0x20 && data[0] != 0x7f) do features.append_query(state, screen, data)
	case:
	}
	update_search_title(window, terminal, base_title, state)
	redraw(renderer, window, terminal, selection_state, state, url_state, true)
}

update_search_title :: proc(window: ^x11.Window, terminal: ^vt.Terminal, base_title: string, state: ^features.State) {
	if !state.active do return
	match_index := 0
	if len(state.matches) > 0 do match_index = state.current+1
	title := fmt.aprintf("%s - search: %s (%d/%d)", current_window_title(terminal, base_title), features.query_text(state), match_index, len(state.matches))
	defer delete(title)
	x11.set_title(window, title)
}

current_window_title :: proc(terminal: ^vt.Terminal, base_title: string) -> string {
	return terminal.title if terminal.title != "" else base_title
}

restore_window_title :: proc(window: ^x11.Window, terminal: ^vt.Terminal, base_title: string) {
	x11.set_title(window, current_window_title(terminal, base_title))
}

redraw :: proc(
	renderer: ^drawing.Renderer,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	selection_state: ^selection.State,
	search_state: ^features.State,
	url_state: ^features.URL_State,
	force: bool,
	shell_state: ^features.Shell_State = nil,
) {
	if url_state.active {
		drawing.draw(renderer, window, terminal, force, nil, features.url_view_screen(url_state))
	} else if search_state.active {
		drawing.draw(renderer, window, terminal, force, &search_state.highlight, features.view_screen(search_state))
	} else if shell_state != nil && shell_state.active {
		drawing.draw(renderer, window, terminal, force, nil, features.shell_view_screen(shell_state))
	} else {
		drawing.draw(renderer, window, terminal, force, selection_state)
	}
}

copy_shortcut :: proc(event: x11.Event) -> bool {
	if event.key != .Text || .Control not_in event.modifiers || .Shift not_in event.modifiers do return false
	return event.input_size == 1 && (event.input[0] == 0x03 || event.input[0] == 'c' || event.input[0] == 'C')
}

paste_shortcut :: proc(event: x11.Event) -> bool {
	if event.key != .Text || .Control not_in event.modifiers || .Shift not_in event.modifiers do return false
	return event.input_size == 1 && (event.input[0] == 0x16 || event.input[0] == 'v' || event.input[0] == 'V')
}

copy_selection :: proc(window: ^x11.Window, terminal: ^vt.Terminal, state: ^selection.State, kind: x11.Selection_Kind) {
	text := selection.text(state, vt.terminal_screen(terminal))
	defer delete(text)
	if text != "" do _ = x11.own_selection(window, kind, transmute([]byte)text)
}

handle_selection_mouse :: proc(
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	state: ^selection.State,
	event: keyboard.Mouse_Event,
) {
	if event.action == .Press && event.button == 2 {
		x11.request_selection(window, .Primary)
		return
	}
	if event.button != 1 do return
	screen := vt.terminal_screen(terminal)
	position := vt.screen_position(screen, event.row-1, event.column-1)
	switch event.action {
	case .Press:
		selection.begin(state, screen, position)
	case .Motion:
		selection.update(state, screen, position)
	case .Release:
		selection.finish(state, screen, position)
		copy_selection(window, terminal, state, .Primary)
	}
	drawing.draw(renderer, window, terminal, true, state)
}

queue_input :: proc(pending: ^[dynamic]byte, offset: int, data: []byte) {
	if len(pending^) - offset + len(data) <= MAX_PENDING_INPUT do append(pending, ..data)
}

drain_pty :: proc(
	window: ^x11.Window,
	process: ^pty.Process,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	selection_state: ^selection.State,
	search_state: ^features.State,
	url_state: ^features.URL_State,
	shell_state: ^features.Shell_State,
	osc52_request: ^OSC52_Request,
	base_title: string,
) -> bool {
	buffer: [16 * 1024]byte
	dirty := false
	for {
		count, result := pty.read(process, buffer[:])
		switch result {
		case .Data:
			selection.clear(selection_state)
			vt.terminal_feed(terminal, buffer[:count])
			process_osc52_actions(window, terminal, osc52_request)
			dirty = true
		case .Would_Block:
			if dirty {
				refresh_after_pty(window, terminal, renderer, selection_state, search_state, url_state, shell_state, base_title)
			}
			return true
		case .End:
			if dirty {
				refresh_after_pty(window, terminal, renderer, selection_state, search_state, url_state, shell_state, base_title)
			}
			return false
		case .Failed:
			if dirty {
				refresh_after_pty(window, terminal, renderer, selection_state, search_state, url_state, shell_state, base_title)
			}
			fmt.eprintln("PTY read failed")
			return false
		}
	}
}

process_osc52_actions :: proc(window: ^x11.Window, terminal: ^vt.Terminal, request: ^OSC52_Request) {
	for {
		action, ok := vt.terminal_osc52_action(terminal)
		if !ok do return
		selection_kind := x11.Selection_Kind.Clipboard
		if action.selection == .Primary do selection_kind = .Primary
		switch action.kind {
		case .Write:
			_ = x11.own_selection(window, selection_kind, action.data)
			vt.terminal_consume_osc52_action(terminal)
		case .Read:
			if request.active do return
			request.active = true
			request.selection = action.selection
			x11.request_selection(window, selection_kind)
			vt.terminal_consume_osc52_action(terminal)
		}
	}
}

queue_terminal_replies :: proc(pending: ^[dynamic]byte, pending_offset: int, terminal: ^vt.Terminal) {
	replies := vt.terminal_take_replies(terminal)
	queue_input(pending, pending_offset, replies)
	vt.terminal_consume_replies(terminal, len(replies))
}

refresh_after_pty :: proc(
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	selection_state: ^selection.State,
	search_state: ^features.State,
	url_state: ^features.URL_State,
	shell_state: ^features.Shell_State,
	base_title: string,
) {
	if search_state.active {
		features.refresh(search_state, vt.terminal_screen(terminal))
		update_search_title(window, terminal, base_title, search_state)
	} else if url_state.active {
		features.url_refresh(url_state, terminal)
		update_url_title(window, terminal, base_title, url_state)
	} else if terminal.title_changed {
		restore_window_title(window, terminal, base_title)
	}
	if shell_state.active do features.shell_refresh(shell_state, vt.terminal_screen(terminal))
	terminal.title_changed = false
	redraw(renderer, window, terminal, selection_state, search_state, url_state, search_state.active || url_state.active || shell_state.active, shell_state)
}
