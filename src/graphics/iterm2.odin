package graphics

import base64 "core:encoding/base64"
import "core:strconv"
import "core:strings"

ITerm2_Size_Kind :: enum {
	Auto,
	Cells,
	Pixels,
	Percent,
}

ITerm2_Size :: struct {
	kind: ITerm2_Size_Kind,
	value: int,
}

ITerm2_Command :: struct {
	width, height: ITerm2_Size,
	preserve_aspect: bool,
}

ITerm2_Error :: enum {
	None,
	Malformed,
	Unsupported,
	Limit,
}

decode_iterm2_inline :: proc(data: []byte, limits: ^Limits = nil) -> (ITerm2_Command, Decoded_Image, ITerm2_Error) {
	command := ITerm2_Command{preserve_aspect = true}
	separator := strings.index_byte(string(data), ':')
	if separator < 0 do return command, {}, .Malformed
	metadata := string(data[:separator])
	payload := data[separator+1:]
	inline := false
	declared_size := -1
	seen_inline, seen_size, seen_width, seen_height, seen_aspect, seen_name := false, false, false, false, false, false
	for len(metadata) > 0 {
		field := metadata
		if end := strings.index_byte(metadata, ';'); end >= 0 {
			field = metadata[:end]
			metadata = metadata[end+1:]
		} else {
			metadata = ""
		}
		equals := strings.index_byte(field, '=')
		if equals <= 0 do return command, {}, .Malformed
		key, value := field[:equals], field[equals+1:]
		switch key {
		case "inline":
			if seen_inline || (value != "0" && value != "1") do return command, {}, .Malformed
			seen_inline = true
			inline = value == "1"
		case "size":
			if seen_size do return command, {}, .Malformed
			seen_size = true
			parsed, ok := strconv.parse_int(value)
			if !ok || parsed < 0 || parsed > MAX_PNG_BYTES do return command, {}, .Limit
			declared_size = parsed
		case "width":
			if seen_width do return command, {}, .Malformed
			seen_width = true
			parsed, ok := iterm2_size(value)
			if !ok do return command, {}, .Malformed
			command.width = parsed
		case "height":
			if seen_height do return command, {}, .Malformed
			seen_height = true
			parsed, ok := iterm2_size(value)
			if !ok do return command, {}, .Malformed
			command.height = parsed
		case "preserveAspectRatio":
			if seen_aspect || (value != "0" && value != "1") do return command, {}, .Malformed
			seen_aspect = true
			command.preserve_aspect = value == "1"
		case "name":
			if seen_name || len(value) > 4096 do return command, {}, .Malformed
			seen_name = true
			decoded_name, decode_error := base64.decode(value, options = {.Strict})
			if decode_error != nil do return command, {}, .Malformed
			delete(decoded_name)
		case:
		}
	}
	if !inline do return command, {}, .Unsupported
	if len(payload) == 0 || len(payload) > ((MAX_PNG_BYTES+2)/3)*4 do return command, {}, .Limit
	decoded, decode_error := base64.decode(string(payload), options = {.Strict})
	if decode_error != nil do return command, {}, .Malformed
	defer delete(decoded)
	if declared_size >= 0 && declared_size != len(decoded) do return command, {}, .Malformed
	if len(decoded) >= 8 && string(decoded[:8]) == "\x89PNG\r\n\x1a\n" {
		image, png_error := decode_png(decoded, limits)
		switch png_error {
		case .None: return command, image, .None
		case .Limit: return command, {}, .Limit
		case .Unsupported: return command, {}, .Unsupported
		case .Invalid_Data: return command, {}, .Malformed
		}
	} else if len(decoded) >= 3 && decoded[0] == 0xff && decoded[1] == 0xd8 && decoded[2] == 0xff {
		image, jpeg_error := decode_jpeg(decoded, limits)
		switch jpeg_error {
		case .None: return command, image, .None
		case .Limit: return command, {}, .Limit
		case .Invalid_Data: return command, {}, .Malformed
		}
	} else if len(decoded) >= 6 && (string(decoded[:6]) == "GIF87a" || string(decoded[:6]) == "GIF89a") {
		image, gif_error := decode_gif(decoded, limits)
		switch gif_error {
		case .None: return command, image, .None
		case .Limit: return command, {}, .Limit
		case .Invalid_Data: return command, {}, .Malformed
		}
	}
	return command, {}, .Unsupported
}

iterm2_size :: proc(value: string) -> (ITerm2_Size, bool) {
	if value == "auto" do return {}, true
	kind := ITerm2_Size_Kind.Cells
	number := value
	if strings.has_suffix(value, "px") {
		kind = .Pixels
		number = value[:len(value)-2]
	} else if strings.has_suffix(value, "%") {
		kind = .Percent
		number = value[:len(value)-1]
	}
	parsed, ok := strconv.parse_int(number)
	if !ok || parsed <= 0 || kind == .Percent && parsed > 100 || parsed > MAX_PLACEMENT_CELLS do return {}, false
	return ITerm2_Size{kind = kind, value = parsed}, true
}
