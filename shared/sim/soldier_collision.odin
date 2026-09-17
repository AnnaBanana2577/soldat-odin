package sim

// The soldier against the map, in the original's order: the head's two points, the
// legs' two points (only the second if the first missed), the swept circle, the
// corners. What a special poly does to the soldier is a Hit or a Poly_Effect event,
// never a wound applied here. Ported from OpenSoldat Sprites.pas by way of the old
// Odin port and shared/sim/soldier.lua.

SURFACECOEFX           :: 0.970
SURFACECOEFY           :: 0.970
CROUCHMOVESURFACECOEFX :: 0.850
CROUCHMOVESURFACECOEFY :: 0.970
STANDSURFACECOEFX      :: 0.000
STANDSURFACECOEFY      :: 0.000

SPRITE_COL_RADIUS :: 3
SLIDELIMIT        :: 0.2
MAX_VELOCITY      :: 11.0

// The hit location the original reports for poly damage; not a real skeleton part.
POLY_HIT_PART :: 12

BACKGROUND_NORMAL       :: 0
BACKGROUND_TRANSITION   :: 1
BACKGROUND_POLY_NONE    :: -1
BACKGROUND_POLY_UNKNOWN :: -2

// Walking "into" background polys: they only block when entered from outside.
Background_State :: struct {
	status:      u8,
	poly:        i16,
	test_result: bool,
}

// The whole check, called at the end of the soldier's step once it has moved.
soldier_collide :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	level := ctx.level
	s.on_ground = false
	s.bg.test_result = false

	// head
	check_map_collision(ctx, w, index, s.pos + {-3.5, -12}, 1, events)
	check_map_collision(ctx, w, index, s.pos + {3.5, -12}, 1, events)

	// Lift the trailing leg slightly so walking doesn't catch on slopes.
	body_y, arm_s: f32 = 0, 0
	left, right := .Left in s.controls, .Right in s.controls
	if left != right {
		if left != (s.direction == 1) do arm_s = 0.25
		else do body_y = 0.25
	}
	if body_y == 0 {
		p := s.pos + {2, 1.9}
		if _, hit := ray_cast(level, p, p, 10); hit do body_y = 0.25
	}
	if arm_s == 0 {
		p := s.pos + {-2, 1.9}
		if _, hit := ray_cast(level, p, p, 10); hit do arm_s = 0.25
	}

	// legs: only the second side if the first didn't collide
	s.on_ground = check_map_collision(ctx, w, index, s.pos + {2, 2 - body_y}, 0, events) ||
	              check_map_collision(ctx, w, index, s.pos + {-2, 2 - arm_s}, 0, events)

	s.on_ground_for_law = check_radius_map_collision(ctx, w, index, s.pos + {0, -1}, s.on_ground, events)
	s.on_ground = check_map_vertices_collision(ctx, w, index, s.pos, 3, s.on_ground || s.on_ground_for_law, events) || s.on_ground

	// Debounced ground state: only changes after two identical ticks.
	if s.on_ground == s.on_ground_last do s.on_ground_permanent = s.on_ground
	s.on_ground_last = s.on_ground

	if !s.bg.test_result {
		s.bg.status = BACKGROUND_NORMAL
		s.bg.poly = BACKGROUND_POLY_NONE
	}

	s.vel.x = clamp(s.vel.x, -MAX_VELOCITY, MAX_VELOCITY)
	s.vel.y = clamp(s.vel.y, -MAX_VELOCITY, MAX_VELOCITY)
}

// What a special poly does when a soldier touches it (HandleSpecialPolyTypes). The
// soldier reports its own wound as a Hit on itself.
@(private = "file")
handle_special_poly :: proc(ctx: ^Context, w: ^World, index: u8, t: Poly_Type, pos: Vec2, events: ^Events) {
	s := &w.soldiers[index]
	self_hit :: proc(w: ^World, index: u8, amount: f32, events: ^Events) {
		s := &w.soldiers[index]
		emit(events, Hit{shooter = index, target = index, weapon = .None, amount = amount, part = POLY_HIT_PART, pos = s.pos, push = {}})
	}
	#partial switch t {
	case .Deadly:
		self_hit(w, index, 50 + s.health, events) // lands the soldier on exactly -50
	case .Bloody_Deadly:
		self_hit(w, index, 450 + s.health, events) // past BRUTAL_DEATH_HEALTH, so it gibs
	case .Hurts, .Lava:
		if !s.dead {
			if rand_int(&w.rng, 10) == 0 {
				self_hit(w, index, 5, events)
				emit(events, Poly_Effect{target = index, type = t, pos = pos})
			}
			if s.health < 1 do self_hit(w, index, 10, events)
		}
		if t == .Lava && rand_int(&w.rng, 3) == 0 {
			spark := pos - {0, 3}
			emit(events, Poly_Effect{target = index, type = .Lava, pos = spark, spark = true})
			if rand_int(&w.rng, 3) == 0 {
				bullet_spawn(ctx, w, spark, -s.vel, .Flamer, index, ctx.weapons[.Flamer].damage, events)
			}
		}
	case .Regenerates:
		if s.health < DEFAULT_HEALTH && w.tick % 12 == 0 {
			self_hit(w, index, -2, events) // negative damage heals
			emit(events, Poly_Effect{target = index, type = t, pos = pos})
		}
	case .Explodes:
		if !s.dead {
			origin := pos - {0, 3}
			emit(events, Poly_Effect{target = index, type = t, pos = origin})
			bullet_spawn(ctx, w, origin, {}, .M79, index, ctx.weapons[.M79].damage, events)
			self_hit(w, index, 4000, events)
		}
	case .Hurts_Flaggers:
		// TODO needs the flag carrier check
	}
}

// Point collision against the map polys; area 1 is the head, area 0 the feet.
check_map_collision :: proc(ctx: ^Context, w: ^World, index: u8, at: Vec2, area: int, events: ^Events) -> bool {
	level := ctx.level
	s := &w.soldiers[index]
	pos := at + s.vel

	polys := sector_polys(level, pos)
	if polys == nil do return false
	bg_test_big_poly_center(level, &s.bg, pos)

	for idx in polys {
		poly := &level.polys[idx]
		if !soldier_collides_with(s, poly.type) || !point_in_poly(pos, poly) do continue
		if bg_test(level, &s.bg, idx) do continue

		handle_special_poly(ctx, w, index, poly.type, pos, events)

		normal, dist, _ := closest_perpendicular(poly, pos)
		push := normal * dist
		speed := vec2_length(s.vel)
		if vec2_length(push) > speed do push = vec2_normalize(push) * speed

		if area == 0 || (area == 1 && (s.vel.y < 0 || s.vel.x > SLIDELIMIT || s.vel.x < -SLIDELIMIT)) {
			s.old_pos = s.pos
			s.pos -= push
			if poly.type == .Bouncy do push = vec2_normalize(push) * (poly.bounciness * speed)
			s.vel -= push
		}
		if area == 0 do apply_ground_friction(w, s, poly, normal)
		return true
	}
	return false
}

@(private = "file")
apply_ground_friction :: proc(w: ^World, s: ^Soldier, poly: ^Polygon, normal: Vec2) {
	#partial switch s.legs.id {
	case .Stand, .Crouch, .Prone, .Prone_Move, .Get_Up, .Fall, .Mercy, .Mercy2, .Own:
		// Standing still on a walkable slope: cancel gravity so you don't slide.
		if s.vel.x < SLIDELIMIT && s.vel.x > -SLIDELIMIT && normal.y > SLIDELIMIT {
			s.pos = s.old_pos
			s.forces.y -= w.gravity
		}
		if normal.y > SLIDELIMIT && poly.type != .Ice && poly.type != .Bouncy {
			#partial switch s.legs.id {
			case .Stand, .Fall, .Crouch:
				s.vel *= {STANDSURFACECOEFX, STANDSURFACECOEFY}
				s.forces.x -= s.vel.x
			case .Prone:
				if s.legs.frame > 24 {
					moving := .Crouch in s.controls && (.Left in s.controls || .Right in s.controls)
					if !moving {
						s.vel *= {STANDSURFACECOEFX, STANDSURFACECOEFY}
						s.forces.x -= s.vel.x
					}
				} else {
					s.vel *= {SURFACECOEFX, SURFACECOEFY}
				}
			case .Get_Up:
				s.vel *= {SURFACECOEFX, SURFACECOEFY}
			case .Prone_Move:
				s.vel *= {STANDSURFACECOEFX, STANDSURFACECOEFY}
			}
		}
	case .Crouch_Run, .Crouch_Run_Back:
		s.vel *= {CROUCHMOVESURFACECOEFX, CROUCHMOVESURFACECOEFY}
	case:
		s.vel *= {SURFACECOEFX, SURFACECOEFY}
	}
}

// Swept circle along the velocity, catching thin polys at high speed.
check_radius_map_collision :: proc(ctx: ^Context, w: ^World, index: u8, at: Vec2, has_collided: bool, events: ^Events) -> bool {
	level := ctx.level
	s := &w.soldiers[index]
	spos := at + {0, -3}
	steps := int(vec2_length(s.vel))
	if steps == 0 do steps = 1
	step := s.vel * (1 / f32(steps))

	for _ in 0 ..< steps {
		spos += step
		for idx in sector_polys(level, spos) {
			poly := &level.polys[idx]
			t := poly.type
			collides := team_collides(t, s.team)
			if (!s.holding_flag && t == .Only_Flaggers) || (s.holding_flag && t == .Not_Flaggers) do collides = false
			if !collides || t == .Doesnt || t == .Only_Bullets do continue
			for k in 0 ..< 3 {
				probe := spos - poly.perp[k] * SPRITE_COL_RADIUS
				if !point_in_poly_edges(probe, poly) do continue
				if bg_test(level, &s.bg, idx) do continue
				if !has_collided do handle_special_poly(ctx, w, index, t, probe, events)
				normal, _, edge := closest_perpendicular(poly, spos)
				dist := point_line_distance(poly.verts[edge], poly.verts[(edge + 1) % 3], probe)
				s.pos = s.old_pos
				s.vel = s.forces - normal * dist
				return true
			}
		}
	}
	return false
}

// Pushes the soldier away from poly corners within radius r.
check_map_vertices_collision :: proc(ctx: ^Context, w: ^World, index: u8, pos: Vec2, r: f32, has_collided: bool, events: ^Events) -> bool {
	level := ctx.level
	s := &w.soldiers[index]
	for idx in sector_polys(level, pos) {
		poly := &level.polys[idx]
		if !soldier_collides_with(s, poly.type) do continue
		for vert in poly.verts {
			if vec2_length(vert - pos) >= r do continue
			if bg_test(level, &s.bg, idx) do continue
			if !has_collided do handle_special_poly(ctx, w, index, poly.type, pos, events)
			s.pos += vec2_normalize(pos - vert)
			return true
		}
	}
	return false
}

soldier_collides_with :: proc(s: ^Soldier, t: Poly_Type) -> bool {
	if t == .Only_Flaggers do return s.holding_flag
	if t == .Not_Flaggers do return !s.holding_flag
	return t != .Doesnt && t != .Only_Bullets && team_collides(t, s.team)
}

// True if the poly is to be ignored as a background poly.
bg_test :: proc(m: ^Level, bg: ^Background_State, poly: u16) -> bool {
	#partial switch m.polys[poly].type {
	case .Background:
		if bg.status == BACKGROUND_TRANSITION {
			bg.test_result = true
			bg.poly = i16(poly)
			return true
		}
	case .Background_Transition:
		bg.test_result = true
		if bg.status == BACKGROUND_NORMAL do bg.status = BACKGROUND_TRANSITION
		return true
	}
	return false
}

bg_test_big_poly_center :: proc(m: ^Level, bg: ^Background_State, pos: Vec2) {
	if bg.status != BACKGROUND_TRANSITION do return
	if bg.poly == BACKGROUND_POLY_UNKNOWN {
		bg.poly = BACKGROUND_POLY_NONE
		for idx in m.back_polys {
			if point_in_poly(pos, &m.polys[idx]) {
				bg.poly = i16(idx)
				bg.test_result = true
				break
			}
		}
	} else if bg.poly != BACKGROUND_POLY_NONE && point_in_poly(pos, &m.polys[bg.poly]) {
		bg.test_result = true
	}
}
