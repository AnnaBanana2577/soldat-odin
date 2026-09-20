package game

import "../../shared/net"
import "../../shared/sim"

// The others, as this client shows them: at a tick a little behind the newest word the
// server has sent, so that for every moment drawn there is a word before it and a word
// after it, and the two are drawn between. Nothing about them is guessed, and so nothing
// about them is ever taken back.
//
// The tick shown is the tick every packet tells the server, and the tick the server
// rewinds to when it judges what I fired (sim/history.odin): what I shoot at is what I
// saw. How far behind it sits follows the line, a few ticks at a time: far enough that
// the next word has always come, and no further.
//
// A word that never comes (a soldier out of view is told of twice a second, and packets
// are lost) is guessed forward from the last for a moment; a gap longer than that, or a
// soldier the server has just placed, is shown where it is next heard of.
View :: struct {
	samples: [sim.MAX_PLAYERS][SAMPLES]Sample, // each soldier as it was told of, by tick
	written: [sim.MAX_PLAYERS]int,             // how many have been written: the ring's head
	newest:  u32, // the newest tick heard of
	tick:    u32, // the tick the others are shown at
	behind:  int, // how far behind the newest that is, in ticks
	least:   int, // the fewest ticks of word ahead of the shown tick this second
	window:  int, // ticks into that second
	prev:    [sim.MAX_PLAYERS]sim.Vec2, // where each was shown a tick ago, for drawing between ticks
}

Sample :: struct {
	tick:    u32,
	held:    bool,
	soldier: sim.Soldier,
}

SAMPLES        :: 24  // words kept for each soldier: a second of them at 30 a second
BEHIND_LEAST   :: 3   // never nearer the newest word than this
BEHIND_MOST    :: 20
GAP_SNAP       :: 15  // ticks between two words beyond which the soldier is shown at the newer
GUESS_MOST     :: 6   // ticks a missing newer word is guessed forward at most: a tenth of a second
WINDOW         :: sim.TICK_RATE // how often how far behind to sit is reconsidered

view_init :: proc(v: ^View) {
	v^ = {behind = 2 * OTHERS_EVERY, least = max(int)}
}

OTHERS_EVERY :: 2 // ticks between the server's words of the others (server/game.odin)

// An update of `tick` is in: the shown tick never runs ahead of the news.
view_heard :: proc(v: ^View, tick: u32) {
	v.newest = max(v.newest, tick)
}

// A soldier as the server had it at `tick`, kept to be shown when the shown tick
// reaches it.
view_receive :: proc(v: ^View, e: ^net.Entry, tick: u32) {
	slot := int(e.slot)
	at := v.written[slot] % SAMPLES
	v.samples[slot][at] = {tick = tick, held = true, soldier = e.soldier}
	v.written[slot] += 1
}

// A soldier the server has just placed: what was heard of it before says nothing about
// where it is now, so it is shown where it is next heard of.
view_place :: proc(v: ^View, slot: u8, pos: sim.Vec2) {
	v.samples[slot] = {}
	v.written[slot] = 0
	v.prev[slot] = pos
}

// One tick on: the shown tick, and every other soldier put where the words around that
// tick have it.
view_advance :: proc(v: ^View, ctx: ^sim.Context, w: ^sim.World, me: u8) {
	view_clock(v)
	for &s, i in w.soldiers {
		if u8(i) == me do continue
		v.prev[i] = s.pos
		before, after := view_around(v, i, v.tick)
		if before == nil && after == nil do continue
		if before == nil { // only word of it is still to come: hold where it was
			v.prev[i] = after.soldier.pos
			view_show(ctx, &s, after, after, 0)
			continue
		}
		if after == nil { // no newer word: guess it on a moment, then hold
			ticks := min(int(v.tick - before.tick), GUESS_MOST)
			view_show(ctx, &s, before, before, 0)
			s.pos += s.vel * f32(ticks)
			continue
		}
		span := f32(after.tick - before.tick)
		if span > GAP_SNAP { // a gap: the newer word rather than a long slide to it
			view_show(ctx, &s, after, after, 0)
			continue
		}
		view_show(ctx, &s, before, after, f32(v.tick - before.tick) / span)
	}
}

// The shown tick: one on per tick, and held so far behind the newest word that a word
// after it has always come. Out of reach of the news it takes its place from them.
@(private = "file")
view_clock :: proc(v: ^View) {
	v.tick += 1
	ahead := int(v.newest) - int(v.tick)
	if ahead < -BEHIND_MOST || ahead > BEHIND_MOST + v.behind { // lost the thread: take it up again
		v.tick = v.newest > u32(v.behind) ? v.newest - u32(v.behind) : 0
		v.least, v.window = max(int), 0
		return
	}

	v.least = min(v.least, ahead)
	v.window += 1
	if v.window < WINDOW do return
	// a second with a moment of nothing ahead sits further back; a second with plenty
	// to spare the whole way sits nearer
	if v.least < 1 do v.behind = min(v.behind + 2, BEHIND_MOST)
	else if v.least > OTHERS_EVERY do v.behind = max(v.behind - 1, BEHIND_LEAST)
	if ahead < v.behind - 2 do v.tick -= 1 // and wait a tick for the news to catch up
	v.least, v.window = max(int), 0
}

// The two words around `tick`: the newest at or before it, and the oldest after it.
@(private = "file")
view_around :: proc(v: ^View, slot: int, tick: u32) -> (before, after: ^Sample) {
	for &s in v.samples[slot] {
		if !s.held do continue
		if s.tick <= tick && (before == nil || s.tick > before.tick) do before = &s
		if s.tick > tick && (after == nil || s.tick < after.tick) do after = &s
	}
	return
}

// A soldier as it stands between two words of it: where it is between the two, and the
// rest as the older has it, since what it holds and how it moves changes in steps.
@(private = "file")
view_show :: proc(ctx: ^sim.Context, s: ^sim.Soldier, before, after: ^Sample, part: f32) {
	s^ = before.soldier
	if s.legs.speed == 0 do sim.anim_set(ctx.anims, &s.legs, s.legs.id, s.legs.frame)
	if s.body.speed == 0 do sim.anim_set(ctx.anims, &s.body, s.body.id, s.body.frame)
	if part <= 0 do return
	s.pos = before.soldier.pos + (after.soldier.pos - before.soldier.pos) * part
	s.vel = before.soldier.vel + (after.soldier.vel - before.soldier.vel) * part
	s.aim = before.soldier.aim + (after.soldier.aim - before.soldier.aim) * part
}

// Where one of the others is drawn, `alpha` of the way into the tick.
view_drawn_pos :: proc(v: ^View, w: ^sim.World, slot: int, alpha: f32) -> sim.Vec2 {
	return v.prev[slot] + (w.soldiers[slot].pos - v.prev[slot]) * alpha
}
