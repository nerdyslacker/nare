package features

import vt "../vt"

Shell_State :: struct {
	active: bool,
	from_latest: int,
	prompts: [dynamic]Source_Position,
	view: vt.Screen,
}

shell_destroy :: proc(state: ^Shell_State) {
	delete(state.prompts)
	delete(state.view.cells)
	delete(state.view.wrapped)
	state^ = {}
}

shell_close :: proc(state: ^Shell_State) {
	state.active = false
	state.from_latest = 0
}

shell_previous :: proc(state: ^Shell_State, screen: ^vt.Screen) {
	was_active := state.active
	state.active = true
	shell_collect_prompts(state, screen)
	if len(state.prompts) == 0 {
		state.active = false
		return
	}
	if was_active || len(state.prompts) > 1 do state.from_latest = min(state.from_latest+1, len(state.prompts)-1)
	shell_build_view(state, screen)
}

shell_next :: proc(state: ^Shell_State, screen: ^vt.Screen) {
	if !state.active do return
	shell_collect_prompts(state, screen)
	if len(state.prompts) == 0 {
		state.active = false
		return
	}
	if state.from_latest == 0 {
		state.active = false
		return
	}
	state.from_latest -= 1
	shell_build_view(state, screen)
}

shell_refresh :: proc(state: ^Shell_State, screen: ^vt.Screen) {
	if !state.active do return
	shell_collect_prompts(state, screen)
	if len(state.prompts) == 0 {
		state.active = false
		return
	}
	state.from_latest = min(state.from_latest, len(state.prompts)-1)
	shell_build_view(state, screen)
}

shell_view_screen :: proc(state: ^Shell_State) -> ^vt.Screen {
	if !state.active do return nil
	return &state.view
}

shell_collect_prompts :: proc(state: ^Shell_State, screen: ^vt.Screen) {
	clear(&state.prompts)
	for row in 0..<vt.screen_source_row_count(screen) {
		cells := vt.screen_source_row(screen, row)
		for column in 0..<len(cells) {
			if .Prompt in cells[column].shell_markers {
				append(&state.prompts, Source_Position{row = i32(row), column = i32(column)})
			}
		}
	}
}

shell_build_view :: proc(state: ^Shell_State, screen: ^vt.Screen) {
	cell_count := screen.columns*screen.rows
	if len(state.view.cells) != cell_count {
		delete(state.view.cells)
		state.view.cells = make([]vt.Cell, cell_count)
	}
	if len(state.view.wrapped) != screen.rows {
		delete(state.view.wrapped)
		state.view.wrapped = make([]bool, screen.rows)
	}
	state.view.columns = screen.columns
	state.view.rows = screen.rows
	state.view.cursor = {row = -1, column = -1}
	state.view.scroll_bottom = screen.rows-1
	blank := vt.blank_cell({})
	for &cell in state.view.cells do cell = blank
	for &wrapped in state.view.wrapped do wrapped = false

	total_rows := vt.screen_source_row_count(screen)
	prompt := state.prompts[len(state.prompts)-1-state.from_latest]
	start_row := clamp(int(prompt.row), 0, max(0, total_rows-screen.rows))
	for view_row in 0..<screen.rows {
		source_row := start_row+view_row
		if source_row >= total_rows do break
		copy(
			state.view.cells[view_row*screen.columns:(view_row+1)*screen.columns],
			vt.screen_source_row(screen, source_row),
		)
		state.view.wrapped[view_row] = vt.screen_source_wrapped(screen, source_row)
	}
}
