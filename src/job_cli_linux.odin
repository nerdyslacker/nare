#+build linux

package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import jobs "jobs"

job_cli_requested :: proc(args: []string) -> bool {
	return len(args) >= 2 && ((args[0] == "status" && args[1] == "job") ||
	       (args[0] == "job" && (args[1] == "run" || args[1] == "init")))
}

job_cli_main :: proc(args: []string) -> int {
	if len(args) >= 2 && args[0] == "job" && args[1] == "init" do return job_shell_init(args[2:])
	path, token, reporter, environment_ok := job_reporting_environment()
	if len(args) >= 2 && args[0] == "job" && args[1] == "run" {
		return job_run_command(args[2:], path, token, reporter, environment_ok)
	}
	if !environment_ok {
		fmt.eprintln("nare: no eligible terminal job reporting session")
		return 1
	}
	return job_status_command(args[2:], path, token, reporter)
}

job_shell_init :: proc(args: []string) -> int {
	if len(args) != 1 do return job_cli_usage_error()
	switch args[0] {
	case "zsh":
		fmt.println(`if ! whence -w + >/dev/null 2>&1; then
  function '+' {
    emulate -L zsh
    local name
    if [[ ${1-} == -- ]]; then
      shift
    elif [[ ${1-} == +* ]]; then
      name=${1#+}
      shift
      [[ -n $name ]] || { print -u2 -- 'Usage: + [+NAME] COMMAND [ARG...]'; return 2; }
      [[ ${1-} == -- ]] && shift
    fi
    (( $# > 0 )) || { print -u2 -- 'Usage: + [+NAME] COMMAND [ARG...]'; return 2; }
    [[ -n $name ]] || name=${1:t}
    command nare job run "$name" -- "$@"
  }
fi`)
		return 0
	case "fish":
		fmt.println(`if not type -q +
  function + --description 'Run a tracked nare background job'
    set -l name
    if test "$argv[1]" = --
      set -e argv[1]
    else if string match -q '+*' -- "$argv[1]"
      set name (string sub -s 2 -- "$argv[1]")
      set -e argv[1]
      if test -z "$name"
        printf '%s\n' 'Usage: + [+NAME] COMMAND [ARG...]' >&2
        return 2
      end
      if test "$argv[1]" = --
        set -e argv[1]
      end
    end
    if not set -q argv[1]
      printf '%s\n' 'Usage: + [+NAME] COMMAND [ARG...]' >&2
      return 2
    end
    if test -z "$name"
      set name (string replace -r '^.*/' '' -- "$argv[1]")
    end
    command nare job run "$name" -- $argv
  end
end`)
		return 0
	case: return job_cli_usage_error()
	}
}

job_status_command :: proc(args: []string, path, token: string, reporter: u64) -> int {
	if len(args) < 1 {
		fmt.eprintln(job_cli_usage())
		return 2
	}
	switch args[0] {
	case "start":
		if len(args) < 2 do return job_cli_usage_error()
		label := args[1]
		external_id := ""
		for index := 2; index < len(args); index += 1 {
			if args[index] != "--id" || index+1 >= len(args) do return job_cli_usage_error()
			index += 1
			external_id = args[index]
		}
		if external_id == "" do external_id = fmt.tprintf("job-%d-%d", posix.getpid(), time.to_unix_nanoseconds(time.now()))
		_, report_error := jobs.report_start(path, token, reporter, external_id, label)
		if report_error != .None do return job_report_error(report_error)
		fmt.println(external_id)
		return 0
	case "progress":
		if len(args) < 4 do return job_cli_usage_error()
		external_id := args[1]
		percent := -1
		message := ""
		for index := 2; index < len(args); index += 1 {
			switch args[index] {
			case "--percent":
				if index+1 >= len(args) do return job_cli_usage_error()
				index += 1
				value, ok := strconv.parse_int(args[index])
				if !ok do return job_cli_usage_error()
				percent = value
			case "--message":
				if index+1 >= len(args) do return job_cli_usage_error()
				index += 1
				message = args[index]
			case: return job_cli_usage_error()
			}
		}
		report_error := jobs.report_progress(path, token, reporter, external_id, percent, message)
		if report_error != .None do return job_report_error(report_error)
		return 0
	case "finish", "fail":
		if len(args) < 2 do return job_cli_usage_error()
		external_id := args[1]
		exit_code := 0 if args[0] == "finish" else 1
		if len(args) > 2 {
			if len(args) != 4 || args[2] != "--exit-code" do return job_cli_usage_error()
			value, ok := strconv.parse_int(args[3])
			if !ok do return job_cli_usage_error()
			exit_code = value
		}
		report_error := jobs.report_finish(path, token, reporter, external_id, exit_code, args[0] == "fail")
		if report_error != .None do return job_report_error(report_error)
		return 0
	case: return job_cli_usage_error()
	}
}

job_run_command :: proc(args: []string, path, token: string, reporter: u64, reporting_available: bool) -> int {
	separator := -1
	for argument, index in args do if argument == "--" {separator = index; break}
	if separator != 1 || separator+1 >= len(args) do return job_cli_usage_error()
	label := args[0]
	external_id := fmt.tprintf("job-%d-%d", posix.getpid(), time.to_unix_nanoseconds(time.now()))
	command_args := args[separator+1:]
	command := make([]cstring, len(command_args)+1)
	for argument, index in command_args do command[index] = strings.clone_to_cstring(argument)
	if !reporting_available do fmt.eprintln("nare: no eligible terminal job reporting session; command will continue untracked")
	launch_pipe: [2]posix.FD
	if posix.pipe(&launch_pipe) != .OK {
		job_command_destroy(command, len(command_args))
		fmt.eprintln("nare: could not create background job supervisor")
		return 1
	}
	supervisor := posix.fork()
	if supervisor < 0 {
		_ = posix.close(launch_pipe[0])
		_ = posix.close(launch_pipe[1])
		job_command_destroy(command, len(command_args))
		fmt.eprintln("nare: could not start background job supervisor")
		return 1
	}
	if supervisor > 0 {
		_ = posix.close(launch_pipe[1])
		started: byte
		count: int
		for {
			count = int(posix.read(launch_pipe[0], &started, 1))
			if count < 0 && posix.errno() == .EINTR do continue
			break
		}
		_ = posix.close(launch_pipe[0])
		job_command_destroy(command, len(command_args))
		if count != 1 || started != 1 {
			fmt.eprintln("nare: could not start background job command")
			return 1
		}
		fmt.println(external_id)
		return 0
	}
	_ = posix.close(launch_pipe[0])
	if posix.setsid() < 0 || !job_detach_terminal_streams() {
		failed := byte(0)
		_ = posix.write(launch_pipe[1], &failed, 1)
		_ = posix.close(launch_pipe[1])
		posix._exit(1)
	}
	child := posix.fork()
	if child < 0 {
		failed := byte(0)
		_ = posix.write(launch_pipe[1], &failed, 1)
		_ = posix.close(launch_pipe[1])
		posix._exit(1)
	}
	if child == 0 {
		_ = posix.close(launch_pipe[1])
		_ = posix.execvp(command[0], raw_data(command))
		posix._exit(127)
	}
	started := byte(1)
	_ = posix.write(launch_pipe[1], &started, 1)
	_ = posix.close(launch_pipe[1])
	reported := false
	if reporting_available {
		_, report_error := jobs.report_start(path, token, reporter, external_id, label, int(child))
		reported = report_error == .None
	}
	status: c.int
	for {
		waited := posix.waitpid(child, &status, {})
		if waited == child do break
		if waited < 0 && posix.errno() == .EINTR do continue
		if reported do _ = jobs.report_finish(path, token, reporter, external_id, 1, true)
		posix._exit(1)
	}
	exit_code := 1
	term_signal := 0
	if posix.WIFEXITED(status) do exit_code = int(posix.WEXITSTATUS(status))
	else if posix.WIFSIGNALED(status) {
		term_signal = int(posix.WTERMSIG(status))
		exit_code = 128+term_signal
	}
	if reported do _ = jobs.report_finish(path, token, reporter, external_id, exit_code, exit_code != 0, term_signal)
	posix._exit(i32(exit_code))
}

job_command_destroy :: proc(command: []cstring, count: int) {
	for argument in command[:count] do delete(argument)
	delete(command)
}

job_detach_terminal_streams :: proc() -> bool {
	path := strings.clone_to_cstring("/dev/null", context.temp_allocator)
	devnull := posix.open(path, {.RDWR})
	if devnull < 0 do return false
	defer posix.close(devnull)
	for descriptor in 0..=2 {
		fd := posix.FD(descriptor)
		if posix.isatty(fd) && posix.dup2(devnull, fd) < 0 do return false
	}
	return true
}

job_reporting_environment :: proc() -> (path, token: string, reporter: u64, ok: bool) {
	path = os.get_env("NARE_JOB_SOCKET", context.temp_allocator)
	token = os.get_env("NARE_JOB_TOKEN", context.temp_allocator)
	reporter_text := os.get_env("NARE_JOB_REPORTER", context.temp_allocator)
	tmux_pane_text := os.get_env("TMUX_PANE", context.temp_allocator)
	if len(tmux_pane_text) > 1 && tmux_pane_text[0] == '%' {
		if value, found := job_tmux_environment("NARE_JOB_SOCKET"); found do path = value
		if value, found := job_tmux_environment("NARE_JOB_TOKEN"); found do token = value
		owner_text := os.get_env("NARE_JOB_TMUX_OWNER", context.temp_allocator)
		if value, found := job_tmux_environment("NARE_JOB_TMUX_OWNER"); found do owner_text = value
		if owner_text == "" do owner_text = reporter_text
		owner, owner_ok := strconv.parse_u64(owner_text)
		pane_id, pane_ok := strconv.parse_int(tmux_pane_text[1:])
		if owner_ok && pane_ok {
			reporter = jobs.tmux_reporter(owner, pane_id)
			ok = reporter != 0 && path != "" && token != ""
			return
		}
	}
	parsed_reporter, parsed := strconv.parse_u64(reporter_text)
	reporter = parsed_reporter
	ok = parsed && path != "" && token != "" && reporter != 0
	return
}

job_tmux_environment :: proc(name: string) -> (string, bool) {
	if os.get_env("TMUX", context.temp_allocator) == "" do return "", false
	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK do return "", false
	child := posix.fork()
	if child < 0 {
		_ = posix.close(pipe_fds[0])
		_ = posix.close(pipe_fds[1])
		return "", false
	}
	if child == 0 {
		_ = posix.close(pipe_fds[0])
		_ = posix.dup2(pipe_fds[1], 1)
		_ = posix.close(pipe_fds[1])
		devnull_path := strings.clone_to_cstring("/dev/null")
		devnull := posix.open(devnull_path, {.WRONLY, .CLOEXEC})
		if devnull >= 0 {
			_ = posix.dup2(devnull, 2)
			_ = posix.close(devnull)
		}
		command := [4]cstring{
			strings.clone_to_cstring("tmux"),
			strings.clone_to_cstring("show-environment"),
			strings.clone_to_cstring(name),
			nil,
		}
		_ = posix.execvp(command[0], raw_data(command[:]))
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
		return "", false
	}
	if !posix.WIFEXITED(status) || posix.WEXITSTATUS(status) != 0 do return "", false
	text := strings.trim_space(string(output[:used]))
	prefix := fmt.tprintf("%s=", name)
	if !strings.has_prefix(text, prefix) || len(text) <= len(prefix) do return "", false
	return strings.clone(text[len(prefix):], context.temp_allocator), true
}

job_report_error :: proc(report_error: jobs.Report_Error) -> int {
	fmt.eprintf("nare: %s\n", jobs.report_error_string(report_error))
	return 1
}

job_cli_usage_error :: proc() -> int {
	fmt.eprintln(job_cli_usage())
	return 2
}

job_cli_usage :: proc() -> string {
	return "usage: nare status job start LABEL [--id ID]\n" +
	       "       nare status job progress ID --percent N [--message TEXT]\n" +
	       "       nare status job finish ID [--exit-code N]\n" +
	       "       nare status job fail ID [--exit-code N]\n" +
	       "       nare job run LABEL -- COMMAND [ARG...]\n" +
	       "       nare job init zsh|fish"
}
