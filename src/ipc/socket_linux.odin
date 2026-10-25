#+build linux

package ipc

import "core:c"
import "core:strings"
import "core:sys/posix"

Socket_Error :: enum {
	None,
	Invalid_Path,
	Create,
	Bind,
	Permissions,
	Listen,
	Connect,
	Accept,
	Would_Block,
	Interrupted,
	Peer_Credentials,
	Unauthorized,
}

Listener :: struct {
	fd: posix.FD,
	path: string,
}

Peer_Credentials :: struct {
	pid: posix.pid_t,
	uid: posix.uid_t,
	gid: posix.gid_t,
}

socket_address :: proc(path: string) -> (posix.sockaddr_un, bool) {
	address: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(address.sun_path) || contains_nul(path) do return address, false
	address.sun_family = .UNIX
	for octet, index in transmute([]byte)path do address.sun_path[index] = c.char(octet)
	return address, true
}

set_close_on_exec :: proc(fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFD)
	return flags >= 0 && posix.fcntl(fd, .SETFD, flags | posix.FD_CLOEXEC) >= 0
}

set_socket_nonblocking :: proc(fd: posix.FD) -> bool {
	flags_value := posix.fcntl(fd, .GETFL)
	if flags_value < 0 do return false
	flags := transmute(posix.O_Flags)flags_value
	flags += {.NONBLOCK}
	return posix.fcntl(fd, .SETFL, flags) >= 0
}

listener_open :: proc(path: string) -> (Listener, Socket_Error) {
	address, path_ok := socket_address(path)
	if !path_ok do return {fd = -1}, .Invalid_Path
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return {fd = -1}, .Create
	if !set_close_on_exec(fd) || !set_socket_nonblocking(fd) {
		_ = posix.close(fd)
		return {fd = -1}, .Create
	}
	mask := posix.mode_t{.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	old_mask := posix.umask(mask)
	bind_result := posix.bind(fd, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address)))
	_ = posix.umask(old_mask)
	if bind_result != .OK {
		_ = posix.close(fd)
		return {fd = -1}, .Bind
	}
	path_c := strings.clone_to_cstring(path)
	permission_result := posix.chmod(path_c, {.IRUSR, .IWUSR})
	delete(path_c)
	if permission_result != .OK {
		path_c = strings.clone_to_cstring(path)
		_ = posix.unlink(path_c)
		delete(path_c)
		_ = posix.close(fd)
		return {fd = -1}, .Permissions
	}
	if posix.listen(fd, 16) != .OK {
		path_c = strings.clone_to_cstring(path)
		_ = posix.unlink(path_c)
		delete(path_c)
		_ = posix.close(fd)
		return {fd = -1}, .Listen
	}
	return {fd = fd, path = strings.clone(path)}, .None
}

listener_close :: proc(listener: ^Listener) {
	if listener.fd >= 0 do _ = posix.close(listener.fd)
	if listener.path != "" {
		path := strings.clone_to_cstring(listener.path)
		_ = posix.unlink(path)
		delete(path)
		delete(listener.path)
	}
	listener^ = {fd = -1}
}

connect_socket :: proc(path: string) -> (posix.FD, Socket_Error) {
	address, path_ok := socket_address(path)
	if !path_ok do return -1, .Invalid_Path
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return -1, .Create
	if !set_close_on_exec(fd) || posix.connect(fd, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address))) != .OK {
		_ = posix.close(fd)
		return -1, .Connect
	}
	credentials, credential_error := peer_credentials(fd)
	if credential_error != .None || credentials.uid != posix.geteuid() {
		_ = posix.close(fd)
		if credential_error != .None do return -1, credential_error
		return -1, .Unauthorized
	}
	return fd, .None
}

peer_credentials :: proc(fd: posix.FD) -> (Peer_Credentials, Socket_Error) {
	credentials: Peer_Credentials
	size := posix.socklen_t(size_of(credentials))
	if posix.getsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(17), &credentials, &size) != .OK ||
	   size != posix.socklen_t(size_of(credentials)) {
		return {}, .Peer_Credentials
	}
	return credentials, .None
}

listener_accept :: proc(listener: ^Listener) -> (posix.FD, Socket_Error) {
	address: posix.sockaddr_un
	address_size := posix.socklen_t(size_of(address))
	fd := posix.accept(listener.fd, (^posix.sockaddr)(&address), &address_size)
	if fd < 0 {
		if posix.errno() == .EAGAIN do return -1, .Would_Block
		if posix.errno() == .EINTR do return -1, .Interrupted
		return -1, .Accept
	}
	credentials, credential_error := peer_credentials(fd)
	if credential_error != .None || credentials.uid != posix.geteuid() {
		_ = posix.close(fd)
		if credential_error != .None do return -1, credential_error
		return -1, .Unauthorized
	}
	if !set_close_on_exec(fd) || !set_socket_nonblocking(fd) {
		_ = posix.close(fd)
		return -1, .Accept
	}
	return fd, .None
}
