package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import features "features"
import keyboard "input"
import pty "pty"
import drawing "render"
import selection "selection"
import vt "vt"
import x11 "x11"

MAX_PENDING_INPUT :: x11.MAX_SELECTION_BYTES + 64 * 1024

Options :: struct {
	renderer: drawing.Kind,
	ligatures: bool,
	font: string,
	url_opener: string,
}

main :: proc() {
	os.exit(app_main())
}

app_main :: proc() -> int {
	options, command, command_err := command_from_args(os.args[1:])
	if command_err != "" {
		fmt.eprintln(command_err)
		return 2
	}
	defer command_destroy(&command)

	window, window_err := x11.open()
	if window_err != .None {
		fmt.eprintln(x11.error_string(window_err))
		return 1
	}
	defer x11.close(&window)
	renderer: drawing.Renderer
	if render_error := drawing.init(&renderer, &window, options.renderer, options.ligatures, options.font); render_error != .None {
		fmt.eprintln(drawing.error_string(render_error))
		return 1
	}
	defer drawing.destroy(&renderer, &window)

	columns, rows := x11.grid_size(&window)
	process, process_err := pty.spawn(command[:], pty_size(columns, rows, window.width, window.height))
	if process_err != .None {
		fmt.eprintln(pty.error_string(process_err))
		return 1
	}
	defer pty.shutdown(&process)
	terminal: vt.Terminal
	if !vt.terminal_init(&terminal, columns, rows) {
		fmt.eprintln("could not initialize terminal")
		return 1
	}
	defer vt.terminal_destroy(&terminal)
	return run(&window, &process, &terminal, &renderer, options.url_opener)
}

command_from_args :: proc(args: []string) -> (options: Options, command: [dynamic]cstring, err: string) {
	options.renderer = .CPU
	options.ligatures = true
	options.font = "monospace"
	options.url_opener = "xdg-open"
	command_args: []string
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch argument {
		case "-h", "--help":
			return options, command, usage()
		case "--renderer=cpu": options.renderer = .CPU
		case "--renderer=gpu": options.renderer = .GPU
		case "--renderer=auto": options.renderer = .Auto
		case "--ligatures=true": options.ligatures = true
		case "--ligatures=false": options.ligatures = false
		case "-e":
			if index+1 >= len(args) do return options, command, usage()
			command_args = args[index+1:]
			index = len(args)
		case:
			if strings.has_prefix(argument, "--font=") && len(argument) > len("--font=") {
				options.font = argument[len("--font="):]
			} else if strings.has_prefix(argument, "--url-opener=") {
				options.url_opener = argument[len("--url-opener="):]
			} else {
				return options, command, usage()
			}
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

usage :: proc() -> string {
	return "usage: nare [--renderer=cpu|gpu|auto] [--font=FAMILY] [--ligatures=true|false] [--url-opener=COMMAND] [-e COMMAND [ARG...]]"
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
) -> int {
	pending: [dynamic]byte
	defer delete(pending)
	pending_offset := 0
	selection_state: selection.State
	search_state: features.State
	defer features.destroy(&search_state)
	url_state: features.URL_State
	defer features.url_destroy(&url_state)
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
				redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true)
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
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true)
				}
			case .Input:
				if url_shortcut(event) {
					if search_state.active do features.close(&search_state)
					selection.clear(&selection_state)
					features.url_open(&url_state, terminal)
					update_url_title(window, &url_state)
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true)
					continue
				}
				if search_shortcut(event) {
					if url_state.active do features.url_close(&url_state)
					selection.clear(&selection_state)
					features.open(&search_state, vt.terminal_screen(terminal))
					update_search_title(window, &search_state)
					redraw(renderer, window, terminal, &selection_state, &search_state, &url_state, true)
					continue
				}
				if url_state.active {
					handle_url_input(window, terminal, renderer, &selection_state, &search_state, &url_state, url_opener, event)
					continue
				}
				if search_state.active {
					handle_search_input(window, terminal, renderer, &selection_state, &search_state, &url_state, event)
					continue
				}
				if copy_shortcut(event) {
					copy_selection(window, terminal, &selection_state, .Clipboard)
					continue
				}
				if paste_shortcut(event) {
					x11.request_selection(window, .Clipboard)
					continue
				}
				if event.key == .Insert && .Shift in event.modifiers {
					x11.request_selection(window, .Primary)
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
				if search_state.active {
					features.close(&search_state)
					x11.set_title(window, "nare")
				}
				if url_state.active {
					features.url_close(&url_state)
					x11.set_title(window, "nare")
				}
				if terminal.modes.mouse_tracking == 0 || .Shift in event.mouse.modifiers {
					handle_selection_mouse(window, terminal, renderer, &selection_state, event.mouse)
				} else {
					encoded: [32]byte
					data := keyboard.encode_mouse(event.mouse, terminal.modes.mouse_tracking, terminal.modes.mouse_sgr, encoded[:])
					queue_input(&pending, pending_offset, data)
				}
			case .Paste:
				paste: [dynamic]byte
				keyboard.encode_paste(x11.take_paste(window), terminal.modes.bracketed_paste, &paste)
				queue_input(&pending, pending_offset, paste[:])
				delete(paste)
				x11.consume_paste(window)
			case:
			}
		}
		if !running do break

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
		if posix.poll(&fds[0], len(fds), -1) < 0 {
			if posix.errno() == .EINTR do continue
			fmt.eprintln("poll failed")
			return 1
		}

		if .IN in fds[1].revents || .HUP in fds[1].revents {
			if !drain_pty(window, process, terminal, renderer, &selection_state, &search_state, &url_state) do running = false
			replies := vt.terminal_take_replies(terminal)
			queue_input(&pending, pending_offset, replies)
			vt.terminal_consume_replies(terminal, len(replies))
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

handle_url_input :: proc(
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
	selection_state: ^selection.State,
	search_state: ^features.State,
	state: ^features.URL_State,
	opener: string,
	event: x11.Event,
) {
	if event.key == .Escape {
		features.url_close(state)
		x11.set_title(window, "nare")
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
	x11.set_title(window, "nare")
	redraw(renderer, window, terminal, selection_state, search_state, state, true)
}

update_url_title :: proc(window: ^x11.Window, state: ^features.URL_State) {
	title := fmt.aprintf("nare - urls: %d (key opens, Shift+key copies)", len(state.links))
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
	event: x11.Event,
) {
	screen := vt.terminal_screen(terminal)
	#partial switch event.key {
	case .Escape:
		features.close(state)
		x11.set_title(window, "nare")
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
	update_search_title(window, state)
	redraw(renderer, window, terminal, selection_state, state, url_state, true)
}

update_search_title :: proc(window: ^x11.Window, state: ^features.State) {
	if !state.active do return
	match_index := 0
	if len(state.matches) > 0 do match_index = state.current+1
	title := fmt.aprintf("nare - search: %s (%d/%d)", features.query_text(state), match_index, len(state.matches))
	defer delete(title)
	x11.set_title(window, title)
}

redraw :: proc(
	renderer: ^drawing.Renderer,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	selection_state: ^selection.State,
	search_state: ^features.State,
	url_state: ^features.URL_State,
	force: bool,
) {
	if url_state.active {
		drawing.draw(renderer, window, terminal, force, nil, features.url_view_screen(url_state))
	} else if search_state.active {
		drawing.draw(renderer, window, terminal, force, &search_state.highlight, features.view_screen(search_state))
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
) -> bool {
	buffer: [16 * 1024]byte
	dirty := false
	for {
		count, result := pty.read(process, buffer[:])
		switch result {
		case .Data:
			selection.clear(selection_state)
			vt.terminal_feed(terminal, buffer[:count])
			dirty = true
		case .Would_Block:
			if dirty {
				if search_state.active {
					features.refresh(search_state, vt.terminal_screen(terminal))
					update_search_title(window, search_state)
				}
				if url_state.active {
					features.url_refresh(url_state, terminal)
					update_url_title(window, url_state)
				}
				redraw(renderer, window, terminal, selection_state, search_state, url_state, search_state.active || url_state.active)
			}
			return true
		case .End:
			if dirty {
				if search_state.active {
					features.refresh(search_state, vt.terminal_screen(terminal))
					update_search_title(window, search_state)
				}
				if url_state.active {
					features.url_refresh(url_state, terminal)
					update_url_title(window, url_state)
				}
				redraw(renderer, window, terminal, selection_state, search_state, url_state, search_state.active || url_state.active)
			}
			return false
		case .Failed:
			if dirty {
				if search_state.active {
					features.refresh(search_state, vt.terminal_screen(terminal))
					update_search_title(window, search_state)
				}
				if url_state.active {
					features.url_refresh(url_state, terminal)
					update_url_title(window, url_state)
				}
				redraw(renderer, window, terminal, selection_state, search_state, url_state, search_state.active || url_state.active)
			}
			fmt.eprintln("PTY read failed")
			return false
		}
	}
}
