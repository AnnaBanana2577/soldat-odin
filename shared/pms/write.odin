package pms

import "core:mem"

// The exact inverse of read. Everything the reader kept is put back where it came from,
// so writing a map that was read and not edited reproduces the original file byte for
// byte. Nothing here validates: the caller decides what a legal map is.

@(private = "file")
Writer :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
put :: proc(w: ^Writer, src: []u8) {
	append(&w.buf, ..src)
}

@(private = "file")
put_u8 :: proc(w: ^Writer, v: u8) {
	value := v
	put(w, mem.ptr_to_bytes(&value))
}

@(private = "file")
put_u16 :: proc(w: ^Writer, v: u16) {
	value := u16le(v)
	put(w, mem.ptr_to_bytes(&value))
}

@(private = "file")
put_i32 :: proc(w: ^Writer, v: i32) {
	value := i32le(v)
	put(w, mem.ptr_to_bytes(&value))
}

@(private = "file")
put_f32 :: proc(w: ^Writer, v: f32) {
	value := f32le(v)
	put(w, mem.ptr_to_bytes(&value))
}

@(private = "file")
put_vec2 :: proc(w: ^Writer, v: Vec2) {
	put_f32(w, v.x)
	put_f32(w, v.y)
}

@(private = "file")
put_vec3 :: proc(w: ^Writer, v: Vec3) {
	put_f32(w, v.x)
	put_f32(w, v.y)
	put_f32(w, v.z)
}

@(private = "file")
put_color :: proc(w: ^Writer, c: Color) {
	put_u8(w, c.b)
	put_u8(w, c.g)
	put_u8(w, c.r)
	put_u8(w, c.a)
}

write :: proc(m: ^Map, allocator := context.allocator) -> []u8 {
	w := Writer {
		buf = make([dynamic]u8, 0, 64 * 1024, allocator),
	}

	put_i32(&w, m.version)
	put(&w, m.name[:])
	put(&w, m.texture[:])
	put_color(&w, m.bg_top)
	put_color(&w, m.bg_bottom)
	put_i32(&w, m.start_jet)
	put_u8(&w, m.grenades)
	put_u8(&w, m.medikits)
	put_u8(&w, m.weather)
	put_u8(&w, m.steps)
	put_i32(&w, m.random_id)

	put_i32(&w, i32(len(m.polygons)))
	for &p in m.polygons {
		for &v in p.verts {
			put_vec2(&w, v.pos)
			put_f32(&w, v.z)
			put_f32(&w, v.rhw)
			put_color(&w, v.color)
			put_vec2(&w, v.uv)
		}
		for n in p.normals {
			put_vec3(&w, n)
		}
		put_u8(&w, u8(p.type))
	}

	put_i32(&w, m.sectors_division)
	put_i32(&w, m.sectors_num)
	for sector in m.sectors {
		put_u16(&w, u16(len(sector)))
		for idx in sector {
			put_u16(&w, idx)
		}
	}

	put_i32(&w, i32(len(m.props)))
	for &p in m.props {
		put_u8(&w, p.active)
		put_u8(&w, p._pad0)
		put_u16(&w, p.style)
		put_i32(&w, p.width)
		put_i32(&w, p.height)
		put_vec2(&w, p.pos)
		put_f32(&w, p.rotation)
		put_vec2(&w, p.scale)
		put_u8(&w, p.alpha)
		put(&w, p._pad1[:])
		put_color(&w, p.color)
		put_u8(&w, p.level)
		put(&w, p._pad2[:])
	}

	put_i32(&w, i32(len(m.scenery)))
	for &s in m.scenery {
		put(&w, s.name[:])
		put_i32(&w, s.date)
	}

	put_i32(&w, i32(len(m.colliders)))
	for &c in m.colliders {
		put_u8(&w, c.active)
		put(&w, c._pad0[:])
		put_vec2(&w, c.pos)
		put_f32(&w, c.radius)
	}

	put_i32(&w, i32(len(m.spawnpoints)))
	for &s in m.spawnpoints {
		put_u8(&w, s.active)
		put(&w, s._pad0[:])
		put_i32(&w, s.x)
		put_i32(&w, s.y)
		put_i32(&w, s.team)
	}

	put_i32(&w, i32(len(m.waypoints)))
	for &wp in m.waypoints {
		put_u8(&w, wp.active)
		put(&w, wp._pad0[:])
		put_i32(&w, wp.id)
		put_i32(&w, wp.x)
		put_i32(&w, wp.y)
		put_u8(&w, wp.left)
		put_u8(&w, wp.right)
		put_u8(&w, wp.up)
		put_u8(&w, wp.down)
		put_u8(&w, wp.jetpack)
		put_u8(&w, wp.path_num)
		put_u8(&w, u8(wp.action))
		put(&w, wp._pad1[:])
		put_i32(&w, wp.connections_num)
		for c in wp.connections {
			put_i32(&w, c)
		}
	}

	put(&w, m.trailing)
	return w.buf[:]
}
