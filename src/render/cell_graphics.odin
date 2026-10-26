package render

import "core:math"

Line_Weight :: enum u8 {
	None,
	Light,
	Heavy,
	Double,
}

Box_Lines :: struct {
	left, right, up, down: Line_Weight,
}

is_cell_graphic :: proc(codepoint: rune) -> bool {
	return codepoint >= 0x23ba && codepoint <= 0x23bd ||
	       codepoint >= 0x2500 && codepoint <= 0x259f ||
	       codepoint >= 0x2800 && codepoint <= 0x28ff
}

append_cell_graphic :: proc(
	output: ^[dynamic]Command,
	x, y, width, height: int,
	codepoint: rune,
	color: u32,
) -> bool {
	if width <= 0 || height <= 0 do return false
	if codepoint >= 0x23ba && codepoint <= 0x23bd {
		positions := [4]int{1, 3, 7, 9}
		thickness := line_thickness(min(width, height), .Light)
		center := y+height*positions[int(codepoint-0x23ba)]/10
		append_rectangle(output, x, center-thickness/2, width, thickness, color)
		return true
	}
	if codepoint >= 0x2580 && codepoint <= 0x259f {
		append_block_element(output, x, y, width, height, codepoint, color)
		return true
	}
	if codepoint >= 0x2800 && codepoint <= 0x28ff {
		append_braille(output, x, y, width, height, codepoint, color)
		return true
	}
	if codepoint < 0x2500 || codepoint > 0x257f do return false
	if append_dashed_or_diagonal(output, x, y, width, height, codepoint, color) do return true
	lines, ok := box_lines(codepoint)
	if !ok do return false
	append_box_lines(output, x, y, width, height, lines, color)
	return true
}

box_lines :: proc(codepoint: rune) -> (lines: Box_Lines, ok: bool) {
	switch codepoint {
	case 0x2500: return Box_Lines{left = .Light, right = .Light}, true
	case 0x2501: return Box_Lines{left = .Heavy, right = .Heavy}, true
	case 0x2502: return Box_Lines{up = .Light, down = .Light}, true
	case 0x2503: return Box_Lines{up = .Heavy, down = .Heavy}, true
	case 0x250c..=0x250f:
		horizontal, vertical := corner_weights(int(codepoint-0x250c))
		return Box_Lines{right = horizontal, down = vertical}, true
	case 0x2510..=0x2513:
		horizontal, vertical := corner_weights(int(codepoint-0x2510))
		return Box_Lines{left = horizontal, down = vertical}, true
	case 0x2514..=0x2517:
		horizontal, vertical := corner_weights(int(codepoint-0x2514))
		return Box_Lines{right = horizontal, up = vertical}, true
	case 0x2518..=0x251b:
		horizontal, vertical := corner_weights(int(codepoint-0x2518))
		return Box_Lines{left = horizontal, up = vertical}, true
	case 0x251c..=0x2523:
		up, branch, down := tee_weights(int(codepoint-0x251c), false)
		return Box_Lines{right = branch, up = up, down = down}, true
	case 0x2524..=0x252b:
		up, branch, down := tee_weights(int(codepoint-0x2524), false)
		return Box_Lines{left = branch, up = up, down = down}, true
	case 0x252c..=0x2533:
		left, right, branch := tee_weights(int(codepoint-0x252c), true)
		return Box_Lines{left = left, right = right, down = branch}, true
	case 0x2534..=0x253b:
		left, right, branch := tee_weights(int(codepoint-0x2534), true)
		return Box_Lines{left = left, right = right, up = branch}, true
	case 0x253c..=0x254b:
		return cross_lines(int(codepoint-0x253c)), true
	case 0x2550: return Box_Lines{left = .Double, right = .Double}, true
	case 0x2551: return Box_Lines{up = .Double, down = .Double}, true
	case 0x2552: return Box_Lines{right = .Double, down = .Light}, true
	case 0x2553: return Box_Lines{right = .Light, down = .Double}, true
	case 0x2554: return Box_Lines{right = .Double, down = .Double}, true
	case 0x2555: return Box_Lines{left = .Double, down = .Light}, true
	case 0x2556: return Box_Lines{left = .Light, down = .Double}, true
	case 0x2557: return Box_Lines{left = .Double, down = .Double}, true
	case 0x2558: return Box_Lines{right = .Double, up = .Light}, true
	case 0x2559: return Box_Lines{right = .Light, up = .Double}, true
	case 0x255a: return Box_Lines{right = .Double, up = .Double}, true
	case 0x255b: return Box_Lines{left = .Double, up = .Light}, true
	case 0x255c: return Box_Lines{left = .Light, up = .Double}, true
	case 0x255d: return Box_Lines{left = .Double, up = .Double}, true
	case 0x255e: return Box_Lines{right = .Double, up = .Light, down = .Light}, true
	case 0x255f: return Box_Lines{right = .Light, up = .Double, down = .Double}, true
	case 0x2560: return Box_Lines{right = .Double, up = .Double, down = .Double}, true
	case 0x2561: return Box_Lines{left = .Double, up = .Light, down = .Light}, true
	case 0x2562: return Box_Lines{left = .Light, up = .Double, down = .Double}, true
	case 0x2563: return Box_Lines{left = .Double, up = .Double, down = .Double}, true
	case 0x2564: return Box_Lines{left = .Double, right = .Double, down = .Light}, true
	case 0x2565: return Box_Lines{left = .Light, right = .Light, down = .Double}, true
	case 0x2566: return Box_Lines{left = .Double, right = .Double, down = .Double}, true
	case 0x2567: return Box_Lines{left = .Double, right = .Double, up = .Light}, true
	case 0x2568: return Box_Lines{left = .Light, right = .Light, up = .Double}, true
	case 0x2569: return Box_Lines{left = .Double, right = .Double, up = .Double}, true
	case 0x256a: return Box_Lines{left = .Double, right = .Double, up = .Light, down = .Light}, true
	case 0x256b: return Box_Lines{left = .Light, right = .Light, up = .Double, down = .Double}, true
	case 0x256c: return Box_Lines{left = .Double, right = .Double, up = .Double, down = .Double}, true
	case 0x256d: return Box_Lines{right = .Light, down = .Light}, true
	case 0x256e: return Box_Lines{left = .Light, down = .Light}, true
	case 0x256f: return Box_Lines{left = .Light, up = .Light}, true
	case 0x2570: return Box_Lines{right = .Light, up = .Light}, true
	case 0x2574: return Box_Lines{left = .Light}, true
	case 0x2575: return Box_Lines{up = .Light}, true
	case 0x2576: return Box_Lines{right = .Light}, true
	case 0x2577: return Box_Lines{down = .Light}, true
	case 0x2578: return Box_Lines{left = .Heavy}, true
	case 0x2579: return Box_Lines{up = .Heavy}, true
	case 0x257a: return Box_Lines{right = .Heavy}, true
	case 0x257b: return Box_Lines{down = .Heavy}, true
	case 0x257c: return Box_Lines{left = .Light, right = .Heavy}, true
	case 0x257d: return Box_Lines{up = .Light, down = .Heavy}, true
	case 0x257e: return Box_Lines{left = .Heavy, right = .Light}, true
	case 0x257f: return Box_Lines{up = .Heavy, down = .Light}, true
	case:
		return {}, false
	}
}

corner_weights :: proc(variation: int) -> (horizontal, vertical: Line_Weight) {
	horizontal = .Heavy if variation&1 != 0 else .Light
	vertical = .Heavy if variation&2 != 0 else .Light
	return
}

tee_weights :: proc(variation: int, horizontal: bool) -> (first, second, branch: Line_Weight) {
	if horizontal {
		weights := [8][3]Line_Weight{
			{.Light, .Light, .Light}, {.Heavy, .Light, .Light},
			{.Light, .Heavy, .Light}, {.Heavy, .Heavy, .Light},
			{.Light, .Light, .Heavy}, {.Heavy, .Light, .Heavy},
			{.Light, .Heavy, .Heavy}, {.Heavy, .Heavy, .Heavy},
		}
		return weights[variation][0], weights[variation][1], weights[variation][2]
	}
	weights := [8][3]Line_Weight{
		{.Light, .Light, .Light}, {.Light, .Heavy, .Light},
		{.Heavy, .Light, .Light}, {.Light, .Light, .Heavy},
		{.Heavy, .Light, .Heavy}, {.Heavy, .Heavy, .Light},
		{.Light, .Heavy, .Heavy}, {.Heavy, .Heavy, .Heavy},
	}
	return weights[variation][0], weights[variation][1], weights[variation][2]
}

cross_lines :: proc(variation: int) -> Box_Lines {
	weights := [16][4]Line_Weight{
		{.Light, .Light, .Light, .Light},
		{.Heavy, .Light, .Light, .Light},
		{.Light, .Heavy, .Light, .Light},
		{.Heavy, .Heavy, .Light, .Light},
		{.Light, .Light, .Heavy, .Light},
		{.Light, .Light, .Light, .Heavy},
		{.Light, .Light, .Heavy, .Heavy},
		{.Heavy, .Light, .Heavy, .Light},
		{.Light, .Heavy, .Heavy, .Light},
		{.Heavy, .Light, .Light, .Heavy},
		{.Light, .Heavy, .Light, .Heavy},
		{.Heavy, .Heavy, .Heavy, .Light},
		{.Heavy, .Heavy, .Light, .Heavy},
		{.Heavy, .Light, .Heavy, .Heavy},
		{.Light, .Heavy, .Heavy, .Heavy},
		{.Heavy, .Heavy, .Heavy, .Heavy},
	}
	value := weights[variation]
	return {left = value[0], right = value[1], up = value[2], down = value[3]}
}

append_box_lines :: proc(output: ^[dynamic]Command, x, y, width, height: int, lines: Box_Lines, color: u32) {
	center_x, center_y := x+width/2, y+height/2
	stroke_scale := min(width, height)
	append_half_horizontal(output, x, center_x+1, center_y, lines.left, stroke_scale, color)
	append_half_horizontal(output, center_x, x+width, center_y, lines.right, stroke_scale, color)
	append_half_vertical(output, y, center_y+1, center_x, lines.up, stroke_scale, color)
	append_half_vertical(output, center_y, y+height, center_x, lines.down, stroke_scale, color)
}

line_thickness :: proc(cross_size: int, weight: Line_Weight) -> int {
	light := max(1, cross_size/12)
	if weight == .Heavy do return max(light+1, cross_size/6)
	return light
}

append_half_horizontal :: proc(
	output: ^[dynamic]Command,
	left, right, center: int,
	weight: Line_Weight,
	cross_size: int,
	color: u32,
) {
	if weight == .None || left >= right do return
	thickness := line_thickness(cross_size, weight)
	if weight == .Double {
		gap := max(1, thickness)
		append_rectangle(output, left, center-gap-thickness, right-left, thickness, color)
		append_rectangle(output, left, center+gap, right-left, thickness, color)
	} else {
		append_rectangle(output, left, center-thickness/2, right-left, thickness, color)
	}
}

append_half_vertical :: proc(
	output: ^[dynamic]Command,
	top, bottom, center: int,
	weight: Line_Weight,
	cross_size: int,
	color: u32,
) {
	if weight == .None || top >= bottom do return
	thickness := line_thickness(cross_size, weight)
	if weight == .Double {
		gap := max(1, thickness)
		append_rectangle(output, center-gap-thickness, top, thickness, bottom-top, color)
		append_rectangle(output, center+gap, top, thickness, bottom-top, color)
	} else {
		append_rectangle(output, center-thickness/2, top, thickness, bottom-top, color)
	}
}

append_dashed_or_diagonal :: proc(
	output: ^[dynamic]Command,
	x, y, width, height: int,
	codepoint: rune,
	color: u32,
) -> bool {
	if codepoint >= 0x256d && codepoint <= 0x2570 {
		append_rounded_corner(output, x, y, width, height, codepoint, color)
		return true
	}
	if codepoint >= 0x2504 && codepoint <= 0x250b || codepoint >= 0x254c && codepoint <= 0x254f {
		horizontal := codepoint == 0x2504 || codepoint == 0x2505 || codepoint == 0x2508 ||
			codepoint == 0x2509 || codepoint == 0x254c || codepoint == 0x254d
		heavy := codepoint == 0x2505 || codepoint == 0x2507 || codepoint == 0x2509 ||
			codepoint == 0x250b || codepoint == 0x254d || codepoint == 0x254f
		pieces := 2 if codepoint >= 0x254c else 3 if codepoint <= 0x2507 else 4
		weight := Line_Weight.Heavy if heavy else .Light
		thickness := line_thickness(min(width, height), weight)
		length := width if horizontal else height
		unit := max(1, length/(pieces*2-1))
		for piece in 0..<pieces {
			start := piece*2*unit
			end := length if piece == pieces-1 else min(length, start+unit)
			if horizontal {
				append_rectangle(output, x+start, y+height/2-thickness/2, end-start, thickness, color)
			} else {
				append_rectangle(output, x+width/2-thickness/2, y+start, thickness, end-start, color)
			}
		}
		return true
	}
	if codepoint >= 0x2571 && codepoint <= 0x2573 {
		if codepoint == 0x2571 || codepoint == 0x2573 do append_diagonal(output, x, y, width, height, false, color)
		if codepoint == 0x2572 || codepoint == 0x2573 do append_diagonal(output, x, y, width, height, true, color)
		return true
	}
	return false
}

append_rounded_corner :: proc(
	output: ^[dynamic]Command,
	x, y, width, height: int,
	codepoint: rune,
	color: u32,
) {
	SAMPLE_GRID :: 8
	sample_total :: SAMPLE_GRID*SAMPLE_GRID
	stroke_pixels := line_thickness(min(width, height), .Light)
	flip_x := codepoint == 0x256e || codepoint == 0x256f
	flip_y := codepoint == 0x256f || codepoint == 0x2570
	target_middle_x := f64(width/2-stroke_pixels/2)+f64(stroke_pixels)/2
	target_middle_y := f64(height/2-stroke_pixels/2)+f64(stroke_pixels)/2
	middle_x := f64(width)-target_middle_x if flip_x else target_middle_x
	middle_y := f64(height)-target_middle_y if flip_y else target_middle_y
	radius := max(1.0, min(f64(width)-middle_x, f64(height)-middle_y))
	center_x := middle_x+radius
	center_y := middle_y+radius
	half_stroke := f64(stroke_pixels)/2

	for pixel_y in 0..<height {
		for pixel_x in 0..<width {
			covered := 0
			for sample_y in 0..<SAMPLE_GRID {
				for sample_x in 0..<SAMPLE_GRID {
					px := f64(pixel_x)+(f64(sample_x)+0.5)/SAMPLE_GRID
					py := f64(pixel_y)+(f64(sample_y)+0.5)/SAMPLE_GRID
					if flip_x do px = f64(width)-px
					if flip_y do py = f64(height)-py
					distance := f64(width+height)
					if px >= middle_x && px <= center_x && py >= middle_y && py <= center_y {
						dx, dy := px-center_x, py-center_y
						distance = abs(math.sqrt(dx*dx+dy*dy)-radius)
					}
					if px >= center_x && px <= f64(width) {
						distance = min(distance, abs(py-middle_y))
					}
					if py >= center_y && py <= f64(height) {
						distance = min(distance, abs(px-middle_x))
					}
					if distance <= half_stroke do covered += 1
				}
			}
			if covered == 0 do continue
			opacity := u8(covered*255/sample_total)
			if opacity == 255 {
				append_rectangle(output, x+pixel_x, y+pixel_y, 1, 1, color)
			} else {
				append_translucent_rectangle(output, x+pixel_x, y+pixel_y, 1, 1, color, opacity)
			}
		}
	}
}

append_diagonal :: proc(
	output: ^[dynamic]Command,
	x, y, width, height: int,
	falling: bool,
	color: u32,
) {
	steps := max(width, height)
	last_x, last_y := -1, -1
	for step in 0..<steps {
		pixel_x := step*(width-1)/max(1, steps-1)
		pixel_y := step*(height-1)/max(1, steps-1)
		if !falling do pixel_y = height-1-pixel_y
		if pixel_x == last_x && pixel_y == last_y do continue
		append_rectangle(output, x+pixel_x, y+pixel_y, 1, 1, color)
		last_x, last_y = pixel_x, pixel_y
	}
}

append_block_element :: proc(
	output: ^[dynamic]Command,
	x, y, width, height: int,
	codepoint: rune,
	color: u32,
) {
	switch codepoint {
	case 0x2580: append_rectangle(output, x, y, width, max(1, height/2), color)
	case 0x2581..=0x2588:
		parts := int(codepoint-0x2580)
		top := y+height-height*parts/8
		append_rectangle(output, x, top, width, y+height-top, color)
	case 0x2589..=0x258f:
		parts := 0x2590-int(codepoint)
		append_rectangle(output, x, y, max(1, width*parts/8), height, color)
	case 0x2590: append_rectangle(output, x+width/2, y, width-width/2, height, color)
	case 0x2591..=0x2593: append_shade(output, x, y, width, height, int(codepoint-0x2590), color)
	case 0x2594: append_rectangle(output, x, y, width, max(1, height/8), color)
	case 0x2595:
		slice := max(1, width/8)
		append_rectangle(output, x+width-slice, y, slice, height, color)
	case 0x2596: append_quadrants(output, x, y, width, height, 0b0100, color)
	case 0x2597: append_quadrants(output, x, y, width, height, 0b1000, color)
	case 0x2598: append_quadrants(output, x, y, width, height, 0b0001, color)
	case 0x2599: append_quadrants(output, x, y, width, height, 0b1101, color)
	case 0x259a: append_quadrants(output, x, y, width, height, 0b1001, color)
	case 0x259b: append_quadrants(output, x, y, width, height, 0b0111, color)
	case 0x259c: append_quadrants(output, x, y, width, height, 0b1011, color)
	case 0x259d: append_quadrants(output, x, y, width, height, 0b0010, color)
	case 0x259e: append_quadrants(output, x, y, width, height, 0b0110, color)
	case 0x259f: append_quadrants(output, x, y, width, height, 0b1110, color)
	case:
	}
}

append_quadrants :: proc(
	output: ^[dynamic]Command,
	x, y, width, height, mask: int,
	color: u32,
) {
	half_width, half_height := width/2, height/2
	if mask&0b0001 != 0 do append_rectangle(output, x, y, half_width, half_height, color)
	if mask&0b0010 != 0 do append_rectangle(output, x+half_width, y, width-half_width, half_height, color)
	if mask&0b0100 != 0 do append_rectangle(output, x, y+half_height, half_width, height-half_height, color)
	if mask&0b1000 != 0 do append_rectangle(output, x+half_width, y+half_height, width-half_width, height-half_height, color)
}

append_shade :: proc(
	output: ^[dynamic]Command,
	x, y, width, height, level: int,
	color: u32,
) {
	for pixel_y in 0..<height {
		run_start := -1
		for pixel_x in 0..=width {
			filled := pixel_x < width && (pixel_x+pixel_y*2)&3 < level
			if filled && run_start < 0 do run_start = pixel_x
			if !filled && run_start >= 0 {
				append_rectangle(output, x+run_start, y+pixel_y, pixel_x-run_start, 1, color)
				run_start = -1
			}
		}
	}
}

append_braille :: proc(
	output: ^[dynamic]Command,
	x, y, width, height: int,
	codepoint: rune,
	color: u32,
) {
	bits := u32(codepoint-0x2800)
	dot_width := max(1, width/4)
	dot_height := max(1, height/8)
	centers_x := [2]int{x+width/4, x+width*3/4}
	centers_y := [4]int{y+height/8, y+height*3/8, y+height*5/8, y+height*7/8}
	dot_bits := [2][4]int{{0, 1, 2, 6}, {3, 4, 5, 7}}
	for column in 0..<2 {
		for row in 0..<4 {
			if bits&(1<<u32(dot_bits[column][row])) == 0 do continue
			append_rectangle(
				output,
				centers_x[column]-dot_width/2,
				centers_y[row]-dot_height/2,
				dot_width,
				dot_height,
				color,
			)
		}
	}
}
