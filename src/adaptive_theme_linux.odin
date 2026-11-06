#+build linux

package main

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import config "config"

Desktop_Color_Scheme :: enum { None, Dark, Light }

adaptive_theme_apply :: proc(settings: ^config.Settings) -> string {
	if settings == nil do return ""
	if settings.adaptive_light_theme != "" || settings.adaptive_dark_theme != "" {
		scheme := desktop_color_scheme()
		name := settings.adaptive_dark_theme if scheme == .Dark else settings.adaptive_light_theme
		if scheme != .None && name != "" {
			if theme_error, found := theme_apply(settings, name); found do return theme_error
		}
	}
	theme_error, _ := theme_apply(settings, settings.theme_name)
	return theme_error
}

theme_apply :: proc(settings: ^config.Settings, name: string) -> (string, bool) {
	path := config.theme_path(settings, name)
	if path == "" do return "", false
	defer delete(path)
	result := config.load(settings, path)
	if result.error == .None do return "", true
	if result.line > 0 do return fmt.aprintf("%s:%d: %s", path, result.line, config.error_string(result.error)), true
	return fmt.aprintf("%s: %s", path, config.error_string(result.error)), true
}

desktop_color_scheme :: proc() -> Desktop_Color_Scheme {
	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK do return .None
	child := posix.fork()
	if child < 0 {
		_ = posix.close(pipe_fds[0])
		_ = posix.close(pipe_fds[1])
		return .None
	}
	if child == 0 {
		_ = posix.close(pipe_fds[0])
		_ = posix.dup2(pipe_fds[1], 1)
		_ = posix.dup2(pipe_fds[1], 2)
		_ = posix.close(pipe_fds[1])
		argv := [10]cstring{
			"dbus-send", "--session", "--print-reply=literal", "--reply-timeout=1000",
			"--dest=org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
			"org.freedesktop.portal.Settings.ReadOne", "string:org.freedesktop.appearance",
			"string:color-scheme", nil,
		}
		_ = posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	_ = posix.close(pipe_fds[1])
	output: [512]byte
	used := 0
	for used < len(output) {
		count := posix.read(pipe_fds[0], &output[used], uint(len(output)-used))
		if count < 0 && posix.errno() == .EINTR do continue
		if count <= 0 do break
		used += int(count)
	}
	_ = posix.close(pipe_fds[0])
	status: c.int
	for {
		waited := posix.waitpid(child, &status, {})
		if waited == child do break
		if waited < 0 && posix.errno() == .EINTR do continue
		return .None
	}
	if !posix.WIFEXITED(status) || posix.WEXITSTATUS(status) != 0 do return .None
	result := strings.trim_space(string(output[:used]))
	if len(result) == 0 || !strings.contains(result, "uint32") do return .None
	if result[len(result)-1] == '1' do return .Dark
	if result[len(result)-1] == '2' do return .Light
	return .None
}
