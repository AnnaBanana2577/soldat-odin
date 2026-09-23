package sim

import "../geom"

// SimpleDecision (AI.pas): how a bot moves and shoots at what it can see. Where it
// stands on the map is bot_path.odin's business; this is the fight alone, decided by
// how far off the target is on each axis, and it ends by pointing the cursor.

bot_fight :: proc(bots: ^Bots, ctx: ^Context, w: ^World, slot: u8) {
	b := &bots[slot]
	if b.target >= MAX_PLAYERS do return
	s := &w.soldiers[slot]
	o := &w.soldiers[b.target]
	ctl := &b.ctl
	m, t := s.pos, o.pos
	info := ctx.weapons[s.weapon.id]
	ammo := s.weapon.ammo

	// A bot walking to a flag or a kit keeps walking: only its gun joins the fight.
	if !b.go_thing do bot_toward(ctl, m.x, t.x)

	dist_x := bot_distance(m.x, t.x)
	switch dist_x {
	case DIST_TOO_CLOSE:
		if !b.go_thing do bot_away(ctl, m.x, t.x)
		ctl.fire = true
	case DIST_VERY_CLOSE:
		if !b.go_thing do ctl.left, ctl.right = false, false
		ctl.fire = true
		if ammo == 0 { // reloading: keep away until it is loaded
			if !b.go_thing do bot_away(ctl, m.x, t.x)
			ctl.fire = false
		}
	case DIST_CLOSE:
		if !b.go_thing do ctl.left, ctl.right = false, false
		ctl.down = true
		ctl.fire = true
		if ammo == 0 {
			if !b.go_thing do bot_away(ctl, m.x, t.x)
			ctl.down, ctl.fire = false, false
		}
	case DIST_ROCK_THROW:
		ctl.down = true
		ctl.fire = true
		if ammo == 0 {
			if !b.go_thing do bot_away(ctl, m.x, t.x)
			ctl.down, ctl.fire = false, false
		}
	case DIST_FAR:
		ctl.fire = true
		if b.prof.camper > 127 && !b.go_thing {
			ctl.up, ctl.down = false, true
		}
	case DIST_VERY_FAR:
		ctl.up = true
		if rand_int(&b.rng, 2) == 0 || s.weapon.id == .Minigun do ctl.fire = true
		if b.prof.camper > 0 {
			if rand_int(&b.rng, 250) == 0 && s.body.id != .Prone do ctl.prone = true
			if !b.go_thing {
				ctl.left, ctl.right, ctl.up = false, false, false
				ctl.down = true
			}
		}
	case DIST_TOO_FAR:
		if rand_int(&b.rng, 4) == 0 || s.weapon.id == .Minigun do ctl.fire = true
		if b.prof.camper > 0 {
			if rand_int(&b.rng, 300) == 0 && s.body.id != .Prone do ctl.prone = true
			if !b.go_thing {
				ctl.left, ctl.right, ctl.up = false, false, false
				ctl.down = true
			}
		}
	}

	// whoever it is fighting is camping: close in, it will not come
	if !b.go_thing {
		other := &bots[b.target]
		if other.playing && other.current > 0 && bot_waypoint(ctx.level, other.current).action > 0 {
			bot_toward(ctl, m.x, t.x)
		}
	}
	// behind cover: crouch by it, and a camper stays and shoots from there
	if b.difficulty < 101 && s.collider_distance < 255 {
		ctl.down = true
		if b.prof.camper > 0 {
			ctl.left, ctl.right = false, false
			if rand_int(&b.rng, 4) == 0 || s.weapon.id == .Minigun do ctl.fire = true
		}
		if s.body.id == .Hands_Up_Aim && s.body.frame != 11 do ctl.fire = false
	}
	// the target is behind cover and this one is not: go around it
	if b.difficulty < 201 && o.collider_distance < 255 && s.collider_distance > 254 && b.prof.camper > 0 {
		if t.x < m.x do ctl.right = true
		if t.x > m.x do ctl.left = true
	}
	// fists, knife or chainsaw against a gun, or against someone above: charge
	if bot_melee(s.weapon.id) && (!bot_melee(o.weapon.id) || t.y > m.y) {
		ctl.left, ctl.right, ctl.down = false, false, false
		ctl.fire = true
		bot_toward(ctl, m.x, t.x)
	}
	// Y: a target well above is jetted up to
	dist_y := bot_distance(m.y, t.y)
	if !b.go_thing && dist_y >= DIST_ROCK_THROW && m.y > t.y do ctl.jet = true
	// a flame god is not fought: back off
	if o.bonus == .Flame_God do bot_away(ctl, m.x, t.x)

	// a grenade now and then, at someone near enough and not above a wall of its own
	if b.prof.grenade_freq > -1 {
		freq := b.prof.grenade_freq
		if ammo == 0 || s.weapon.fire_count > 125 do freq /= 2
		if b.current > 0 && bot_waypoint(ctx.level, b.current).action > 0 do freq /= 2
		if b.difficulty < 100 do freq /= 2
		if b.difficulty < 201 {
			reachable := (dist_y < DIST_VERY_CLOSE && m.y > t.y) || m.y < t.y
			if rand_int(&b.rng, freq) == 0 && dist_x < DIST_FAR && s.grenades > 0 && reachable {
				ctl.throw_nade = true
			}
		}
	}
	// a knife thrower throws it rather than stabbing with it
	if s.cease_fire_counter < 30 && s.weapon.id == .Knife && b.prof.favourite == .Knife {
		ctl.fire = false
		ctl.throw_weapon = true
	}

	// Where it points: the target ten ticks of its own speed on, raised by the drop of
	// the bullet over the distance, and off by as much as its file allows.
	at := t + o.vel * 10
	lead: f32 = dist_x < DIST_FAR ? 0.5 : 1.75
	acc := f32(b.accuracy)
	ctl.aim = {
		f32(geom.round_half_even(at.x)),
		f32(geom.round_half_even(at.y - (lead * f32(dist_x) / info.speed) - acc + f32(rand_int(&b.rng, b.accuracy)))),
	}

	// Impossible: against a sniper it works out where the target will be when the shot
	// arrives, and fires on the frames its pose allows.
	if b.difficulty < 60 && (o.weapon.id == .Barrett || o.weapon.id == .Ruger) {
		dist := f32(geom.round_half_even(geom.vec2_length(m - t)))
		ahead := Vec2{f32(geom.round_half_even(t.x)), f32(geom.round_half_even(t.y))}
		for _ in 0 ..< geom.round_half_even(dist / ctx.weapons[o.weapon.id].speed) {
			ahead.x += f32(geom.round_half_even(o.vel.x))
			ahead.y += f32(geom.round_half_even(o.vel.y))
		}
		ctl.aim = ahead
		if s.weapon.fire_count < 3 {
			bot_free_controls(b)
			ctl.fire = true
			ctl.down = true
			#partial switch s.body.id {
			case .Stand, .Recoil, .Prone, .Shotgun, .Barret, .Small_Recoil, .Aim_Recoil,
			     .Hands_Up_Recoil, .Aim, .Hands_Up_Aim:
			case:
				ctl.fire = false
			}
		}
	}
}

// GoToThing (AI.pas): walk, and jet, toward a thing. A bot keeps pace behind a team
// mate carrying the flag rather than crowding it.
bot_go_to_thing :: proc(b: ^Bot, ctx: ^Context, w: ^World, slot: u8, t: ^Thing) {
	s := &w.soldiers[slot]
	ctl := &b.ctl
	m := s.pos
	// the near end of the thing, so a flag is walked to from the side it is on
	p1, p2 := t.pos[0], t.pos[1]
	at := p2
	if p2.x > p1.x && m.x < p2.x do at = p2
	if p2.x > p1.x && m.x > p1.x do at = p1
	if p2.x < p1.x && m.x < p1.x do at = p1
	if p2.x < p1.x && m.x > p2.x do at = p2
	if t.holder > 0 do at.y += 5
	if at.x >= m.x do ctl.right = true
	if at.x < m.x do ctl.left = true

	if t.holder > 0 && !t.in_base {
		holder := &w.soldiers[t.holder - 1]
		if holder.team == s.team {
			// right behind it: crouch and let it run
			if d := bot_distance(m.x, at.x); d == DIST_TOO_CLOSE || d == DIST_VERY_CLOSE {
				ctl.left, ctl.right = false, false
				ctl.down = true
			}
			ctl.jet = .Jet in holder.controls
		}
	}
	if dist_y := bot_distance(m.y, at.y); dist_y >= DIST_VERY_CLOSE && m.y > at.y do ctl.jet = true
}

// Toward a point on the x axis, and away from it.
@(private = "file")
bot_toward :: proc(ctl: ^Bot_Control, from, to: f32) {
	ctl.left, ctl.right = false, false
	if to > from do ctl.right = true
	if to < from do ctl.left = true
}

@(private = "file")
bot_away :: proc(ctl: ^Bot_Control, from, to: f32) {
	ctl.left, ctl.right = false, false
	if to < from do ctl.right = true
	if to > from do ctl.left = true
}

@(private = "file")
bot_melee :: proc(id: Weapon_Id) -> bool {
	return id == .None || id == .Knife || id == .Chainsaw
}
