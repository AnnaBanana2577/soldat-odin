// The queries on a map: its sectors, a ray cast, the tests of a point or a segment
// against a polygon, and which polygons a team passes.
package polymap

import "../geom"

// Polys in sector (sx, sy), or nil outside the map's sector grid.
sector_at :: proc(m: ^Polymap, sx, sy: int) -> []u16 {
	n := int(m.sectors_num)
	if sx < -n || sx > n || sy < -n || sy > n do return nil
	return m.sectors[(sx + n) * (2 * n + 1) + (sy + n)]
}

// Sector lookup used by soldier collision: excludes the outermost ring.
sector_polys :: proc(m: ^Polymap, pos: geom.Vec2) -> []u16 {
	sx := geom.round_half_even(pos.x / f32(m.sectors_division))
	sy := geom.round_half_even(pos.y / f32(m.sectors_division))
	n := int(m.sectors_num)
	if sx > -n && sx < n && sy > -n && sy < n do return sector_at(m, sx, sy)
	return nil
}

point_in_poly :: proc(p: geom.Vec2, poly: ^Polygon) -> bool {
	a, b, c := poly.verts[0], poly.verts[1], poly.verts[2]
	ap := p - a
	p_ab := (b.x - a.x) * ap.y - (b.y - a.y) * ap.x > 0
	p_ac := (c.x - a.x) * ap.y - (c.y - a.y) * ap.x > 0
	if p_ac == p_ab do return false
	p_bc := (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x) > 0
	return p_bc == p_ab
}

point_in_poly_edges :: proc(p: geom.Vec2, poly: ^Polygon) -> bool {
	for k in 0 ..< 3 {
		if geom.vec2_dot(poly.perp[k], p - poly.verts[k]) < 0 do return false
	}
	return true
}

// Normal of the edge closest to pos, the distance to it, and the edge index (0..2).
closest_perpendicular :: proc(poly: ^Polygon, pos: geom.Vec2) -> (perp: geom.Vec2, dist: f32, edge: int) {
	v := poly.verts
	d1 := geom.point_line_distance(v[0], v[1], pos)
	d2 := geom.point_line_distance(v[1], v[2], pos)
	d3 := geom.point_line_distance(v[2], v[0], pos)
	edge, dist = 0, d1
	if d2 < d1 do edge, dist = 1, d2
	if d3 < d2 && d3 < d1 do edge, dist = 2, d3
	return poly.perp[edge], dist, edge
}

// Intersection of segment a-b with any edge of the polygon.
line_in_poly :: proc(a, b: geom.Vec2, poly: ^Polygon) -> (hit: geom.Vec2, ok: bool) {
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
ray_cast :: proc(m: ^Polymap, a, b: geom.Vec2, max_dist: f32, filter := DEFAULT_RAY_FILTER) -> (dist: f32, hit: bool) {
	dist = geom.vec2_length(a - b)
	if dist > max_dist do return 9999999, true

	div := f32(m.sectors_division)
	ax := geom.round_half_even(min(a.x, b.x) / div)
	ay := geom.round_half_even(min(a.y, b.y) / div)
	bx := geom.round_half_even(max(a.x, b.x) / div)
	by := geom.round_half_even(max(a.y, b.y) / div)
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
				if p, ok := line_in_poly(a, b, poly); ok do return geom.vec2_length(p - a), true
			}
		}
	}

	if filter.check_collider {
		// A segment crossing a collider circle counts as blocked.
		e := a.y - b.y
		f := b.x - a.x
		g := a.x * b.y - a.y * b.x
		h := geom.sqrt_f32(e * e + f * f)
		ab2 := geom.vec2_dot(a - b, a - b)
		for c in m.colliders {
			if !c.active do continue
			if abs(e * c.pos.x + f * c.pos.y + g) / h <= c.radius {
				r := ab2 + c.radius * c.radius
				if geom.vec2_dot(a - c.pos, a - c.pos) <= r && geom.vec2_dot(b - c.pos, b - c.pos) <= r do return dist, false
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
collision_test :: proc(m: ^Polymap, pos: geom.Vec2, is_flag := false) -> (push: geom.Vec2, hit: bool) {
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
