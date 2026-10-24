package vt

import "core:unicode"
import "core:unicode/utf8"
import graphics "../graphics"

MAX_COMBINING_RUNES :: 4
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
	tab_stops: []bool,
	wrapped: []bool,
	scrollback: [dynamic][]Cell,
	scrollback_wrapped: [dynamic]bool,
	scrollback_limit: int,
	image_registry: ^graphics.Registry,
	image_screen: graphics.Screen,
	image_row_offset: int,
}

Logical_Line :: struct {
	cells: [dynamic]Cell,
	cursor_offset: int,
	has_cursor: bool,
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
}

screen_resize :: proc(screen: ^Screen, columns, rows: int, attributes: Attributes) -> bool {
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
	cursor_row, cursor_column := pack_logical_lines(lines[:], columns, attributes, &packed_rows, &packed_wrapped)

	new_cells := make([]Cell, columns * rows)
	blank := blank_cell(attributes)
	for &cell in new_cells do cell = blank
	new_wrapped := make([]bool, rows)
	visible_start := max(0, len(packed_rows)-rows)
	visible_count := min(rows, len(packed_rows)-visible_start)
	for row in 0..<visible_count {
		copy(new_cells[row*columns:(row+1)*columns], packed_rows[visible_start+row])
		new_wrapped[row] = packed_wrapped[visible_start+row]
	}

	for row in screen.scrollback do delete(row)
	clear(&screen.scrollback)
	clear(&screen.scrollback_wrapped)
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
		row := screen.scrollback[row_index] if is_history else screen.cells[row_index*screen.columns:(row_index+1)*screen.columns]
		wrapped := screen.scrollback_wrapped[row_index] if is_history else screen.wrapped[row_index]
		content_length := row_content_length(row)
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
) -> (cursor_row, cursor_column: int) {
	cursor_found := false
	for &line in lines {
		row := make_blank_row(columns, attributes)
		column := 0
		for index := 0; index < len(line.cells); index += 1 {
			cell := line.cells[index]
			if cell.continuation {
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
		append(packed_rows, row)
		append(packed_wrapped, false)
	}
	if !cursor_found {
		cursor_row = max(0, len(packed_rows^)-1)
		cursor_column = 0
	}
	return
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

screen_source_row_count :: proc(screen: ^Screen) -> int {
	return len(screen.scrollback) + screen.rows
}

screen_source_row :: proc(screen: ^Screen, row: int) -> []Cell {
	if row < 0 || row >= screen_source_row_count(screen) do return nil
	if row < len(screen.scrollback) do return screen.scrollback[row]
	visible_row := row-len(screen.scrollback)
	return screen.cells[visible_row*screen.columns:(visible_row+1)*screen.columns]
}

screen_source_wrapped :: proc(screen: ^Screen, row: int) -> bool {
	if row < 0 || row >= screen_source_row_count(screen) do return false
	if row < len(screen.scrollback) do return screen.scrollback_wrapped[row]
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

screen_extract :: proc(screen: ^Screen, first, last: Cursor) -> string {
	start := screen_position(screen, first.row, first.column)
	end := screen_position(screen, last.row, last.column)
	if cursor_after(start, end) do start, end = end, start
	result: [dynamic]byte
	for row in start.row..=end.row {
		start_column := start.column if row == start.row else 0
		end_column := end.column if row == end.row else screen.columns-1
		if row < end.row && !screen.wrapped[row] {
			for end_column >= start_column && copy_blank(cell_at(screen, row, end_column)) do end_column -= 1
		}
		for column := start_column; column <= end_column; column += 1 {
			cell := cell_at(screen, row, column)
			if cell.continuation do continue
			append_rune(&result, cell.codepoint)
			for index in 0..<int(cell.combining_count) do append_rune(&result, cell.combining[index])
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
	return Cell{codepoint = ' ', width = 1, attributes = attributes}
}

screen_put :: proc(screen: ^Screen, codepoint: rune, attributes: Attributes, autowrap: bool, hyperlink_id: u32 = 0) {
	if unicode.is_combining(codepoint) {
		column := screen.cursor.column - 1
		row := screen.cursor.row
		if screen.wrap_pending do column = screen.cursor.column
		if column >= 0 {
			cell := cell_at(screen, row, column)
			if cell.continuation && column > 0 do cell = cell_at(screen, row, column-1)
			if int(cell.combining_count) < len(cell.combining) {
				cell.combining[cell.combining_count] = codepoint
				cell.combining_count += 1
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
		if screen.scroll_top == 0 && screen.scroll_bottom == screen.rows-1 && screen.scrollback_limit > 0 {
			row := make([]Cell, screen.columns)
			copy(row, screen.cells[:screen.columns])
			append(&screen.scrollback, row)
			append(&screen.scrollback_wrapped, screen.wrapped[0])
			if len(screen.scrollback) > screen.scrollback_limit {
				delete(screen.scrollback[0])
				ordered_remove(&screen.scrollback, 0)
				ordered_remove(&screen.scrollback_wrapped, 0)
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
