package render

import graphics "../graphics"
import vt "../vt"

PLACEHOLDER_CODEPOINT :: rune(0x10EEEE)

placeholder_diacritics := [297]rune{
	0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
	0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
	0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
	0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
	0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
	0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
	0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
	0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
	0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
	0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
	0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
	0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
	0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
	0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
	0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
	0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
	0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
	0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
	0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
	0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
	0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
	0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
	0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
	0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
	0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
	0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
	0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
	0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
	0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
	0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
	0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
	0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
	0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
	0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7,
	0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
	0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
	0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
	0x1D244,
}

Placeholder_Info :: struct {
	image_id: u32,
	placement_id: u32,
	row, column: int,
	most_significant: int,
}

placeholder_diacritic_value :: proc(codepoint: rune) -> (int, bool) {
	for value, index in placeholder_diacritics {
		if value == codepoint do return index, true
	}
	return 0, false
}

placeholder_color_id :: proc(color: vt.Color) -> (u32, bool) {
	switch color.kind {
	case .Default: return 0, false
	case .Indexed, .RGB: return color.value, true
	}
	return 0, false
}

placeholder_advance :: proc(previous: Placeholder_Info, previous_valid: bool, cell: ^vt.Cell) -> (Placeholder_Info, bool) {
	image_id, image_ok := placeholder_color_id(cell.attributes.foreground)
	if !image_ok || image_id == 0 do return {}, false
	placement_id, _ := placeholder_color_id(cell.attributes.underline_color)
	row_value, column_value, most_significant := 0, 0, 0
	count := 0
	for codepoint in cell.combining[:int(cell.combining_count)] {
		value, ok := placeholder_diacritic_value(codepoint)
		if !ok do continue
		switch count {
		case 0: row_value = value
		case 1: column_value = value
		case 2: most_significant = value
		case:
		}
		count += 1
	}
	same := previous_valid && previous.image_id&0xFFFFFF == image_id && previous.placement_id == placement_id
	info := Placeholder_Info{image_id = image_id, placement_id = placement_id}
	switch {
	case count == 0:
		if same {
			info.row = previous.row
			info.column = previous.column+1
			info.most_significant = previous.most_significant
		}
	case count == 1:
		info.row = row_value
		if same && previous.row == info.row {
			info.column = previous.column+1
			info.most_significant = previous.most_significant
		}
	case count == 2:
		info.row = row_value
		info.column = column_value
		if same && previous.row == info.row && previous.column+1 == info.column {
			info.most_significant = previous.most_significant
		}
	case:
		info.row = row_value
		info.column = column_value
		info.most_significant = most_significant
	}
	info.image_id |= (u32(info.most_significant)&0xFF)<<24
	return info, true
}

placeholder_virtual_placement :: proc(registry: ^graphics.Registry, image_id: u64, protocol_id: u32) -> ^graphics.Placement {
	if protocol_id != 0 {
		placement := graphics.find_protocol_placement(registry, image_id, protocol_id)
		if placement != nil && placement.virtual do return placement
		return nil
	}
	for &placement in registry.placements {
		if placement.image_id == image_id && placement.virtual do return &placement
	}
	return nil
}

placeholder_command :: proc(
	placement: ^graphics.Placement,
	info: Placeholder_Info,
	cell_w, cell_h: int,
	screen_row, screen_column, row_top, row_bottom: int,
) -> (Command, bool) {
	fit_x, fit_y, fit_width, fit_height := image_destination(placement^, cell_w, cell_h, 0)
	if fit_width <= 0 || fit_height <= 0 do return {}, false
	if info.row >= placement.rows || info.column >= placement.columns do return {}, false
	grid_x := (screen_column-info.column)*cell_w
	grid_y := (screen_row-info.row)*cell_h
	fit_x += grid_x
	fit_y += grid_y
	cell_left := screen_column*cell_w
	cell_right := cell_left+cell_w
	cell_top := screen_row*cell_h
	cell_bottom := cell_top+cell_h
	left := max(cell_left, fit_x)
	right := min(cell_right, fit_x+fit_width)
	top := max(cell_top, fit_y)
	bottom := min(cell_bottom, fit_y+fit_height)
	if left >= right || top >= bottom do return {}, false
	source_left := placement.source_x+(placement.source_width*(left-fit_x))/fit_width
	source_right := min(placement.source_x+placement.source_width, placement.source_x+(placement.source_width*(right-fit_x)+fit_width-1)/fit_width)
	source_top := placement.source_y+(placement.source_height*(top-fit_y))/fit_height
	source_bottom := min(placement.source_y+placement.source_height, placement.source_y+(placement.source_height*(bottom-fit_y)+fit_height-1)/fit_height)
	source_width := max(1, source_right-source_left)
	source_height := max(1, source_bottom-source_top)
	return Command{
		kind = .Image,
		x = left,
		y = top,
		width = right-left,
		height = bottom-top,
		clip_left = max(0, left),
		clip_right = right,
		clip_top = max(row_top, top),
		clip_bottom = min(row_bottom, bottom),
		image_id = placement.image_id,
		placement_id = placement.id,
		source_x = source_left,
		source_y = source_top,
		source_width = source_width,
		source_height = source_height,
		z = placement.z,
	}, true
}

append_placeholder_commands :: proc(
	output: ^[dynamic]Command,
	screen: ^vt.Screen,
	row: int,
	layer: Image_Layer,
	cell_w, cell_h: int,
) {
	registry := screen.image_registry
	if registry == nil do return
	start := len(output^)
	row_top, row_bottom := row*cell_h, (row+1)*cell_h
	previous: Placeholder_Info
	previous_valid := false
	for column in 0..<screen.columns {
		cell := vt.cell_at(screen, row, column)
		if cell.codepoint != PLACEHOLDER_CODEPOINT {
			previous_valid = false
			continue
		}
		info, ok := placeholder_advance(previous, previous_valid, cell)
		if !ok {
			previous_valid = false
			continue
		}
		previous = info
		previous_valid = true
		resource := graphics.find_protocol_image(registry, .Kitty, info.image_id)
		if resource == nil do continue
		placement := placeholder_virtual_placement(registry, resource.id, info.placement_id)
		if placement == nil do continue
		if image_placement_layer(registry, placement^) != layer do continue
		command, command_ok := placeholder_command(placement, info, cell_w, cell_h, row, column, row_top, row_bottom)
		if command_ok do append(output, command)
	}
	sort_image_commands(output^, start)
}

find_placeholder_anchor :: proc(screen: ^vt.Screen, placement: ^graphics.Placement) -> (row, column: int, ok: bool) {
	registry := screen.image_registry
	if registry == nil || placement == nil do return
	resource := graphics.find_image(registry, placement.image_id)
	if resource == nil do return
	minimum_row := screen.rows
	minimum_column := screen.columns
	for current_row in 0..<screen.rows {
		previous: Placeholder_Info
		previous_valid := false
		for current_column in 0..<screen.columns {
			cell := vt.cell_at(screen, current_row, current_column)
			if cell.codepoint != PLACEHOLDER_CODEPOINT {
				previous_valid = false
				continue
			}
			info, info_ok := placeholder_advance(previous, previous_valid, cell)
			if !info_ok {
				previous_valid = false
				continue
			}
			previous = info
			previous_valid = true
			if info.image_id != resource.protocol_id do continue
			if placement.protocol_id != 0 && info.placement_id != placement.protocol_id do continue
			minimum_row = min(minimum_row, current_row)
			minimum_column = min(minimum_column, current_column)
		}
	}
	if minimum_row == screen.rows || minimum_column == screen.columns do return 0, 0, false
	return minimum_row, minimum_column, true
}
