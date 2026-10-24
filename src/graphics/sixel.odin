package graphics

MAX_SIXEL_COLORS :: 256
MAX_SIXEL_REPEAT :: MAX_IMAGE_DIMENSION

Sixel_Palette :: [MAX_SIXEL_COLORS][4]byte

Sixel_Error :: enum {
	None,
	Malformed,
	Limit,
}

Sixel_Info :: struct {
	transparent: bool,
	pixel_aspect_height: int,
}

Sixel_State :: struct {
	x, y: int,
	max_x, max_y: int,
	raster_width, raster_height: int,
	current_color: int,
	palette: Sixel_Palette,
	pixels: []byte,
	width, height: int,
	seen_raster: bool,
	saw_data: bool,
	pixel_aspect_height: int,
	background_color: [4]byte,
	background_set: bool,
	max_repeat: int,
	max_colors: int,
}

decode_sixel_dcs :: proc(
	data: []byte,
	shared_palette: ^Sixel_Palette = nil,
	limits: ^Limits = nil,
) -> (Decoded_Image, Sixel_Info, Sixel_Error) {
	body, transparent, pixel_aspect_height, header_error := sixel_header(data)
	if header_error != .None do return {}, {}, header_error
	measured := sixel_state_init(pixel_aspect_height, nil, limits)
	if process_error := sixel_process(&measured, body); process_error != .None do return {}, {}, process_error
	width := max(measured.raster_width, measured.max_x)
	height := max(measured.raster_height, measured.max_y)
	if !measured.saw_data && (width == 0 || height == 0) do return {}, {}, .Malformed
	stride, byte_count, layout_error := image_layout_with_limits(width, height, .RGBA8, limits)
	if layout_error != .None do return {}, {}, .Limit
	pixels := make([]byte, byte_count)
	state := sixel_state_init(pixel_aspect_height, shared_palette, limits)
	state.pixels = pixels
	state.width = width
	state.height = height
	if process_error := sixel_process(&state, body); process_error != .None {
		delete(pixels)
		return {}, {}, process_error
	}
	if !transparent {
		background := state.background_color if state.background_set else state.palette[0]
		for offset := 0; offset < len(pixels); offset += 4 {
			if pixels[offset+3] == 0 do copy(pixels[offset:offset+4], background[:])
		}
	}
	if shared_palette != nil do shared_palette^ = state.palette
	return Decoded_Image{
		width = width,
		height = height,
		stride = stride,
		format = .RGBA8,
		pixels = pixels,
	}, Sixel_Info{
		transparent = transparent,
		pixel_aspect_height = state.pixel_aspect_height,
	}, .None
}

sixel_header :: proc(data: []byte) -> (body: []byte, transparent: bool, pixel_aspect_height: int, err: Sixel_Error) {
	values := [3]int{}
	value_index := 0
	value := 0
	active := false
	for index in 0..<len(data) {
		character := data[index]
		if character >= '0' && character <= '9' {
			active = true
			digit := int(character-'0')
			if value > 100_000 do return nil, false, 0, .Malformed
			value = value*10+digit
			continue
		}
		if character == ';' {
			if value_index >= len(values) do return nil, false, 0, .Malformed
			values[value_index] = value if active else 0
			value_index += 1
			value = 0
			active = false
			continue
		}
		if character != 'q' || value_index >= len(values) do return nil, false, 0, .Malformed
		values[value_index] = value if active else 0
		if values[0] < 0 || values[0] > 9 || values[1] < 0 || values[1] > 2 do return nil, false, 0, .Malformed
		return data[index+1:], values[1] == 1, sixel_header_aspect(values[0]), .None
	}
	return nil, false, 0, .Malformed
}

sixel_header_aspect :: proc(value: int) -> int {
	switch value {
	case 2: return 5
	case 3, 4: return 3
	case 7, 8, 9: return 1
	case: return 2
	}
}

sixel_palette_default :: proc() -> Sixel_Palette {
	palette: Sixel_Palette
	defaults := [16][3]byte{
		{0, 0, 0}, {0, 0, 205}, {205, 0, 0}, {205, 0, 205},
		{0, 205, 0}, {0, 205, 205}, {205, 205, 0}, {229, 229, 229},
		{127, 127, 127}, {92, 92, 255}, {255, 0, 0}, {255, 0, 255},
		{0, 255, 0}, {0, 255, 255}, {255, 255, 0}, {255, 255, 255},
	}
	for index in 0..<len(defaults) {
		palette[index] = {defaults[index][0], defaults[index][1], defaults[index][2], 255}
	}
	for index in len(defaults)..<len(palette) do palette[index][3] = 255
	return palette
}

sixel_state_init :: proc(pixel_aspect_height: int, palette: ^Sixel_Palette, limits: ^Limits) -> Sixel_State {
	state: Sixel_State
	state.pixel_aspect_height = pixel_aspect_height
	state.palette = palette^ if palette != nil else sixel_palette_default()
	state.max_repeat = limits.max_sixel_repeat if limits != nil else MAX_SIXEL_REPEAT
	state.max_colors = limits.max_sixel_colors if limits != nil else MAX_SIXEL_COLORS
	return state
}

sixel_process :: proc(state: ^Sixel_State, data: []byte) -> Sixel_Error {
	index := 0
	for index < len(data) {
		character := data[index]
		switch character {
		case '?'..='~':
			if draw_error := sixel_draw(state, character-'?', 1); draw_error != .None do return draw_error
			index += 1
		case '!':
			values, count, next, ok := sixel_parameters(data, index+1, 1)
			if !ok || count != 1 || values[0] <= 0 || values[0] > MAX_SIXEL_REPEAT || next >= len(data) ||
			   data[next] < '?' || data[next] > '~' {
				return .Malformed
			}
			if values[0] > state.max_repeat do return .Limit
			if draw_error := sixel_draw(state, data[next]-'?', values[0]); draw_error != .None do return draw_error
			index = next+1
		case '#':
			values, count, next, ok := sixel_parameters(data, index+1, 5)
			if !ok || (count != 1 && count != 5) || values[0] < 0 || values[0] >= MAX_SIXEL_COLORS do return .Malformed
			if values[0] >= state.max_colors do return .Limit
			state.current_color = values[0]
			if count == 5 {
				color, color_ok := sixel_color(values[1], values[2], values[3], values[4])
				if !color_ok do return .Malformed
				state.palette[state.current_color] = color
			}
			index = next
		case '"':
			if state.seen_raster || state.saw_data do return .Malformed
			values, count, next, ok := sixel_parameters(data, index+1, 4)
			if !ok || (count != 2 && count != 4) || values[0] <= 0 || values[1] <= 0 do return .Malformed
			state.pixel_aspect_height = max(1, (values[0]+values[1]/2)/values[1])
			if state.pixel_aspect_height > MAX_IMAGE_DIMENSION do return .Limit
			if count == 4 {
				if _, _, layout_error := image_layout(values[2], values[3], .RGBA8); layout_error != .None do return .Limit
				state.raster_width, state.raster_height = values[2], values[3]
				state.background_color = state.palette[0]
				state.background_set = true
			}
			state.seen_raster = true
			index = next
		case '$':
			state.x = 0
			index += 1
		case '-':
			state.x = 0
			state.y += 6
			if state.y > MAX_IMAGE_DIMENSION do return .Limit
			index += 1
		case:
			return .Malformed
		}
	}
	return .None
}

sixel_parameters :: proc(data: []byte, start, maximum: int) -> (values: [5]int, count, next: int, ok: bool) {
	index := start
	for count < maximum {
		if index >= len(data) || data[index] < '0' || data[index] > '9' do return values, count, index, false
		value := 0
		for index < len(data) && data[index] >= '0' && data[index] <= '9' {
			digit := int(data[index]-'0')
			if value > 100_000 do return values, count, index, false
			value = value*10+digit
			index += 1
		}
		values[count] = value
		count += 1
		if index >= len(data) || data[index] != ';' do return values, count, index, true
		index += 1
	}
	if index < len(data) && data[index] == ';' do return values, count, index, false
	return values, count, index, true
}

sixel_draw :: proc(state: ^Sixel_State, pattern: byte, repeat: int) -> Sixel_Error {
	if repeat <= 0 || state.x > MAX_IMAGE_DIMENSION-repeat || state.y > MAX_IMAGE_DIMENSION-6 do return .Limit
	if !state.background_set {
		state.background_color = state.palette[0]
		state.background_set = true
	}
	state.saw_data = true
	state.max_x = max(state.max_x, state.x+repeat)
	state.max_y = max(state.max_y, state.y+6)
	if len(state.pixels) > 0 && pattern != 0 {
		color := state.palette[state.current_color]
		for x in state.x..<state.x+repeat {
			for bit in 0..<6 {
				if pattern & (byte(1)<<u32(bit)) == 0 do continue
				y := state.y+bit
				if x >= state.width || y >= state.height do continue
				offset := y*state.width*4+x*4
				copy(state.pixels[offset:offset+4], color[:])
			}
		}
	}
	state.x += repeat
	return .None
}

sixel_color :: proc(system, first, second, third: int) -> ([4]byte, bool) {
	if system == 2 {
		if first < 0 || first > 100 || second < 0 || second > 100 || third < 0 || third > 100 do return {}, false
		return {
			byte((first*255+50)/100),
			byte((second*255+50)/100),
			byte((third*255+50)/100),
			255,
		}, true
	}
	if system != 1 || first < 0 || first > 360 || second < 0 || second > 100 || third < 0 || third > 100 {
		return {}, false
	}
	hue := (first+240)%360
	lightness, saturation := second, third
	chroma := (100-abs(2*lightness-100))*saturation/100
	segment := hue/60
	remainder := hue%120
	x := chroma*(60-abs(remainder-60))/60
	r, g, b := 0, 0, 0
	switch segment {
	case 0: r, g = chroma, x
	case 1: r, g = x, chroma
	case 2: g, b = chroma, x
	case 3: g, b = x, chroma
	case 4: r, b = x, chroma
	case 5: r, b = chroma, x
	}
	match := lightness-chroma/2
	return {
		byte(clamp((r+match)*255/100, 0, 255)),
		byte(clamp((g+match)*255/100, 0, 255)),
		byte(clamp((b+match)*255/100, 0, 255)),
		255,
	}, true
}
