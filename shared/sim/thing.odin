package sim

// The thing pool and what every thing shares: a small Verlet skeleton (two points
// for a gun, four for a flag, kit, parachute or stationary gun), its physics against
// the map, a holder, a timeout. What each kind of thing means lives in its own file:
// flag, kit, dropped_gun, parachute, stat_gun. Ported from TThing in Things.pas by
// way of shared/sim/things.lua.

FLAG_SCALE :: 4.0
KIT_SCALE  :: 2.15
PARA_SCALE :: 5.0
STAT_SCALE :: 4.0

MIN_MOVE_DELTA     :: 0.63 // below this average movement a grounded thing goes static
FLAG_STAND_FORCEUP :: -16.0
THING_LIFT         :: 0.5 // the collision probe sits this far above the point

// The spawn point kinds the map author places.
SPAWN_ALPHA_FLAG  :: 5
SPAWN_BRAVO_FLAG  :: 6
SPAWN_GRENADE_KIT :: 7
SPAWN_MEDICAL_KIT :: 8
SPAWN_STAT_GUN    :: 16

Thing_Style :: enum u8 {
	None, Alpha_Flag, Bravo_Flag, Medical_Kit, Grenade_Kit, Weapon,
	Flamer_Kit, Predator_Kit, Vest_Kit, Berserk_Kit, Cluster_Kit, Parachute, Stat_Gun,
}

Thing :: struct {
	style:         Thing_Style,
	weapon:        Weapon_Id, // a dropped gun's
	ammo:          i32,
	flip:          bool, // a dropped gun thrown facing left
	holder:        u8,   // soldier index + 1, 0 when loose
	owner:         u8,   // who dropped or threw it, index + 1
	timeout:       i32,
	static:        bool, // at rest: no physics until something moves it
	points:        int,  // 2 or 4
	pos:           [4]Vec2,
	old_pos:       [4]Vec2,
	forces:        [4]Vec2,
	collide_count: [4]u8, // touches per point, for the landing sounds
	in_base:       bool,  // a flag at home
	interest:      i32,   // a stationary gun's heat
	respawn_wait:  i32,   // a taken kit's way back
	respawn_style: Thing_Style,
}

// The particle objects the things are built from.
Skeletons :: struct {
	flag, kit, para, stat: Particle_Object,
	gostek:                Particle_Object, // the corpses' constraints and rest lengths
	rifles:                [len(GUN_SCALES)]Particle_Object, // karabin.po at each gun length
}

GUN_SCALES :: [?]f32{1.0, 1.1, 1.8, 2.2, 2.8, 3.6, 3.7, 3.9, 4.3, 5.0, 5.5}

// A dropped gun: karabin.po at the gun's length, with its own damping and gravity.
Gun_Object :: struct {
	scale, damping, gravity: f32,
}

GUN_OBJECTS := #partial [Weapon_Id]Gun_Object{
	.Colt = {1.0, 0.994, 1.05}, .Eagle = {1.1, 0.996, 1.09}, .MP5 = {2.2, 0.995, 1.11},
	.AK74 = {3.7, 0.994, 1.16}, .Steyr = {3.7, 0.994, 1.16}, .Spas = {3.6, 0.993, 1.15},
	.Ruger = {3.6, 0.993, 1.13}, .M79 = {2.8, 0.994, 1.15}, .Barrett = {4.3, 0.993, 1.18},
	.M249 = {3.9, 0.993, 1.2}, .Minigun = {5.5, 0.991, 1.4}, .Knife = {1.8, 0.994, 1.15},
	.Chainsaw = {2.8, 0.994, 1.15}, .LAW = {2.8, 0.994, 1.15}, .Bow = {5.0, 0.996, 0.65},
	.Bow2 = {5.0, 0.996, 0.65},
}

// Damping and gravity of the rest (CreateThing's cases).
@(private = "file")
Thing_Physics :: struct {
	damping, gravity: f32,
}

@(private = "file")
THING_PHYSICS := [Thing_Style]Thing_Physics{
	.None = {0.989, 1.05}, .Alpha_Flag = {0.991, 1.0}, .Bravo_Flag = {0.991, 1.0},
	.Medical_Kit = {0.989, 1.05}, .Grenade_Kit = {0.989, 1.07}, .Cluster_Kit = {0.989, 1.07},
	.Flamer_Kit = {0.989, 1.17}, .Predator_Kit = {0.989, 1.17}, .Vest_Kit = {0.989, 1.17}, .Berserk_Kit = {0.989, 1.17},
	.Weapon = {0.989, 1.05}, .Parachute = {0.993, 1.15}, .Stat_Gun = {0.99, 0.2},
}

is_flag :: proc(style: Thing_Style) -> bool {
	return style == .Alpha_Flag || style == .Bravo_Flag
}

// The skeleton a thing is built from.
thing_skeleton :: proc(ctx: ^Context, style: Thing_Style, weapon: Weapon_Id) -> ^Particle_Object {
	sk := ctx.skeletons
	#partial switch style {
	case .Alpha_Flag, .Bravo_Flag: return &sk.flag
	case .Parachute: return &sk.para
	case .Stat_Gun:  return &sk.stat
	case .Weapon:
		gun := GUN_OBJECTS[weapon]
		for scale, i in GUN_SCALES do if scale == gun.scale do return &sk.rifles[i]
	}
	return &sk.kit
}

@(private = "file")
thing_physics_of :: proc(t: ^Thing) -> (damping, gravity: f32) {
	if t.style == .Weapon {
		if gun := GUN_OBJECTS[t.weapon]; gun.scale > 0 do return gun.damping, gun.gravity
	}
	p := THING_PHYSICS[t.style]
	return p.damping, p.gravity
}

// Builds a thing of a style at a spot from its skeleton, at rest.
thing_place :: proc(ctx: ^Context, t: ^Thing, style: Thing_Style, pos: Vec2, weapon: Weapon_Id = .None) {
	t^ = {style = style, weapon = weapon}
	skel := thing_skeleton(ctx, style, weapon)
	t.points = min(4, len(skel.points))
	for k in 0 ..< 4 {
		p := skel.points[min(k, t.points - 1)]
		t.pos[k] = p + pos
	}
	// the two flags face each other: alpha's cloth is mirrored to the other side
	if style == .Alpha_Flag {
		t.pos[2].x = pos.x + 12
		t.pos[3].x = pos.x + 12
	}
	t.old_pos = t.pos
	t.in_base = is_flag(style)
	t.timeout = FLAG_TIMEOUT
}

thing_create :: proc(ctx: ^Context, w: ^World, style: Thing_Style, pos: Vec2, weapon: Weapon_Id = .None) -> (index: int, ok: bool) {
	for &t, i in w.things {
		if t.style != .None || t.respawn_wait > 0 do continue
		thing_place(ctx, &t, style, pos, weapon)
		return i, true
	}
	return 0, false
}

thing_clear :: proc(t: ^Thing) {
	t^ = {}
}

// A random active spawn point of this exact kind.
level_thing_spawn :: proc(m: ^Level, kind: i32, rng: ^u64) -> (pos: Vec2, ok: bool) {
	count := 0
	for s in m.spawnpoints do if s.active && s.team == kind do count += 1
	if count == 0 do return {}, false
	n := rand_int(rng, count)
	for s in m.spawnpoints {
		if !(s.active && s.team == kind) do continue
		if n == 0 do return s.pos, true
		n -= 1
	}
	return {}, false
}

// The flags and kits from the map's spawn points, at the start of a round.
things_spawn :: proc(ctx: ^Context, w: ^World) {
	for &t in w.things do thing_clear(&t)
	if pos, ok := level_thing_spawn(ctx.level, SPAWN_ALPHA_FLAG, &w.rng); ok {
		w.flag_home[0] = pos
		thing_create(ctx, w, .Alpha_Flag, pos)
	}
	if pos, ok := level_thing_spawn(ctx.level, SPAWN_BRAVO_FLAG, &w.rng); ok {
		w.flag_home[1] = pos
		thing_create(ctx, w, .Bravo_Flag, pos)
	}
	for _ in 0 ..< ctx.level.medikits do kit_spawn(ctx, w, .Medical_Kit)
	if w.round.max_grenades > 0 do for _ in 0 ..< ctx.level.grenade_packs do kit_spawn(ctx, w, .Grenade_Kit)
	for s in ctx.level.spawnpoints {
		if s.active && s.team == SPAWN_STAT_GUN {
			if i, ok := thing_create(ctx, w, .Stat_Gun, s.pos); ok do w.things[i].timeout = 60
		}
	}
}

things_update :: proc(ctx: ^Context, w: ^World, events: ^Events) {
	for &t, i in w.things {
		switch t.style {
		case .None:
			kit_respawn_tick(ctx, w, &t)
		case .Alpha_Flag, .Bravo_Flag:
			flag_update(ctx, w, &t, u8(i), events)
		case .Weapon:
			dropped_gun_update(ctx, w, &t, u8(i), events)
		case .Medical_Kit, .Grenade_Kit, .Flamer_Kit, .Predator_Kit, .Vest_Kit, .Berserk_Kit, .Cluster_Kit:
			kit_update(ctx, w, &t, u8(i), events)
		case .Parachute:
			parachute_update(ctx, w, &t, u8(i), events)
		case .Stat_Gun:
			stat_gun_update(ctx, w, &t, u8(i), events)
		}
	}
}

// A client's claim to have taken a thing: judged with the claimant alone in mind,
// first claim wins. Returns true and emits the pickup when taken.
// A pickup as a client predicts it: the thing is free, this soldier may take it and
// is near, so it takes it. The claim goes to the server from the event.
thing_claim :: proc(ctx: ^Context, w: ^World, soldier: u8, index: u8, events: ^Events) -> bool {
	t := &w.things[index]
	s := &w.soldiers[soldier]
	if !thing_free(t, s) || !thing_may_take(w, t, s) do return false
	thing_take(ctx, w, soldier, index, events)
	return true
}

// A pickup as the server grants it, and as every client applies the commit: the
// claimant judged its own reach and need, which its relayed copy here may no longer
// show. Only the contest is judged: the thing is still there, in nobody's hands.
thing_grant :: proc(ctx: ^Context, w: ^World, soldier: u8, index: u8, events: ^Events) -> bool {
	t := &w.things[index]
	if !thing_free(t, &w.soldiers[soldier]) do return false
	thing_take(ctx, w, soldier, index, events)
	return true
}

thing_free :: proc(t: ^Thing, s: ^Soldier) -> bool {
	return t.style != .None && t.holder == 0 && s.active && !s.dead
}

thing_may_take :: proc(w: ^World, t: ^Thing, s: ^Soldier) -> bool {
	#partial switch t.style {
	case .Alpha_Flag, .Bravo_Flag:
		return flag_can_grab(t, s)
	case .Weapon:
		return dropped_gun_can_pickup(t, s)
	case .Medical_Kit, .Grenade_Kit, .Flamer_Kit, .Predator_Kit, .Vest_Kit, .Berserk_Kit, .Cluster_Kit:
		return kit_can_pickup(w, t, s)
	}
	return false
}

thing_take :: proc(ctx: ^Context, w: ^World, soldier: u8, index: u8, events: ^Events) {
	t := &w.things[index]
	#partial switch t.style {
	case .Alpha_Flag, .Bravo_Flag:
		flag_grab(t, index, soldier, events)
	case .Weapon:
		dropped_gun_pickup(ctx, w, t, index, soldier, events)
	case .Medical_Kit, .Grenade_Kit, .Flamer_Kit, .Predator_Kit, .Vest_Kit, .Berserk_Kit, .Cluster_Kit:
		kit_pickup(ctx, w, t, index, soldier, events)
	}
}

// A holder that died or left drops the thing where it is.
thing_check_holder :: proc(w: ^World, t: ^Thing) {
	if t.holder == 0 do return
	h := &w.soldiers[t.holder - 1]
	if !h.active || h.dead {
		t.holder = 0
		t.static = false
	}
}

thing_center :: proc(t: ^Thing) -> Vec2 {
	return (t.pos[0] + t.pos[1]) * 0.5
}

// Moves a thing forward by some ticks: a relayed thing arrives whole with the age of
// its state, and every world runs it on from the same numbers.
thing_advance :: proc(ctx: ^Context, w: ^World, t: ^Thing, ticks: int, events: ^Events) {
	for _ in 0 ..< ticks do thing_physics(ctx, w, t, events)
}

// One tick of the Verlet skeleton: each point against the map, then the integration
// with the thing's damping and gravity, one constraint pass, and rest once settled.
// While carried only the cloth tip collides, but every point still integrates or the
// cloth freezes into a board.
thing_physics :: proc(ctx: ^Context, w: ^World, t: ^Thing, events: ^Events) {
	flag := is_flag(t.style)
	damping, gravity := thing_physics_of(t)
	team := Team.None
	if t.owner > 0 {
		if o := &w.soldiers[t.owner - 1]; o.active do team = o.team
	}

	collided, collided2 := false, false
	for k in 0 ..< t.points {
		if t.holder > 0 && k != 1 do continue
		p := t.pos[k]
		hit: bool
		if flag && k == 0 {
			// the pole base probes around itself so the flag can stand on ledges
			hit = thing_collide(ctx, t, k, p + {-10, -8}, team) || thing_collide(ctx, t, k, p + {10, -8}, team) ||
			      thing_collide(ctx, t, k, p + {-10, 0}, team) || thing_collide(ctx, t, k, p + {10, 0}, team)
			if hit do t.forces[1].y += FLAG_STAND_FORCEUP * w.gravity
		} else {
			hit = thing_collide(ctx, t, k, p, team)
		}
		if !hit do continue
		if collided do collided2 = true
		collided = true
		// the landing sounds: the first touch of each point, then any hard enough bounce
		n := t.collide_count[k]
		moved := vec2_length(p - t.old_pos[k])
		limit: u8 = t.style == .Weapon ? 30 : 3
		if n == 0 || (moved > 1.5 && n < limit) do emit(events, Thing_Hit{thing = t.style, pos = p, vel = p - t.old_pos[k], part = u8(k)})
		t.collide_count[k] = min(n + 1, 255)
	}

	for k in 0 ..< t.points {
		t.forces[k].y += gravity * w.gravity
		p := t.pos[k]
		t.pos[k] = p * (1 + damping) - t.old_pos[k] * damping + t.forces[k]
		t.old_pos[k] = p
		t.forces[k] = {}
	}

	// a stationary gun's base freezes once it has settled
	if t.style == .Stat_Gun && t.timeout < 0 {
		t.pos[1], t.pos[2] = t.old_pos[1], t.old_pos[2]
	}

	skel := thing_skeleton(ctx, t.style, t.weapon)
	for c in skel.constraints {
		a, b := c[0], c[1]
		if a >= 4 || b >= 4 do continue
		rest := vec2_length(skel.points[b] - skel.points[a])
		d := t.pos[b] - t.pos[a]
		l := vec2_length(d)
		if l == 0 do continue
		diff := (l - rest) / l
		t.pos[a] += d * 0.5 * diff
		t.pos[b] -= d * 0.5 * diff
	}

	// settled: stop simulating until something disturbs it
	if t.style != .Stat_Gun && t.holder == 0 && collided && collided2 {
		movement := (vec2_length(t.pos[0] - t.old_pos[0]) + vec2_length(t.pos[1] - t.old_pos[1])) / 2
		if movement < MIN_MOVE_DELTA {
			t.static = true
			t.old_pos = t.pos
		}
	}
}

// A point against the map: a flag's pole base stops dead and its other points
// bounce along the push-out; everything else is put back where it was and pushed
// out, so guns and kits slide to a stop instead of bouncing.
@(private = "file")
thing_collide :: proc(ctx: ^Context, t: ^Thing, k: int, at: Vec2, team: Team) -> bool {
	level := ctx.level
	probe := at - {0, THING_LIFT}
	flag := is_flag(t.style)
	hit := false
	for idx in sector_polys(level, probe) {
		poly := &level.polys[idx]
		ty := poly.type
		#partial switch ty {
		case .Only_Bullets, .Only_Player, .Doesnt, .Only_Flaggers, .Not_Flaggers, .Background, .Background_Transition:
			continue
		}
		if flag && ty >= .Red_Bullets && ty <= .Green_Player do continue
		if team != .None && !team_collides(ty, team) do continue
		if !point_in_poly_edges(probe, poly) do continue
		normal, dist, _ := closest_perpendicular(poly, probe)
		push := vec2_normalize(normal) * dist
		p, o := &t.pos[k], &t.old_pos[k]
		if flag && k == 0 {
			p^ = o^
		} else if flag {
			travel := vec2_length(p^ - o^)
			p^ -= push
			o^ = p^ + vec2_normalize(push) * travel
			if k == 1 && t.holder == 0 do t.forces[1].y -= 1
		} else {
			p^ = o^ - push
		}
		hit = true
	}
	return hit
}
