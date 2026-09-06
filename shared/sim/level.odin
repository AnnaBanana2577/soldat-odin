package sim

import "core:strings"

// The map: polygons in sectors, colliders, spawn points, and the props and scenery
// names the client draws. Loading a .pms and the collision queries on it.
// Ported from OpenSoldat MapFile.pas / PolyMap.pas by way of the old Odin port.

MAX_POLYS       :: 5000
MAX_SECTOR      :: 25
MIN_SECTORZ     :: -35
MAX_SECTORZ     :: 35
MAX_PROPS       :: 500
MAX_SPAWNPOINTS :: 255
MAX_COLLIDERS   :: 128

Poly_Type :: enum u8 {
	Normal                = 0,
	Only_Bullets          = 1,
	Only_Player           = 2,
	Doesnt                = 3,
	Ice                   = 4,
	Deadly                = 5,
	Bloody_Deadly         = 6,
	Hurts                 = 7,
	Regenerates           = 8,
	Lava                  = 9,
	Red_Bullets           = 10,
	Red_Player            = 11,
	Blue_Bullets          = 12,
	Blue_Player           = 13,
	Yellow_Bullets        = 14,
	Yellow_Player         = 15,
	Green_Bullets         = 16,
	Green_Player          = 17,
	Bouncy                = 18,
	Explodes              = 19,
	Hurts_Flaggers        = 20,
	Only_Flaggers         = 21,
	Not_Flaggers          = 22,
	Non_Flagger_Collides  = 23,
	Background            = 24,
	Background_Transition = 25,
}

Color :: [4]u8 // rgba

Polygon :: struct {
	verts:      [3]Vec2,
	colors:     [3]Color,
	uvs:        [3]Vec2,
	perp:       [3]Vec2, // normalized edge normals; perp[k] belongs to edge k -> k+1
	bounciness: f32,
	type:       Poly_Type,
}

Spawnpoint :: struct {
	active: bool,
	pos:    Vec2,
	team:   i32, // 0 general, 1 alpha, 2 bravo, 3 charlie, 4 delta, then the flag and kit spawns
}

Collider :: struct {
	active: bool,
	pos:    Vec2,
	radius: f32,
}

// A piece of scenery placed by the map author. Purely decorative: nothing collides.
Prop :: struct {
	style:         u16, // 1-based index into Level.scenery, 0 = none
	width, height: i32,
	pos:           Vec2,
	rotation:      f32,
	scale:         Vec2,
	alpha:         u8,
	color:         Color,
	level:         u8, // 0 behind the map, 1 in front of it, 2 in front of the players
}

Level :: struct {
	name:             string,
	texture:          string,
	bg_top:           Color,
	bg_bottom:        Color,
	start_jet:        i32,
	grenade_packs:    u8,
	medikits:         u8,
	weather:          u8,
	steps:            u8,
	polys:            []Polygon,
	back_polys:       []u16, // indices of Background / Background_Transition polys
	sectors_division: i32,
	sectors_num:      i32,
	sectors:          [][]u16, // (2n+1)^2 grid of poly indices, see sector_at
	spawnpoints:      []Spawnpoint,
	colliders:        []Collider,
	props:            []Prop,
	scenery:          []string, // image names props refer to by 1-based style
}

Level_Error :: enum {
	None, Too_Many_Polys, Bad_Sectors, Too_Many_Props, Too_Many_Colliders, Too_Many_Spawnpoints,
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
take_vec2 :: proc(r: ^File_Reader) -> Vec2 {
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

level_load :: proc(data: []u8, allocator := context.allocator) -> (m: Level, err: Level_Error) {
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
			if k == 2 do p.bounciness = vec2_length(n) // encoded in the third normal's length
			p.perp[k] = vec2_normalize(n)
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
	// waypoints follow; the bots here do not use them
	return m, .None
}

level_destroy :: proc(m: ^Level, allocator := context.allocator) {
	context.allocator = allocator
	delete(m.name)
	delete(m.texture)
	delete(m.polys)
	delete(m.back_polys)
	delete(m.props)
	for s in m.scenery do delete(s)
	delete(m.scenery)
	for s in m.sectors do delete(s)
	delete(m.sectors)
	delete(m.spawnpoints)
	delete(m.colliders)
	m^ = {}
}

// A random active spawn point of the team's, or of the general ones, or the origin.
level_spawn_point :: proc(m: ^Level, team: Team, rng: ^u64) -> Vec2 {
	want := i32(team)
	for pass in 0 ..< 2 {
		count := 0
		for s in m.spawnpoints do if s.active && s.team == want do count += 1
		if count > 0 {
			pick := rand_int(rng, count)
			for s in m.spawnpoints {
				if !(s.active && s.team == want) do continue
				if pick == 0 do return s.pos
				pick -= 1
			}
		}
		if pass == 0 do want = 0
	}
	return {}
}

// ---- queries ----

// Polys in sector (sx, sy), or nil outside the map's sector grid.
sector_at :: proc(m: ^Level, sx, sy: int) -> []u16 {
	n := int(m.sectors_num)
	if sx < -n || sx > n || sy < -n || sy > n do return nil
	return m.sectors[(sx + n) * (2 * n + 1) + (sy + n)]
}

// Sector lookup used by soldier collision: excludes the outermost ring.
sector_polys :: proc(m: ^Level, pos: Vec2) -> []u16 {
	sx := round_half_even(pos.x / f32(m.sectors_division))
	sy := round_half_even(pos.y / f32(m.sectors_division))
	n := int(m.sectors_num)
	if sx > -n && sx < n && sy > -n && sy < n do return sector_at(m, sx, sy)
	return nil
}

point_in_poly :: proc(p: Vec2, poly: ^Polygon) -> bool {
	a, b, c := poly.verts[0], poly.verts[1], poly.verts[2]
	ap := p - a
	p_ab := (b.x - a.x) * ap.y - (b.y - a.y) * ap.x > 0
	p_ac := (c.x - a.x) * ap.y - (c.y - a.y) * ap.x > 0
	if p_ac == p_ab do return false
	p_bc := (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x) > 0
	return p_bc == p_ab
}

point_in_poly_edges :: proc(p: Vec2, poly: ^Polygon) -> bool {
	for k in 0 ..< 3 {
		if vec2_dot(poly.perp[k], p - poly.verts[k]) < 0 do return false
	}
	return true
}

// Normal of the edge closest to pos, the distance to it, and the edge index (0..2).
closest_perpendicular :: proc(poly: ^Polygon, pos: Vec2) -> (perp: Vec2, dist: f32, edge: int) {
	v := poly.verts
	d1 := point_line_distance(v[0], v[1], pos)
	d2 := point_line_distance(v[1], v[2], pos)
	d3 := point_line_distance(v[2], v[0], pos)
	edge, dist = 0, d1
	if d2 < d1 do edge, dist = 1, d2
	if d3 < d2 && d3 < d1 do edge, dist = 2, d3
	return poly.perp[edge], dist, edge
}

// Intersection of segment a-b with any edge of the polygon.
line_in_poly :: proc(a, b: Vec2, poly: ^Polygon) -> (hit: Vec2, ok: bool) {
	for i in 0 ..< 3 {
		p := poly.verts[i]
		q := poly.verts[(i + 1) % 3]
		if b.x == a.x && q.x == p.x do continue
		if b.x == a.x {
			bk := (q.y - p.y) / (q.x - p.x)
			bm := p.y - bk * p.x
			hit = {a.x, bk * a.x + bm}
			if hit.x > min(p.x, q.x) && hit.x < max(p.x, q.x) && hit.y > min(a.y, b.y) && hit.y < max(a.y, b.y) do return hit, true
		} else if q.x == p.x {
			ak := (b.y - a.y) / (b.x - a.x)
			am := a.y - ak * a.x
			hit = {p.x, ak * p.x + am}
			if hit.y > min(p.y, q.y) && hit.y < max(p.y, q.y) && hit.x > min(a.x, b.x) && hit.x < max(a.x, b.x) do return hit, true
		} else {
			ak := (b.y - a.y) / (b.x - a.x)
			bk := (q.y - p.y) / (q.x - p.x)
			if ak == bk do continue
			am := a.y - ak * a.x
			bm := p.y - bk * p.x
			hit.x = (bm - am) / (ak - bk)
			hit.y = ak * hit.x + am
			if hit.x > min(p.x, q.x) && hit.x < max(p.x, q.x) && hit.x > min(a.x, b.x) && hit.x < max(a.x, b.x) do return hit, true
		}
	}
	return {}, false
}

Ray_Filter :: struct {
	player:         bool,
	flag:           bool,
	bullet:         bool,
	check_collider: bool,
	team:           Team,
}

DEFAULT_RAY_FILTER :: Ray_Filter{bullet = true}

// The distance to the first blocking poly along a-b, if any. Rays longer than
// max_dist report a hit at a huge distance.
ray_cast :: proc(m: ^Level, a, b: Vec2, max_dist: f32, filter := DEFAULT_RAY_FILTER) -> (dist: f32, hit: bool) {
	dist = vec2_length(a - b)
	if dist > max_dist do return 9999999, true

	div := f32(m.sectors_division)
	ax := round_half_even(min(a.x, b.x) / div)
	ay := round_half_even(min(a.y, b.y) / div)
	bx := round_half_even(max(a.x, b.x) / div)
	by := round_half_even(max(a.y, b.y) / div)
	if ax > MAX_SECTORZ || bx < MIN_SECTORZ || ay > MAX_SECTORZ || by < MIN_SECTORZ do return dist, false
	ax = max(MIN_SECTORZ, ax)
	ay = max(MIN_SECTORZ, ay)
	bx = min(MAX_SECTORZ, bx)
	by = min(MAX_SECTORZ, by)

	for sx in ax ..= bx {
		for sy in ay ..= by {
			for w in sector_at(m, sx, sy) {
				poly := &m.polys[w]
				if !ray_poly_collides(poly.type, filter) do continue
				if point_in_poly(a, poly) do return 0, true
				if p, ok := line_in_poly(a, b, poly); ok do return vec2_length(p - a), true
			}
		}
	}

	if filter.check_collider {
		// A segment crossing a collider circle counts as blocked.
		e := a.y - b.y
		f := b.x - a.x
		g := a.x * b.y - a.y * b.x
		h := sqrt_f32(e * e + f * f)
		ab2 := vec2_dot(a - b, a - b)
		for c in m.colliders {
			if !c.active do continue
			if abs(e * c.pos.x + f * c.pos.y + g) / h <= c.radius {
				r := ab2 + c.radius * c.radius
				if vec2_dot(a - c.pos, a - c.pos) <= r && vec2_dot(b - c.pos, b - c.pos) <= r do return dist, false
			}
		}
	}
	return dist, false
}

@(private = "file")
ray_poly_collides :: proc(t: Poly_Type, f: Ray_Filter) -> bool {
	#partial switch t {
	case .Red_Bullets:    return f.team == .Alpha && f.bullet
	case .Red_Player:     return f.team == .Alpha && f.player
	case .Blue_Bullets:   return f.team == .Bravo && f.bullet
	case .Blue_Player:    return f.team == .Bravo && f.player
	case .Yellow_Bullets: return f.team == .Charlie && f.bullet
	case .Yellow_Player:  return f.team == .Charlie && f.player
	case .Green_Bullets:  return f.team == .Delta && f.bullet
	case .Green_Player:   return f.team == .Delta && f.player
	case .Only_Flaggers:  return f.flag && f.player
	case .Not_Flaggers:   return !f.flag && f.player
	case .Non_Flagger_Collides: return f.flag && f.player && f.bullet
	case .Only_Bullets:   return f.bullet
	case .Only_Player:    return f.player
	case .Doesnt, .Background, .Background_Transition: return false
	}
	return true
}

// Point-in-solid test for spawn checks (muzzle, grenade release point): the push-out
// vector of the containing poly.
collision_test :: proc(m: ^Level, pos: Vec2, is_flag := false) -> (push: Vec2, hit: bool) {
	for idx in sector_polys(m, pos) {
		poly := &m.polys[idx]
		#partial switch poly.type {
		case .Only_Bullets, .Only_Player, .Doesnt, .Red_Player, .Blue_Player, .Yellow_Player,
		     .Green_Player, .Background, .Background_Transition:
			continue
		case .Only_Flaggers, .Not_Flaggers, .Non_Flagger_Collides:
			if !is_flag do continue
		}
		if point_in_poly(pos, poly) {
			normal, dist, _ := closest_perpendicular(poly, pos)
			return normal * (1.5 * dist), true
		}
	}
	return {}, false
}

// Whether a bullet fired by `team` collides with a poly of this type.
bullet_team_collides :: proc(t: Poly_Type, team: Team) -> bool {
	#partial switch t {
	case .Red_Bullets, .Red_Player:       return t == .Red_Bullets && team == .Alpha
	case .Blue_Bullets, .Blue_Player:     return t == .Blue_Bullets && team == .Bravo
	case .Yellow_Bullets, .Yellow_Player: return t == .Yellow_Bullets && team == .Charlie
	case .Green_Bullets, .Green_Player:   return t == .Green_Bullets && team == .Delta
	case .Non_Flagger_Collides:           return false
	}
	return true
}

// Whether a (non-bullet) object on `team` collides with a poly of this type.
team_collides :: proc(t: Poly_Type, team: Team) -> bool {
	#partial switch t {
	case .Red_Bullets, .Red_Player:       if t == .Red_Bullets && team == .Alpha || team != .Alpha do return false
	case .Blue_Bullets, .Blue_Player:     if t == .Blue_Bullets && team == .Bravo || team != .Bravo do return false
	case .Yellow_Bullets, .Yellow_Player: if t == .Yellow_Bullets && team == .Charlie || team != .Charlie do return false
	case .Green_Bullets, .Green_Player:   if t == .Green_Bullets && team == .Delta || team != .Delta do return false
	case .Non_Flagger_Collides:           return false
	}
	return true
}

// First intersection of segment start-end with a circle (the start if already inside).
line_circle_collision :: proc(start, end, center: Vec2, radius: f32) -> (point: Vec2, hit: bool) {
	r2 := radius * radius
	if vec2_dot(start - center, start - center) <= r2 do return start, true
	if vec2_dot(end - center, end - center) <= r2 do return end, true
	d := end - start
	a := vec2_dot(d, d)
	if a < 1e-10 do return {}, false
	f := start - center
	b := 2 * vec2_dot(f, d)
	c := vec2_dot(f, f) - r2
	disc := b * b - 4 * a * c
	if disc < 0 do return {}, false
	sq := sqrt_f32(disc)
	t1 := (-b - sq) / (2 * a)
	t2 := (-b + sq) / (2 * a)
	if t1 >= 0 && t1 <= 1 do return start + d * t1, true
	if t2 >= 0 && t2 <= 1 do return start + d * t2, true
	return {}, false
}
