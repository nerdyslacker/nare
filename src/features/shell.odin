package features

import vt "../vt"

MAX_SHELL_OUTPUT_BYTES :: 16 * 1024 * 1024

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

shell_selected_output :: proc(state: ^Shell_State, screen: ^vt.Screen) -> (string, bool) {
	if !state.active || len(state.prompts) == 0 || state.from_latest >= len(state.prompts) do return "", false
	prompt_index := len(state.prompts)-1-state.from_latest
	prompt := state.prompts[prompt_index]
	limit := Source_Position{row = i32(vt.screen_source_row_count(screen)-1), column = i32(screen.columns)}
	if prompt_index+1 < len(state.prompts) do limit = state.prompts[prompt_index+1]
	output, output_found := Source_Position{}, false
	finished, finished_found := Source_Position{}, false
	for row in int(prompt.row)..=int(limit.row) {
		cells := vt.screen_source_row(screen, row)
		first_column := int(prompt.column) if row == int(prompt.row) else 0
		last_column := int(limit.column) if row == int(limit.row) else len(cells)
		for column in first_column..<last_column {
			cell := &cells[column]
			if !output_found && .Output in cell.shell_markers {
				output = {row = i32(row), column = i32(column)}
				output_found = true
			}
			if output_found && .Finished in cell.shell_markers {
				finished = {row = i32(row), column = i32(column)}
				finished_found = true
				break
			}
		}
		if finished_found do break
	}
	if !output_found do return "", false
	end := finished if finished_found else limit
	return vt.screen_extract_source(
		screen,
		{row = int(output.row), column = int(output.column)},
		{row = int(end.row), column = int(end.column)},
		MAX_SHELL_OUTPUT_BYTES,
	)
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
