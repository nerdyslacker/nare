package vt

import "core:unicode"
import "core:unicode/utf8"
import graphics "../graphics"

// Emoji ZWJ families and tag sequences require more storage than ordinary
// combining accents. These codepoints remain attached to one terminal cell
// and are shaped together by HarfBuzz.
MAX_COMBINING_RUNES :: 16
DEFAULT_SCROLLBACK_LINES :: 10000

Color_Kind :: enum { Default, Indexed, RGB }
Color :: struct { kind: Color_Kind, value: u32 }

Shell_Marker :: enum { Prompt, Command, Output, Finished }
Shell_Markers :: bit_set[Shell_Marker; u8]

Attributes :: struct {
	foreground: Color,
	background: Color,
	bold: bool,
	faint: bool,
	italic: bool,
	underline: bool,
	double_underline: bool,
	blink: bool,
	inverse: bool,
	hidden: bool,
	strikethrough: bool,
}

Cell :: struct {
	codepoint: rune,
	combining: [MAX_COMBINING_RUNES]rune,
	combining_count: u8,
	width: u8,
	continuation: bool,
	hyperlink_id: u32,
	shell_markers: Shell_Markers,
	shell_exit_status: i32,
	shell_exit_status_set: bool,
	attributes: Attributes,
}

Cursor :: struct { row, column: int }

Screen :: struct {
	cells: []Cell,
	columns: int,
	rows: int,
	cursor: Cursor,
	saved_cursor: Cursor,
	scroll_top: int,
	scroll_bottom: int,
	wrap_pending: bool,
	live_prompt_active: bool,
	live_prompt_row: int,
	tab_stops: []bool,
	wrapped: []bool,
	scrollback: [dynamic][]Cell,
	scrollback_wrapped: [dynamic]bool,
	scrollback_start: int,
	scrollback_limit: int,
	image_registry: ^graphics.Registry,
	image_screen: graphics.Screen,
	image_row_offset: int,
}

Logical_Line :: struct {
	cells: [dynamic]Cell,
	cursor_offset: int,
	has_cursor: bool,
	viewport_offset: int,
	has_viewport: bool,
}

screen_init :: proc(
	screen: ^Screen,
	columns, rows: int,
	scrollback_limit: int = 0,
	image_registry: ^graphics.Registry = nil,
	image_screen: graphics.Screen = .Main,
) -> bool {
	if columns <= 0 || rows <= 0 do return false
	screen.columns = columns
	screen.rows = rows
	screen.cells = make([]Cell, columns * rows)
	screen.tab_stops = make([]bool, columns)
	screen.wrapped = make([]bool, rows)
	screen.scroll_top = 0
	screen.scroll_bottom = rows - 1
	screen.scrollback_limit = max(0, scrollback_limit)
	screen.image_registry = image_registry
	screen.image_screen = image_screen
	for column := 8; column < columns; column += 8 do screen.tab_stops[column] = true
	screen_clear(screen, {})
	return true
}

screen_destroy :: proc(screen: ^Screen) {
	if screen.image_registry != nil do graphics.clear_screen(screen.image_registry, screen.image_screen)
	delete(screen.cells)
	delete(screen.tab_stops)
	delete(screen.wrapped)
	for row in screen.scrollback do delete(row)
	delete(screen.scrollback)
	delete(screen.scrollback_wrapped)
	screen^ = {}
}

screen_has_image_placements :: proc(screen: ^Screen) -> bool {
	return screen.image_registry != nil && graphics.screen_has_placements(screen.image_registry, screen.image_screen)
}

screen_clear :: proc(screen: ^Screen, attributes: Attributes) {
	if screen.image_registry != nil do graphics.clear_screen(screen.image_registry, screen.image_screen)
	blank := blank_cell(attributes)
	for &cell in screen.cells do cell = blank
	for &wrapped in screen.wrapped do wrapped = false
	screen.cursor = {}
	screen.saved_cursor = {}
	screen.scroll_top = 0
	screen.scroll_bottom = screen.rows - 1
	screen.wrap_pending = false
	screen.live_prompt_active = false
	screen.live_prompt_row = 0
}

screen_resize :: proc(screen: ^Screen, columns, rows: int, attributes: Attributes) -> bool {
	prompt_start, active_prompt := screen_active_prompt_start(screen)
	if !active_prompt do return screen_resize_reflow(screen, columns, rows, attributes)
	prompt_lines_above_cursor := screen.cursor.row-prompt_start
	for row in prompt_start..=screen.cursor.row {
		clear_row(screen, row, attributes)
		marker := Shell_Marker.Prompt if row == prompt_start else Shell_Marker.Finished
		cell_at(screen, row, 0).shell_markers += {marker}
	}
	if !screen_resize_reflow(screen, columns, rows, attributes) do return false
	mapped_prompt_start := max(0, screen.cursor.row-prompt_lines_above_cursor)
	for row in mapped_prompt_start..=screen.cursor.row do clear_row(screen, row, attributes)
	cell_at(screen, mapped_prompt_start, 0).shell_markers += {.Prompt}
	screen.live_prompt_row = mapped_prompt_start
	return true
}

screen_active_prompt_start :: proc(screen: ^Screen) -> (int, bool) {
	if screen == nil || screen.rows <= 0 || screen.columns <= 0 do return 0, false
	if screen.live_prompt_active {
		return clamp(screen.live_prompt_row, 0, min(screen.cursor.row, screen.rows-1)), true
	}
	for row := clamp(screen.cursor.row, 0, screen.rows-1); row >= 0; row -= 1 {
		for column := screen.columns-1; column >= 0; column -= 1 {
			markers := cell_at(screen, row, column).shell_markers
			if .Command in markers || .Output in markers do return 0, false
			if .Prompt in markers do return row, true
		}
	}
	return 0, false
}

screen_resize_reflow :: proc(screen: ^Screen, columns, rows: int, attributes: Attributes) -> bool {
	if columns <= 0 || rows <= 0 do return false
	if columns == screen.columns && rows == screen.rows do return true
	lines := collect_logical_lines(screen)
	defer destroy_logical_lines(&lines)
	packed_rows: [dynamic][]Cell
	packed_wrapped: [dynamic]bool
	defer {
		for row in packed_rows do delete(row)
		delete(packed_rows)
		delete(packed_wrapped)
	}
	cursor_row, cursor_column, viewport_row := pack_logical_lines(lines[:], columns, attributes, &packed_rows, &packed_wrapped)

	new_cells := make([]Cell, columns * rows)
	blank := blank_cell(attributes)
	for &cell in new_cells do cell = blank
	new_wrapped := make([]bool, rows)
	minimum_start := max(0, cursor_row-rows+1)
	visible_start := clamp(viewport_row, minimum_start, cursor_row)
	visible_count := min(rows, len(packed_rows)-visible_start)
	for row in 0..<visible_count {
		copy(new_cells[row*columns:(row+1)*columns], packed_rows[visible_start+row])
		new_wrapped[row] = packed_wrapped[visible_start+row]
	}

	for row in screen.scrollback do delete(row)
	clear(&screen.scrollback)
	clear(&screen.scrollback_wrapped)
	screen.scrollback_start = 0
	history_start := max(0, visible_start-screen.scrollback_limit)
	for index in history_start..<visible_start {
		row := make([]Cell, columns)
		copy(row, packed_rows[index])
		append(&screen.scrollback, row)
		append(&screen.scrollback_wrapped, packed_wrapped[index])
	}

	new_tabs := make([]bool, columns)
	copy(new_tabs, screen.tab_stops[:min(columns, len(screen.tab_stops))])
	for column := 8; column < columns; column += 8 {
		if column >= len(screen.tab_stops) do new_tabs[column] = true
	}
	delete(screen.cells)
	delete(screen.tab_stops)
	delete(screen.wrapped)
	screen.cells = new_cells
	screen.tab_stops = new_tabs
	screen.wrapped = new_wrapped
	screen.columns = columns
	screen.rows = rows
	screen.cursor.row = clamp(cursor_row-visible_start, 0, rows-1)
	screen.cursor.column = clamp(cursor_column, 0, columns-1)
	screen.saved_cursor.row = clamp(screen.saved_cursor.row, 0, rows-1)
	screen.saved_cursor.column = clamp(screen.saved_cursor.column, 0, columns-1)
	screen.scroll_top = 0
	screen.scroll_bottom = rows - 1
	screen.wrap_pending = false
	return true
}

screen_resize_without_reflow :: proc(screen: ^Screen, columns, rows: int, attributes: Attributes) -> bool {
	if columns <= 0 || rows <= 0 do return false
	if columns == screen.columns && rows == screen.rows do return true
	new_cells := make([]Cell, columns*rows)
	blank := blank_cell(attributes)
	for &cell in new_cells do cell = blank
	new_wrapped := make([]bool, rows)
	copy_rows := min(screen.rows, rows)
	copy_columns := min(screen.columns, columns)
	for row in 0..<copy_rows {
		copy(
			new_cells[row*columns:row*columns+copy_columns],
			screen.cells[row*screen.columns:row*screen.columns+copy_columns],
		)
		new_wrapped[row] = screen.wrapped[row]
		// Do not retain half of a wide glyph at the new right edge.
		last := &new_cells[row*columns+columns-1]
		if last.continuation {
			last^ = blank
			if columns > 1 do new_cells[row*columns+columns-2] = blank
		} else if last.width == 2 {
			last^ = blank
		}
	}
	new_tabs := make([]bool, columns)
	copy(new_tabs, screen.tab_stops[:min(columns, len(screen.tab_stops))])
	for column := 8; column < columns; column += 8 {
		if column >= len(screen.tab_stops) do new_tabs[column] = true
	}
	delete(screen.cells)
	delete(screen.tab_stops)
	delete(screen.wrapped)
	screen.cells = new_cells
	screen.tab_stops = new_tabs
	screen.wrapped = new_wrapped
	screen.columns = columns
	screen.rows = rows
	screen.cursor.row = clamp(screen.cursor.row, 0, rows-1)
	screen.cursor.column = clamp(screen.cursor.column, 0, columns-1)
	screen.saved_cursor.row = clamp(screen.saved_cursor.row, 0, rows-1)
	screen.saved_cursor.column = clamp(screen.saved_cursor.column, 0, columns-1)
	screen.scroll_top = 0
	screen.scroll_bottom = rows-1
	screen.wrap_pending = false
	return true
}

collect_logical_lines :: proc(screen: ^Screen) -> [dynamic]Logical_Line {
	lines: [dynamic]Logical_Line
	current := Logical_Line{}
	last_used_row := screen.cursor.row
	for row in 0..<screen.rows {
		cells := screen.cells[row*screen.columns:(row+1)*screen.columns]
		if row_content_length(cells) > 0 || screen.wrapped[row] do last_used_row = max(last_used_row, row)
	}
	source_count := len(screen.scrollback) + last_used_row + 1
	for source_index in 0..<source_count {
		is_history := source_index < len(screen.scrollback)
		row_index := source_index if is_history else source_index-len(screen.scrollback)
		row := screen_scrollback_row(screen, row_index) if is_history else screen.cells[row_index*screen.columns:(row_index+1)*screen.columns]
		wrapped := screen_scrollback_wrapped(screen, row_index) if is_history else screen.wrapped[row_index]
		content_length := row_content_length(row)
		if source_index == len(screen.scrollback) {
			current.has_viewport = true
			current.viewport_offset = len(current.cells)
		}
		if !is_history && row_index == screen.cursor.row {
			current.has_cursor = true
			current.cursor_offset = len(current.cells) + screen.cursor.column
			content_length = max(content_length, screen.cursor.column+1)
		}
		append(&current.cells, ..row[:content_length])
		if !wrapped {
			append(&lines, current)
			current = {}
		}
	}
	if len(current.cells) > 0 || current.has_cursor do append(&lines, current)
	if len(lines) == 0 do append(&lines, Logical_Line{})
	return lines
}

row_content_length :: proc(row: []Cell) -> int {
	for index := len(row)-1; index >= 0; index -= 1 {
		cell := row[index]
		if cell.codepoint != ' ' || cell.combining_count > 0 || cell.continuation || cell.hyperlink_id != 0 ||
		   cell.shell_markers != {} || cell.attributes != {} {
			return index+1
		}
	}
	return 0
}

pack_logical_lines :: proc(
	lines: []Logical_Line,
	columns: int,
	attributes: Attributes,
	packed_rows: ^[dynamic][]Cell,
	packed_wrapped: ^[dynamic]bool,
) -> (cursor_row, cursor_column, viewport_row: int) {
	cursor_found := false
	viewport_found := false
	for &line in lines {
		row := make_blank_row(columns, attributes)
		column := 0
		for index := 0; index < len(line.cells); index += 1 {
			cell := line.cells[index]
			if cell.continuation {
				if line.has_viewport && line.viewport_offset == index && !viewport_found {
					viewport_row, viewport_found = len(packed_rows^), true
				}
				if line.has_cursor && line.cursor_offset == index && !cursor_found {
					cursor_row, cursor_column, cursor_found = len(packed_rows^), max(0, column-1), true
				}
				continue
			}
			width := max(1, unicode.normalized_east_asian_width(cell.codepoint))
			if width > columns do width = 1
			if column+width > columns {
				append(packed_rows, row)
				append(packed_wrapped, true)
				row = make_blank_row(columns, attributes)
				column = 0
			}
			if line.has_viewport && line.viewport_offset == index && !viewport_found {
				viewport_row, viewport_found = len(packed_rows^), true
			}
			if line.has_cursor && line.cursor_offset == index && !cursor_found {
				cursor_row, cursor_column, cursor_found = len(packed_rows^), column, true
			}
			cell.width = u8(width)
			cell.continuation = false
			row[column] = cell
			if width == 2 {
				row[column+1] = blank_cell(cell.attributes)
				row[column+1].width = 0
				row[column+1].continuation = true
			}
			column += width
		}
		if line.has_cursor && !cursor_found {
			cursor_row, cursor_column, cursor_found = len(packed_rows^), min(column, columns-1), true
		}
		if line.has_viewport && !viewport_found {
			viewport_row, viewport_found = len(packed_rows^), true
		}
		append(packed_rows, row)
		append(packed_wrapped, false)
	}
	if !cursor_found {
		cursor_row = max(0, len(packed_rows^)-1)
		cursor_column = 0
	}
	return cursor_row, cursor_column, viewport_row
}

make_blank_row :: proc(columns: int, attributes: Attributes) -> []Cell {
	row := make([]Cell, columns)
	blank := blank_cell(attributes)
	for &cell in row do cell = blank
	return row
}

destroy_logical_lines :: proc(lines: ^[dynamic]Logical_Line) {
	for &line in lines^ do delete(line.cells)
	delete(lines^)
}

cell_at :: proc(screen: ^Screen, row, column: int) -> ^Cell {
	return &screen.cells[row * screen.columns + column]
}

screen_scrollback_index :: proc(screen: ^Screen, row: int) -> int {
	return (screen.scrollback_start+row)%len(screen.scrollback)
}

screen_scrollback_row :: proc(screen: ^Screen, row: int) -> []Cell {
	return screen.scrollback[screen_scrollback_index(screen, row)]
}

screen_scrollback_wrapped :: proc(screen: ^Screen, row: int) -> bool {
	return screen.scrollback_wrapped[screen_scrollback_index(screen, row)]
}

screen_prepare_scrollback :: proc(screen: ^Screen) {
	keep_count := min(len(screen.scrollback), screen.scrollback_limit)
	if len(screen.scrollback) == keep_count && (screen.scrollback_start == 0 || keep_count == screen.scrollback_limit) do return
	remove_count := len(screen.scrollback)-keep_count
	rows := make([dynamic][]Cell, 0, keep_count)
	wrapped := make([dynamic]bool, 0, keep_count)
	for row in 0..<len(screen.scrollback) {
		cells := screen_scrollback_row(screen, row)
		if row < remove_count {
			delete(cells)
		} else {
			append(&rows, cells)
			append(&wrapped, screen_scrollback_wrapped(screen, row))
		}
	}
	delete(screen.scrollback)
	delete(screen.scrollback_wrapped)
	screen.scrollback = rows
	screen.scrollback_wrapped = wrapped
	screen.scrollback_start = 0
}

screen_source_row_count :: proc(screen: ^Screen) -> int {
	return len(screen.scrollback) + screen.rows
}

screen_source_row :: proc(screen: ^Screen, row: int) -> []Cell {
	if row < 0 || row >= screen_source_row_count(screen) do return nil
	if row < len(screen.scrollback) do return screen_scrollback_row(screen, row)
	visible_row := row-len(screen.scrollback)
	return screen.cells[visible_row*screen.columns:(visible_row+1)*screen.columns]
}

screen_source_wrapped :: proc(screen: ^Screen, row: int) -> bool {
	if row < 0 || row >= screen_source_row_count(screen) do return false
	if row < len(screen.scrollback) do return screen_scrollback_wrapped(screen, row)
	return screen.wrapped[row-len(screen.scrollback)]
}

screen_position :: proc(screen: ^Screen, row, column: int) -> Cursor {
	position := Cursor{
		row = clamp(row, 0, screen.rows-1),
		column = clamp(column, 0, screen.columns-1),
	}
	if cell_at(screen, position.row, position.column).continuation && position.column > 0 {
		position.column -= 1
	}
	return position
}

screen_selectable_position :: proc(screen: ^Screen, row, column: int) -> (Cursor, bool) {
	if row < 0 || row >= screen.rows || column < 0 || column >= screen.columns do return {}, false
	cells := screen.cells[row*screen.columns:(row+1)*screen.columns]
	content_length := row_content_length(cells)
	if content_length == 0 || column >= content_length do return {}, false
	return screen_position(screen, row, column), true
}

screen_cell_selectable :: proc(screen: ^Screen, row, column: int) -> bool {
	if row < 0 || row >= screen.rows || column < 0 || column >= screen.columns do return false
	cells := screen.cells[row*screen.columns:(row+1)*screen.columns]
	return column < row_content_length(cells)
}

screen_extract :: proc(screen: ^Screen, first, last: Cursor) -> string {
	start := screen_position(screen, first.row, first.column)
	end := screen_position(screen, last.row, last.column)
	if cursor_after(start, end) do start, end = end, start
	result: [dynamic]byte
	for row in start.row..=end.row {
		start_column := start.column if row == start.row else 0
		end_column := end.column if row == end.row else screen.columns-1
		if row == end.row {
			content_length := row_content_length(screen.cells[row*screen.columns:(row+1)*screen.columns])
			end_column = min(end_column, content_length-1)
		}
		if row < end.row && !screen.wrapped[row] {
			for end_column >= start_column && copy_blank(cell_at(screen, row, end_column)) do end_column -= 1
		}
		if start_column <= end_column {
			for column := start_column; column <= end_column; column += 1 {
				cell := cell_at(screen, row, column)
				if cell.continuation do continue
				append_rune(&result, cell.codepoint)
				for index in 0..<int(cell.combining_count) do append_rune(&result, cell.combining[index])
			}
		}
		if row < end.row && !screen.wrapped[row] do append(&result, '\n')
	}
	return string(result[:])
}

screen_extract_source :: proc(screen: ^Screen, first, last_exclusive: Cursor, max_bytes: int) -> (string, bool) {
	row_count := screen_source_row_count(screen)
	if max_bytes < 0 || first.row < 0 || first.row >= row_count ||
	   last_exclusive.row < first.row || last_exclusive.row >= row_count {
		return "", false
	}
	start_column := clamp(first.column, 0, screen.columns)
	end_column := clamp(last_exclusive.column, 0, screen.columns)
	if first.row == last_exclusive.row && start_column > end_column do return "", false
	result: [dynamic]byte
	for row in first.row..=last_exclusive.row {
		cells := screen_source_row(screen, row)
		first_column := start_column if row == first.row else 0
		last_column := end_column if row == last_exclusive.row else screen.columns
		if row < last_exclusive.row && !screen_source_wrapped(screen, row) {
			for last_column > first_column && copy_blank(&cells[last_column-1]) do last_column -= 1
		}
		for column in first_column..<last_column {
			cell := &cells[column]
			if cell.continuation do continue
			append_rune(&result, cell.codepoint)
			for index in 0..<int(cell.combining_count) do append_rune(&result, cell.combining[index])
			if len(result) > max_bytes {
				delete(result)
				return "", false
			}
		}
		if row < last_exclusive.row && !screen_source_wrapped(screen, row) {
			if len(result) >= max_bytes {
				delete(result)
				return "", false
			}
			append(&result, '\n')
		}
	}
	return string(result[:]), true
}

cursor_after :: proc(left, right: Cursor) -> bool {
	return left.row > right.row || left.row == right.row && left.column > right.column
}

copy_blank :: proc(cell: ^Cell) -> bool {
	return !cell.continuation && cell.codepoint == ' ' && cell.combining_count == 0
}

append_rune :: proc(output: ^[dynamic]byte, value: rune) {
	bytes, count := utf8.encode_rune(value)
	append(output, ..bytes[:count])
}

blank_cell :: proc(attributes: Attributes) -> Cell {
	background := attributes.foreground if attributes.inverse else attributes.background
	return Cell{codepoint = ' ', width = 1, attributes = {background = background}}
}

screen_put :: proc(screen: ^Screen, codepoint: rune, attributes: Attributes, autowrap: bool, hyperlink_id: u32 = 0) {
	previous, previous_column := screen_previous_cell(screen)
	if unicode.is_combining(codepoint) || emoji_sequence_extension(previous, codepoint) {
		if previous != nil && int(previous.combining_count) < len(previous.combining) {
			previous.combining[previous.combining_count] = codepoint
			previous.combining_count += 1
			if emoji_sequence_is_wide(previous, codepoint) {
				screen_widen_sequence_cell(screen, previous, previous_column, attributes)
			}
		}
		return
	}

	width := unicode.normalized_east_asian_width(codepoint)
	if width <= 0 do return
	if screen.wrap_pending {
		if autowrap {
			screen.wrapped[screen.cursor.row] = true
			screen.cursor.column = 0
			line_feed(screen, attributes)
		}
		screen.wrap_pending = false
	}
	if width == 2 && screen.cursor.column == screen.columns - 1 {
		if !autowrap do return
		screen.wrapped[screen.cursor.row] = true
		screen.cursor.column = 0
		line_feed(screen, attributes)
	}

	cell := cell_at(screen, screen.cursor.row, screen.cursor.column)
	markers := cell.shell_markers
	exit_status := cell.shell_exit_status
	exit_status_set := cell.shell_exit_status_set
	erase_cells(screen, screen.cursor.row, screen.cursor.column, screen.cursor.column+width-1, attributes)
	cell = cell_at(screen, screen.cursor.row, screen.cursor.column)
	cell^ = Cell{
		codepoint = codepoint,
		width = u8(width),
		hyperlink_id = hyperlink_id,
		shell_markers = markers,
		shell_exit_status = exit_status,
		shell_exit_status_set = exit_status_set,
		attributes = attributes,
	}
	if width == 2 {
		continuation := cell_at(screen, screen.cursor.row, screen.cursor.column+1)
		continuation^ = blank_cell(attributes)
		continuation.continuation = true
		continuation.width = 0
		continuation.hyperlink_id = hyperlink_id
	}
	if screen.cursor.column + width >= screen.columns {
		screen.cursor.column = screen.columns - 1
		screen.wrap_pending = true
	} else {
		screen.cursor.column += width
	}
}

screen_previous_cell :: proc(screen: ^Screen) -> (cell: ^Cell, column: int) {
	if screen == nil || screen.columns <= 0 || screen.rows <= 0 do return nil, -1
	column = screen.cursor.column if screen.wrap_pending else screen.cursor.column-1
	if column < 0 do return nil, -1
	cell = cell_at(screen, screen.cursor.row, column)
	if cell.continuation && column > 0 {
		column -= 1
		cell = cell_at(screen, screen.cursor.row, column)
	}
	return
}

emoji_sequence_extension :: proc(previous: ^Cell, codepoint: rune) -> bool {
	if previous == nil do return false
	if codepoint == 0x200d || codepoint == 0xfe0e || codepoint == 0xfe0f ||
	   codepoint >= 0x1f3fb && codepoint <= 0x1f3ff ||
	   codepoint >= 0xe0020 && codepoint <= 0xe007f {
		return true
	}
	if previous.combining_count > 0 && previous.combining[previous.combining_count-1] == 0x200d do return true
	return previous.codepoint >= 0x1f1e6 && previous.codepoint <= 0x1f1ff &&
	       codepoint >= 0x1f1e6 && codepoint <= 0x1f1ff
}

emoji_sequence_is_wide :: proc(cell: ^Cell, codepoint: rune) -> bool {
	if cell == nil || cell.width != 1 do return false
	if codepoint == 0xfe0f do return true
	return cell.codepoint >= 0x1f1e6 && cell.codepoint <= 0x1f1ff &&
	       codepoint >= 0x1f1e6 && codepoint <= 0x1f1ff
}

screen_widen_sequence_cell :: proc(screen: ^Screen, cell: ^Cell, column: int, attributes: Attributes) {
	if screen == nil || cell == nil || column < 0 || column+1 >= screen.columns do return
	continuation := cell_at(screen, screen.cursor.row, column+1)
	continuation^ = blank_cell(attributes)
	continuation.width = 0
	continuation.continuation = true
	continuation.hyperlink_id = cell.hyperlink_id
	cell.width = 2
	if !screen.wrap_pending && screen.cursor.column == column+1 {
		if screen.cursor.column+1 >= screen.columns {
			screen.cursor.column = screen.columns-1
			screen.wrap_pending = true
		} else do screen.cursor.column += 1
	}
}

line_feed :: proc(screen: ^Screen, attributes: Attributes) {
	if screen.cursor.row == screen.scroll_bottom {
		scroll_up(screen, 1, attributes)
	} else {
		screen.cursor.row = min(screen.rows-1, screen.cursor.row+1)
	}
	screen.wrap_pending = false
}

reverse_index :: proc(screen: ^Screen, attributes: Attributes) {
	if screen.cursor.row == screen.scroll_top {
		scroll_down(screen, 1, attributes)
	} else {
		screen.cursor.row = max(0, screen.cursor.row-1)
	}
	screen.wrap_pending = false
}

scroll_up :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	amount := clamp(count, 1, screen.scroll_bottom-screen.scroll_top+1)
	for _ in 0..<amount {
		if screen.live_prompt_active && screen.live_prompt_row >= screen.scroll_top && screen.live_prompt_row <= screen.scroll_bottom {
			screen.live_prompt_row = max(screen.scroll_top, screen.live_prompt_row-1)
		}
		if screen.scroll_top == 0 && screen.scroll_bottom == screen.rows-1 {
			screen_prepare_scrollback(screen)
			if screen.scrollback_limit > 0 {
				row := make([]Cell, screen.columns)
				copy(row, screen.cells[:screen.columns])
				if len(screen.scrollback) < screen.scrollback_limit {
					append(&screen.scrollback, row)
					append(&screen.scrollback_wrapped, screen.wrapped[0])
				} else {
					index := screen.scrollback_start
					delete(screen.scrollback[index])
					screen.scrollback[index] = row
					screen.scrollback_wrapped[index] = screen.wrapped[0]
					screen.scrollback_start = (index+1)%len(screen.scrollback)
				}
			}
		}
		for row in screen.scroll_top..<screen.scroll_bottom {
			copy(screen.cells[row*screen.columns:(row+1)*screen.columns], screen.cells[(row+1)*screen.columns:(row+2)*screen.columns])
			screen.wrapped[row] = screen.wrapped[row+1]
		}
		clear_row(screen, screen.scroll_bottom, attributes)
		if screen.image_registry != nil {
			full_viewport := screen.scroll_top == 0 && screen.scroll_bottom == screen.rows-1
			graphics.scroll_up(
				screen.image_registry,
				screen.image_screen,
				screen.scroll_top,
				screen.scroll_bottom,
				len(screen.scrollback),
				full_viewport,
				full_viewport && screen.image_screen == .Main && screen.scrollback_limit > 0,
			)
		}
	}
}

scroll_down :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	amount := clamp(count, 1, screen.scroll_bottom-screen.scroll_top+1)
	for _ in 0..<amount {
		if screen.live_prompt_active && screen.live_prompt_row >= screen.scroll_top && screen.live_prompt_row <= screen.scroll_bottom {
			screen.live_prompt_row = min(screen.scroll_bottom, screen.live_prompt_row+1)
		}
		for row := screen.scroll_bottom; row > screen.scroll_top; row -= 1 {
			copy(screen.cells[row*screen.columns:(row+1)*screen.columns], screen.cells[(row-1)*screen.columns:row*screen.columns])
			screen.wrapped[row] = screen.wrapped[row-1]
		}
		clear_row(screen, screen.scroll_top, attributes)
		if screen.image_registry != nil {
			graphics.scroll_down(
				screen.image_registry,
				screen.image_screen,
				screen.scroll_top,
				screen.scroll_bottom,
				screen.scroll_top == 0 && screen.scroll_bottom == screen.rows-1,
			)
		}
	}
}

clear_row :: proc(screen: ^Screen, row: int, attributes: Attributes) {
	blank := blank_cell(attributes)
	for &cell in screen.cells[row*screen.columns:(row+1)*screen.columns] do cell = blank
	screen.wrapped[row] = false
}

erase_cells :: proc(screen: ^Screen, row, first, last: int, attributes: Attributes) {
	first_column := clamp(first, 0, screen.columns-1)
	last_column := clamp(last, first_column, screen.columns-1)
	if cell_at(screen, row, first_column).continuation && first_column > 0 do first_column -= 1
	if cell_at(screen, row, last_column).width == 2 && last_column+1 < screen.columns do last_column += 1
	if screen.image_registry != nil {
		graphics.erase_cell_area(screen.image_registry, screen.image_screen, row, first_column, last_column)
	}
	blank := blank_cell(attributes)
	for column in first_column..=last_column do cell_at(screen, row, column)^ = blank
}

insert_cells :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	amount := clamp(count, 1, screen.columns-screen.cursor.column)
	row_start := screen.cursor.row * screen.columns
	for column := screen.columns-1; column >= screen.cursor.column+amount; column -= 1 {
		screen.cells[row_start+column] = screen.cells[row_start+column-amount]
	}
	erase_cells(screen, screen.cursor.row, screen.cursor.column, screen.cursor.column+amount-1, attributes)
	sanitize_row(screen, screen.cursor.row, attributes)
}

delete_cells :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	amount := clamp(count, 1, screen.columns-screen.cursor.column)
	row_start := screen.cursor.row * screen.columns
	for column := screen.cursor.column; column < screen.columns-amount; column += 1 {
		screen.cells[row_start+column] = screen.cells[row_start+column+amount]
	}
	erase_cells(screen, screen.cursor.row, screen.columns-amount, screen.columns-1, attributes)
	sanitize_row(screen, screen.cursor.row, attributes)
}

sanitize_row :: proc(screen: ^Screen, row: int, attributes: Attributes) {
	blank := blank_cell(attributes)
	for column in 0..<screen.columns {
		cell := cell_at(screen, row, column)
		if cell.continuation {
			if column == 0 || cell_at(screen, row, column-1).width != 2 do cell^ = blank
		} else if cell.width == 2 {
			if column+1 >= screen.columns {
				cell^ = blank
			} else {
				next := cell_at(screen, row, column+1)
				next^ = blank_cell(cell.attributes)
				next.width = 0
				next.continuation = true
			}
		}
	}
}
