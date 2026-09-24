// A map file: the bytes of a .pms read from disk, and the fields taken out of them.
// The one place the game touches the filesystem for a map. Out-of-range reads yield
// zeroes, like the original loader.
package polymap

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../geom"

// A map from the base assets folder (the "shared" folder of opensoldat/base), by name.
load_file :: proc(base_dir, map_name: string) -> (m: Polymap, ok: bool) {
	path, _ := filepath.join({base_dir, "maps", fmt.tprintf("%s.pms", map_name)}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("failed to read %s: %v", path, read_err)
		return m, false
	}
	err: Error
	m, err = load(data)
	if err != .None {
		fmt.eprintfln("failed to load map %s: %v", path, err)
		return m, false
	}
	return m, true
}

@(private = "file")
File_Reader :: struct {
	data: []u8,
	pos:  int,
}

// Out-of-range reads yield zeroes, like the original loader.
@(private = "file")
take :: proc(r: ^File_Reader, dst: []u8) {
	if r.pos + len(dst) <= len(r.data) {
		copy(dst, r.data[r.pos:])
	} else {
		for &b in dst do b = 0
	}
	r.pos += len(dst)
}

@(private = "file")
take_u8 :: proc(r: ^File_Reader) -> (v: u8) {
	take(r, ([^]u8)(&v)[:1])
	return
}

@(private = "file")
take_u16 :: proc(r: ^File_Reader) -> (v: u16le) {
	take(r, ([^]u8)(&v)[:2])
	return
}

@(private = "file")
take_i32 :: proc(r: ^File_Reader) -> (v: i32le) {
	take(r, ([^]u8)(&v)[:4])
	return
}

@(private = "file")
take_f32 :: proc(r: ^File_Reader) -> (v: f32le) {
	take(r, ([^]u8)(&v)[:4])
	return
}

@(private = "file")
take_vec2 :: proc(r: ^File_Reader) -> geom.Vec2 {
	x := f32(take_f32(r))
	y := f32(take_f32(r))
	return {x, y}
}

// Fixed-size length-prefixed string field.
@(private = "file")
take_string :: proc(r: ^File_Reader, max_size: int) -> string {
	n := int(take_u8(r))
	if n > max_size || r.pos + max_size > len(r.data) {
		r.pos += max_size
		return ""
	}
	field := r.data[r.pos:][:n]
	r.pos += max_size
	if i := strings.index_byte(string(field), 0); i >= 0 do field = field[:i]
	return strings.clone(string(field))
}

// Stored as BGRA on disk.
@(private = "file")
take_color :: proc(r: ^File_Reader) -> Color {
	b := take_u8(r)
	g := take_u8(r)
	red := take_u8(r)
	a := take_u8(r)
	return {red, g, b, a}
}

load :: proc(data: []u8, allocator := context.allocator) -> (m: Polymap, err: Error) {
	context.allocator = allocator
	r := File_Reader{data = data}

	_ = take_i32(&r) // version
	m.name = take_string(&r, 38)
	m.texture = take_string(&r, 24)
	m.bg_top = take_color(&r)
	m.bg_bottom = take_color(&r)
	m.start_jet = 119 * i32(take_i32(&r)) / 100 // the original's "quickfix" scaling
	m.grenade_packs = take_u8(&r)
	m.medikits = take_u8(&r)
	m.weather = take_u8(&r)
	m.steps = take_u8(&r)
	_ = take_i32(&r) // random id

	poly_count := int(take_i32(&r))
	if poly_count < 0 || poly_count > MAX_POLYS do return m, .Too_Many_Polys
	m.polys = make([]Polygon, poly_count)
	back := make([dynamic]u16, 0, 16)
	for &p, i in m.polys {
		for k in 0 ..< 3 {
			p.verts[k] = take_vec2(&r)
			_ = take_f32(&r) // z
			_ = take_f32(&r) // rhw
			p.colors[k] = take_color(&r)
			p.uvs[k] = take_vec2(&r)
		}
		for k in 0 ..< 3 {
			n := take_vec2(&r)
			_ = take_f32(&r) // z
			if k == 2 do p.bounciness = geom.vec2_length(n) // encoded in the third normal's length
			p.perp[k] = geom.vec2_normalize(n)
		}
		p.type = Poly_Type(take_u8(&r))
		if p.type == .Background || p.type == .Background_Transition do append(&back, u16(i))
	}
	m.back_polys = back[:]

	m.sectors_division = i32(take_i32(&r))
	m.sectors_num = i32(take_i32(&r))
	if m.sectors_num < 0 || m.sectors_num > MAX_SECTOR || m.sectors_division <= 0 do return m, .Bad_Sectors
	side := int(2 * m.sectors_num + 1)
	m.sectors = make([][]u16, side * side)
	for &sector in m.sectors {
		count := int(take_u16(&r))
		if count > MAX_POLYS do return m, .Bad_Sectors
		sector = make([]u16, count)
		n := 0
		for _ in 0 ..< count {
			idx := int(take_u16(&r)) - 1 // file indices are 1-based
			if idx >= 0 && idx < poly_count {
				sector[n] = u16(idx)
				n += 1
			}
		}
		sector = sector[:n]
	}

	prop_count := int(take_i32(&r))
	if prop_count < 0 || prop_count > MAX_PROPS do return m, .Too_Many_Props
	props := make([dynamic]Prop, 0, prop_count)
	for _ in 0 ..< prop_count {
		p: Prop
		active := take_u8(&r) != 0
		r.pos += 1
		p.style = u16(take_u16(&r))
		p.width = i32(take_i32(&r))
		p.height = i32(take_i32(&r))
		p.pos = take_vec2(&r)
		p.rotation = f32(take_f32(&r))
		p.scale = take_vec2(&r)
		p.alpha = take_u8(&r)
		r.pos += 3
		p.color = take_color(&r)
		p.level = take_u8(&r)
		r.pos += 3
		// The original hides inactive props, anything above level 2, and styles that
		// name no scenery entry.
		if active && p.level <= 2 && p.style > 0 do append(&props, p)
	}
	m.props = props[:]

	scenery_count := int(take_i32(&r))
	if scenery_count < 0 || scenery_count > MAX_PROPS do return m, .Too_Many_Props
	m.scenery = make([]string, scenery_count)
	for i in 0 ..< scenery_count {
		m.scenery[i] = take_string(&r, 50)
		_ = take_i32(&r) // timestamp
	}
	for &p in m.props {
		if int(p.style) > scenery_count do p.style = 0
	}

	collider_count := int(take_i32(&r))
	if collider_count < 0 || collider_count > MAX_COLLIDERS do return m, .Too_Many_Colliders
	m.colliders = make([]Collider, collider_count)
	for &c in m.colliders {
		c.active = take_u8(&r) != 0
		r.pos += 3
		c.pos = take_vec2(&r)
		c.radius = f32(take_f32(&r))
	}

	spawn_count := int(take_i32(&r))
	if spawn_count < 0 || spawn_count > MAX_SPAWNPOINTS do return m, .Too_Many_Spawnpoints
	m.spawnpoints = make([]Spawnpoint, spawn_count)
	for &s in m.spawnpoints {
		s.active = take_u8(&r) != 0
		r.pos += 3
		x := i32(take_i32(&r))
		y := i32(take_i32(&r))
		s.team = i32(take_i32(&r))
		s.pos = {f32(x), f32(y)}
		if abs(x) >= 2_000_000 || abs(y) >= 2_000_000 do s.active = false
	}
	// The waypoints the bots walk (bot_path.odin), numbered from 1 as their own
	// connections refer to them.
	waypoint_count := int(take_i32(&r))
	if waypoint_count < 0 || waypoint_count > MAX_WAYPOINTS do return m, .Too_Many_Waypoints
	m.waypoints = make([]Waypoint, waypoint_count + 1)
	for &p in m.waypoints[1:] {
		p.active = take_u8(&r) != 0
		r.pos += 3
		_ = take_i32(&r) // the editor's own numbering, which nothing reads
		x := i32(take_i32(&r))
		y := i32(take_i32(&r))
		p.pos = {f32(x), f32(y)}
		p.left = take_u8(&r) != 0
		p.right = take_u8(&r) != 0
		p.up = take_u8(&r) != 0
		p.down = take_u8(&r) != 0
		p.jet = take_u8(&r) != 0
		p.path = take_u8(&r)
		p.action = take_u8(&r)
		r.pos += 5
		p.count = clamp(int(take_i32(&r)), 0, MAX_CONNECTIONS)
		for &c in p.connections {
			c = i32(take_i32(&r))
			if c < 0 || int(c) > waypoint_count do c = 0 // a connection to nowhere
		}
	}
	return m, .None
}
