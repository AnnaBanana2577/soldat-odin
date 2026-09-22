package client

// Making a map, and writing one back.
//
// Saving drops the leftovers: the bytes past the end of the waypoints that 97 of the 99
// stock maps carry, left there by editors that rewrote a file in place without
// truncating it. The codec keeps them so that opening and writing is byte-identical and
// therefore testable; an editor that has been asked to save has no reason to hand them on.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../shared/pms"

// The sector grid a new map gets. The game reads this rather than deriving it, so it has
// to be there and be the right shape: (2n+1)^2 cells, all empty until there are polygons
// to put in them.
NEW_SECTORS_DIVISION :: 100
NEW_SECTORS_NUM :: 25

// A blank map that the game will load: a name, a texture, a sky, and an empty sector
// grid. No polygons, so it opens as the gradient and nothing else.
new_map :: proc(name: string, allocator := context.allocator) -> pms.Map {
	context.allocator = allocator
	m: pms.Map

	m.version = pms.VERSION
	pms.set_text(m.name[:], name)
	pms.set_text(m.texture[:], "default.bmp") // resolved to default.png by the lookup
	m.bg_top = {66, 86, 122, 255}
	m.bg_bottom = {16, 18, 26, 255}
	m.start_jet = 190
	m.grenades = 4
	m.medikits = 4
	m.random_id = 1

	m.sectors_division = NEW_SECTORS_DIVISION
	m.sectors_num = NEW_SECTORS_NUM
	side := pms.sector_side(&m)
	m.sectors = make([][]u16, side * side)

	// Empty, but every other list has to exist so write() has something to count.
	m.polygons = make([]pms.Polygon, 0)
	m.props = make([]pms.Prop, 0)
	m.scenery = make([]pms.Scenery, 0)
	m.colliders = make([]pms.Collider, 0)
	m.spawnpoints = make([]pms.Spawnpoint, 0)
	m.waypoints = make([]pms.Waypoint, 0)
	m.trailing = make([]u8, 0)
	return m
}

// Write the open map to base/maps/<name>.pms.
//
// Through a temporary file and a rename, which is not only crash safety: writing over a
// longer file in place without truncating is exactly what left those leftovers behind.
@(private)
save_map :: proc(e: ^Editor) {
	if !e.loaded do return

	name := pms.text_of(e.open.name[:])
	if e.file == "" {
		set_status(e, strings.clone("this map has no filename to save to"))
		return
	}

	// The leftovers are somebody else's accident; do not pass them on.
	e.open.trailing = e.open.trailing[:0]

	bytes := pms.write(&e.open)
	defer delete(bytes)

	path, _ := filepath.join({e.base, "maps", e.file}, context.temp_allocator)
	if err := write_atomically(path, bytes); err != nil {
		set_status(e, fmt.aprintf("could not save %s: %v", e.file, err))
		return
	}
	set_status(e, fmt.aprintf("saved %s  -  %d bytes", e.file, len(bytes)))
	_ = name
}

// Create a map, write it, and open it.
@(private)
create_map :: proc(e: ^Editor, name: string) {
	trimmed := strings.trim_space(name)
	if trimmed == "" {
		set_status(e, strings.clone("a map needs a name"))
		return
	}
	file := strings.has_suffix(trimmed, ".pms") ? strings.clone(trimmed) : strings.concatenate({trimmed, ".pms"})
	defer delete(file)

	path, _ := filepath.join({e.base, "maps", file}, context.temp_allocator)
	if os.exists(path) {
		set_status(e, fmt.aprintf("%s already exists", file))
		return
	}

	m := new_map(strings.trim_suffix(trimmed, ".pms"))
	bytes := pms.write(&m)
	pms.destroy(&m)
	defer delete(bytes)

	if err := write_atomically(path, bytes); err != nil {
		set_status(e, fmt.aprintf("could not create %s: %v", file, err))
		return
	}

	// Reread the list so the new map is in it, then open it the ordinary way.
	reload_names(e)
	open_named(e, file)
}

@(private = "file")
write_atomically :: proc(path: string, bytes: []u8) -> os.Error {
	temp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	os.write_entire_file(temp, bytes) or_return
	if err := os.rename(temp, path); err != nil {
		os.remove(temp)
		return err
	}
	return nil
}
