package config

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

window_size_state_paths :: proc() -> (directory, path: string) {
	base := os.get_env("XDG_STATE_HOME", context.temp_allocator)
	if base != "" {
		directory = fmt.aprintf("%s/%s", base, PROFILE_NAME)
		path = fmt.aprintf("%s/window-size", directory)
		return
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return
	directory = fmt.aprintf("%s/.local/state/%s", home, PROFILE_NAME)
	path = fmt.aprintf("%s/window-size", directory)
	return
}

parse_window_size_state :: proc(contents: string) -> (width, height: int, ok: bool) {
	fields, fields_error := strings.fields(contents, context.temp_allocator)
	if fields_error != nil || len(fields) != 2 do return
	width_value, width_ok := strconv.parse_int(fields[0])
	height_value, height_ok := strconv.parse_int(fields[1])
	if !width_ok || !height_ok || width_value < MIN_WINDOW_WIDTH || height_value < MIN_WINDOW_HEIGHT ||
	   width_value > MAX_WINDOW_SIZE || height_value > MAX_WINDOW_SIZE {
		return 0, 0, false
	}
	return width_value, height_value, true
}

window_startup_size :: proc(settings: Window_Settings) -> (width, height: int) {
	width, height = settings.width, settings.height
	if !settings.remember_size do return
	directory, path := window_size_state_paths()
	defer delete(directory)
	defer delete(path)
	if path == "" do return
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do return
	if saved_width, saved_height, ok := parse_window_size_state(string(data)); ok {
		width, height = saved_width, saved_height
	}
	return
}

save_window_size :: proc(settings: Window_Settings, width, height: int) -> bool {
	if !settings.remember_size || width < MIN_WINDOW_WIDTH || height < MIN_WINDOW_HEIGHT ||
	   width > MAX_WINDOW_SIZE || height > MAX_WINDOW_SIZE {
		return false
	}
	directory, path := window_size_state_paths()
	defer delete(directory)
	defer delete(path)
	if directory == "" || path == "" do return false
	if directory_error := os.make_directory_all(directory); directory_error != nil && directory_error != .Exist do return false
	contents := fmt.aprintf("%d %d\n", width, height)
	defer delete(contents)
	return os.write_entire_file(path, contents, {.Read_User, .Write_User}) == nil
}
