package sim

// A grenade, rocket or cluster going off: a Hit on every living soldier in the
// radius (the caller wounds), the things knocked, nearby explosives set off.
// Ported from explode() in Bullets.pas by way of the old Odin port.

M79_EXPLOSION_RADIUS      :: 64
FRAG_EXPLOSION_RADIUS     :: 85
CLUSTER_EXPLOSION_RADIUS  :: 35
AFTER_EXPLOSION_RADIUS    :: 50
EXPLOSION_IMPACT_MULTIPLY :: 3.75

Explosion_Kind :: enum u8 { Frag, M79, Cluster }

// `hit_soldier` and `hit_part` name a soldier the projectile struck directly, or -1.
explode :: proc(ctx: ^Context, w: ^World, b: ^Bullet, index: u16, kind: Explosion_Kind, hit_soldier, hit_part: int, events: ^Events) {
	weapon: Weapon_Id
	radius: f32
	switch kind {
	case .Frag:    weapon, radius = .Frag, FRAG_EXPLOSION_RADIUS
	case .M79:     weapon, radius = .M79, M79_EXPLOSION_RADIUS
	case .Cluster: weapon, radius = .Frag, CLUSTER_EXPLOSION_RADIUS
	}
	info := &ctx.weapons[weapon]
	emit(events, Explosion{id = index, player = b.owner, weapon = weapon, pos = b.pos, radius = radius})

	soldiers := targets(w, b.lag) // as the thrower saw them
	for i in 0 ..< MAX_PLAYERS {
		s := target_soldier(w, soldiers, b.owner, i)
		if !s.active || s.team == .Spectator do continue
		if s.dead {
			ragdoll_explosion(w, u8(i), b.pos, radius)
			continue
		}
		pose := soldier_pose(ctx.anims, s, s.pos)
		part := hit_part
		if i != hit_soldier || hit_part < 0 {
			best := max(f32)
			for p in HIT_PARTS {
				if d := vec2_dot(b.pos - pose[p], b.pos - pose[p]); d < best do best, part = d, p
			}
		}
		a := b.pos - pose[part]
		dist2 := vec2_dot(a, a)
		if dist2 >= radius * radius do continue
		dist := sqrt_f32(dist2)
		modifier := hitbox_modifier(info, part)
		a *= (1 / (dist + 1)) * EXPLOSION_IMPACT_MULTIPLY
		if kind == .Cluster do modifier *= 0.5
		else do a.y *= 2
		if s.cease_fire_counter < 0 {
			emit(events, Hit{shooter = b.owner, target = u8(i), weapon = b.weapon, amount = (1 / (dist + 1)) * info.damage * modifier, part = 0, pos = pose[part], push = -a})
		}
	}

	// the blast shoves flags (and kits with kits_collide): every point in range gets its
	// previous position pulled back, which Verlet turns into a kick away from the blast
	for &t in w.things {
		if t.style == .None do continue
		if t.style != .Alpha_Flag && t.style != .Bravo_Flag && !w.round.kits_collide do continue
		for k in 0 ..< 4 {
			a := b.pos - t.pos[k]
			dist2 := vec2_dot(a, a)
			if dist2 >= radius * radius do continue
			t.old_pos[k] += a * (0.5 * (1 / (sqrt_f32(dist2) + 1)) * EXPLOSION_IMPACT_MULTIPLY)
			t.static = false
		}
	}

	// big explosions set off nearby grenades and rockets
	if kind == .Cluster do return
	bullet_end(w, b, index, events)
	for &other, i in w.bullets {
		if !other.active do continue
		if other.style != .Frag_Grenade && other.style != .M79 && other.style != .LAW do continue
		a := b.pos - other.pos
		if vec2_dot(a, a) >= AFTER_EXPLOSION_RADIUS * AFTER_EXPLOSION_RADIUS do continue
		bullet_end(w, &other, u16(i), events)
		explode(ctx, w, &other, u16(i), other.style == .Frag_Grenade ? .Frag : .M79, -1, -1, events)
	}
}
