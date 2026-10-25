package selection

import vt "../vt"

State :: struct {
	anchor: vt.Cursor,
	focus: vt.Cursor,
	active: bool,
	dragging: bool,
}

begin :: proc(state: ^State, screen: ^vt.Screen, position: vt.Cursor, activate: bool = true) {
	normalized := vt.screen_position(screen, position.row, position.column)
	state.anchor = normalized
	state.focus = normalized
	state.active = activate
	state.dragging = true
}

update :: proc(state: ^State, screen: ^vt.Screen, position: vt.Cursor) {
	if !state.dragging do return
	normalized := vt.screen_position(screen, position.row, position.column)
	if normalized != state.anchor do state.active = true
	state.focus = normalized
}

finish :: proc(state: ^State, screen: ^vt.Screen, position: vt.Cursor) {
	update(state, screen, position)
	state.dragging = false
}

clear :: proc(state: ^State) {
	state^ = {}
}

contains :: proc(state: ^State, screen: ^vt.Screen, row, column: int) -> bool {
	if state == nil || !state.active do return false
	position := vt.screen_position(screen, row, column)
	first, last := bounds(state)
	return !vt.cursor_after(first, position) && !vt.cursor_after(position, last) && vt.screen_cell_selectable(screen, row, column)
}

bounds :: proc(state: ^State) -> (first, last: vt.Cursor) {
	first, last = state.anchor, state.focus
	if vt.cursor_after(first, last) do first, last = last, first
	return
}

text :: proc(state: ^State, screen: ^vt.Screen) -> string {
	if state == nil || !state.active do return ""
	return vt.screen_extract(screen, state.anchor, state.focus)
}
