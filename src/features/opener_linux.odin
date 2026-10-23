package features

import "core:c"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

open_url :: proc(opener, url: string) -> bool {
	if opener == "" || url == "" do return false
	opener_arg := strings.clone_to_cstring(opener)
	defer delete(opener_arg)
	url_arg := strings.clone_to_cstring(url)
	defer delete(url_arg)
	argv := [3]cstring{opener_arg, url_arg, nil}
	child := posix.fork()
	if child < 0 do return false
	if child == 0 {
		grandchild := posix.fork()
		if grandchild < 0 do posix._exit(127)
		if grandchild > 0 do posix._exit(0)
		_ = posix.setsid()
		if linux.close_range(3, linux.Fd(max(i32)), {}) != .NONE {
			for fd := 3; fd < 1024; fd += 1 do _ = posix.close(posix.FD(fd))
		}
		_ = posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	status: c.int
	for {
		result := posix.waitpid(child, &status, {})
		if result == child do return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
		if result < 0 && posix.errno() == .EINTR do continue
		return false
	}
}
