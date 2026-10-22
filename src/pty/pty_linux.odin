package pty

import "core:c"
import "core:sys/posix"

foreign import libc "system:c"
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	ptsname_r :: proc(fd: c.int, buffer: [^]byte, size: c.size_t) -> c.int ---
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

spawn :: proc(argv: []cstring, size: Size) -> (process: Process, err: Error) {
	process.master = -1
	if len(argv) < 2 || argv[0] == nil || argv[len(argv)-1] != nil {
		return process, .Invalid_Command
	}
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
	ready_pipe: [2]posix.FD
	if posix.pipe(&ready_pipe) != .OK {
		close(&process)
		return process, .Fork
	}

	child := posix.fork()
	if child < 0 {
		_ = posix.close(ready_pipe[0])
		_ = posix.close(ready_pipe[1])
		close(&process)
		return process, .Fork
	}
	if child == 0 {
		_ = posix.close(ready_pipe[0])
		child_exec(master, slave_name, argv, size, ready_pipe[1])
	}
	_ = posix.close(ready_pipe[1])
	process.child = child
	ready_count := wait_child_ready(ready_pipe[0])
	_ = posix.close(ready_pipe[0])
	if ready_count != 1 {
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

child_exec :: proc(master: posix.FD, slave_name: cstring, argv: []cstring, size: Size, ready_fd: posix.FD) -> ! {
	if posix.setsid() < 0 {
		posix._exit(127)
	}
	slave := posix.open(slave_name, {.RDWR})
	if slave < 0 {
		posix._exit(127)
	}
	if ioctl(c.int(slave), TIOCSCTTY, 0) != 0 || !apply_size(slave, size) ||
	   posix.dup2(slave, 0) < 0 || posix.dup2(slave, 1) < 0 || posix.dup2(slave, 2) < 0 {
		posix._exit(127)
	}
	if slave > 2 {
		_ = posix.close(slave)
	}
	_ = posix.close(master)
	if posix.setenv("TERM", "xterm-256color", true) != .OK {
		posix._exit(127)
	}
	ready: [1]byte = {1}
	if posix.write(ready_fd, &ready[0], len(ready)) != 1 {
		posix._exit(127)
	}
	_ = posix.close(ready_fd)
	_ = posix.execvp(argv[0], raw_data(argv))
	posix._exit(127)
}

wait_child_ready :: proc(fd: posix.FD) -> c.ssize_t {
	ready: [1]byte
	for {
		count := posix.read(fd, &ready[0], len(ready))
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

close :: proc(process: ^Process) {
	if process.master >= 0 && !process.closed {
		_ = posix.close(process.master)
		process.closed = true
		process.master = -1
	}
}

shutdown :: proc(process: ^Process) {
	close(process)
	if process.child > 0 && !process.reaped {
		_ = posix.killpg(process.child, .SIGHUP)
		_, _ = reap(process, true)
	}
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
