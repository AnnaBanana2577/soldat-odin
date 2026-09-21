package pms

import "core:mem"
import "core:slice"

Error :: enum {
	None,
	Truncated, // the file ended inside a record
	Too_Many_Polys,
	Bad_Sectors,
	Too_Many_Props,
	Too_Many_Scenery,
	Too_Many_Colliders,
	Too_Many_Spawnpoints,
	Too_Many_Waypoints,
}

@(private = "file")
Reader :: struct {
	data:    []u8,
	pos:     int,
	overrun: bool, // set once a read went past the end; everything after it is zeroes
}

// The game's loader zero-fills reads past the end rather than failing, so a truncated
// map still loads with garbage on the end. We fill the same way but remember it, so the
// caller can refuse a file instead of silently inventing the rest of it.
@(private = "file")
take :: proc(r: ^Reader, dst: []u8) {
	if r.pos >= 0 && r.pos + len(dst) <= len(r.data) {
		copy(dst, r.data[r.pos:])
	} else {
		slice.zero(dst)
		r.overrun = true
	}
	r.pos += len(dst)
}

@(private = "file")
take_u8 :: proc(r: ^Reader) -> u8 {
	v: u8
	take(r, mem.ptr_to_bytes(&v))
	return v
}

@(private = "file")
take_u16 :: proc(r: ^Reader) -> u16 {
	v: u16le
	take(r, mem.ptr_to_bytes(&v))
	return u16(v)
}

@(private = "file")
take_i32 :: proc(r: ^Reader) -> i32 {
	v: i32le
	take(r, mem.ptr_to_bytes(&v))
	return i32(v)
}

@(private = "file")
take_f32 :: proc(r: ^Reader) -> f32 {
	v: f32le
	take(r, mem.ptr_to_bytes(&v))
	return f32(v)
}

@(private = "file")
take_vec2 :: proc(r: ^Reader) -> Vec2 {
	x := take_f32(r)
	y := take_f32(r)
	return {x, y}
}

@(private = "file")
take_vec3 :: proc(r: ^Reader) -> Vec3 {
	x := take_f32(r)
	y := take_f32(r)
	z := take_f32(r)
	return {x, y, z}
}

// bgra on disk, rgba in memory.
@(private = "file")
take_color :: proc(r: ^Reader) -> Color {
	b := take_u8(r)
	g := take_u8(r)
	red := take_u8(r)
	a := take_u8(r)
	return {red, g, b, a}
}

// Counts in the file are signed and untrusted. Reject anything negative or past the
// game's own limit before allocating on the strength of it.
@(private = "file")
take_count :: proc(r: ^Reader, limit: int, too_many: Error) -> (n: int, err: Error) {
	n = int(take_i32(r))
	if n < 0 || n > limit {
		return 0, too_many
	}
	return n, .None
}

// Read a whole map. On error nothing stays allocated and the zero value comes back, so
// the caller never has to clean up after a failure.
read :: proc(data: []u8, allocator := context.allocator) -> (m: Map, err: Error) {
	m, err = read_all(data, allocator)
	if err != .None {
		// This cannot be a defer inside read_all. Odin does not carry assignments made
		// in a defer out to the named return values, so the caller would be handed the
		// slices we had just freed.
		destroy(&m, allocator)
	}
	return m, err
}

@(private = "file")
read_all :: proc(data: []u8, allocator: mem.Allocator) -> (m: Map, err: Error) {
	context.allocator = allocator
	r := Reader{data = data}

	m.version = take_i32(&r)
	take(&r, m.name[:])
	take(&r, m.texture[:])
	m.bg_top = take_color(&r)
	m.bg_bottom = take_color(&r)
	m.start_jet = take_i32(&r)
	m.grenades = take_u8(&r)
	m.medikits = take_u8(&r)
	m.weather = take_u8(&r)
	m.steps = take_u8(&r)
	m.random_id = take_i32(&r)

	poly_count := take_count(&r, MAX_POLYS, .Too_Many_Polys) or_return
	m.polygons = make([]Polygon, poly_count)
	for &p in m.polygons {
		for &v in p.verts {
			v.pos = take_vec2(&r)
			v.z = take_f32(&r)
			v.rhw = take_f32(&r)
			v.color = take_color(&r)
			v.uv = take_vec2(&r)
		}
		for &n in p.normals {
			n = take_vec3(&r)
		}
		p.type = Poly_Type(take_u8(&r))
	}

	m.sectors_division = take_i32(&r)
	m.sectors_num = take_i32(&r)
	if m.sectors_num < 0 || m.sectors_num > MAX_SECTOR {
		return m, .Bad_Sectors
	}
	side := sector_side(&m)
	m.sectors = make([][]u16, side * side)
	for &sector in m.sectors {
		count := int(take_u16(&r))
		if count > MAX_POLYS {
			return m, .Bad_Sectors
		}
		sector = make([]u16, count)
		for &idx in sector {
			idx = take_u16(&r) // 1-based, and not necessarily in range
		}
	}

	prop_count := take_count(&r, MAX_PROPS, .Too_Many_Props) or_return
	m.props = make([]Prop, prop_count)
	for &p in m.props {
		p.active = take_u8(&r)
		p._pad0 = take_u8(&r)
		p.style = take_u16(&r)
		p.width = take_i32(&r)
		p.height = take_i32(&r)
		p.pos = take_vec2(&r)
		p.rotation = take_f32(&r)
		p.scale = take_vec2(&r)
		p.alpha = take_u8(&r)
		take(&r, p._pad1[:])
		p.color = take_color(&r)
		p.level = take_u8(&r)
		take(&r, p._pad2[:])
	}

	scenery_count := take_count(&r, MAX_PROPS, .Too_Many_Scenery) or_return
	m.scenery = make([]Scenery, scenery_count)
	for &s in m.scenery {
		take(&r, s.name[:])
		s.date = take_i32(&r)
	}

	collider_count := take_count(&r, MAX_COLLIDERS, .Too_Many_Colliders) or_return
	m.colliders = make([]Collider, collider_count)
	for &c in m.colliders {
		c.active = take_u8(&r)
		take(&r, c._pad0[:])
		c.pos = take_vec2(&r)
		c.radius = take_f32(&r)
	}

	spawn_count := take_count(&r, MAX_SPAWNPOINTS, .Too_Many_Spawnpoints) or_return
	m.spawnpoints = make([]Spawnpoint, spawn_count)
	for &s in m.spawnpoints {
		s.active = take_u8(&r)
		take(&r, s._pad0[:])
		s.x = take_i32(&r)
		s.y = take_i32(&r)
		s.team = take_i32(&r)
	}

	waypoint_count := take_count(&r, MAX_WAYPOINTS, .Too_Many_Waypoints) or_return
	m.waypoints = make([]Waypoint, waypoint_count)
	for &w in m.waypoints {
		w.active = take_u8(&r)
		take(&r, w._pad0[:])
		w.id = take_i32(&r)
		w.x = take_i32(&r)
		w.y = take_i32(&r)
		w.left = take_u8(&r)
		w.right = take_u8(&r)
		w.up = take_u8(&r)
		w.down = take_u8(&r)
		w.jetpack = take_u8(&r)
		w.path_num = take_u8(&r)
		w.action = Waypoint_Action(take_u8(&r))
		take(&r, w._pad1[:])
		w.connections_num = take_i32(&r)
		for &c in w.connections {
			c = take_i32(&r)
		}
	}

	if r.overrun {
		return m, .Truncated
	}
	if r.pos < len(data) {
		m.trailing = slice.clone(data[r.pos:])
	}
	return m, .None
}

destroy :: proc(m: ^Map, allocator := context.allocator) {
	context.allocator = allocator
	delete(m.polygons)
	for sector in m.sectors {
		delete(sector)
	}
	delete(m.sectors)
	delete(m.props)
	delete(m.scenery)
	delete(m.colliders)
	delete(m.spawnpoints)
	delete(m.waypoints)
	delete(m.trailing)
	m^ = {}
}
