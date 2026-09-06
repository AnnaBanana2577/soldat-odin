package sim

import "core:fmt"
import "core:os"
import "core:path/filepath"

// The one place the sim touches the filesystem: a map from the base assets folder
// (the "shared" folder of opensoldat/base), by name.
level_load_file :: proc(base_dir, map_name: string) -> (m: Level, ok: bool) {
	path, _ := filepath.join({base_dir, "maps", fmt.tprintf("%s.pms", map_name)}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read %s: %v", path, read_err)
		return m, false
	}
	err: Level_Error
	m, err = level_load(data)
	if err != .None {
		fmt.eprintfln("failed to load map %s: %v", path, err)
		return m, false
	}
	return m, true
}
