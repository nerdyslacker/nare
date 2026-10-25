#+build linux

package ipc

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

Socket_Error :: enum {
	None,
	Invalid_Path,
	Runtime_Directory,
	Create,
	Bind,
	In_Use,
	Unsafe_Existing_Path,
	Stale_Cleanup,
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

private_mode :: proc(mode: posix.mode_t) -> bool {
	public_bits := posix.mode_t{.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	return mode & public_bits == {}
}

runtime_socket_path :: proc(runtime_directory: string) -> (string, Socket_Error) {
	if len(runtime_directory) == 0 || runtime_directory[0] != '/' || contains_nul(runtime_directory) {
		return "", .Runtime_Directory
	}
	path := strings.clone_to_cstring(runtime_directory)
	status: posix.stat_t
	result := posix.lstat(path, &status)
	delete(path)
	if result != .OK || !posix.S_ISDIR(status.st_mode) || status.st_uid != posix.geteuid() ||
	   !private_mode(status.st_mode) {
		return "", .Runtime_Directory
	}
	separator := ""
	if runtime_directory[len(runtime_directory)-1] != '/' do separator = "/"
	socket_path := fmt.aprintf("%s%snare.sock", runtime_directory, separator)
	address, valid := socket_address(socket_path)
	_ = address
	if !valid {
		delete(socket_path)
		return "", .Invalid_Path
	}
	return socket_path, .None
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
		bind_errno := posix.errno()
		if bind_errno != .EADDRINUSE {
			_ = posix.close(fd)
			return {fd = -1}, .Bind
		}
		probe := posix.socket(.UNIX, .STREAM)
		if probe < 0 {
			_ = posix.close(fd)
			return {fd = -1}, .Create
		}
		connect_result := posix.connect(probe, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address)))
		connect_errno := posix.errno()
		_ = posix.close(probe)
		if connect_result == .OK {
			_ = posix.close(fd)
			return {fd = -1}, .In_Use
		}
		if connect_errno != .ECONNREFUSED {
			_ = posix.close(fd)
			return {fd = -1}, .Bind
		}
		path_c := strings.clone_to_cstring(path)
		status: posix.stat_t
		stat_result := posix.lstat(path_c, &status)
		if stat_result != .OK || !posix.S_ISSOCK(status.st_mode) || status.st_uid != posix.geteuid() {
			delete(path_c)
			_ = posix.close(fd)
			return {fd = -1}, .Unsafe_Existing_Path
		}
		if posix.unlink(path_c) != .OK {
			delete(path_c)
			_ = posix.close(fd)
			return {fd = -1}, .Stale_Cleanup
		}
		delete(path_c)
		old_mask = posix.umask(mask)
		bind_result = posix.bind(fd, (^posix.sockaddr)(&address), posix.socklen_t(size_of(address)))
		_ = posix.umask(old_mask)
		if bind_result != .OK {
			_ = posix.close(fd)
			return {fd = -1}, .Bind
		}
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

listener_open_runtime :: proc(runtime_directory: string) -> (Listener, Socket_Error) {
	path, path_error := runtime_socket_path(runtime_directory)
	if path_error != .None do return {fd = -1}, path_error
	defer delete(path)
	return listener_open(path)
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
