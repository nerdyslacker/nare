package jobs

import "core:strings"
import "core:time"

MAX_TRACKED_JOBS :: 256
MAX_LABEL_BYTES :: 128
MAX_MESSAGE_BYTES :: 256
MAX_EXTERNAL_ID_BYTES :: 128
TMUX_REPORTER_FLAG :: u64(1)<<63

State :: enum { Starting, Running, Succeeded, Failed, Cancelled, Unknown }
Source :: enum { Nare_Launch, External_Reporter, Shell_Integration }

Owner :: struct {
	window, tab, pane: u64,
}

tmux_reporter :: proc(owner: u64, pane_id: int) -> u64 {
	if owner == 0 || owner > u64(max(u32)) || pane_id < 0 || pane_id > int(max(i32)) do return 0
	return TMUX_REPORTER_FLAG | owner<<31 | u64(pane_id)
}

tmux_reporter_identity :: proc(reporter: u64) -> (owner: u64, pane_id: int, ok: bool) {
	if reporter & TMUX_REPORTER_FLAG == 0 do return
	owner = (reporter & ~TMUX_REPORTER_FLAG)>>31
	pane_id = int(reporter & u64(max(i32)))
	ok = owner != 0
	return
}

Job :: struct {
	id: u64,
	owner: Owner,
	source: Source,
	label, rule_name: string,
	message: string,
	state: State,
	started, finished: time.Time,
	pid, exit_code, signal, progress: int,
	reporter: u64,
	external_id: string,
}

register_reported :: proc(registry: ^Registry, owner: Owner, reporter: u64, external_id, label: string, pid: int = 0) -> u64 {
	if reporter == 0 || external_id == "" || len(external_id) > MAX_EXTERNAL_ID_BYTES ||
	   by_reporter_id(registry, reporter, external_id) != nil {
		return 0
	}
	id := register(registry, .External_Reporter, owner, label, "", pid)
	job := by_id(registry, id)
	if job == nil do return 0
	job.reporter = reporter
	job.external_id = strings.clone(external_id)
	return id
}

by_reporter_id :: proc(registry: ^Registry, reporter: u64, external_id: string) -> ^Job {
	if registry == nil || reporter == 0 || external_id == "" do return nil
	for &job in registry.jobs do if job.reporter == reporter && job.external_id == external_id do return &job
	return nil
}

Registry :: struct {
	jobs: [dynamic]Job,
	next_id: u64,
	revision: u64,
}

register :: proc(registry: ^Registry, source: Source, owner: Owner, label, rule_name: string, pid: int = 0, starting: bool = false) -> u64 {
	if registry == nil || owner.window == 0 || owner.pane == 0 || label == "" || len(label) > MAX_LABEL_BYTES || len(rule_name) > MAX_LABEL_BYTES || pid < 0 do return 0
	if len(registry.jobs) >= MAX_TRACKED_JOBS {
		removed := false
		for job, index in registry.jobs {
			if job.state == .Running || job.state == .Starting do continue
			destroy_job(&registry.jobs[index])
			ordered_remove(&registry.jobs, index)
			removed = true
			break
		}
		if !removed do return 0
	}
	registry.next_id += 1
	if registry.next_id == 0 do registry.next_id = 1
	append(&registry.jobs, Job{
		id = registry.next_id,
		owner = owner,
		source = source,
		label = strings.clone(label),
		rule_name = strings.clone(rule_name),
		state = .Starting if starting else .Running,
		started = time.now(),
		pid = pid,
		progress = -1,
	})
	registry.revision += 1
	return registry.next_id
}

finish :: proc(registry: ^Registry, id: u64, exit_code, signal: int) {
	job := by_id(registry, id)
	if job == nil || (job.state != .Running && job.state != .Starting) do return
	job.exit_code = exit_code
	job.signal = signal
	job.state = .Succeeded if exit_code == 0 && signal == 0 else .Failed
	job.finished = time.now()
	registry.revision += 1
}

cancel :: proc(registry: ^Registry, id: u64) {
	job := by_id(registry, id)
	if job == nil || (job.state != .Running && job.state != .Starting) do return
	job.state = .Cancelled
	job.finished = time.now()
	registry.revision += 1
}

mark_running :: proc(registry: ^Registry, id: u64, pid: int = 0) -> bool {
	job := by_id(registry, id)
	if job == nil || job.state != .Starting || pid < 0 do return false
	job.state = .Running
	if pid > 0 do job.pid = pid
	registry.revision += 1
	return true
}

set_progress :: proc(registry: ^Registry, id: u64, percent: int, message: string = "") -> bool {
	job := by_id(registry, id)
	if job == nil || (job.state != .Running && job.state != .Starting) || percent < 0 || percent > 100 || len(message) > MAX_MESSAGE_BYTES do return false
	job.progress = percent
	replace_string(&job.message, message)
	registry.revision += 1
	return true
}

mark_unknown :: proc(registry: ^Registry, id: u64, message: string = "") -> bool {
	job := by_id(registry, id)
	if job == nil || (job.state != .Running && job.state != .Starting) || len(message) > MAX_MESSAGE_BYTES do return false
	job.state = .Unknown
	job.finished = time.now()
	replace_string(&job.message, message)
	registry.revision += 1
	return true
}

owner_lost :: proc(registry: ^Registry, pane: u64, message: string = "owning pane closed") {
	if registry == nil || pane == 0 do return
	for &job in registry.jobs do if job.owner.pane == pane && job.source != .Nare_Launch {
		_ = mark_unknown(registry, job.id, message)
	}
}

prune :: proc(registry: ^Registry, completed_timeout, failed_timeout: time.Duration) -> int {
	if registry == nil do return 0
	removed := 0
	for index := len(registry.jobs)-1; index >= 0; index -= 1 {
		job := &registry.jobs[index]
		timeout := completed_timeout
		if job.state == .Failed || job.state == .Unknown do timeout = failed_timeout
		if job.state == .Running || job.state == .Starting || timeout < 0 || time.since(job.finished) < timeout do continue
		destroy_job(job)
		ordered_remove(&registry.jobs, index)
		removed += 1
	}
	if removed > 0 do registry.revision += 1
	return removed
}

elapsed :: proc(job: ^Job) -> time.Duration {
	if job == nil do return 0
	if job.state == .Running || job.state == .Starting do return time.since(job.started)
	return max(time.Duration(0), time.diff(job.started, job.finished))
}

by_id :: proc(registry: ^Registry, id: u64) -> ^Job {
	if registry == nil || id == 0 do return nil
	for &job in registry.jobs do if job.id == id do return &job
	return nil
}

destroy_job :: proc(job: ^Job) {
	delete(job.label)
	delete(job.rule_name)
	delete(job.message)
	delete(job.external_id)
	job^ = {}
}

replace_string :: proc(target: ^string, value: string) {
	replacement := strings.clone(value)
	delete(target^)
	target^ = replacement
}

destroy :: proc(registry: ^Registry) {
	if registry == nil do return
	for &job in registry.jobs do destroy_job(&job)
	delete(registry.jobs)
	registry^ = {}
}
