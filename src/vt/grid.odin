package vt

import "core:unicode"

MAX_COMBINING_RUNES :: 4
DEFAULT_SCROLLBACK_LINES :: 10000

Color_Kind :: enum { Default, Indexed, RGB }
Color :: struct { kind: Color_Kind, value: u32 }

Attributes :: struct {
	foreground: Color,
	background: Color,
	bold: bool,
	faint: bool,
	italic: bool,
	underline: bool,
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
	scrollback: [dynamic][]Cell,
	scrollback_limit: int,
}

screen_init :: proc(screen: ^Screen, columns, rows: int, scrollback_limit: int = 0) -> bool {
	if columns <= 0 || rows <= 0 do return false
	screen.columns = columns
	screen.rows = rows
	screen.cells = make([]Cell, columns * rows)
	screen.tab_stops = make([]bool, columns)
	screen.scroll_top = 0
	screen.scroll_bottom = rows - 1
	screen.scrollback_limit = max(0, scrollback_limit)
	for column := 8; column < columns; column += 8 do screen.tab_stops[column] = true
	screen_clear(screen, {})
	return true
}

screen_destroy :: proc(screen: ^Screen) {
	delete(screen.cells)
	delete(screen.tab_stops)
	for row in screen.scrollback do delete(row)
	delete(screen.scrollback)
	screen^ = {}
}

screen_clear :: proc(screen: ^Screen, attributes: Attributes) {
	blank := blank_cell(attributes)
	for &cell in screen.cells do cell = blank
	screen.cursor = {}
	screen.saved_cursor = {}
	screen.scroll_top = 0
	screen.scroll_bottom = screen.rows - 1
	screen.wrap_pending = false
}

screen_resize :: proc(screen: ^Screen, columns, rows: int, attributes: Attributes) -> bool {
	if columns <= 0 || rows <= 0 do return false
	new_cells := make([]Cell, columns * rows)
	blank := blank_cell(attributes)
	for &cell in new_cells do cell = blank
	copy_rows := min(rows, screen.rows)
	copy_columns := min(columns, screen.columns)
	for row in 0..<copy_rows {
		copy(new_cells[row*columns:row*columns+copy_columns], screen.cells[row*screen.columns:row*screen.columns+copy_columns])
	}
	new_tabs := make([]bool, columns)
	copy(new_tabs, screen.tab_stops[:min(columns, len(screen.tab_stops))])
	for column := 8; column < columns; column += 8 {
		if column >= len(screen.tab_stops) do new_tabs[column] = true
	}
	delete(screen.cells)
	delete(screen.tab_stops)
	screen.cells = new_cells
	screen.tab_stops = new_tabs
	screen.columns = columns
	screen.rows = rows
	screen.cursor.row = clamp(screen.cursor.row, 0, rows-1)
	screen.cursor.column = clamp(screen.cursor.column, 0, columns-1)
	screen.saved_cursor.row = clamp(screen.saved_cursor.row, 0, rows-1)
	screen.saved_cursor.column = clamp(screen.saved_cursor.column, 0, columns-1)
	screen.scroll_top = 0
	screen.scroll_bottom = rows - 1
	screen.wrap_pending = false
	return true
}

cell_at :: proc(screen: ^Screen, row, column: int) -> ^Cell {
	return &screen.cells[row * screen.columns + column]
}

blank_cell :: proc(attributes: Attributes) -> Cell {
	return Cell{codepoint = ' ', width = 1, attributes = attributes}
}

screen_put :: proc(screen: ^Screen, codepoint: rune, attributes: Attributes, autowrap: bool) {
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
			screen.cursor.column = 0
			line_feed(screen, attributes)
		}
		screen.wrap_pending = false
	}
	if width == 2 && screen.cursor.column == screen.columns - 1 {
		if !autowrap do return
		screen.cursor.column = 0
		line_feed(screen, attributes)
	}

	cell := cell_at(screen, screen.cursor.row, screen.cursor.column)
	cell^ = Cell{codepoint = codepoint, width = u8(width), attributes = attributes}
	if width == 2 {
		continuation := cell_at(screen, screen.cursor.row, screen.cursor.column+1)
		continuation^ = blank_cell(attributes)
		continuation.continuation = true
		continuation.width = 0
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
			if len(screen.scrollback) > screen.scrollback_limit {
				delete(screen.scrollback[0])
				ordered_remove(&screen.scrollback, 0)
			}
		}
		for row in screen.scroll_top..<screen.scroll_bottom {
			copy(screen.cells[row*screen.columns:(row+1)*screen.columns], screen.cells[(row+1)*screen.columns:(row+2)*screen.columns])
		}
		clear_row(screen, screen.scroll_bottom, attributes)
	}
}

scroll_down :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	amount := clamp(count, 1, screen.scroll_bottom-screen.scroll_top+1)
	for _ in 0..<amount {
		for row := screen.scroll_bottom; row > screen.scroll_top; row -= 1 {
			copy(screen.cells[row*screen.columns:(row+1)*screen.columns], screen.cells[(row-1)*screen.columns:row*screen.columns])
		}
		clear_row(screen, screen.scroll_top, attributes)
	}
}

clear_row :: proc(screen: ^Screen, row: int, attributes: Attributes) {
	blank := blank_cell(attributes)
	for &cell in screen.cells[row*screen.columns:(row+1)*screen.columns] do cell = blank
}

erase_cells :: proc(screen: ^Screen, row, first, last: int, attributes: Attributes) {
	first_column := clamp(first, 0, screen.columns-1)
	last_column := clamp(last, first_column, screen.columns-1)
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
}

delete_cells :: proc(screen: ^Screen, count: int, attributes: Attributes) {
	amount := clamp(count, 1, screen.columns-screen.cursor.column)
	row_start := screen.cursor.row * screen.columns
	for column := screen.cursor.column; column < screen.columns-amount; column += 1 {
		screen.cells[row_start+column] = screen.cells[row_start+column+amount]
	}
	erase_cells(screen, screen.cursor.row, screen.columns-amount, screen.columns-1, attributes)
}
