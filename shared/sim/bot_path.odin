package sim

import "../geom"

// ControlBot (AI.pas): one tick of a bot. It looks for someone to shoot at, and
// failing that walks the waypoints the map author laid; then it looks for a flag or a
// kit worth fetching, steps out from under a grenade, and gets itself unstuck.
//
// Only what this game has is here. The original also sorts its paths by the mode
// (infiltration, hold the flag) and looks for the bow of a Rambo match; this is capture
// the flag alone, so a bot walks its own team's path and the other team's while it
// carries their flag.

bot_walk :: proc(bots: ^Bots, ctx: ^Context, w: ^World, slot: u8) {
	b := &bots[slot]
	s := &w.soldiers[slot]
	ctl := &b.ctl
	level := ctx.level

	// a grenade being wound up stays wound up; every other key starts this tick down
	winding := ctl.throw_nade
	bot_free_controls(b)
	ctl.throw_nade = winding && s.body.id == .Throw

	look := bot_head(ctx, w, slot) - {0, 2}
	held := bot_flag_held(w, slot)

	// >see anyone?
	see := false
	nearest := f32(999999)
	for &o, i in w.soldiers {
		if u8(i) == slot || u8(i) == b.friend || !o.active || o.team == .Spectator do continue
		if o.bonus == .Predator && !o.holding_flag do continue // unseen, unless it carries something
		dead := o.dead
		if dead && !(b.prof.shoot_dead && o.respawn_counter > w.round.respawn_time - DEAD_INTEREST) do continue
		start := bot_head(ctx, w, u8(i))
		if _, inside := collision_test(level, start); inside do start.y += 6 // a head in the ground
		d, blocked := ray_cast(level, look, start, BOT_SIGHT)
		if blocked || d >= nearest do continue
		b.target = u8(i)
		see = true
		if !dead do nearest = d
		if dead { // nothing is thrown at a body
			ctl.throw_nade = false
			ctl.throw_weapon = false
		}
		if o.team == s.team do see = false
	}
	// <see anyone?

	// whoever wounded it last is hunted until it is out of sight
	if b.pissed_off == slot do b.pissed_off = NOBODY
	if b.pissed_off != NOBODY {
		o := &w.soldiers[b.pissed_off]
		if !o.active || (!w.round.friendly_fire && o.team == s.team) do b.pissed_off = NOBODY
	}
	if b.target != NOBODY && w.round.friendly_fire && w.soldiers[b.target].team != s.team {
		b.pissed_off = NOBODY
	}
	if b.pissed_off != NOBODY {
		if _, blocked := ray_cast(level, look, bot_head(ctx, w, b.pissed_off), BOT_SIGHT); !blocked {
			b.target = b.pissed_off
			see = true
		} else {
			b.pissed_off = NOBODY
		}
	}

	// carrying the flag against someone who is not: run it home instead of fighting
	run_away := false
	if see && held != nil && !w.soldiers[b.target].holding_flag {
		see, run_away = false, true
	}

	if !see {
		if !b.go_thing do bot_follow_path(b, ctx, w, slot, held, run_away)
	} else {
		if b.current != 0 && bot_waypoint(level, b.current).action == 0 do b.current = 0
		bot_fight(bots, ctx, w, slot)
		// a waypoint to camp on is held on to through the fight
		if b.current > 0 && held == nil && bot_waypoint(level, b.current).action == 1 {
			ctl.left, ctl.right, ctl.up, ctl.down, ctl.jet = false, false, false, false, false
		}
		if b.chatty {
			if rand_int(&b.rng, 115 * b.prof.chat_freq) == 0 do b.says = b.prof.chat_see_enemy
			if rand_int(&b.rng, 790 * b.prof.chat_freq) == 0 do b.taunts = b.target
		}
		b.waypoint_time = 0
	}

	bot_seek_thing(b, ctx, w, slot, held, run_away)

	// out from under a grenade
	if b.difficulty < 201 {
		for &bullet in w.bullets {
			if !bullet.active || bullet.style != .Frag_Grenade do continue
			if geom.vec2_length(bullet.pos - s.pos) >= FRAG_EXPLOSION_RADIUS * 1.4 do continue
			ctl.left = bullet.pos.x > s.pos.x
			ctl.right = !ctl.left
		}
	}
	// the hand opens as the throw finishes
	if s.body.id == .Throw && s.body.frame > 35 do ctl.throw_nade = false

	// too long on the way to one waypoint: back to the one before, over whatever is in
	// the way
	b.give_up -= 1
	if b.give_up < 0 {
		b.current = b.old
		b.give_up = WAYPOINT_GIVE_UP
		bot_free_controls(b)
		ctl.up = true
	}
	// and too long on one waypoint: the path is no good, take it from the top
	if b.waypoint_time > WAYPOINT_STUCK {
		bot_free_controls(b)
		b.current = 0
		b.go_thing = false
		b.waypoint_time = 0
	}
	// falling fast: jet before it lands
	if s.vel.y > 3.35 do b.fall_save = true
	if s.vel.y < 1.35 do b.fall_save = false
	if b.fall_save do ctl.jet = true

	if b.chatty && rand_int(&b.rng, b.prof.chat_freq * 150) == 0 && bot_leader(w) == slot {
		b.says = b.prof.chat_winning
	}
	if rand_int(&b.rng, 190) == 0 do b.pissed_off = NOBODY
}

// GO WITH WAYPOINTS: with nobody in sight it walks the path, holding the keys the
// waypoint it is heading for says to hold, waiting on the ones that say to wait.
@(private = "file")
bot_follow_path :: proc(b: ^Bot, ctx: ^Context, w: ^World, slot: u8, held: ^Thing, run_away: bool) {
	s := &w.soldiers[slot]
	ctl := &b.ctl
	level := ctx.level

	// the one it stands on: near any, or the nearest of the lot when it has none
	radius: f32 = b.current == 0 ? WAYPOINT_REACH : WAYPOINT_RADIUS
	k := bot_closest_waypoint(level, s.pos, radius, b.current)
	b.old = b.current
	if b.next == 0 do b.next = 1
	// its own team's path, and the other team's while it carries their flag
	b.path = u8(s.team)
	if held != nil do b.path = s.team == .Alpha ? 2 : 1
	if k > 0 && (b.path == bot_waypoint(level, k).path || b.current == 0) do b.current = k
	if b.current <= 0 || b.current >= len(level.waypoints) do return

	cur := level.waypoints[b.current]
	// newly arrived: one of the ways on from here at random, and it faces it
	if b.old != b.current {
		if n := int(cur.connections[rand_int(&b.rng, cur.count)]); n > 0 {
			b.next = n
			at := level.waypoints[n].pos
			ctl.aim = {f32(geom.round_half_even(at.x)), f32(geom.round_half_even(at.y))}
		}
	}
	next := bot_waypoint(level, b.next)
	ctl.left, ctl.right, ctl.up, ctl.down, ctl.jet = next.left, next.right, next.up, next.down, next.jet

	// a waypoint that says to wait, for as long as it says: one to camp on, or one to
	// hold for a second, five, ten, fifteen or twenty. Not while carrying the flag.
	if held == nil {
		waits := cur.action == 1 ||
			(cur.action == 2 && b.one_place < 1 * TICK_RATE) ||
			(cur.action == 3 && b.one_place < 5 * TICK_RATE) ||
			(cur.action == 4 && b.one_place < 10 * TICK_RATE) ||
			(cur.action == 5 && b.one_place < 15 * TICK_RATE) ||
			(cur.action == 6 && b.one_place < 20 * TICK_RATE)
		if waits {
			ctl.left, ctl.right, ctl.up, ctl.down, ctl.jet = false, false, false, false, false
			if s.stat == 0 && b.prof.camper > 0 && b.one_place > 180 do ctl.down = true
		}
	}
	// fire back at whoever is shooting at it while it runs the flag home
	if run_away && b.pissed_off != NOBODY {
		at := w.soldiers[b.pissed_off].pos
		speed := ctx.weapons[s.weapon.id].speed
		drop := 1.75 * 100 / speed
		ctl.aim = {
			f32(geom.round_half_even(at.x)),
			f32(geom.round_half_even(at.y - drop - f32(b.accuracy) + f32(rand_int(&b.rng, b.accuracy)))),
		}
		ctl.fire = true
	}

	if b.last == b.current do b.waypoint_time += 1
	else do b.waypoint_time = 0
	b.last = b.current

	// standing still while trying to walk: stuck on something, so jump
	if cur.action == 0 {
		if (ctl.left || ctl.right) && !ctl.down && geom.vec2_length(s.vel) < 3 do b.one_place += 1
		else do b.one_place = 0
	} else {
		b.one_place += 1
	}
	if cur.action == 0 && b.one_place > 90 {
		if ctl.left && ctl.right do ctl.right = false
		ctl.up = true
	}

	if b.difficulty < 201 {
		// back to the gun it can fight with
		in_hand := s.weapon.id
		sidearm := in_hand == .None || in_hand == .Colt || in_hand == .Knife || in_hand == .Chainsaw || in_hand == .LAW
		if sidearm && s.secondary.id != .None do ctl.change = true
		// and a full clip before it needs one
		if s.weapon.ammo < 4 && ctx.weapons[in_hand].ammo > 3 do ctl.reload = true
	}
	// up again, in its own time
	if rand_int(&b.rng, 150) == 0 && (s.body.id == .Prone || s.legs.id == .Prone_Move) do ctl.prone = true
}

// >see a flag or a kit? The first one in sight and close enough that it wants is what
// it walks to, until the thing has been chased long enough (Thing.interest).
@(private = "file")
bot_seek_thing :: proc(b: ^Bot, ctx: ^Context, w: ^World, slot: u8, held: ^Thing, run_away: bool) {
	s := &w.soldiers[slot]
	ctl := &b.ctl
	look := bot_head(ctx, w, slot) - {0, 4}
	mine: Thing_Style = s.team == .Alpha ? .Alpha_Flag : .Bravo_Flag

	seen := false
	for &t in w.things {
		if seen || t.style == .None || t.holder == slot + 1 do continue
		wanted: bool
		#partial switch t.style {
		case .Alpha_Flag, .Bravo_Flag, .Flamer_Kit, .Predator_Kit, .Vest_Kit, .Berserk_Kit:
			wanted = true
		case .Cluster_Kit:  wanted = s.grenades == 0
		case .Medical_Kit:  wanted = s.health < DEFAULT_HEALTH
		case .Grenade_Kit:  wanted = s.grenades < w.round.max_grenades
		case .Weapon:       wanted = t.weapon == .Knife // a thrown knife to take up again
		}
		if !wanted do continue
		d, blocked := ray_cast(ctx.level, look, t.pos[1] - {0, 5}, BOT_SIGHT)
		if blocked || d >= DIST_FAR do continue

		seen = true
		// its own flag at home is left where it is, unless it is carrying the other one
		if t.style == mine && t.in_base do seen = held != nil
		// nothing else is fetched while its own flag is away, and the other team's is
		// only taken from their base close up
		if t.style != mine && !bot_flag_at_home(w, s.team) do seen = false
		if t.style != mine && t.in_base && d > DIST_CLOSE do seen = false
		// unless it is hurt and the medikit is right there
		if t.style == .Medical_Kit && s.health < HURT_HEALTH && d < DIST_VERY_CLOSE do seen = true
		// none of it while running the flag home
		if run_away {
			#partial switch t.style {
			case .Medical_Kit, .Grenade_Kit, .Flamer_Kit, .Predator_Kit, .Berserk_Kit: seen = false
			}
		}
		// and no second bonus
		if s.bonus != .None {
			#partial switch t.style {
			case .Flamer_Kit, .Predator_Kit, .Berserk_Kit: seen = false
			}
		}
		if t.style == .Weapon && t.weapon == .Knife do seen = true
		if !seen do continue

		if t.holder == 0 do t.interest -= 1
		if t.interest > 0 {
			if b.chatty && is_flag(t.style) && rand_int(&b.rng, 400 * b.prof.chat_freq) == 0 do b.says = "Flag!"
			b.go_thing = true
			bot_go_to_thing(b, ctx, w, slot, &t)
		} else {
			b.go_thing = false
		}
		// its knife, bare handed: fetch it whatever else is going on
		if t.style == .Weapon && t.weapon == .Knife && s.weapon.id == .None && b.prof.favourite == .Knife {
			ctl.fire = false
			b.target = NOBODY
			b.go_thing = true
			bot_go_to_thing(b, ctx, w, slot, &t)
		}
	}
	if !seen do b.go_thing = false
}

// Whether a team's own flag is at its base.
@(private = "file")
bot_flag_at_home :: proc(w: ^World, team: Team) -> bool {
	t := bot_team_flag(w, team)
	return t != nil && t.in_base
}

// The first waypoint within `radius` of a point that is not the one it is on, 0 for
// none (TWaypoints.FindClosest, which takes the first it finds and not the closest).
bot_closest_waypoint :: proc(m: ^Level, pos: Vec2, radius: f32, current: int) -> int {
	for p, i in m.waypoints {
		if i == current || !p.active do continue
		if geom.vec2_length(pos - p.pos) < radius do return i
	}
	return 0
}

// Waypoint number `i`, or a blank one when there is none.
bot_waypoint :: proc(m: ^Level, i: int) -> Waypoint {
	if i > 0 && i < len(m.waypoints) do return m.waypoints[i]
	return {}
}
