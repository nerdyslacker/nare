package features

import "core:strings"
import "core:unicode"
import vt "../vt"

MAX_URL_HINTS :: 26
MAX_URL_RUNES :: 2048
URL_PREFIXES := [?]string{
	"https://", "http://", "file:", "ssh:", "mailto:", "magnet:", "ipfs://", "ipns:",
	"gemini://", "gopher://", "git://", "news:", "ftp://", "tel:",
}

URL :: struct {
	text: string,
	first, last: Source_Position,
	hint: byte,
	hyperlink_id: u32,
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

url_open :: proc(state: ^URL_State, terminal: ^vt.Terminal) {
	state.active = true
	url_refresh(state, terminal)
}

url_close :: proc(state: ^URL_State) {
	url_destroy(state)
}

url_refresh :: proc(state: ^URL_State, terminal: ^vt.Terminal) {
	url_clear_links(state)
	screen := vt.terminal_screen(terminal)
	detect_urls(state, terminal, screen)
	build_url_view(state, screen)
}

url_highlight :: proc(state: ^URL_State, terminal: ^vt.Terminal, screen: ^vt.Screen, row, column: int) -> bool {
	url_clear_links(state)
	detect_urls(state, terminal, screen)
	if len(state.links) == 0 {
		url_close(state)
		return false
	}
	hovered := url_link_at_cell(state, screen, row, column)
	if hovered < 0 {
		url_close(state)
		return false
	}
	state.active = true
	build_url_view(state, screen, false, hovered)
	return true
}

url_for_hint :: proc(state: ^URL_State, hint: byte) -> string {
	normalized := hint
	if normalized >= 'A' && normalized <= 'Z' do normalized += 'a'-'A'
	for &link in state.links {
		if link.hint == normalized do return link.text
	}
	return ""
}

url_at_cell :: proc(terminal: ^vt.Terminal, screen: ^vt.Screen, row, column: int) -> string {
	if terminal == nil || screen == nil || row < 0 || row >= screen.rows || column < 0 || column >= screen.columns do return ""
	state: URL_State
	defer url_destroy(&state)
	detect_urls(&state, terminal, screen)
	index := url_link_at_cell(&state, screen, row, column)
	if index >= 0 do return strings.clone(state.links[index].text)
	return ""
}

url_link_at_cell :: proc(state: ^URL_State, screen: ^vt.Screen, row, column: int) -> int {
	if state == nil || screen == nil || row < 0 || row >= screen.rows || column < 0 || column >= screen.columns do return -1
	cell := vt.cell_at(screen, row, column)
	if cell.hyperlink_id != 0 {
		for link, index in state.links {
			if link.hyperlink_id == cell.hyperlink_id do return index
		}
		return -1
	}
	source_row := max(0, vt.screen_source_row_count(screen)-screen.rows)+row
	for link, index in state.links {
		if link.hyperlink_id != 0 || source_row < int(link.first.row) || source_row > int(link.last.row) do continue
		if source_row == int(link.first.row) && column < int(link.first.column) do continue
		if source_row == int(link.last.row) && column > int(link.last.column) do continue
		return index
	}
	return -1
}

url_view_screen :: proc(state: ^URL_State) -> ^vt.Screen {
	if !state.active do return nil
	return &state.view
}

url_clear_links :: proc(state: ^URL_State) {
	for &link in state.links do delete(link.text)
	clear(&state.links)
}

detect_urls :: proc(state: ^URL_State, terminal: ^vt.Terminal, screen: ^vt.Screen) {
	text: [dynamic]rune
	positions: [dynamic]Source_Position
	hyperlink_ids: [dynamic]u32
	defer delete(text)
	defer delete(positions)
	defer delete(hyperlink_ids)
	total_rows := vt.screen_source_row_count(screen)
	first_source_row := max(0, total_rows-screen.rows)
	detect_osc_hyperlinks(state, terminal, screen, first_source_row, total_rows)
	for source_row in first_source_row..<total_rows {
		row := vt.screen_source_row(screen, source_row)
		content_length := vt.row_content_length(row)
		for column in 0..<content_length {
			cell := &row[column]
			if cell.continuation do continue
			position := Source_Position{row = i32(source_row), column = i32(column)}
			append(&text, cell.codepoint)
			append(&positions, position)
			append(&hyperlink_ids, cell.hyperlink_id)
			for index in 0..<int(cell.combining_count) {
				append(&text, cell.combining[index])
				append(&positions, position)
				append(&hyperlink_ids, cell.hyperlink_id)
			}
		}
		if source_row+1 < total_rows && !vt.screen_source_wrapped(screen, source_row) {
			append(&text, '\n')
			append(&positions, Source_Position{row = i32(source_row), column = i32(max(0, content_length-1))})
			append(&hyperlink_ids, 0)
		}
	}

	for index := 0; index < len(text) && len(state.links) < MAX_URL_HINTS; {
		if hyperlink_ids[index] != 0 {
			index += 1
			continue
		}
		prefix_length := url_prefix_length(text[:], index)
		if prefix_length == 0 {
			index += 1
			continue
		}
		end := index+prefix_length
		for end < len(text) && end-index < MAX_URL_RUNES && hyperlink_ids[end] == 0 && !url_terminator(text[end]) do end += 1
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

detect_osc_hyperlinks :: proc(
	state: ^URL_State,
	terminal: ^vt.Terminal,
	screen: ^vt.Screen,
	first_source_row, total_rows: int,
) {
	for source_row in first_source_row..<total_rows {
		row := vt.screen_source_row(screen, source_row)
		for column in 0..<len(row) {
			cell := &row[column]
			if cell.continuation || cell.hyperlink_id == 0 do continue
			position := Source_Position{row = i32(source_row), column = i32(column)}
			found := false
			for &link in state.links {
				if link.hyperlink_id == cell.hyperlink_id {
					link.last = position
					found = true
					break
				}
			}
			if found || len(state.links) >= MAX_URL_HINTS do continue
			uri := vt.terminal_hyperlink(terminal, cell.hyperlink_id)
			if uri == "" do continue
			append(&state.links, URL{
				text = strings.clone(uri),
				first = position,
				last = position,
				hint = 'a'+byte(len(state.links)),
				hyperlink_id = cell.hyperlink_id,
			})
		}
	}
}

url_prefix_length :: proc(text: []rune, index: int) -> int {
	if index > 0 && ascii_scheme_character(text[index-1]) do return 0
	for prefix in URL_PREFIXES {
		if ascii_at(text, index, prefix) do return len(prefix)
	}
	return 0
}

ascii_scheme_character :: proc(value: rune) -> bool {
	return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' || value >= '0' && value <= '9' || value == '+' || value == '-' || value == '.'
}

ascii_at :: proc(text: []rune, index: int, value: string) -> bool {
	if index < 0 || index+len(value) > len(text) do return false
	for offset in 0..<len(value) {
		if text[index+offset] != rune(value[offset]) do return false
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

build_url_view :: proc(state: ^URL_State, screen: ^vt.Screen, show_hints: bool = true, highlighted_link: int = -1) {
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
	state.view.image_row_offset = screen.image_row_offset
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
	for &link, index in state.links {
		if !show_hints && index != highlighted_link do continue
		if link.hyperlink_id != 0 {
			for &cell in state.view.cells {
				if !cell.continuation && cell.hyperlink_id == link.hyperlink_id do cell.attributes.underline = .Single
			}
		} else {
			first_row := int(link.first.row)-first_source_row
			last_row := int(link.last.row)-first_source_row
			for row in first_row..=last_row {
				first_column := int(link.first.column) if row == first_row else 0
				last_column := int(link.last.column) if row == last_row else screen.columns-1
				for column in first_column..=last_column {
					cell := vt.cell_at(&state.view, row, column)
					if !cell.continuation do cell.attributes.underline = .Single
				}
			}
		}
		if show_hints {
			first_row := int(link.first.row)-first_source_row
			hint_cell := vt.cell_at(&state.view, first_row, int(link.first.column))
			hint_cell.codepoint = rune(link.hint)
			hint_cell.combining_count = 0
			hint_cell.width = 1
			hint_cell.continuation = false
			hint_cell.attributes.inverse = !hint_cell.attributes.inverse
			hint_cell.attributes.bold = true
		}
	}
}
