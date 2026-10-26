package pty

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

foreign import libc "system:c"
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	ptsname_r :: proc(fd: c.int, buffer: [^]byte, size: c.size_t) -> c.int ---
	tcgetpgrp :: proc(fd: c.int) -> posix.pid_t ---
}

TIOCSCTTY  :: c.ulong(0x540e)
TIOCSWINSZ :: c.ulong(0x5414)

Size :: struct { rows, columns, width, height: u16 }
Winsize :: struct { rows, columns, width, height: u16 }

Error :: enum {
	None,
	Invalid_Command,
	Open_Master,
	Grant_Master,
	Unlock_Master,
	Slave_Name,
	Fork,
	Child_Setup,
	Nonblocking,
	Resize,
	Wait,
}

Read_Result :: enum { Data, Would_Block, End, Failed }
Write_Result :: enum { Data, Would_Block, Failed }

Process :: struct {
	master:      posix.FD,
	child:       posix.pid_t,
	reaped:      bool,
	wait_status: c.int,
	closed:      bool,
}

spawn :: proc(argv: []cstring, size: Size, term: string = "xterm-256color", working_directory: string = "") -> (process: Process, err: Error) {
	process.master = -1
	if len(argv) < 2 || argv[0] == nil || argv[len(argv)-1] != nil {
		return process, .Invalid_Command
	}
	term_cstring := strings.clone_to_cstring(term)
	defer delete(term_cstring)
	working_directory_cstring := strings.clone_to_cstring(working_directory)
	defer delete(working_directory_cstring)
	master := posix.posix_openpt({.RDWR, .NOCTTY, .CLOEXEC})
	if master < 0 {
		return process, .Open_Master
	}
	process.master = master
	if posix.grantpt(master) != .OK {
		close(&process)
		return process, .Grant_Master
	}
	if posix.unlockpt(master) != .OK {
		close(&process)
		return process, .Unlock_Master
	}
	slave_name_buffer: [4096]byte
	if ptsname_r(c.int(master), &slave_name_buffer[0], len(slave_name_buffer)) != 0 {
		close(&process)
		return process, .Slave_Name
	}
	slave_name := cstring(&slave_name_buffer[0])
	exec_pipe: [2]posix.FD
	if posix.pipe(&exec_pipe) != .OK {
		close(&process)
		return process, .Fork
	}
	if posix.fcntl(exec_pipe[1], .SETFD, posix.FD_CLOEXEC) < 0 {
		_ = posix.close(exec_pipe[0])
		_ = posix.close(exec_pipe[1])
		close(&process)
		return process, .Fork
	}

	child := posix.fork()
	if child < 0 {
		_ = posix.close(exec_pipe[0])
		_ = posix.close(exec_pipe[1])
		close(&process)
		return process, .Fork
	}
	if child == 0 {
		_ = posix.close(exec_pipe[0])
		child_exec(master, slave_name, argv, size, exec_pipe[1], term_cstring, working_directory_cstring)
	}
	_ = posix.close(exec_pipe[1])
	process.child = child
	exec_status := wait_child_exec(exec_pipe[0])
	_ = posix.close(exec_pipe[0])
	if exec_status != 0 {
		shutdown(&process)
		return process, .Child_Setup
	}
	if !set_nonblocking(master) {
		shutdown(&process)
		return process, .Nonblocking
	}
	if resize(&process, size) != .None {
		shutdown(&process)
		return process, .Resize
	}
	return process, .None
}

spawn_detached :: proc(argv: []cstring) -> Error {
	if len(argv) < 2 || argv[0] == nil || argv[len(argv)-1] != nil do return .Invalid_Command
	child := posix.fork()
	if child < 0 do return .Fork
	if child == 0 {
		if posix.setsid() < 0 do posix._exit(127)
		grandchild := posix.fork()
		if grandchild < 0 do posix._exit(127)
		if grandchild > 0 do posix._exit(0)
		_ = posix.execvp(argv[0], raw_data(argv))
		posix._exit(127)
	}
	status: c.int
	for {
		result := posix.waitpid(child, &status, {})
		if result < 0 && posix.errno() == .EINTR do continue
		if result != child do return .Wait
		break
	}
	return .None if posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0 else .Child_Setup
}

child_exec :: proc(master: posix.FD, slave_name: cstring, argv: []cstring, size: Size, exec_fd: posix.FD, term, working_directory: cstring) -> ! {
	if posix.setsid() < 0 {
		child_exec_failed(exec_fd)
	}
	slave := posix.open(slave_name, {.RDWR})
	if slave < 0 {
		child_exec_failed(exec_fd)
	}
	if ioctl(c.int(slave), TIOCSCTTY, 0) != 0 || !apply_size(slave, size) ||
	   posix.dup2(slave, 0) < 0 || posix.dup2(slave, 1) < 0 || posix.dup2(slave, 2) < 0 {
		child_exec_failed(exec_fd)
	}
	if slave > 2 {
		_ = posix.close(slave)
	}
	_ = posix.close(master)
	if posix.setenv("TERM", term, true) != .OK {
		child_exec_failed(exec_fd)
	}
	if working_directory != nil && (^byte)(working_directory)^ != 0 && posix.chdir(working_directory) != .OK {
		child_exec_failed(exec_fd)
	}
	_ = posix.execvp(argv[0], raw_data(argv))
	child_exec_failed(exec_fd)
}

child_exec_failed :: proc(fd: posix.FD) -> ! {
	failed: [1]byte = {1}
	_ = posix.write(fd, &failed[0], len(failed))
	posix._exit(127)
}

wait_child_exec :: proc(fd: posix.FD) -> c.ssize_t {
	status: [1]byte
	for {
		count := posix.read(fd, &status[0], len(status))
		if count < 0 && posix.errno() == .EINTR do continue
		return count
	}
}

set_nonblocking :: proc(fd: posix.FD) -> bool {
	flags_value := posix.fcntl(fd, .GETFL)
	if flags_value < 0 {
		return false
	}
	flags := transmute(posix.O_Flags)flags_value
	flags += {.NONBLOCK}
	return posix.fcntl(fd, .SETFL, flags) >= 0
}

apply_size :: proc(fd: posix.FD, size: Size) -> bool {
	value := Winsize{size.rows, size.columns, size.width, size.height}
	return ioctl(c.int(fd), TIOCSWINSZ, rawptr(&value)) == 0
}

resize :: proc(process: ^Process, size: Size) -> Error {
	if process.master < 0 || !apply_size(process.master, size) {
		return .Resize
	}
	return .None
}

foreground_is_root :: proc(process: ^Process) -> bool {
	group, group_ok := foreground_pid(process)
	if !group_ok do return false
	path_buffer: [64]byte
	path := fmt.bprintf(path_buffer[:], "/proc/%d/status", group)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	defer delete(data)
	uid, ok := status_effective_uid(string(data))
	return ok && uid == 0
}

foreground_cwd :: proc(process: ^Process) -> (string, bool) {
	group, group_ok := foreground_pid(process)
	if !group_ok do return "", false
	path_buffer: [64]byte
	path := fmt.bprintf(path_buffer[:], "/proc/%d/cwd", group)
	cwd, err := os.read_link(path, context.allocator)
	if err != nil || len(cwd) == 0 || cwd[0] != '/' {
		delete(cwd)
		return "", false
	}
	return cwd, true
}

foreground_pid :: proc(process: ^Process) -> (int, bool) {
	if process == nil || process.master < 0 || process.closed do return 0, false
	group := tcgetpgrp(c.int(process.master))
	return int(group), group > 0
}

status_effective_uid :: proc(status: string) -> (uid: int, ok: bool) {
	for index := 0; index+4 <= len(status); index += 1 {
		if index > 0 && status[index-1] != '\n' do continue
		if status[index:index+4] != "Uid:" do continue
		cursor := index+4
		for field in 0..<2 {
			for cursor < len(status) && (status[cursor] == ' ' || status[cursor] == '\t') do cursor += 1
			if cursor >= len(status) || status[cursor] < '0' || status[cursor] > '9' do return 0, false
			value := 0
			for cursor < len(status) && status[cursor] >= '0' && status[cursor] <= '9' {
				value = value*10+int(status[cursor]-'0')
				cursor += 1
			}
			if field == 1 do return value, true
		}
	}
	return 0, false
}

read :: proc(process: ^Process, buffer: []byte) -> (count: int, result: Read_Result) {
	for {
		n := posix.read(process.master, raw_data(buffer), c.size_t(len(buffer)))
		if n > 0 do return int(n), .Data
		if n == 0 do return 0, .End
		#partial switch posix.errno() {
		case .EINTR: continue
		case .EAGAIN: return 0, .Would_Block
		case .EIO: return 0, .End
		case: return 0, .Failed
		}
	}
}

write :: proc(process: ^Process, data: []byte) -> (count: int, result: Write_Result) {
	for {
		n := posix.write(process.master, raw_data(data), c.size_t(len(data)))
		if n >= 0 do return int(n), .Data
		#partial switch posix.errno() {
		case .EINTR: continue
		case .EAGAIN: return 0, .Would_Block
		case: return 0, .Failed
		}
	}
}

reap :: proc(process: ^Process, block: bool = false) -> (done: bool, err: Error) {
	if process.reaped || process.child <= 0 {
		return process.reaped, .None
	}
	options: posix.Wait_Flags
	if !block do options += {.NOHANG}
	for {
		pid := posix.waitpid(process.child, &process.wait_status, options)
		if pid == process.child {
			process.reaped = true
			return true, .None
		}
		if pid == 0 do return false, .None
		if posix.errno() == .EINTR do continue
		if posix.errno() == .ECHILD {
			process.reaped = true
			return true, .None
		}
		return false, .Wait
	}
}

exit_code :: proc(process: ^Process) -> int {
	if !process.reaped do return -1
	if posix.WIFEXITED(process.wait_status) do return int(posix.WEXITSTATUS(process.wait_status))
	if posix.WIFSIGNALED(process.wait_status) do return 128 + int(posix.WTERMSIG(process.wait_status))
	return -1
}

termination_signal :: proc(process: ^Process) -> int {
	if process == nil || !process.reaped || !posix.WIFSIGNALED(process.wait_status) do return 0
	return int(posix.WTERMSIG(process.wait_status))
}

close :: proc(process: ^Process) {
	if process.master >= 0 && !process.closed {
		_ = posix.close(process.master)
		process.closed = true
		process.master = -1
	}
}

shutdown :: proc(process: ^Process) {
	close(process)
	if process.child <= 0 || process.reaped do return
	terminate_group(process, .SIGHUP)
	if wait_for_reap(process, 10) do return
	terminate_group(process, .SIGTERM)
	if wait_for_reap(process, 10) do return
	terminate_group(process, .SIGKILL)
	_, _ = reap(process, true)
}

terminate_group :: proc(process: ^Process, signal: posix.Signal) {
	if posix.killpg(process.child, signal) != .OK do _ = posix.kill(process.child, signal)
}

wait_for_reap :: proc(process: ^Process, attempts: int) -> bool {
	for attempt in 0..<attempts {
		done, err := reap(process)
		if done do return true
		if err != .None do return false
		if attempt+1 < attempts do time.sleep(10 * time.Millisecond)
	}
	return false
}

error_string :: proc(err: Error) -> string {
	switch err {
	case .None:            return "none"
	case .Invalid_Command: return "invalid command"
	case .Open_Master:     return "could not open PTY master"
	case .Grant_Master:    return "could not grant PTY slave"
	case .Unlock_Master:   return "could not unlock PTY slave"
	case .Slave_Name:      return "could not resolve PTY slave"
	case .Fork:            return "could not fork child"
	case .Child_Setup:     return "child PTY setup failed"
	case .Nonblocking:     return "could not make PTY nonblocking"
	case .Resize:          return "could not resize PTY"
	case .Wait:            return "could not reap child"
	}
	return "unknown PTY error"
}
