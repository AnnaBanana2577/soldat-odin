package sim

// A bullet's tick of collisions, in the original's order: the map, the colliders,
// the soldiers, the things. A bullet stopped by one is rewound so the later checks
// still see its path, and only a nearer hit wins. Ported from Bullets.pas by way of
// the old Odin port.
//
// A soldier hit is a Hit event, never a wound: whoever applies the events decides
// (the server does; a client only shows the blood).

GRENADE_SURFACECOEF :: 0.88
PART_RADIUS         :: 7

FLAG_PART_RADIUS         :: 10 // the hit radius of a flag's or kit's first two points
THING_PUSH_MULTIPLIER    :: 9
THING_COLLISION_COOLDOWN :: 60 // ticks before the same bullet can push the same thing again

// The pose points checked for hits, in priority order (the head first).
HIT_PARTS :: [7]int{11, 10, 9, 5, 4, 3, 2}

bullet_collide :: proc(ctx: ^Context, w: ^World, b: ^Bullet, index: u16, events: ^Events) {
	saved_vel, saved_pos, saved_old := b.vel, b.pos, b.old_pos
	nearest: f32 = -1 // the distance to what stopped it so far

	wall: Vec2
	if b.style == .Frag_Grenade do map_collide(ctx, w, b, index, b.pos + {0, -2}, events)
	wall = map_collide(ctx, w, b, index, b.pos, events)
	if !b.active {
		nearest = vec2_length(wall - saved_old)
		b.vel, b.pos, b.old_pos = saved_vel, saved_pos, saved_old
		b.ricochet_count -= 1
	}

	collider, hit_collider := collider_collide(ctx, w, b, index, nearest, events)
	if !b.active {
		nearest = vec2_length((hit_collider ? collider : wall) - saved_old)
		b.vel, b.pos, b.old_pos = saved_vel, saved_pos, saved_old
	}

	point, hit := soldier_collide_bullet(ctx, w, b, index, nearest, events)
	if !b.active {
		stop := hit ? point : hit_collider ? collider : wall
		nearest = vec2_length(stop - saved_old)
	}

	thing_collide_bullet(ctx, w, b, nearest, events)
}

@(private = "file")
bullet_poly_collides :: proc(t: Poly_Type, team: Team) -> bool {
	#partial switch t {
	case .Only_Player, .Doesnt, .Only_Flaggers, .Not_Flaggers, .Background, .Background_Transition:
		return false
	}
	return bullet_team_collides(t, team)
}

// Steps along the velocity looking for a solid poly. Returns the contact point.
@(private = "file")
map_collide :: proc(ctx: ^Context, w: ^World, b: ^Bullet, index: u16, at: Vec2, events: ^Events) -> Vec2 {
	level := ctx.level
	team := w.soldiers[b.owner].team
	steps := int(max(abs(b.vel.x), abs(b.vel.y)) / 2.5)
	if steps == 0 do steps = 1
	step := b.vel / f32(steps)
	n := int(level.sectors_num)

	for i in 0 ..< steps {
		pos := at + f32(i) * step
		sx := round_half_even(pos.x / f32(level.sectors_division))
		sy := round_half_even(pos.y / f32(level.sectors_division))
		if sx < -n || sx > n || sy < -n || sy > n {
			bullet_end(w, b, index, events)
			return {}
		}
		for idx in sector_at(level, sx, sy) {
			poly := &level.polys[idx]
			if !bullet_poly_collides(poly.type, team) || !point_in_poly_edges(pos, poly) do continue

			#partial switch b.style {
			case .Plain, .Shotgun, .Punch, .Knife, .M2:
				if ricochet(level, w, b, index, poly, pos, team, events) do emit(events, Ricochet{id = index, owner = b.owner, pos = b.pos, vel = b.vel})
				else do emit(events, Wall_Hit{id = index, owner = b.owner, weapon = b.weapon, pos = pos, vel = b.vel})
			case .M79, .Flame_Arrow, .LAW:
				before := pos - b.vel
				if ricochet(level, w, b, index, poly, pos, team, events) {
					emit(events, Ricochet{id = index, owner = b.owner, pos = b.pos, vel = b.vel})
				} else {
					b.pos = before
					explode(ctx, w, b, index, .M79, -1, -1, events)
				}
			case .Arrow:
				// arrows stick into walls
				b.pos = pos - b.vel
				b.forces.y -= w.gravity * BULLET_GRAVITY
				b.timeout = min(b.timeout, ARROW_RESIST)
				if b.timeout < 20 do b.forces.y += w.gravity * BULLET_GRAVITY
			case .Frag_Grenade, .Flame:
				if b.style == .Frag_Grenade && vec2_length(b.vel) > 1.5 do emit(events, Grenade_Bounce{id = index, owner = b.owner, pos = pos})
				normal, dist, _ := closest_perpendicular(poly, b.pos)
				b.pos = pos
				b.vel = (b.vel - vec2_normalize(normal) * dist) * GRENADE_SURFACECOEF
				if b.style == .Flame do b.timeout = min(b.timeout, 16)
			case .Cluster_Nade:
				cluster_split(ctx, w, b, events)
				emit(events, Cluster_Split{id = index, owner = b.owner, pos = b.pos})
				bullet_end(w, b, index, events)
			case .Cluster:
				explode(ctx, w, b, index, .Cluster, -1, -1, events)
				bullet_end(w, b, index, events)
			case .Thrown_Knife:
				b.pos = pos - b.vel
				emit(events, Wall_Hit{id = index, owner = b.owner, weapon = b.weapon, pos = pos, vel = b.vel})
				dropped_gun_land_knife(w, b)
				bullet_end(w, b, index, events, pos)
			}
			return pos
		}
	}
	return {}
}

// A glancing hit deflects; anything else stops the bullet. True if it survived.
@(private = "file")
ricochet :: proc(level: ^Level, w: ^World, b: ^Bullet, index: u16, poly: ^Polygon, pos: Vec2, team: Team, events: ^Events) -> bool {
	b.old_pos = b.pos
	b.pos = pos - b.vel
	// one ricochet per surface contact
	if vec2_length(b.pos - b.hit_spot) <= 50 {
		bullet_end(w, b, index, events, pos)
		return false
	}
	b.ricochet_count += 1
	normal, _, _ := closest_perpendicular(poly, b.pos)
	speed := vec2_length(b.vel)
	reflect := vec2_normalize(normal) * -speed
	b.vel = b.vel * (25.0 / 35) + reflect * (10.0 / 35)
	b.pos = pos
	b.hit_spot = pos
	b.old_pos = pos
	// dead if the deflected path is still inside geometry
	probe := pos + vec2_normalize(b.vel) * (speed / 6)
	for idx in sector_polys(level, probe) {
		p := &level.polys[idx]
		if bullet_poly_collides(p.type, team) && point_in_poly_edges(probe, p) {
			bullet_end(w, b, index, events, pos)
			return false
		}
	}
	return true
}

@(private = "file")
cluster_split :: proc(ctx: ^Context, w: ^World, b: ^Bullet, events: ^Events) {
	origin := b.pos - b.vel
	for _ in 0 ..< 5 {
		v := b.vel * -0.75
		v.x = -v.x - 2.5 + rand_f32(&w.rng) * 5
		v.y = v.y - 2.5 + rand_f32(&w.rng) * 2.5
		bullet_spawn(ctx, w, origin, v, .Cluster, b.owner, ctx.weapons[.Frag].damage / 2, events)
	}
}

// The map's colliders: invisible circles, usually behind sandbags, that stop fire.
@(private = "file")
collider_collide :: proc(ctx: ^Context, w: ^World, b: ^Bullet, index: u16, nearest: f32, events: ^Events) -> (point: Vec2, hit: bool) {
	for c in ctx.level.colliders {
		if !c.active do continue
		p, ok := line_circle_collision(b.pos, b.pos + b.vel, c.pos, c.radius / 1.7)
		if !ok do continue
		if nearest > -1 && vec2_length(p - b.old_pos) > nearest do return {}, false // something nearer stopped it
		#partial switch b.style {
		case .Plain, .Shotgun, .Punch, .Knife, .Thrown_Knife, .M2:
			b.pos = p - b.vel
			emit(events, Collider_Hit{id = index, owner = b.owner, pos = p, vel = b.vel})
			if b.style == .Thrown_Knife do dropped_gun_land_knife(w, b)
			bullet_end(w, b, index, events, p)
		case .Frag_Grenade:
			// not stopped by cover it was thrown from right next to
			if b.timeout < GRENADE_TIMEOUT - 2 {
				explode(ctx, w, b, index, .Frag, -1, -1, events)
				bullet_end(w, b, index, events)
			}
		case .Flame:
			bullet_end(w, b, index, events)
		case .Arrow:
			if b.timeout > ARROW_RESIST {
				b.forces.y -= w.gravity * BULLET_GRAVITY
				emit(events, Wall_Hit{id = index, owner = b.owner, weapon = b.weapon, pos = p, vel = b.vel})
				bullet_end(w, b, index, events, p)
			}
		case .M79, .Flame_Arrow, .LAW:
			explode(ctx, w, b, index, .M79, -1, -1, events)
			bullet_end(w, b, index, events)
		case .Cluster_Nade:
			cluster_split(ctx, w, b, events)
			emit(events, Cluster_Split{id = index, owner = b.owner, pos = b.pos})
			bullet_end(w, b, index, events)
		case .Cluster:
			explode(ctx, w, b, index, .Cluster, -1, -1, events)
			bullet_end(w, b, index, events)
		}
		return p, true
	}
	return {}, false
}

// The bullet's path against the living soldiers' poses, nearest first. A hit is a
// Blood and a Hit event with the damage this weapon does to that part and the
// knockback; the bullet stops, pierces or explodes as its style says.
@(private = "file")
soldier_collide_bullet :: proc(ctx: ^Context, w: ^World, b: ^Bullet, index: u16, nearest: f32, events: ^Events) -> (hit_point: Vec2, hit: bool) {
	if b.style == .Arrow && b.timeout <= ARROW_RESIST do return
	if b.style == .Cluster_Nade do return

	info := &ctx.weapons[b.weapon]
	owner := &w.soldiers[b.owner]
	soldiers := targets(w, b.lag) // as the shooter saw them
	melee := b.style == .Punch || b.style == .Knife

	owner_vulnerable_after: i32
	#partial switch b.style {
	case .Frag_Grenade: owner_vulnerable_after = GRENADE_TIMEOUT - 50
	case .M2:           owner_vulnerable_after = M2BULLET_TIMEOUT - 20
	case .Flame:        owner_vulnerable_after = FLAMER_TIMEOUT
	case:               owner_vulnerable_after = BULLET_TIMEOUT - 20
	}

	// candidates nearest first
	order: [MAX_PLAYERS]int
	dists: [MAX_PLAYERS]f32
	count := 0
	for i in 0 ..< MAX_PLAYERS {
		s := &soldiers[i]
		if !s.active || s.dead || i == int(b.hit_body) do continue // TODO corpses are targets too (ragdoll)
		if i == int(b.owner) && b.timeout >= owner_vulnerable_after do continue
		d := vec2_dot(b.pos - s.pos, b.pos - s.pos)
		j := count
		for j > 0 && d < dists[j - 1] {
			dists[j], order[j] = dists[j - 1], order[j - 1]
			j -= 1
		}
		dists[j], order[j] = d, i
		count += 1
	}

	radius: f32 = b.style == .Frag_Grenade ? PART_RADIUS + 1 : PART_RADIUS
	for c in 0 ..< count {
		ti := order[c]
		target := &soldiers[ti]
		if melee && ti == int(b.owner) do continue

		start, end: Vec2
		if melee {
			owner_pose := soldier_pose(ctx.anims, owner, owner.pos)
			start = owner_pose[14] + hands_aim_direction(&owner_pose) * 4
			end = b.pos + b.vel
		} else {
			start = b.pos
			end = b.pos + b.vel
		}

		pose := soldier_pose(ctx.anims, target, target.pos)
		part := -1
		point: Vec2
		best := max(f32)
		for p in HIT_PARTS {
			center := pose[p]
			if !melee do center.x -= 2
			if q, ok := line_circle_collision(start, end, center, radius); ok {
				if d := vec2_dot(q - start, q - start); d < best do best, part, point = d, p, q
			}
		}
		if part < 0 do continue
		if nearest > -1 && vec2_length(point - b.old_pos) > nearest do return // a wall hit closer than this soldier wins
		hit_point, hit = point, true
		if target.cease_fire_counter >= 0 do continue

		push: Vec2
		if b.style != .Frag_Grenade && b.style != .Flame && b.style != .Arrow do push = b.vel * info.push
		modifier := hitbox_modifier(info, part)
		wound :: proc(events: ^Events, b: ^Bullet, ti: int, amount: f32, part: int, point, push: Vec2) {
			emit(events, Hit{shooter = b.owner, target = u8(ti), weapon = b.weapon, amount = amount, part = u8(part + 1), pos = point, push = push})
		}

		#partial switch b.style {
		case .Plain, .Shotgun, .Punch, .Knife, .M2:
			b.pos = point
			emit(events, Blood{shooter = b.owner, target = u8(ti), pos = point, vel = b.vel})
			speed := vec2_length(b.vel)
			wound(events, b, ti, speed * b.hit_multiply * modifier, part, point, push)
			b.hit_body = i8(ti)
			// a punched enemy starts throwing its gun away
			if b.style == .Punch && (target.team == .None || target.team != owner.team) && target.weapon.id != .Bow && target.weapon.id != .Bow2 {
				anim_apply(ctx.anims, &w.soldiers[ti].body, .Throw_Weapon, 11) // the live one, not the frame
			}
			// fast bullets pierce and go on to the next soldier
			if speed > 23 {
				b.vel *= 0.75
				continue
			}
			if speed > 5 && speed / info.speed >= 0.9 {
				b.vel *= 0.66
				continue
			}
			bullet_end(w, b, index, events, point)
		case .Frag_Grenade:
			explode(ctx, w, b, index, .Frag, ti, part, events)
			bullet_end(w, b, index, events)
		case .Arrow:
			b.pos = point - b.vel
			b.forces.y -= w.gravity * BULLET_GRAVITY
			emit(events, Blood{shooter = b.owner, target = u8(ti), pos = point, vel = b.vel})
			wound(events, b, ti, vec2_length(b.vel) * b.hit_multiply * modifier, part, point, push)
			bullet_end(w, b, index, events, point)
		case .M79, .Flame_Arrow, .LAW:
			explode(ctx, w, b, index, .M79, ti, part, events)
			b.pos = point
			bullet_end(w, b, index, events)
			wound(events, b, ti, vec2_length(b.vel) * b.hit_multiply, part, point, push)
		case .Flame:
			if ti == int(b.owner) do return point, true
			b.pos = pose[part]
			b.vel = target.vel
			if b.timeout < 3 && b.ricochet_count < 2 {
				if b.hit_multiply >= ctx.weapons[.Flamer].damage / 3 {
					b.timeout = FLAMER_TIMEOUT - 1
					b.ricochet_count += 1
					bullet_spawn(ctx, w, pose[part], -target.vel, .Flamer, b.owner, 2 * b.hit_multiply / 3, events)
				}
				if target.health > -1 do wound(events, b, ti, b.hit_multiply, part, point, {})
			}
		case .Cluster:
			explode(ctx, w, b, index, .Cluster, ti, part, events)
			bullet_end(w, b, index, events)
		case .Thrown_Knife:
			wound(events, b, ti, vec2_length(b.vel) * b.hit_multiply * 0.01, part, point, push)
			bullet_end(w, b, index, events)
		}
		return point, true
	}
	return
}

// The weapon's damage modifier for a pose point (0-based).
hitbox_modifier :: proc(info: ^Weapon_Info, part: int) -> f32 {
	point := part + 1 // the original's 1-based skeleton numbering
	switch {
	case point <= 4:  return info.mod_legs
	case point <= 11: return info.mod_chest
	}
	return info.mod_head
}

// Bullets knock flags (and kits with kits_collide) around; the bullet keeps flying.
@(private = "file")
thing_collide_bullet :: proc(ctx: ^Context, w: ^World, b: ^Bullet, nearest: f32, events: ^Events) {
	if b.style == .Frag_Grenade do return
	if b.timeout >= BULLET_TIMEOUT - 1 do return // not on the tick it was fired
	for &t, ti in w.things {
		if t.style == .None do continue
		is_flag := t.style == .Alpha_Flag || t.style == .Bravo_Flag
		if !is_flag && !w.round.kits_collide do continue
		if t.holder == b.owner + 1 do continue // not the flag you carry

		part := -1
		point: Vec2
		for k in 0 ..< 2 {
			if p, ok := line_circle_collision(b.pos, b.pos + b.vel, t.pos[k], FLAG_PART_RADIUS); ok {
				part, point = k, p
				break
			}
		}
		if part < 0 do continue
		if nearest > -1 && vec2_length(point - b.old_pos) > nearest do return

		// the original stops looking while this bullet is cooling down on this thing
		slot := 0
		for cd, i in b.thing_cooldowns {
			if cd.thing == u8(ti + 1) && w.tick < cd.until do return
			if cd.until < b.thing_cooldowns[slot].until do slot = i
		}
		b.thing_cooldowns[slot] = {thing = u8(ti + 1), until = w.tick + THING_COLLISION_COOLDOWN}

		thing_vel := t.pos[part] - t.old_pos[part]
		t.pos[part] += (b.vel - thing_vel) * ctx.weapons[b.weapon].push * THING_PUSH_MULTIPLIER
		t.static = false
		if b.style == .Plain || b.style == .Shotgun do emit(events, Thing_Hit{thing = t.style, pos = point, vel = b.vel, part = u8(part)})
		return
	}
}
