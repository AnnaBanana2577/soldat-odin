package game

import "../../shared/net"
import "../../shared/sim"

// The others, as this client shows them: at a server tick a little in the past, the
// view tick. Each tick the view moves one tick on and every other soldier is guessed
// on with it from its last known controls (sim.soldier_reckon, the guess the server
// and every other client make too); then the server's word, when it comes, replaces
// the guess. The view tick is told to the server with every packet, and the server
// judges my shots against the soldiers of that tick: what I am shown is what I hit.
//
// The clock follows the promptest updates: one that comes ahead of the view pulls it
// forward at once, and the rest, held up on the line, are guessed on the ticks they
// are behind. Should even the promptest come late for a whole second, the line has
// grown longer, and the view waits a tick.
//
// Where the server's word lands a soldier away from where it was drawn, the difference
// becomes an offset that blends out, so a correction glides instead of snapping.
View :: struct {
	tick:      u32, // the server tick the others are shown at
	window:    int, // ticks into this second
	least_age: u32, // how late the promptest update of this second came, in ticks
	drawn: [sim.MAX_PLAYERS]sim.Vec2, // where each soldier was drawn when the last tick ended
	prev:  [sim.MAX_PLAYERS]sim.Vec2, // where its step of this tick began: drawn from here to pos
	err:   [sim.MAX_PLAYERS]sim.Vec2, // the drawn offset, blending out
}

NEVER_LATE   :: max(u32)
VIEW_WINDOW  :: sim.TICK_RATE
MAX_CATCH_UP :: 12   // ticks a late word is guessed on at most
ERR_SNAP     :: 60.0 // further than this from where it was drawn, a soldier jumps
ERR_DECAY    :: 0.88 // share of the offset kept per tick
ERR_RATE     :: 1.0  // and at least this many units gone per tick

view_init :: proc(v: ^View) {
	v^ = {least_age = NEVER_LATE}
}

// One tick on: the clock, and everyone but `me` guessed on with it.
view_advance :: proc(v: ^View, ctx: ^sim.Context, w: ^sim.World, me: u8) {
	waits := false
	v.window += 1
	if v.window >= VIEW_WINDOW {
		waits = v.least_age != NEVER_LATE && v.least_age > 0
		v.window, v.least_age = 0, NEVER_LATE
	}
	if !waits do v.tick += 1

	scratch: sim.Events // what their steps would cause is the server's to say
	for &s, i in w.soldiers {
		if u8(i) == me || !s.active || s.dead do continue
		v.drawn[i] = s.pos + v.err[i]
		v.prev[i] = s.pos
		if !waits {
			sim.events_clear(&scratch)
			sim.soldier_reckon(ctx, w, u8(i), &scratch)
		}
		e := &v.err[i]
		if l := sim.vec2_length(e^); l > 0 {
			kept := min(l * ERR_DECAY, l - ERR_RATE)
			e^ = kept <= 0 ? {} : e^ * (kept / l)
		}
	}
}

// An update of `tick` is in: the clock never runs behind the news.
view_heard :: proc(v: ^View, tick: u32) {
	if tick > v.tick do v.tick = tick
	v.least_age = min(v.least_age, v.tick - tick)
}

// The server's word on a soldier as of `tick`, over the guess: brought on to the view
// tick, and drawn on from where the guess was drawn.
view_receive :: proc(v: ^View, ctx: ^sim.Context, w: ^sim.World, e: ^net.Entry, tick: u32) {
	s := &w.soldiers[e.slot]
	was_shown := s.active && !s.dead
	sim.soldier_copy_served(s, &e.soldier)
	if !e.has_owned do return
	sim.soldier_copy_owned(ctx.anims, s, &e.soldier)
	scratch: sim.Events
	for _ in 0 ..< min(v.tick - tick, MAX_CATCH_UP) {
		sim.events_clear(&scratch)
		sim.soldier_reckon(ctx, w, e.slot, &scratch)
	}
	v.prev[e.slot] = s.pos - s.vel
	off := v.drawn[e.slot] - v.prev[e.slot]
	v.err[e.slot] = was_shown && sim.vec2_length(off) <= ERR_SNAP ? off : {}
}

// A soldier the server has just placed: drawn there at once, not glided to.
view_place :: proc(v: ^View, slot: u8, pos: sim.Vec2) {
	v.prev[slot], v.drawn[slot], v.err[slot] = pos, pos, {}
}

// Where one of the others is drawn, `alpha` of the way into the tick.
view_drawn_pos :: proc(v: ^View, w: ^sim.World, slot: int, alpha: f32) -> sim.Vec2 {
	return v.prev[slot] + (w.soldiers[slot].pos - v.prev[slot]) * alpha + v.err[slot]
}
