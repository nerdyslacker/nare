package features

import "core:strings"
import "core:unicode"
import vt "../vt"

MAX_URL_HINTS :: 26
MAX_URL_RUNES :: 2048

URL :: struct {
	text: string,
	first, last: Source_Position,
	hint: byte,
}

URL_State :: struct {
	active: bool,
	links: [dynamic]URL,
	view: vt.Screen,
}

url_destroy :: proc(state: ^URL_State) {
	url_clear_links(state)
	delete(state.links)
	delete(state.view.cells)
	delete(state.view.wrapped)
	state^ = {}
}

url_open :: proc(state: ^URL_State, screen: ^vt.Screen) {
	state.active = true
	url_refresh(state, screen)
}

url_close :: proc(state: ^URL_State) {
	url_destroy(state)
}

url_refresh :: proc(state: ^URL_State, screen: ^vt.Screen) {
	url_clear_links(state)
	detect_urls(state, screen)
	build_url_view(state, screen)
}

url_for_hint :: proc(state: ^URL_State, hint: byte) -> string {
	normalized := hint
	if normalized >= 'A' && normalized <= 'Z' do normalized += 'a'-'A'
	for &link in state.links {
		if link.hint == normalized do return link.text
	}
	return ""
}

url_view_screen :: proc(state: ^URL_State) -> ^vt.Screen {
	if !state.active do return nil
	return &state.view
}

url_clear_links :: proc(state: ^URL_State) {
	for &link in state.links do delete(link.text)
	clear(&state.links)
}

detect_urls :: proc(state: ^URL_State, screen: ^vt.Screen) {
	text: [dynamic]rune
	positions: [dynamic]Source_Position
	defer delete(text)
	defer delete(positions)
	total_rows := vt.screen_source_row_count(screen)
	first_source_row := max(0, total_rows-screen.rows)
	for source_row in first_source_row..<total_rows {
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
		if source_row+1 < total_rows && !vt.screen_source_wrapped(screen, source_row) {
			append(&text, '\n')
			append(&positions, Source_Position{row = i32(source_row), column = i32(max(0, content_length-1))})
		}
	}

	for index := 0; index < len(text) && len(state.links) < MAX_URL_HINTS; {
		prefix_length := url_prefix_length(text[:], index)
		if prefix_length == 0 {
			index += 1
			continue
		}
		end := index+prefix_length
		for end < len(text) && end-index < MAX_URL_RUNES && !url_terminator(text[end]) do end += 1
		for end > index+prefix_length && trailing_url_punctuation(text[end-1]) do end -= 1
		if end > index+prefix_length {
			bytes: [dynamic]byte
			for value in text[index:end] do vt.append_rune(&bytes, value)
			append(&state.links, URL{
				text = strings.clone(string(bytes[:])),
				first = positions[index],
				last = positions[end-1],
				hint = 'a'+byte(len(state.links)),
			})
			delete(bytes)
		}
		index = max(index+1, end)
	}
}

url_prefix_length :: proc(text: []rune, index: int) -> int {
	http := []rune{'h', 't', 't', 'p', ':', '/', '/'}
	https := []rune{'h', 't', 't', 'p', 's', ':', '/', '/'}
	if runes_at(text, index, https) do return len(https)
	if runes_at(text, index, http) do return len(http)
	return 0
}

runes_at :: proc(text: []rune, index: int, value: []rune) -> bool {
	if index < 0 || index+len(value) > len(text) do return false
	for offset in 0..<len(value) {
		if text[index+offset] != value[offset] do return false
	}
	return true
}

url_terminator :: proc(value: rune) -> bool {
	return unicode.is_space(value) || value < 0x20 || value == '<' || value == '>' || value == '"' || value == '\'' || value == '`'
}

trailing_url_punctuation :: proc(value: rune) -> bool {
	switch value {
	case '.', ',', ';', ':', '!', '?', ')', ']', '}': return true
	case: return false
	}
}

build_url_view :: proc(state: ^URL_State, screen: ^vt.Screen) {
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
	total_rows := vt.screen_source_row_count(screen)
	first_source_row := max(0, total_rows-screen.rows)
	for view_row in 0..<screen.rows {
		source_row := first_source_row+view_row
		copy(
			state.view.cells[view_row*screen.columns:(view_row+1)*screen.columns],
			vt.screen_source_row(screen, source_row),
		)
		state.view.wrapped[view_row] = vt.screen_source_wrapped(screen, source_row)
	}
	for &link in state.links {
		first_row := int(link.first.row)-first_source_row
		last_row := int(link.last.row)-first_source_row
		for row in first_row..=last_row {
			first_column := int(link.first.column) if row == first_row else 0
			last_column := int(link.last.column) if row == last_row else screen.columns-1
			for column in first_column..=last_column {
				cell := vt.cell_at(&state.view, row, column)
				if !cell.continuation do cell.attributes.underline = true
			}
		}
		hint_cell := vt.cell_at(&state.view, first_row, int(link.first.column))
		hint_cell.codepoint = rune(link.hint)
		hint_cell.combining_count = 0
		hint_cell.width = 1
		hint_cell.continuation = false
		hint_cell.attributes.inverse = !hint_cell.attributes.inverse
		hint_cell.attributes.bold = true
	}
}
