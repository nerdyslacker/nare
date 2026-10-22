package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import keyboard "input"
import pty "pty"
import drawing "render"
import vt "vt"
import x11 "x11"

MAX_PENDING_INPUT :: 256 * 1024

Options :: struct {
	renderer: drawing.Kind,
	ligatures: bool,
	font: string,
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
	defer drawing.destroy(&renderer)

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
	return run(&window, &process, &terminal, &renderer)
}

command_from_args :: proc(args: []string) -> (options: Options, command: [dynamic]cstring, err: string) {
	options.renderer = .CPU
	options.ligatures = true
	options.font = "monospace"
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
	return "usage: nare [--renderer=cpu|gpu|auto] [--font=FAMILY] [--ligatures=true|false] [-e COMMAND [ARG...]]"
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

run :: proc(window: ^x11.Window, process: ^pty.Process, terminal: ^vt.Terminal, renderer: ^drawing.Renderer) -> int {
	pending: [dynamic]byte
	defer delete(pending)
	pending_offset := 0
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
				drawing.draw(renderer, window, terminal, true)
			case .Resize:
				columns, rows := x11.grid_size(window)
				if !drawing.resize(renderer, window) ||
				   !vt.terminal_resize(terminal, columns, rows) ||
				   pty.resize(process, pty_size(columns, rows, event.width, event.height)) != .None {
					fmt.eprintln("could not resize PTY")
					running = false
				} else {
					drawing.draw(renderer, window, terminal, true)
				}
			case .Input:
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
				encoded: [32]byte
				data := keyboard.encode_mouse(event.mouse, terminal.modes.mouse_tracking, terminal.modes.mouse_sgr, encoded[:])
				queue_input(&pending, pending_offset, data)
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
			if !drain_pty(window, process, terminal, renderer) do running = false
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

queue_input :: proc(pending: ^[dynamic]byte, offset: int, data: []byte) {
	if len(pending^) - offset + len(data) <= MAX_PENDING_INPUT do append(pending, ..data)
}

drain_pty :: proc(
	window: ^x11.Window,
	process: ^pty.Process,
	terminal: ^vt.Terminal,
	renderer: ^drawing.Renderer,
) -> bool {
	buffer: [16 * 1024]byte
	dirty := false
	for {
		count, result := pty.read(process, buffer[:])
		switch result {
		case .Data:
			vt.terminal_feed(terminal, buffer[:count])
			dirty = true
		case .Would_Block:
			if dirty do drawing.draw(renderer, window, terminal)
			return true
		case .End:
			if dirty do drawing.draw(renderer, window, terminal)
			return false
		case .Failed:
			if dirty do drawing.draw(renderer, window, terminal)
			fmt.eprintln("PTY read failed")
			return false
		}
	}
}
