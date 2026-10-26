package jobs

import "core:strings"
import "core:time"

MAX_TRACKED_JOBS :: 256

State :: enum { Running, Succeeded, Failed, Cancelled }

Job :: struct {
	id, owner: u64,
	label, rule_name: string,
	state: State,
	started, finished: time.Time,
	exit_code, signal: int,
}

Registry :: struct {
	jobs: [dynamic]Job,
	next_id: u64,
}

register :: proc(registry: ^Registry, owner: u64, label, rule_name: string) -> u64 {
	if registry == nil || owner == 0 || label == "" || rule_name == "" do return 0
	if len(registry.jobs) >= MAX_TRACKED_JOBS {
		removed := false
		for job, index in registry.jobs {
			if job.state == .Running do continue
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
		label = strings.clone(label),
		rule_name = strings.clone(rule_name),
		state = .Running,
		started = time.now(),
	})
	return registry.next_id
}

finish :: proc(registry: ^Registry, id: u64, exit_code, signal: int) {
	job := by_id(registry, id)
	if job == nil || job.state != .Running do return
	job.exit_code = exit_code
	job.signal = signal
	job.state = .Succeeded if exit_code == 0 && signal == 0 else .Failed
	job.finished = time.now()
}

cancel :: proc(registry: ^Registry, id: u64) {
	job := by_id(registry, id)
	if job == nil || job.state != .Running do return
	job.state = .Cancelled
	job.finished = time.now()
}

by_id :: proc(registry: ^Registry, id: u64) -> ^Job {
	if registry == nil || id == 0 do return nil
	for &job in registry.jobs do if job.id == id do return &job
	return nil
}

destroy_job :: proc(job: ^Job) {
	delete(job.label)
	delete(job.rule_name)
	job^ = {}
}

destroy :: proc(registry: ^Registry) {
	if registry == nil do return
	for &job in registry.jobs do destroy_job(&job)
	delete(registry.jobs)
	registry^ = {}
}
