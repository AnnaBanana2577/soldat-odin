package client

import "core:math/linalg"
import "../shared/sim"

// Dead reckoning of the other soldiers. Each relayed state is copied over the
// soldier and stepped through the ticks it is old (the state's age at the server plus
// half our round trip), then one tick per tick on its last known controls until the
// next state. Where a state lands a soldier away from where it was drawn, the
// difference becomes an offset that blends out at a limited rate.
View :: struct {
	world: ^sim.World,
	me:    u8,
	prev:  [sim.MAX_PLAYERS]sim.Vec2, // where each soldier was before its last step
	err:   [sim.MAX_PLAYERS]sim.Vec2, // drawn offset, blending out
	drawn: [sim.MAX_PLAYERS]sim.Vec2, // this frame's position
	lead:  int,                       // ticks to fast-forward a fresh state by, beyond its age
}

MAX_FAST_FORWARD :: 30
ERR_SNAP  :: 60.0 // further than this from where it was drawn, a soldier jumps
ERR_DECAY :: 0.88 // share of the offset kept per tick
ERR_RATE  :: 1.0  // and at least this many units gone per tick

// Buttons a dead-reckoned soldier never presses: one-shot actions that would fire,
// throw or change weapons on our copy alone.
NEVER_EXTRAPOLATED :: sim.Buttons{.Fire, .Throw, .Reload, .Change, .Suicide, .Drop, .Flag_Throw, .Prone}

view_init :: proc(v: ^View, world: ^sim.World, me: u8) {
	v^ = {}
	v.world = world
	v.me = me
}

view_destroy :: proc(v: ^View) {
}

// A soldier as its owner last sent it, some ticks ago at the server.
view_receive_state :: proc(v: ^View, ctx: ^sim.Context, slot: u8, s: ^sim.Soldier, age: int) {
	cur := &v.world.soldiers[slot]
	was_alive := cur.active && !cur.dead
	drawn_at := cur.pos + v.err[slot]
	cur^ = s^
	for _ in 0 ..< min(age + v.lead, MAX_FAST_FORWARD) do step_remote(v, ctx, slot)
	if was_alive && cur.active && !cur.dead {
		off := drawn_at - cur.pos
		v.err[slot] = linalg.length(off) > ERR_SNAP ? {} : off
	} else {
		v.err[slot] = {}
		v.prev[slot] = cur.pos
	}
}

// One tick of every remote soldier on its last known controls, and the offsets
// blending out.
dead_reckon :: proc(v: ^View, ctx: ^sim.Context) {
	for &s, i in v.world.soldiers {
		if !s.active || s.dead || u8(i) == v.me do continue
		v.prev[i] = s.pos
		step_remote(v, ctx, u8(i))
		blend_out(&v.err[i])
	}
}

blend_out :: proc(e: ^sim.Vec2) {
	l := linalg.length(e^)
	if l == 0 do return
	nl := l * ERR_DECAY
	if l - nl < ERR_RATE do nl = l - ERR_RATE
	e^ = nl <= 0 ? {} : e^ * (nl / l)
}

step_remote :: proc(v: ^View, ctx: ^sim.Context, slot: u8) {
	s := &v.world.soldiers[slot]
	scratch: sim.Events
	cmd := sim.Command{buttons = s.controls - NEVER_EXTRAPOLATED, aim = s.aim}
	sim.soldier_step(ctx, v.world, slot, cmd, &scratch)
}

view_interpolate :: proc(v: ^View, alpha: f32) {
	for &s, i in v.world.soldiers {
		if !s.active || u8(i) == v.me do continue
		v.drawn[i] = v.prev[i] + (s.pos - v.prev[i]) * alpha + v.err[i]
	}
}
