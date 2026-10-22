package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import keyboard "input"
import pty "pty"
import vt "vt"
import x11 "x11"

MAX_PENDING_INPUT :: 256 * 1024

main :: proc() {
	os.exit(app_main())
}

app_main :: proc() -> int {
	command, command_err := command_from_args(os.args[1:])
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
	return run(&window, &process, &terminal)
}

command_from_args :: proc(args: []string) -> (command: [dynamic]cstring, err: string) {
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		return command, "usage: nare [-e COMMAND [ARG...]]"
	}
	command_args := args
	if len(args) > 0 {
		if args[0] != "-e" || len(args) == 1 {
			return command, "usage: nare [-e COMMAND [ARG...]]"
		}
		command_args = args[1:]
	}
	if len(command_args) == 0 {
		shell := os.get_env("SHELL", context.temp_allocator)
		if shell == "" do shell = "/bin/sh"
		append(&command, strings.clone_to_cstring(shell))
	} else {
		for arg in command_args do append(&command, strings.clone_to_cstring(arg))
	}
	append(&command, nil)
	return command, ""
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

run :: proc(window: ^x11.Window, process: ^pty.Process, terminal: ^vt.Terminal) -> int {
	pending: [dynamic]byte
	defer delete(pending)
	pending_offset := 0
	running := true

	for running {
		for {
			event, available := x11.next_event(window)
			if !available do break
			#partial switch event.kind {
			case .Close:
				running = false
			case .Redraw:
				x11.redraw(window)
			case .Resize:
				columns, rows := x11.grid_size(window)
				if !vt.terminal_resize(terminal, columns, rows) ||
				   pty.resize(process, pty_size(columns, rows, event.width, event.height)) != .None {
					fmt.eprintln("could not resize PTY")
					running = false
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
			if !drain_pty(process, terminal) do running = false
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

	_, reap_err := pty.reap(process, true)
	if reap_err != .None do return 1
	return pty.exit_code(process)
}

queue_input :: proc(pending: ^[dynamic]byte, offset: int, data: []byte) {
	if len(pending^) - offset + len(data) <= MAX_PENDING_INPUT do append(pending, ..data)
}

drain_pty :: proc(process: ^pty.Process, terminal: ^vt.Terminal) -> bool {
	buffer: [16 * 1024]byte
	for {
		count, result := pty.read(process, buffer[:])
		switch result {
		case .Data:
			vt.terminal_feed(terminal, buffer[:count])
			write_all_stdout(buffer[:count])
		case .Would_Block:
			return true
		case .End:
			return false
		case .Failed:
			fmt.eprintln("PTY read failed")
			return false
		}
	}
}

write_all_stdout :: proc(data: []byte) {
	for offset := 0; offset < int(len(data)); {
		written := posix.write(1, raw_data(data[offset:]), c.size_t(int(len(data))-offset))
		if written > 0 {
			offset += int(written)
			continue
		}
		if written < 0 && posix.errno() == .EINTR do continue
		return
	}
}
