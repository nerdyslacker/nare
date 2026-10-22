package render

import vt "../vt"
import x11 "../x11"

hit_test :: proc(window: ^x11.Window, screen: ^vt.Screen, x, y: int) -> vt.Cursor {
	column := clamp(x/max(1, window.cell_w), 0, screen.columns-1)
	row := clamp(y/max(1, window.cell_h), 0, screen.rows-1)
	return vt.screen_position(screen, row, column)
}
