package render

import "core:math"
import "core:time"
import vt "../vt"
import x11 "../x11"

CURSOR_TRAIL_FRAME_MS :: 8
CURSOR_TRAIL_SLICE_HEIGHT :: 1
CURSOR_TRAIL_DECAY_FACTOR :: 6.9314718

Cursor_Trail_Rect :: struct {
	left, top, right, bottom: f32,
}

Cursor_Trail_Point :: struct {
	x, y: f32,
}

Cursor_Trail :: struct {
	enabled: bool,
	delay_ms, decay_fast_ms, decay_slow_ms, threshold: int,
	initialized, pending, active: bool,
	observed, target: Cursor_Trail_Rect,
	corners: [4]Cursor_Trail_Point,
	observed_at, updated_at: time.Tick,
	cursor_context_generation: u64,
	previous_bounds: Cursor_Trail_Rect,
	previous_bounds_valid: bool,
}

cursor_trail_configure :: proc(trail: ^Cursor_Trail, enabled: bool, delay_ms, decay_fast_ms, decay_slow_ms, threshold: int) {
	trail.enabled = enabled
	trail.delay_ms = delay_ms
	trail.decay_fast_ms = decay_fast_ms
	trail.decay_slow_ms = decay_slow_ms
	trail.threshold = threshold
	if !enabled {
		trail.pending = false
		trail.active = false
	}
}

cursor_trail_rect :: proc(window: ^x11.Window, terminal: ^vt.Terminal, screen: ^vt.Screen) -> Cursor_Trail_Rect {
	left := f32(screen.cursor.column*window.cell_w)
	top := f32(screen.cursor.row*window.cell_h)
	width, height := window.cell_w, window.cell_h
	style := terminal.modes.cursor_style
	if style == .Blinking_Bar || style == .Steady_Bar {
		width = clamp(terminal.cursor_beam_width, 1, window.cell_w)
	} else if style == .Blinking_Underline || style == .Steady_Underline {
		height = clamp(terminal.cursor_underline_height, 1, window.cell_h)
		top += f32(window.cell_h-height)
	}
	return {left = left, top = top, right = left+f32(width), bottom = top+f32(height)}
}

cursor_trail_set_corners :: proc(trail: ^Cursor_Trail, rect: Cursor_Trail_Rect) {
	trail.corners = {
		{x = rect.right, y = rect.top},
		{x = rect.right, y = rect.bottom},
		{x = rect.left, y = rect.bottom},
		{x = rect.left, y = rect.top},
	}
}

cursor_trail_bounds :: proc(trail: ^Cursor_Trail) -> Cursor_Trail_Rect {
	bounds := Cursor_Trail_Rect{
		left = trail.corners[0].x, top = trail.corners[0].y,
		right = trail.corners[0].x, bottom = trail.corners[0].y,
	}
	for corner in trail.corners[1:] {
		bounds.left = min(bounds.left, corner.x)
		bounds.top = min(bounds.top, corner.y)
		bounds.right = max(bounds.right, corner.x)
		bounds.bottom = max(bounds.bottom, corner.y)
	}
	return bounds
}

cursor_trail_snap :: proc(trail: ^Cursor_Trail, rect: Cursor_Trail_Rect, now: time.Tick, generation: u64) {
	if trail.active {
		trail.previous_bounds = cursor_trail_bounds(trail)
		trail.previous_bounds_valid = true
	}
	trail.observed = rect
	trail.target = rect
	cursor_trail_set_corners(trail, rect)
	trail.initialized = true
	trail.pending = false
	trail.active = false
	trail.observed_at = now
	trail.updated_at = now
	trail.cursor_context_generation = generation
}

cursor_trail_target_corners :: proc(rect: Cursor_Trail_Rect) -> [4]Cursor_Trail_Point {
	return {
		{x = rect.right, y = rect.top},
		{x = rect.right, y = rect.bottom},
		{x = rect.left, y = rect.bottom},
		{x = rect.left, y = rect.top},
	}
}

cursor_trail_advance :: proc(trail: ^Cursor_Trail, elapsed_ms: f32) {
	target := cursor_trail_target_corners(trail.target)
	center := Cursor_Trail_Point{
		x = (trail.target.left+trail.target.right)*0.5,
		y = (trail.target.top+trail.target.bottom)*0.5,
	}
	diagonal := math.sqrt((trail.target.right-trail.target.left)*(trail.target.right-trail.target.left)+
	                      (trail.target.bottom-trail.target.top)*(trail.target.bottom-trail.target.top))*0.5
	if diagonal < 0.5 do diagonal = 0.5
	dots: [4]f32
	minimum, maximum := f32(1e30), f32(-1e30)
	for index in 0..<4 {
		dx := target[index].x-trail.corners[index].x
		dy := target[index].y-trail.corners[index].y
		distance := math.sqrt(dx*dx+dy*dy)
		if distance < 0.001 {
			dots[index] = 0
			continue
		}
		dots[index] = (dx*(target[index].x-center.x)+dy*(target[index].y-center.y))/(diagonal*distance)
	}
	for dot in dots {
		minimum = min(minimum, dot)
		maximum = max(maximum, dot)
	}
	for index in 0..<4 {
		dx := target[index].x-trail.corners[index].x
		dy := target[index].y-trail.corners[index].y
		if abs(dx) < 0.001 && abs(dy) < 0.001 do continue
		decay := f32(trail.decay_slow_ms)
		if maximum > minimum {
			decay += f32(trail.decay_fast_ms-trail.decay_slow_ms)*(dots[index]-minimum)/(maximum-minimum)
		}
		step := 1-math.exp(-CURSOR_TRAIL_DECAY_FACTOR*elapsed_ms/max(1, decay))
		trail.corners[index].x += dx*step
		trail.corners[index].y += dy*step
	}
}

cursor_trail_update :: proc(
	trail: ^Cursor_Trail,
	window: ^x11.Window,
	terminal: ^vt.Terminal,
	screen: ^vt.Screen,
	suppressed: bool,
) {
	if trail == nil || window == nil || terminal == nil || screen == nil do return
	now := time.tick_now()
	rect := cursor_trail_rect(window, terminal, screen)
	if !trail.enabled || suppressed || !terminal.modes.cursor_visible ||
	   trail.cursor_context_generation != terminal.cursor_context_generation {
		cursor_trail_snap(trail, rect, now, terminal.cursor_context_generation)
		return
	}
	if !trail.initialized {
		cursor_trail_snap(trail, rect, now, terminal.cursor_context_generation)
		return
	}
	if trail.observed != rect {
		if trail.observed.right-trail.observed.left != rect.right-rect.left ||
		   trail.observed.bottom-trail.observed.top != rect.bottom-rect.top {
			cursor_trail_snap(trail, rect, now, terminal.cursor_context_generation)
			return
		}
		trail.observed = rect
		trail.observed_at = now
		trail.pending = true
	}

	started := false
	if trail.pending && time.tick_since(trail.observed_at) >= time.Duration(trail.delay_ms)*time.Millisecond {
		trail.pending = false
		dx := abs(int((trail.observed.left-trail.target.left)/f32(max(1, window.cell_w))))
		dy := abs(int((trail.observed.top-trail.target.top)/f32(max(1, window.cell_h))))
		if !trail.active && dx <= trail.threshold && dy <= trail.threshold {
			cursor_trail_snap(trail, trail.observed, now, terminal.cursor_context_generation)
			return
		}
		trail.target = trail.observed
		trail.active = true
		started = true
	}
	if !trail.active do return

	trail.previous_bounds = cursor_trail_bounds(trail)
	trail.previous_bounds_valid = true
	elapsed_ms := f32(time.tick_since(trail.updated_at))/f32(time.Millisecond)
	if started do elapsed_ms = 0
	cursor_trail_advance(trail, min(elapsed_ms, 50))
	trail.updated_at = now
	target := cursor_trail_target_corners(trail.target)
	trail.active = false
	for index in 0..<4 {
		if abs(target[index].x-trail.corners[index].x) >= 0.5 || abs(target[index].y-trail.corners[index].y) >= 0.5 {
			trail.active = true
			break
		}
	}
	if !trail.active do cursor_trail_set_corners(trail, trail.target)
}

cursor_trail_state_timeout_ms :: proc(trail: ^Cursor_Trail) -> int {
	if trail == nil || !trail.enabled || !trail.initialized do return -1
	if trail.pending {
		remaining := time.Duration(trail.delay_ms)*time.Millisecond-time.tick_since(trail.observed_at)
		if remaining <= 0 do return 0
		return max(1, int((remaining+time.Millisecond-time.Nanosecond)/time.Millisecond))
	}
	if trail.active {
		remaining := CURSOR_TRAIL_FRAME_MS*time.Millisecond-time.tick_since(trail.updated_at)
		if remaining <= 0 do return 0
		return max(1, int((remaining+time.Millisecond-time.Nanosecond)/time.Millisecond))
	}
	return -1
}

cursor_trail_row_damaged :: proc(trail: ^Cursor_Trail, row, cell_height: int) -> bool {
	if trail == nil do return false
	top, bottom := f32(row*cell_height), f32((row+1)*cell_height)
	if trail.previous_bounds_valid && trail.previous_bounds.bottom > top && trail.previous_bounds.top < bottom do return true
	if trail.active {
		bounds := cursor_trail_bounds(trail)
		return bounds.bottom > top && bounds.top < bottom
	}
	return false
}

cursor_trail_segment :: proc(trail: ^Cursor_Trail, y: f32) -> (left, right: f32, ok: bool) {
	left, right = f32(1e30), f32(-1e30)
	for index in 0..<4 {
		first := trail.corners[index]
		second := trail.corners[(index+1)%4]
		low, high := min(first.y, second.y), max(first.y, second.y)
		if y < low || y > high do continue
		x := first.x
		if high-low > 0.001 do x += (second.x-first.x)*(y-first.y)/(second.y-first.y)
		left, right = min(left, x), max(right, x)
		ok = true
	}
	return
}

append_cursor_trail_commands :: proc(output: ^[dynamic]Command, trail: ^Cursor_Trail, row, cell_height: int, color: u32) {
	if trail == nil || !trail.active do return
	// shortcut: rasterize the quad into pixel rows; add polygon commands if profiling shows this path is too costly.
	bounds := cursor_trail_bounds(trail)
	row_top, row_bottom := row*cell_height, (row+1)*cell_height
	top := max(row_top, int(bounds.top))
	bottom := min(row_bottom, int(bounds.bottom+0.999))
	for y := top; y < bottom; y += CURSOR_TRAIL_SLICE_HEIGHT {
		height := min(CURSOR_TRAIL_SLICE_HEIGHT, bottom-y)
		left_f, right_f, ok := cursor_trail_segment(trail, f32(y)+f32(height)*0.5)
		if !ok do continue
		left, right := int(left_f), int(right_f+0.999)
		if right <= left do continue
		if f32(y+height) > trail.target.top && f32(y) < trail.target.bottom {
			target_left, target_right := int(trail.target.left), int(trail.target.right+0.999)
			if left < target_left do append_rectangle(output, left, y, min(right, target_left)-left, height, color)
			if right > target_right do append_rectangle(output, max(left, target_right), y, right-max(left, target_right), height, color)
		} else {
			append_rectangle(output, left, y, right-left, height, color)
		}
	}
}
