package features

import "core:c"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

pipe_output :: proc(command: string, data: []byte) -> bool {
	if command == "" do return false
	command_arg := strings.clone_to_cstring(command)
	defer delete(command_arg)
	child := posix.fork()
	if child < 0 do return false
	if child == 0 {
		fds: [2]posix.FD
		if posix.pipe(&fds) != .OK do posix._exit(127)
		worker := posix.fork()
		if worker < 0 do posix._exit(127)
		if worker > 0 {
			_ = posix.close(fds[0])
			_ = posix.close(fds[1])
			posix._exit(0)
		}
		_ = posix.setsid()
		consumer := posix.fork()
		if consumer < 0 do posix._exit(127)
		if consumer == 0 {
			_ = posix.close(fds[1])
			if posix.dup2(fds[0], posix.STDIN_FILENO) < 0 do posix._exit(127)
			_ = posix.close(fds[0])
			if linux.close_range(3, linux.Fd(max(i32)), {}) != .NONE {
				for fd := 3; fd < 1024; fd += 1 do _ = posix.close(posix.FD(fd))
			}
			argv := [2]cstring{command_arg, nil}
			_ = posix.execvp(argv[0], raw_data(argv[:]))
			posix._exit(127)
		}
		_ = posix.close(fds[0])
		writer_fd := posix.FD(3)
		if fds[1] != writer_fd {
			if posix.dup2(fds[1], writer_fd) < 0 do posix._exit(127)
			_ = posix.close(fds[1])
		}
		if linux.close_range(4, linux.Fd(max(i32)), {}) != .NONE {
			for fd := 4; fd < 1024; fd += 1 do _ = posix.close(posix.FD(fd))
		}
		_ = write_all(writer_fd, data)
		_ = posix.close(writer_fd)
		status: c.int
		for {
			result := posix.waitpid(consumer, &status, {})
			if result == consumer do break
			if result < 0 && posix.errno() == .EINTR do continue
			break
		}
		posix._exit(0)
	}
	status: c.int
	for {
		result := posix.waitpid(child, &status, {})
		if result == child do return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
		if result < 0 && posix.errno() == .EINTR do continue
		return false
	}
}

write_all :: proc(fd: posix.FD, data: []byte) -> bool {
	offset: int = 0
	for offset < len(data) {
		remaining: int = len(data)-offset
		count := posix.write(fd, raw_data(data[offset:]), c.size_t(remaining))
		if count > 0 {
			offset += int(count)
		} else if count < 0 && posix.errno() == .EINTR {
			continue
		} else {
			return false
		}
	}
	return true
}
