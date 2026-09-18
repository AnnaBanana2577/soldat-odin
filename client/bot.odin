package client

import "core:time"
import "../shared/sim"

// A bot's brain, for testing: what a client sees, turned into this tick's input. It
// runs toward the nearest living enemy, jets when the target is above, jumps when it
// stops making progress, and fires with line of sight within range. Something to
// shoot at and be shot by, not the original's waypoint AI.
Bot :: struct {
	me:       u8,
	tick:     int,
	jet_hold: int, // ticks of jet left to hold
	stuck:    int, // ticks spent trying to move without getting anywhere
	last_x:   f32,
	rng:      u64,
	dodge:    bool, // -dodge: in a fight, change direction and jet at random, as a person does
	strafe:   int,  // -1, 0 or 1: the dodge now
	strafe_left: int, // ticks until the next change
}

BOT_FIRE_RANGE :: 650.0

bot_init :: proc(b: ^Bot, me: u8, dodge: bool) {
	b^ = {me = me, dodge = dodge, rng = u64(time.now()._nsec) | 1}
}

bot_input :: proc(b: ^Bot, in_: ^Input, ctx: ^sim.Context, w: ^sim.World) {
	b.tick += 1
	s := &w.soldiers[b.me]
	held: sim.Buttons
	in_.aim = s.pos + {f32(s.direction) * 100, 0}
	if s.active && !s.dead {
		if target, dist := bot_nearest_enemy(w, b.me); target != nil {
			d := target.pos - s.pos
			if abs(d.x) > 30 do held += d.x > 0 ? {.Right} : {.Left}
			if d.y < -60 && s.jets > 20 do b.jet_hold = 12
			if s.on_ground && d.y < -30 && abs(d.x) < 220 && b.tick % 40 == 0 do held += {.Jump}
			// no progress while trying to move: jump and jet over whatever is in the way
			moving := held & {.Left, .Right} != {}
			if moving && abs(s.pos.x - b.last_x) < 0.3 do b.stuck += 1
			else do b.stuck = 0
			if b.stuck > 30 {
				held += {.Jump}
				if b.stuck > 45 {
					b.jet_hold = 10
					b.stuck = 0
				}
			}
			if b.dodge && dist < BOT_FIRE_RANGE do bot_dodge(b, &held)
			in_.aim = target.pos + {(sim.rand_f32(&b.rng) * 2 - 1) * 10, -8 + (sim.rand_f32(&b.rng) * 2 - 1) * 8}
			if dist < BOT_FIRE_RANGE && s.cease_fire_counter < 0 {
				_, blocked := sim.ray_cast(ctx.level, s.pos - {0, 8}, target.pos - {0, 8}, BOT_FIRE_RANGE, {bullet = true, team = s.team})
				if !blocked && sim.rand_int(&b.rng, 10) < 7 do held += {.Fire}
			}
		}
		if b.jet_hold > 0 {
			b.jet_hold -= 1
			held += {.Jet}
		}
	}
	b.last_x = s.pos.x
	in_.held = held
}

// Left, right or still, jumping and jetting, each for a few ticks at random: the moves
// a guess from the last keys gets wrong.
bot_dodge :: proc(b: ^Bot, held: ^sim.Buttons) {
	b.strafe_left -= 1
	if b.strafe_left <= 0 {
		b.strafe = sim.rand_int(&b.rng, 3) - 1
		b.strafe_left = 6 + sim.rand_int(&b.rng, 20)
		if sim.rand_int(&b.rng, 3) == 0 do b.jet_hold = 4 + sim.rand_int(&b.rng, 14)
		if sim.rand_int(&b.rng, 4) == 0 do held^ += {.Jump}
	}
	held^ -= {.Left, .Right}
	if b.strafe < 0 do held^ += {.Left}
	if b.strafe > 0 do held^ += {.Right}
}

bot_nearest_enemy :: proc(w: ^sim.World, me: u8) -> (target: ^sim.Soldier, dist: f32) {
	s := &w.soldiers[me]
	dist = max(f32)
	for &o, i in w.soldiers {
		if u8(i) == me || !o.active || o.dead || o.team == .Spectator || o.team == s.team do continue
		if d := sim.vec2_length(o.pos - s.pos); d < dist do target, dist = &o, d
	}
	return
}
