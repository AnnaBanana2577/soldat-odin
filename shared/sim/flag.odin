package sim

// The flags: hanging from a carrier's hand, dropped, thrown, returned, captured,
// timing out back to base. Ported from the flag parts of things.lua and rules.lua.

FLAG_TIMEOUT        :: 60 * 25 // ticks a loose flag lies around before returning
FLAG_RADIUS         :: 20.0
BASE_RADIUS         :: 75.0 // how far from home still counts as in base
TOUCHDOWN_RADIUS    :: 28.0 // how close to the other flag a carrier must get to score
FLAG_THROW_POWER    :: 4.225
FLAG_HOLDING_FORCEUP :: -14.0

flag_team :: proc(style: Thing_Style) -> Team {
	return style == .Alpha_Flag ? .Alpha : .Bravo
}

flag_home :: proc(w: ^World, style: Thing_Style) -> Vec2 {
	return w.flag_home[style == .Alpha_Flag ? 0 : 1]
}

flag_update :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, events: ^Events) {
	thing_check_holder(w, t)
	if t.holder > 0 {
		holder := &w.soldiers[t.holder - 1]
		if .Flag_Throw in holder.controls do flag_throw(ctx, w, t, holder)
	}
	if !t.static do thing_physics(ctx, w, t, events)
	if t.holder > 0 {
		holder := &w.soldiers[t.holder - 1]
		holder.holding_flag = true
		pose := soldier_pose(ctx.anims, holder, holder.pos)
		t.pos[0] = pose[7] // the hand the flag hangs from
		t.forces[1].y += FLAG_HOLDING_FORCEUP * w.gravity
		t.timeout = FLAG_TIMEOUT
	}
	home := flag_home(w, t.style)
	t.in_base = vec2_length(t.pos[0] - home) < BASE_RADIUS
	if t.in_base && t.holder == 0 do t.timeout = FLAG_TIMEOUT
	if t.holder == 0 && !t.in_base {
		t.timeout -= 1
		if t.timeout <= 0 {
			pos := t.pos[0]
			flag_respawn(ctx, w, t)
			emit(events, Flag_Return{player = 255, flag = t.style, pos = pos})
			return
		}
	}
	// the server's own checks: a carrier home with the other flag scores, a loose flag
	// touched by its own team goes home (not claims: the server judges these)
	if t.holder > 0 do flag_capture(ctx, w, t, index, events)
	if t.holder == 0 && !t.in_base do flag_return_touch(ctx, w, t, events)
}

// May this soldier grab it: the other team's flag, not under cease fire, near.
flag_can_grab :: proc(t: ^Thing, s: ^Soldier) -> bool {
	if s.team == flag_team(t.style) || s.cease_fire_counter > 0 do return false
	return vec2_length(thing_center(t) - s.pos) <= FLAG_RADIUS
}

// The grab: the flag hangs from the soldier's hand from now on.
flag_grab :: proc(t: ^Thing, index: u8, soldier: u8, events: ^Events) {
	t.holder = soldier + 1
	t.static = false
	t.timeout = FLAG_TIMEOUT
	emit(events, Flag_Grab{player = soldier, thing = index, flag = t.style, pos = t.pos[0]})
}

@(private = "file")
flag_return_touch :: proc(ctx: ^Context, w: ^World, t: ^Thing, events: ^Events) {
	for &s, i in w.soldiers {
		if !s.active || s.dead || s.team != flag_team(t.style) do continue
		if vec2_length(thing_center(t) - s.pos) > FLAG_RADIUS do continue
		pos := t.pos[0]
		flag_respawn(ctx, w, t)
		emit(events, Flag_Return{player = u8(i), flag = t.style, pos = pos})
		return
	}
}

@(private = "file")
flag_capture :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, events: ^Events) {
	holder := &w.soldiers[t.holder - 1]
	if holder.team == flag_team(t.style) do return
	for &other, i in w.things {
		if u8(i) == index || !is_flag(other.style) || other.holder != 0 || !other.in_base do continue
		if vec2_length(t.pos[0] - other.pos[0]) < TOUCHDOWN_RADIUS {
			holder.flags += 1
			w.round.scores[holder.team] += 1
			emit(events, Flag_Score{player = t.holder - 1, flag = t.style, pos = t.pos[0]})
			flag_respawn(ctx, w, t)
			return
		}
	}
}

// TSprite.ThrowFlag: the carrier lobs the flag toward the cursor, unless it would
// land in a wall right away.
@(private = "file")
flag_throw :: proc(ctx: ^Context, w: ^World, t: ^Thing, holder: ^Soldier) {
	if holder.body.id == .Roll || holder.body.id == .Roll_Back do return
	pose := soldier_pose(ctx.anims, holder, holder.pos)
	d := vec2_normalize(holder.aim - pose[14]) * FLAG_THROW_POWER
	o := d * 5
	b := d + holder.vel
	n := o + b
	for k in 0 ..< 3 {
		if _, blocked := ray_cast(ctx.level, pose[14], t.pos[k] + n, 200, {flag = true, player = true}); blocked do return
	}
	for k in 0 ..< 4 {
		t.old_pos[k] = t.pos[k] + o - b
		t.pos[k] += o
	}
	t.holder = 0
	t.static = false
	holder.holding_flag = false
}

flag_respawn :: proc(ctx: ^Context, w: ^World, t: ^Thing) {
	thing_place(ctx, t, t.style, flag_home(w, t.style))
}
