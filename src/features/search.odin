package features

import "core:unicode/utf8"
import selection "../selection"
import vt "../vt"

MAX_SEARCH_BYTES :: 1024

Source_Position :: struct {
	row, column: i32,
}

Match :: struct {
	first, last: Source_Position,
}

State :: struct {
	active: bool,
	query: [dynamic]byte,
	matches: [dynamic]Match,
	current: int,
	view: vt.Screen,
	highlight: selection.State,
}

destroy :: proc(state: ^State) {
	delete(state.query)
	delete(state.matches)
	delete(state.view.cells)
	delete(state.view.wrapped)
	state^ = {}
}

open :: proc(state: ^State, screen: ^vt.Screen) {
	state.active = true
	clear(&state.query)
	state.current = 0
	refresh(state, screen)
}

close :: proc(state: ^State) {
	delete(state.query)
	delete(state.matches)
	delete(state.view.cells)
	delete(state.view.wrapped)
	state^ = {}
}

append_query :: proc(state: ^State, screen: ^vt.Screen, data: []byte) {
	if !state.active || len(data) == 0 || len(state.query)+len(data) > MAX_SEARCH_BYTES do return
	append(&state.query, ..data)
	state.current = 0
	refresh(state, screen)
}

backspace :: proc(state: ^State, screen: ^vt.Screen) {
	if !state.active || len(state.query) == 0 do return
	_, size := utf8.decode_last_rune(state.query[:])
	if size <= 0 do size = 1
	resize(&state.query, len(state.query)-size)
	state.current = 0
	refresh(state, screen)
}

next :: proc(state: ^State, screen: ^vt.Screen) {
	if len(state.matches) == 0 do return
	state.current = (state.current+1)%len(state.matches)
	build_view(state, screen)
}

previous :: proc(state: ^State, screen: ^vt.Screen) {
	if len(state.matches) == 0 do return
	state.current = (state.current+len(state.matches)-1)%len(state.matches)
	build_view(state, screen)
}

refresh :: proc(state: ^State, screen: ^vt.Screen) {
	clear(&state.matches)
	if len(state.query) > 0 do find_matches(state, screen)
	if state.current >= len(state.matches) do state.current = 0
	build_view(state, screen)
}

query_text :: proc(state: ^State) -> string {
	return string(state.query[:])
}

view_screen :: proc(state: ^State) -> ^vt.Screen {
	if !state.active do return nil
	return &state.view
}

find_matches :: proc(state: ^State, screen: ^vt.Screen) {
	query: [dynamic]rune
	defer delete(query)
	for offset := 0; offset < len(state.query); {
		value, size := utf8.decode_rune(state.query[offset:])
		if size <= 0 do size = 1
		append(&query, value)
		offset += size
	}
	if len(query) == 0 do return

	text: [dynamic]rune
	positions: [dynamic]Source_Position
	defer delete(text)
	defer delete(positions)
	for source_row in 0..<vt.screen_source_row_count(screen) {
		row := vt.screen_source_row(screen, source_row)
		content_length := vt.row_content_length(row)
		for column in 0..<content_length {
			cell := &row[column]
			if cell.continuation do continue
			position := Source_Position{row = i32(source_row), column = i32(column)}
			append(&text, cell.codepoint)
			append(&positions, position)
			for index in 0..<int(cell.combining_count) {
				append(&text, cell.combining[index])
				append(&positions, position)
			}
		}
		if source_row+1 < vt.screen_source_row_count(screen) && !vt.screen_source_wrapped(screen, source_row) {
			append(&text, '\n')
			append(&positions, Source_Position{row = i32(source_row), column = i32(max(0, content_length-1))})
		}
	}

	for index := 0; index+len(query) <= len(text); index += 1 {
		matched := true
		for query_index in 0..<len(query) {
			if text[index+query_index] != query[query_index] {
				matched = false
				break
			}
		}
		if matched {
			append(&state.matches, Match{first = positions[index], last = positions[index+len(query)-1]})
		}
	}
}

build_view :: proc(state: ^State, screen: ^vt.Screen) {
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
	start_row := max(0, total_rows-screen.rows)
	if len(state.matches) > 0 {
		match := state.matches[state.current]
		start_row = clamp(int(match.first.row)-screen.rows/2, 0, max(0, total_rows-screen.rows))
		if int(match.last.row) >= start_row+screen.rows {
			start_row = clamp(int(match.last.row)-screen.rows+1, 0, max(0, total_rows-screen.rows))
		}
	}
	for view_row in 0..<screen.rows {
		source_row := start_row+view_row
		if source_row >= total_rows do break
		copy(
			state.view.cells[view_row*screen.columns:(view_row+1)*screen.columns],
			vt.screen_source_row(screen, source_row),
		)
		state.view.wrapped[view_row] = vt.screen_source_wrapped(screen, source_row)
	}

	selection.clear(&state.highlight)
	if len(state.matches) == 0 do return
	match := state.matches[state.current]
	first_row := int(match.first.row)-start_row
	last_row := int(match.last.row)-start_row
	if first_row < 0 || last_row >= screen.rows do return
	selection.begin(&state.highlight, &state.view, {row = first_row, column = int(match.first.column)})
	selection.finish(&state.highlight, &state.view, {row = last_row, column = int(match.last.column)})
}
