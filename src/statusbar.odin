package main

import c "core:c"
import libc "core:c/libc"
import sha1 "core:crypto/legacy/sha1"
import endian "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import config "config"
import pty "pty"
import vt "vt"

foreign import status_libc "system:c"
foreign status_libc {
	posix_spawn_file_actions_init :: proc(actions: rawptr) -> c.int ---
	posix_spawn_file_actions_destroy :: proc(actions: rawptr) -> c.int ---
	posix_spawn_file_actions_addclose :: proc(actions: rawptr, fd: c.int) -> c.int ---
	posix_spawn_file_actions_adddup2 :: proc(actions: rawptr, fd, new_fd: c.int) -> c.int ---
}

Statusbar_Spawn_Actions :: struct #align(8) {storage: [128]byte}

MAX_GIT_INDEX_BYTES :: 16 * 1024 * 1024
MAX_GIT_INDEX_ENTRIES :: 4096
MAX_GIT_HASH_BYTES :: 32 * 1024 * 1024
GIT_STATUS_TIMEOUT_MS :: 1500

Statusbar_Sample_Job :: struct {
	battery_requested, resource_requested, git_requested, command_requested: bool,
	battery: [64]byte,
	battery_length: int,
	resource: [128]byte,
	resource_length: int,
	git: [128]byte,
	git_length: int,
	command: [128]byte,
	command_length: int,
	cwd: [4096]byte,
	cwd_length: int,
	command_pid: int,
	cpu_total, cpu_idle: u64,
	cpu_ready: bool,
}

Statusbar_State :: struct {
	visible: bool,
	render_cache: Statusbar_Render_Cache,
	clock, battery, resource, local_host, cwd, cwd_source, git, command: string,
	last_clock, last_cwd, last_git, last_command, last_battery, last_resource: time.Time,
	cwd_pane, git_pane, command_pane: ^Pane,
	cwd_local: bool,
	cpu_total, cpu_idle: u64,
	cpu_ready: bool,
	sample_job: ^Statusbar_Sample_Job,
	sample_thread: ^thread.Thread,
}

statusbar_destroy :: proc(state: ^Statusbar_State) {
	if state.sample_thread != nil do thread.destroy(state.sample_thread)
	if state.sample_job != nil do free(state.sample_job)
	statusbar_render_cache_destroy(&state.render_cache)
	delete(state.clock)
	delete(state.battery)
	delete(state.resource)
	delete(state.local_host)
	delete(state.cwd)
	delete(state.cwd_source)
	delete(state.git)
	delete(state.command)
	state^ = {}
}

statusbar_visible :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil || !workspace.statusbar.visible do return false
	return workspace.quake == nil || workspace.settings.statusbar.show_in_quake
}

statusbar_height :: proc(workspace: ^Workspace) -> int {
	return workspace.settings.statusbar.height if statusbar_visible(workspace) else 0
}

statusbar_has_module :: proc(settings: ^config.Statusbar_Settings, wanted: config.Status_Module) -> bool {
	for module in settings.left do if module == wanted do return true
	for module in settings.center do if module == wanted do return true
	for module in settings.right do if module == wanted do return true
	return false
}

statusbar_tick :: proc(workspace: ^Workspace, force: bool = false) {
	if !statusbar_visible(workspace) do return
	settings := &workspace.settings.statusbar
	now := time.now()
	changed := statusbar_harvest_sample(&workspace.statusbar)
	if statusbar_has_module(settings, .Clock) && (force || time.since(workspace.statusbar.last_clock) >= time.Duration(settings.clock_update_ms)*time.Millisecond) {
		workspace.statusbar.last_clock = now
		changed = statusbar_update_clock(&workspace.statusbar, settings.clock_format) || changed
	}
	if statusbar_has_module(settings, .Cwd) && (force || time.since(workspace.statusbar.last_cwd) >= time.Duration(settings.cwd_update_ms)*time.Millisecond) {
		workspace.statusbar.last_cwd = now
		changed = statusbar_update_cwd(workspace) || changed
	}
	battery_due := statusbar_has_module(settings, .Battery) && (force || time.since(workspace.statusbar.last_battery) >= time.Duration(settings.battery_update_ms)*time.Millisecond)
	resource_due := statusbar_has_module(settings, .Resource) && (force || time.since(workspace.statusbar.last_resource) >= time.Duration(settings.resource_update_ms)*time.Millisecond)
	git_due := statusbar_has_module(settings, .Git) && (force || workspace.statusbar.git_pane != workspace_active_pane(workspace) || time.since(workspace.statusbar.last_git) >= time.Duration(settings.git_update_ms)*time.Millisecond)
	command_due := statusbar_has_module(settings, .Command) && (force || workspace.statusbar.command_pane != workspace_active_pane(workspace) || time.since(workspace.statusbar.last_command) >= time.Duration(settings.command_update_ms)*time.Millisecond)
	if workspace.statusbar.sample_thread == nil && (battery_due || resource_due || git_due || command_due) {
		git_request := false
		command_request := false
		command_pid := 0
		pane := workspace_active_pane(workspace)
		tab := workspace_active_tab(workspace)
		if git_due {
			changed = statusbar_update_cwd(workspace) || changed
			if workspace.statusbar.git_pane != pane do changed = statusbar_replace(&workspace.statusbar.git, "") || changed
			workspace.statusbar.git_pane = pane
			git_request = pane != nil && workspace.statusbar.cwd_local && workspace.statusbar.cwd_source != "" && len(workspace.statusbar.cwd_source) <= 4096
			if !git_request do changed = statusbar_replace(&workspace.statusbar.git, "") || changed
		}
		if command_due {
			if workspace.statusbar.command_pane != pane do changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			workspace.statusbar.command_pane = pane
			owner := pane_tmux_owner(pane)
			if tab_is_tmux(tab) {
				value := ""
				if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil do value = statusbar_sanitize(string(info.current_command[:]))
				changed = statusbar_replace(&workspace.statusbar.command, value) || changed
			} else if owner != nil && owner.remote_host != "" {
				changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			} else if pane != nil {
				pid, ok := pty.foreground_pid(&pane.process)
				if ok do command_request, command_pid = true, pid
				else do changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			} else {
				changed = statusbar_replace(&workspace.statusbar.command, "") || changed
			}
		}
		started := statusbar_start_sample(&workspace.statusbar, battery_due, resource_due, git_request, command_request, workspace.statusbar.cwd_source, command_pid)
		if started || (!battery_due && !resource_due && !git_request && !command_request) {
			if battery_due do workspace.statusbar.last_battery = now
			if resource_due do workspace.statusbar.last_resource = now
			if git_due do workspace.statusbar.last_git = now
			if command_due do workspace.statusbar.last_command = now
		}
	}
	if changed && !force do workspace_draw_statusbar(workspace)
}

statusbar_update_clock :: proc(state: ^Statusbar_State, format: string) -> bool {
	format_c, format_error := strings.clone_to_cstring(format, context.temp_allocator)
	if format_error != nil do return false
	now := libc.time(nil)
	local := libc.localtime(&now)
	if local == nil do return statusbar_replace(&state.clock, "")
	buffer: [128]c.char
	count := libc.strftime(&buffer[0], len(buffer), format_c, local)
	if count == 0 do return statusbar_replace(&state.clock, "")
	return statusbar_replace(&state.clock, string(cstring(&buffer[0])))
}

statusbar_collect_battery :: proc() -> string {
	entries, directory_error := os.read_directory_by_path("/sys/class/power_supply", -1, context.temp_allocator)
	if directory_error != nil do return ""
	for entry in entries {
		base := fmt.tprintf("/sys/class/power_supply/%s", entry.name)
		type_data, type_error := os.read_entire_file(fmt.tprintf("%s/type", base), context.temp_allocator)
		if type_error != nil || strings.trim_space(string(type_data)) != "Battery" do continue
		capacity_data, capacity_error := os.read_entire_file(fmt.tprintf("%s/capacity", base), context.temp_allocator)
		if capacity_error != nil do continue
		capacity, ok := strconv.parse_int(strings.trim_space(string(capacity_data)))
		if !ok || capacity < 0 || capacity > 100 do continue
		status_data, _ := os.read_entire_file(fmt.tprintf("%s/status", base), context.temp_allocator)
		status := strings.trim_space(string(status_data))
		marker := ""
		if status == "Charging" do marker = "+"
		else if status == "Discharging" do marker = "-"
		return fmt.tprintf("BAT %d%%%s", capacity, marker)
	}
	return ""
}

statusbar_collect_resources :: proc(job: ^Statusbar_Sample_Job) -> string {
	cpu_percent, cpu_ok := statusbar_cpu_percent(job)
	ram_percent, ram_ok := statusbar_ram_percent()
	storage_percent, storage_ok := statusbar_storage_percent()
	if cpu_ok && ram_ok && storage_ok {
		return fmt.tprintf("CPU %d%% RAM %d%% STORAGE %d%%", cpu_percent, ram_percent, storage_percent)
	} else if ram_ok && storage_ok {
		return fmt.tprintf("RAM %d%% STORAGE %d%%", ram_percent, storage_percent)
	}
	return ""
}

statusbar_start_sample :: proc(state: ^Statusbar_State, battery, resource, git, command: bool, cwd: string, command_pid: int) -> bool {
	if !battery && !resource && !git && !command do return false
	job := new(Statusbar_Sample_Job)
	if job == nil do return false
	job.battery_requested = battery
	job.resource_requested = resource
	job.git_requested = git
	job.command_requested = command
	job.command_pid = command_pid
	if git do statusbar_copy_sample(job.cwd[:], &job.cwd_length, cwd)
	job.cpu_total = state.cpu_total
	job.cpu_idle = state.cpu_idle
	job.cpu_ready = state.cpu_ready
	worker := thread.create_and_start_with_data(rawptr(job), statusbar_sample_worker, nil, .Low, false, "nare-status")
	if worker == nil {
		free(job)
		return false
	}
	state.sample_job = job
	state.sample_thread = worker
	return true
}

statusbar_sample_worker :: proc(data: rawptr) {
	job := cast(^Statusbar_Sample_Job)data
	if job.battery_requested do statusbar_copy_sample(job.battery[:], &job.battery_length, statusbar_collect_battery())
	if job.resource_requested do statusbar_copy_sample(job.resource[:], &job.resource_length, statusbar_collect_resources(job))
	if job.git_requested do statusbar_copy_sample(job.git[:], &job.git_length, statusbar_collect_git(string(job.cwd[:job.cwd_length])))
	if job.command_requested do statusbar_copy_sample(job.command[:], &job.command_length, statusbar_collect_command(job.command_pid))
}

statusbar_copy_sample :: proc(buffer: []byte, length: ^int, value: string) {
	count := min(len(buffer), len(value))
	copy(buffer[:count], transmute([]byte)value[:count])
	length^ = count
}

statusbar_harvest_sample :: proc(state: ^Statusbar_State) -> bool {
	if state.sample_thread == nil || !thread.is_done(state.sample_thread) do return false
	thread.destroy(state.sample_thread)
	job := state.sample_job
	state.sample_thread = nil
	state.sample_job = nil
	if job == nil do return false
	defer free(job)
	changed := false
	if job.battery_requested do changed = statusbar_replace(&state.battery, string(job.battery[:job.battery_length])) || changed
	if job.resource_requested {
		state.cpu_total = job.cpu_total
		state.cpu_idle = job.cpu_idle
		state.cpu_ready = job.cpu_ready
		changed = statusbar_replace(&state.resource, string(job.resource[:job.resource_length])) || changed
	}
	if job.git_requested do changed = statusbar_replace(&state.git, statusbar_sanitize(string(job.git[:job.git_length]))) || changed
	if job.command_requested do changed = statusbar_replace(&state.command, statusbar_sanitize(string(job.command[:job.command_length]))) || changed
	return changed
}

statusbar_update_cwd :: proc(workspace: ^Workspace) -> bool {
	state := &workspace.statusbar
	tab := workspace_active_tab(workspace)
	pane := workspace_active_pane(workspace)
	state.cwd_pane = pane
	if tab == nil || pane == nil do return statusbar_set_cwd(state, "", false)
	owner := pane_tmux_owner(pane)
	remote := owner != nil && owner.remote_host != ""

	if tab_is_tmux(tab) {
		if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil && len(info.current_path) > 0 {
			pane.terminal.cwd_changed = false
			return statusbar_set_cwd(state, string(info.current_path[:]), !remote)
		}
	}
	if pane.terminal.cwd_path != "" {
		pane.terminal.cwd_changed = false
		return statusbar_set_cwd(state, pane.terminal.cwd_path, !remote)
	}
	if remote do return statusbar_set_cwd(state, "", false)
	cwd, ok := pty.foreground_cwd(&pane.process)
	if !ok do return statusbar_set_cwd(state, "", false)
	defer delete(cwd)
	return statusbar_set_cwd(state, cwd, true)
}

statusbar_set_cwd :: proc(state: ^Statusbar_State, value: string, local: bool) -> bool {
	changed := statusbar_replace(&state.cwd, statusbar_sanitize(value))
	if state.cwd_source != value do config.replace_string(&state.cwd_source, value)
	state.cwd_local = local && value != ""
	return changed
}

statusbar_collect_command :: proc(pid: int) -> string {
	if pid <= 0 do return ""
	path_buffer: [64]byte
	path := fmt.bprintf(path_buffer[:], "/proc/%d/comm", pid)
	return strings.trim_space(statusbar_read_small(path))
}

statusbar_collect_git :: proc(cwd: string) -> string {
	git_dir, worktree, found := statusbar_find_git(cwd)
	if !found do return ""
	head_path, head_error := filepath.join({git_dir, "HEAD"}, context.temp_allocator)
	if head_error != nil do return ""
	head := strings.trim_space(statusbar_read_small(head_path))
	label := ""
	if strings.has_prefix(head, "ref: refs/heads/") {
		branch := head[len("ref: refs/heads/"):]
		if branch != "" do label = fmt.tprintf("git:%s", branch)
	} else if len(head) >= 8 && statusbar_is_hex(head) {
		label = fmt.tprintf("git:%s", head[:8])
	}
	if label == "" do return ""
	dirty, known := statusbar_git_complete_dirty(cwd)
	if !known do dirty, known = statusbar_git_tracked_dirty(git_dir, worktree)
	if known && dirty do return fmt.tprintf("%s*", label)
	return label
}

statusbar_git_complete_dirty :: proc(cwd: string) -> (dirty, known: bool) {
	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK do return false, false
	for &fd in pipe_fds {
		if fd > 2 do continue
		duplicate := posix.fcntl(fd, .DUPFD_CLOEXEC, 3)
		if duplicate < 0 {
			_ = posix.close(pipe_fds[0])
			_ = posix.close(pipe_fds[1])
			return false, false
		}
		_ = posix.close(fd)
		fd = posix.FD(duplicate)
	}
	defer posix.close(pipe_fds[0])
	defer posix.close(pipe_fds[1])
	_ = posix.fcntl(pipe_fds[0], .SETFD, posix.FD_CLOEXEC)
	_ = posix.fcntl(pipe_fds[1], .SETFD, posix.FD_CLOEXEC)

	actions: Statusbar_Spawn_Actions
	if posix_spawn_file_actions_init(rawptr(&actions)) != 0 do return false, false
	defer posix_spawn_file_actions_destroy(rawptr(&actions))
	if posix_spawn_file_actions_adddup2(rawptr(&actions), c.int(pipe_fds[1]), 1) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), c.int(pipe_fds[0])) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), c.int(pipe_fds[1])) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), 0) != 0 ||
	   posix_spawn_file_actions_addclose(rawptr(&actions), 2) != 0 {
		return false, false
	}
	cwd_c, cwd_error := strings.clone_to_cstring(cwd, context.temp_allocator)
	if cwd_error != nil do return false, false
	argv := [12]cstring{
		"git", "-C", cwd_c, "--no-optional-locks", "-c", "core.fsmonitor=false",
		"status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=none", "--", nil,
	}
	child: posix.pid_t
	if posix.posix_spawnp(&child, "git", rawptr(&actions), nil, &argv[0], posix.environ) != .NONE do return false, false
	_ = posix.close(pipe_fds[1])
	pipe_fds[1] = -1
	start := time.tick_now()
	status: c.int
	for time.tick_since(start) < GIT_STATUS_TIMEOUT_MS*time.Millisecond {
		poll_fd := posix.pollfd{fd = pipe_fds[0], events = {.IN}}
		poll_result := posix.poll(&poll_fd, 1, 50)
		if poll_result > 0 && (.IN in poll_fd.revents) {
			value: byte
			if posix.read(pipe_fds[0], &value, 1) > 0 {
				_ = posix.kill(child, .SIGKILL)
				_ = posix.waitpid(child, &status, {})
				return true, true
			}
		}
		waited := posix.waitpid(child, &status, {.NOHANG})
		if waited == child {
			return false, posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
		}
		if waited < 0 do return false, false
	}
	_ = posix.kill(child, .SIGKILL)
	_ = posix.waitpid(child, &status, {})
	return false, false
}

statusbar_find_git :: proc(cwd: string) -> (git_dir, worktree: string, found: bool) {
	if cwd == "" || cwd[0] != '/' do return
	current := cwd
	for _ in 0..<64 {
		dot_git, join_error := filepath.join({current, ".git"}, context.temp_allocator)
		if join_error != nil do return
		if os.is_directory(dot_git) {
			git_dir = dot_git
		} else if marker := strings.trim_space(statusbar_read_small(dot_git)); strings.has_prefix(marker, "gitdir:") {
			target := strings.trim_space(marker[len("gitdir:"):])
			if filepath.is_abs(target) {
				git_dir = target
			} else {
				git_dir, join_error = filepath.join({filepath.dir(dot_git), target}, context.temp_allocator)
				if join_error != nil do return
			}
		}
		if git_dir != "" do return git_dir, current, true
		parent := filepath.dir(current)
		if parent == current do break
		current = parent
	}
	return
}

statusbar_git_tracked_dirty :: proc(git_dir, worktree: string) -> (dirty, known: bool) {
	config_dir := git_dir
	common_path, common_error := filepath.join({git_dir, "commondir"}, context.temp_allocator)
	if common_error == nil {
		common := strings.trim_space(statusbar_read_small(common_path))
		if common != "" {
			if filepath.is_abs(common) {
				config_dir = common
			} else if resolved, resolve_error := filepath.join({git_dir, common}, context.temp_allocator); resolve_error == nil {
				config_dir = resolved
			}
		}
	}
	config_path, config_error := filepath.join({config_dir, "config"}, context.temp_allocator)
	if config_error != nil do return false, false
	config_data := statusbar_read_small(config_path)
	if statusbar_git_uses_sha256(config_data) do return false, false
	index_path, index_error := filepath.join({git_dir, "index"}, context.temp_allocator)
	if index_error != nil do return false, false
	index, index_ok := statusbar_read_bounded(index_path, MAX_GIT_INDEX_BYTES)
	if !index_ok || len(index) < 12+sha1.DIGEST_SIZE || string(index[:4]) != "DIRC" do return false, false
	version := endian.unchecked_get_u32be(index[4:8])
	entry_count := endian.unchecked_get_u32be(index[8:12])
	if (version != 2 && version != 3) || entry_count > MAX_GIT_INDEX_ENTRIES do return false, false
	cursor := 12
	hashed_bytes := 0
	for _ in 0..<int(entry_count) {
		entry_start := cursor
		if cursor+62 > len(index)-sha1.DIGEST_SIZE do return false, false
		mtime_seconds := endian.unchecked_get_u32be(index[cursor+8:cursor+12])
		mtime_nanos := endian.unchecked_get_u32be(index[cursor+12:cursor+16])
		mode := endian.unchecked_get_u32be(index[cursor+24:cursor+28])
		size := endian.unchecked_get_u32be(index[cursor+36:cursor+40])
		expected_hash := index[cursor+40:cursor+60]
		flags := endian.unchecked_get_u16be(index[cursor+60:cursor+62])
		cursor += 62
		if version == 3 && flags&0x4000 != 0 {
			if cursor+2 > len(index)-sha1.DIGEST_SIZE do return false, false
			cursor += 2
		}
		path_start := cursor
		for cursor < len(index)-sha1.DIGEST_SIZE && index[cursor] != 0 do cursor += 1
		if cursor >= len(index)-sha1.DIGEST_SIZE do return false, false
		path := string(index[path_start:cursor])
		if path == "" || path[0] == '/' || path == ".." || strings.has_prefix(path, "../") || strings.contains(path, "/../") do return false, false
		cursor += 1
		entry_size := cursor-entry_start
		cursor += (8-entry_size%8)%8
		if cursor > len(index)-sha1.DIGEST_SIZE do return false, false
		if mode&0o170000 == 0o160000 do continue
		full_path, join_error := filepath.join({worktree, path}, context.temp_allocator)
		if join_error != nil do return false, false
		info, stat_error := os.lstat(full_path, context.temp_allocator)
		if stat_error != nil do return true, true
		mtime := time.to_unix_nanoseconds(info.modification_time)
		executable := .Execute_User in info.mode
		index_executable := mode&0o111 != 0
		type_matches := (mode&0o170000 == 0o120000 && info.type == .Symlink) || (mode&0o170000 == 0o100000 && info.type == .Regular)
		stat_matches := type_matches && u64(max(0, info.size)) == u64(size) && u64(max(0, mtime/1e9)) == u64(mtime_seconds) && u64(max(0, mtime%1e9)) == u64(mtime_nanos) && executable == index_executable
		if stat_matches do continue
		matches, hash_ok := statusbar_git_blob_matches(full_path, info, expected_hash, &hashed_bytes)
		if !hash_ok || !matches do return true, true
	}
	return false, true
}

statusbar_read_small :: proc(path: string) -> string {
	data, ok := statusbar_read_bounded(path, 4096)
	return string(data) if ok else ""
}

statusbar_read_bounded :: proc(path: string, limit: int) -> ([]byte, bool) {
	file, open_error := os.open(path)
	if open_error != nil do return nil, false
	defer os.close(file)
	capacity := limit+1
	expected_size := i64(-1)
	if info, stat_error := os.stat(path, context.temp_allocator); stat_error == nil && info.type == .Regular && info.size > 0 {
		if info.size > i64(limit) do return nil, false
		expected_size = info.size
		capacity = int(info.size)+1
	}
	buffer := make([]byte, capacity, context.temp_allocator)
	total := 0
	for total < len(buffer) {
		count, read_error := os.read(file, buffer[total:])
		if count > 0 do total += count
		if read_error != nil || count == 0 do break
	}
	if total > limit || (expected_size >= 0 && i64(total) != expected_size) do return nil, false
	return buffer[:total], true
}

statusbar_git_uses_sha256 :: proc(config_data: string) -> bool {
	remaining := config_data
	for remaining != "" {
		line := remaining
		if newline := strings.index_byte(remaining, '\n'); newline >= 0 {
			line, remaining = remaining[:newline], remaining[newline+1:]
		} else do remaining = ""
		line = strings.trim_space(line)
		separator := strings.index_byte(line, '=')
		if separator < 0 do continue
		key := strings.trim_space(line[:separator])
		value := strings.trim_space(line[separator+1:])
		if strings.to_lower(key, context.temp_allocator) == "objectformat" && strings.to_lower(value, context.temp_allocator) == "sha256" do return true
	}
	return false
}

statusbar_git_blob_matches :: proc(path: string, info: os.File_Info, expected: []byte, hashed_bytes: ^int) -> (bool, bool) {
	data: []byte
	if info.type == .Symlink {
		target, link_error := os.read_link(path, context.temp_allocator)
		if link_error != nil do return false, false
		data = transmute([]byte)target
	} else if info.type == .Regular {
		if info.size < 0 || info.size > MAX_GIT_HASH_BYTES-i64(hashed_bytes^) do return false, false
		contents, read_ok := statusbar_read_bounded(path, int(info.size))
		if !read_ok do return false, false
		data = contents
	} else do return false, true
	if len(data) > MAX_GIT_HASH_BYTES-hashed_bytes^ do return false, false
	hashed_bytes^ += len(data)
	header_buffer: [64]byte
	header := fmt.bprintf(header_buffer[:], "blob %d%c", len(data), byte(0))
	ctx: sha1.Context
	digest: [sha1.DIGEST_SIZE]byte
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)header)
	sha1.update(&ctx, data)
	sha1.final(&ctx, digest[:])
	if len(expected) != len(digest) do return false, false
	for value, index in digest do if value != expected[index] do return false, true
	return true, true
}

statusbar_is_hex :: proc(value: string) -> bool {
	for byte in transmute([]byte)value {
		if !((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F')) do return false
	}
	return value != ""
}

statusbar_cpu_percent :: proc(job: ^Statusbar_Sample_Job) -> (int, bool) {
	data, err := os.read_entire_file("/proc/stat", context.temp_allocator)
	if err != nil do return 0, false
	line := string(data)
	if newline := strings.index_byte(line, '\n'); newline >= 0 do line = line[:newline]
	cursor := 3
	total, idle := u64(0), u64(0)
	field := 0
	for {
		for cursor < len(line) && (line[cursor] == ' ' || line[cursor] == '\t') do cursor += 1
		if cursor >= len(line) do break
		start := cursor
		for cursor < len(line) && line[cursor] >= '0' && line[cursor] <= '9' do cursor += 1
		if start == cursor do break
		value, ok := strconv.parse_u64(line[start:cursor])
		if !ok do return 0, false
		total += value
		if field == 3 || field == 4 do idle += value
		field += 1
	}
	if field < 4 do return 0, false
	if !job.cpu_ready {
		job.cpu_total, job.cpu_idle, job.cpu_ready = total, idle, true
		return 0, false
	}
	delta_total := total-job.cpu_total if total >= job.cpu_total else 0
	delta_idle := idle-job.cpu_idle if idle >= job.cpu_idle else 0
	job.cpu_total, job.cpu_idle = total, idle
	if delta_total == 0 do return 0, false
	busy := delta_total-delta_idle if delta_total >= delta_idle else 0
	return clamp(int(busy*100/delta_total), 0, 100), true
}

statusbar_ram_percent :: proc() -> (int, bool) {
	data, err := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	if err != nil do return 0, false
	total, available := u64(0), u64(0)
	remaining := string(data)
	for remaining != "" {
		line := remaining
		if newline := strings.index_byte(remaining, '\n'); newline >= 0 {
			line, remaining = remaining[:newline], remaining[newline+1:]
		} else do remaining = ""
		if strings.has_prefix(line, "MemTotal:") do total = statusbar_first_u64(line[len("MemTotal:"):])
		else if strings.has_prefix(line, "MemAvailable:") do available = statusbar_first_u64(line[len("MemAvailable:"):])
	}
	if total == 0 || available > total do return 0, false
	return int((total-available)*100/total), true
}

statusbar_first_u64 :: proc(value: string) -> u64 {
	start := 0
	for start < len(value) && (value[start] == ' ' || value[start] == '\t') do start += 1
	end := start
	for end < len(value) && value[end] >= '0' && value[end] <= '9' do end += 1
	if start == end do return 0
	result, ok := strconv.parse_u64(value[start:end])
	return result if ok else 0
}

statusbar_storage_percent :: proc() -> (int, bool) {
	info: posix.statvfs_t
	if posix.statvfs("/", &info) != .OK do return 0, false
	total := u64(info.f_blocks)
	available := u64(info.f_bavail)
	if total == 0 || available > total do return 0, false
	return int((total-available)*100/total), true
}

statusbar_replace :: proc(target: ^string, value: string) -> bool {
	if target^ == value do return false
	config.replace_string(target, value)
	return true
}

statusbar_group_text :: proc(workspace: ^Workspace, modules: []config.Status_Module) -> string {
	output := make([dynamic]byte, 0, 128, context.temp_allocator)
	for module in modules {
		value := statusbar_module_text(workspace, module)
		if value == "" do continue
		if len(output) > 0 do append(&output, ..transmute([]byte)workspace.settings.statusbar.separator)
		append(&output, ..transmute([]byte)value)
	}
	return string(output[:])
}

statusbar_group_modules :: proc(workspace: ^Workspace, modules: []config.Status_Module) -> []Statusbar_Draw_Module {
	result := make([dynamic]Statusbar_Draw_Module, 0, len(modules), context.temp_allocator)
	settings := &workspace.settings.statusbar
	for module in modules {
		value := statusbar_module_text(workspace, module)
		if value == "" do continue
		style := settings.module_styles[int(module)]
		foreground := settings.foreground
		background := settings.background
		if style.foreground_set do foreground = style.foreground
		if style.background_set do background = style.background
		append(&result, {text = value, foreground = foreground, background = background})
	}
	return result[:]
}

statusbar_module_group_key :: proc(modules: []Statusbar_Draw_Module) -> string {
	output := make([dynamic]byte, 0, len(modules)*32, context.temp_allocator)
	for module in modules {
		part := fmt.tprintf("%08x:%08x:%s\x00", module.foreground, module.background, module.text)
		append(&output, ..transmute([]byte)part)
	}
	return string(output[:])
}

statusbar_module_text :: proc(workspace: ^Workspace, module: config.Status_Module) -> string {
	tab := workspace_active_tab(workspace)
	pane := workspace_active_pane(workspace)
	if tab == nil || pane == nil do return ""
	owner := pane_tmux_owner(pane)
	remote := owner != nil && owner.remote_host != ""
	switch module {
	case .Mode:
		if tab_is_tmux(tab) do return "tmux+ssh" if remote else "tmux"
		return "ssh" if remote else "local"
	case .Session:
		if tab_is_tmux(tab) && len(tab.tmux_owner.tmux_session.title) > 0 do return statusbar_sanitize(string(tab.tmux_owner.tmux_session.title[:]))
		if tab.custom_title != "" do return statusbar_sanitize(tab.custom_title)
		if pane.display_title != "" do return statusbar_sanitize(pane.display_title)
		if pane.terminal.title != "" do return statusbar_sanitize(pane.terminal.title)
		return statusbar_sanitize(workspace.title)
	case .Host:
		if remote do return statusbar_sanitize(owner.remote_host)
		return statusbar_local_hostname(&workspace.statusbar)
	case .Cwd:
		if workspace.statusbar.cwd_pane != pane || pane.terminal.cwd_changed do statusbar_update_cwd(workspace)
		return workspace.statusbar.cwd
	case .Git:
		if workspace.statusbar.git_pane != pane do return ""
		return workspace.statusbar.git
	case .Command:
		if tab_is_tmux(tab) {
			if info := workspace_tmux_pane_info(tab.tmux_owner, pane.tmux_pane_id); info != nil do return statusbar_sanitize(string(info.current_command[:]))
			return ""
		}
		if workspace.statusbar.command_pane != pane do return ""
		return workspace.statusbar.command
	case .Size:
		screen := vt.terminal_screen(&pane.terminal)
		return fmt.tprintf("%dx%d", screen.columns, screen.rows)
	case .Tabs: return fmt.tprintf("%d/%d", workspace.active+1, len(workspace.tabs))
	case .Clock: return workspace.statusbar.clock
	case .Battery: return workspace.statusbar.battery
	case .Resource: return workspace.statusbar.resource
	}
	return ""
}

statusbar_local_hostname :: proc(state: ^Statusbar_State) -> string {
	if state.local_host != "" do return state.local_host
	buffer: [256]c.char
	if posix.gethostname(&buffer[0], len(buffer)) != .OK do return ""
	buffer[len(buffer)-1] = 0
	value := statusbar_sanitize(string(cstring(&buffer[0])))
	if value != "" do config.replace_string(&state.local_host, value)
	return state.local_host
}

statusbar_sanitize :: proc(value: string) -> string {
	output := make([dynamic]byte, 0, min(128, len(value)), context.temp_allocator)
	remaining := value
	for remaining != "" {
		codepoint, width := utf8.decode_rune_in_string(remaining)
		if width <= 0 do break
		remaining = remaining[width:]
		if codepoint == utf8.RUNE_ERROR && width == 1 do continue
		if codepoint < 0x20 || codepoint == 0x7f do continue
		encoded, encoded_width := utf8.encode_rune(codepoint)
		if len(output)+encoded_width > 128 do break
		append(&output, ..encoded[:encoded_width])
	}
	return string(output[:])
}

workspace_draw_statusbar :: proc(workspace: ^Workspace) {
	if !statusbar_visible(workspace) do return
	pane := workspace_active_pane(workspace)
	if pane == nil do return
	settings := &workspace.settings.statusbar
	tab_height := workspace_tab_bar_height(workspace)
	y := tab_height if settings.position == .Top && workspace.settings.tabs.edge == .Top else 0
	if settings.position == .Bottom {
		y = workspace.root.height-settings.height
		if workspace.settings.tabs.edge == .Bottom do y -= tab_height
	}
	left, center, right: string
	left_modules, center_modules, right_modules: []Statusbar_Draw_Module
	if settings.module_blocks {
		left_modules = statusbar_group_modules(workspace, settings.left[:])
		center_modules = statusbar_group_modules(workspace, settings.center[:])
		right_modules = statusbar_group_modules(workspace, settings.right[:])
		left = statusbar_module_group_key(left_modules)
		center = statusbar_module_group_key(center_modules)
		right = statusbar_module_group_key(right_modules)
	} else {
		left = statusbar_group_text(workspace, settings.left[:])
		center = statusbar_group_text(workspace, settings.center[:])
		right = statusbar_group_text(workspace, settings.right[:])
	}
	draw_workspace_statusbar(
		&workspace.statusbar.render_cache, workspace.root, pane.renderer.font,
		left, center, right, left_modules, center_modules, right_modules,
		settings.module_blocks, settings.border, y, settings.height,
		settings.background, settings.foreground, statusbar_active_accent(workspace),
	)
}

statusbar_active_accent :: proc(workspace: ^Workspace) -> u32 {
	tab := workspace_active_tab(workspace)
	if tab == nil do return workspace.settings.statusbar.accent
	for pane in tab.panes do if pane.root_foreground do return workspace.settings.ui_colors.root_tab_background
	if tab_is_tmux(tab) do return workspace.settings.tmux.active_tab_color
	return workspace.settings.ui_colors.active_tab_background
}
