package features

import vt "../vt"

Scrollback_State :: struct {
	active: bool,
	offset: int,
	history_rows: int,
	view: vt.Screen,
}

scrollback_destroy :: proc(state: ^Scrollback_State) {
	delete(state.view.cells)
	delete(state.view.wrapped)
	state^ = {}
}

scrollback_close :: proc(state: ^Scrollback_State) {
	state.active = false
	state.offset = 0
}

scrollback_scroll :: proc(state: ^Scrollback_State, screen: ^vt.Screen, rows: int) {
	scrollback_set_offset(state, screen, state.offset+rows)
}

scrollback_set_offset :: proc(state: ^Scrollback_State, screen: ^vt.Screen, offset: int) {
	state.history_rows = len(screen.scrollback)
	state.offset = clamp(offset, 0, len(screen.scrollback))
	state.active = state.offset > 0
	if state.active do build_scrollback_view(state, screen)
}

scrollback_refresh :: proc(state: ^Scrollback_State, screen: ^vt.Screen) {
	current_history := len(screen.scrollback)
	if state.active && current_history > state.history_rows {
		state.offset = min(current_history, state.offset+current_history-state.history_rows)
	}
	state.history_rows = current_history
	state.offset = clamp(state.offset, 0, current_history)
	state.active = state.offset > 0
	if state.active do build_scrollback_view(state, screen)
}

scrollback_view_screen :: proc(state: ^Scrollback_State) -> ^vt.Screen {
	if state == nil || !state.active do return nil
	return &state.view
}

build_scrollback_view :: proc(state: ^Scrollback_State, screen: ^vt.Screen) {
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
	state.view.image_registry = screen.image_registry
	state.view.image_screen = screen.image_screen
	state.view.image_row_offset = state.offset
	blank := vt.blank_cell({})
	for &cell in state.view.cells do cell = blank
	for &wrapped in state.view.wrapped do wrapped = false

	start_row := max(0, len(screen.scrollback)-state.offset)
	for view_row in 0..<screen.rows {
		source_row := start_row+view_row
		if source_row >= vt.screen_source_row_count(screen) do break
		copy(
			state.view.cells[view_row*screen.columns:(view_row+1)*screen.columns],
			vt.screen_source_row(screen, source_row),
		)
		state.view.wrapped[view_row] = vt.screen_source_wrapped(screen, source_row)
	}
}
