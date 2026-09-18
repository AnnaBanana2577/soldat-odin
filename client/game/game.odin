package game

import "../connection"
import "../input"
import "../../shared/net"
import "../../shared/sim"

// The game as this client plays it. One world, rebuilt every tick by one rule:
//
//   the world is the server's newest snapshot;
//   my pending commands are replayed on it, stepping the whole world, which predicts
//     everything they touch;
//   everything that is not mine is then overwritten with the world as shown: a few
//     ticks behind, blended between the two snapshots around the render tick;
//   the corpses step, and the effects are gathered: mine from my replay, the rest
//     from the server as the render clock reaches their tick.
//
// Mine is what my commands can change: my soldier, the bullets I fired, the things I
// hold or let go of (`mine`). Everything else is the server's word, shown late enough
// that the next snapshot is always there to blend toward, so it is never guessed and
// never corrected. Nothing is kept across ticks but the pending commands, the corpses
// and the events waiting for the render clock.
//
// The game owns what the sim reads and never writes (the map, the animations, the
// weapons, the things' skeletons), loaded for the map the server named.
Game :: struct {
	ctx:       sim.Context,
	level:     sim.Level,
	anims:     ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:   sim.World,
	me:      u8,
	seq:     u32, // my command count
	pending: [dynamic]sim.Command, // not yet applied by the server, oldest first
	snaps:   Snapshots,
	shown:   ^net.Snapshot, // scratch: the world at the render tick

	events:    sim.Events, // this tick's effects
	frontier:  sim.Events, // scratch: what the newest command's step produced
	timeline:  [dynamic]net.Timed_Event, // the server's events, until the render clock reaches their tick
	next_fact: u32, // the server's decisions come numbered: the next to take

	time_scale:  f64, // my tick rate against the server's, steering the queue depth
	shots_fired: int,      // ours, for the HUD
	hits_predicted, hits_confirmed: int, // my hits as I saw them, and as the server ruled
	my_prev:     sim.Vec2, // my position a tick ago, for drawing between ticks

	// a correction: the server put my soldier elsewhere than I predicted for the same
	// command; the difference is drawn as an offset that blends out
	predicted: [PREDICTED_KEPT]sim.Vec2, // my position after each command, by seq
	checked:   u32,      // the newest ack compared
	smooth:    sim.Vec2, // the drawn offset
}

PREDICTED_KEPT :: 64
SMOOTH_DECAY   :: 0.8  // share of the offset kept per tick
SMOOTH_SNAP    :: 60.0 // a correction this large is shown at once

// The sim's data for the map, read from `base`, and an empty world for slot `me`.
init :: proc(g: ^Game, base, map_name: string, me: u8, interp_ticks: int) -> bool {
	ok: bool
	if g.level, ok = sim.level_load_file(base, map_name); !ok do return false
	if g.anims, ok = sim.anims_load_files(base); !ok do return false
	if g.skeletons, ok = sim.skeletons_load_files(base); !ok do return false
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	g.me = me
	sim.world_init(&g.world, 0)
	sim.round_init(&g.world.round)
	snapshots_init(&g.snaps, interp_ticks)
	g.shown = new(net.Snapshot)
	g.time_scale = 1
	return true
}

destroy :: proc(g: ^Game) {
	sim.level_destroy(&g.level)
	free(g.anims)
	free(g.skeletons)
	delete(g.pending)
	delete(g.timeline)
	free(g.shown)
	snapshots_destroy(&g.snaps)
}

// ---- what is mine ----

@(private)
mine_soldier :: proc(g: ^Game, slot: int) -> bool { return u8(slot) == g.me }
mine_bullet  :: proc(g: ^Game, b: ^sim.Bullet) -> bool { return b.active && b.owner == g.me }
mine_thing   :: proc(g: ^Game, t: ^sim.Thing) -> bool { return t.style != .None && (t.holder == g.me + 1 || t.owner == g.me + 1) }

// An action of mine, which my replay produced; the server's copy is skipped.
@(private)
mine_event :: proc(g: ^Game, e: sim.Event) -> bool {
	owner, action := sim.event_owner(e)
	return action && owner == g.me
}

// ---- receiving ----

// Every snapshot that arrived since the last tick. Its ack retires my commands and
// checks my prediction; its queue depth sets my clock: slower with too many waiting,
// faster with too few, and exactly the server's when the queue is near the target,
// so ticks and frames keep step. Its events wait for the render clock.
receive :: proc(g: ^Game, conn: ^connection.Connection) {
	for data in connection.receive(conn) {
		r := net.reader_make(data)
		if net.Msg(net.read_u8(&r)) != .Snapshot do continue
		snap := snapshots_receive(&g.snaps, &r)
		if snap == nil do continue
		for len(g.pending) > 0 && g.pending[0].seq <= snap.ack do ordered_remove(&g.pending, 0)
		if snap.ack > g.checked && snap.ack + PREDICTED_KEPT > g.seq {
			g.smooth += g.predicted[snap.ack % PREDICTED_KEPT] - snap.soldiers[g.me].pos
			if sim.vec2_length(g.smooth) > SMOOTH_SNAP do g.smooth = {}
			g.checked = snap.ack
		}
		depth := int(snap.queue_depth)
		g.time_scale = depth < TARGET_QUEUE - 1 ? 1.02 : depth > TARGET_QUEUE + 1 ? 0.98 : 1
		for e in sim.events_slice(&snap.events) do append(&g.timeline, net.Timed_Event{tick = snap.tick, e = e})
		for f in snap.facts[:snap.fact_count] {
			if f.seq < g.next_fact do continue // carried again until acknowledged: had it
			append(&g.timeline, f)
			g.next_fact = f.seq + 1
		}
	}
}

// ---- the tick ----

simulate :: proc(g: ^Game, in_: ^input.Input) {
	g.seq += 1
	append(&g.pending, input.command(in_, g.seq))
	latest := snapshots_latest(&g.snaps)
	if latest == nil do return

	g.my_prev = g.world.soldiers[g.me].pos
	world_reset(&g.world, latest)
	replay(g)
	snapshots_advance(&g.snaps)
	if snapshots_shown(&g.snaps, g.shown) do overlay(g, g.shown)
	sim.ragdolls_update(&g.ctx, &g.world)
	gather_effects(g)
	g.smooth *= SMOOTH_DECAY
}

// The authoritative state over the world; the corpses and the rng are the client's own.
@(private)
world_reset :: proc(w: ^sim.World, snap: ^net.Snapshot) {
	w.tick = snap.tick
	w.round = snap.round
	w.soldiers = snap.soldiers
	w.things = snap.things
	w.bullets = snap.bullets
}

// My pending commands, oldest first, each a tick of my soldier, the things and the
// bullets: the sim as it is. Only the newest command's step is new this tick; its
// events are kept, the rest are re-runs of earlier ticks and theirs are thrown away.
@(private)
replay :: proc(g: ^Game) {
	scratch: sim.Events
	for cmd, i in g.pending {
		events := i == len(g.pending) - 1 ? &g.frontier : &scratch
		sim.events_clear(events)
		sim.soldier_step(&g.ctx, &g.world, g.me, cmd, events)
		g.predicted[cmd.seq % PREDICTED_KEPT] = g.world.soldiers[g.me].pos
		sim.things_update(&g.ctx, &g.world, events)
		sim.bullets_update(&g.ctx, &g.world, events)
		g.world.tick += 1 // the tick the server will run this command on
	}
}

// Everything that is not mine, as the shown world has it. What the shown world holds
// of mine is my own past, and my replay has the present of it: dropped.
@(private)
overlay :: proc(g: ^Game, shown: ^net.Snapshot) {
	w := &g.world
	for i in 0 ..< sim.MAX_PLAYERS {
		if !mine_soldier(g, i) do w.soldiers[i] = shown.soldiers[i]
	}
	for &t, i in w.things {
		if !mine_thing(g, &t) do t = mine_thing(g, &shown.things[i]) ? {} : shown.things[i]
	}
	for &b, i in w.bullets {
		if !mine_bullet(g, &b) do b = mine_bullet(g, &shown.bullets[i]) ? {} : shown.bullets[i]
	}
}

// This tick's effects for the sparks and sounds: my actions from my replay, and from
// the server everything the render clock has reached, except my actions again.
@(private)
gather_effects :: proc(g: ^Game) {
	sim.events_clear(&g.events)
	for e in sim.events_slice(&g.frontier) {
		if mine_event(g, e) do sim.emit(&g.events, e)
	}
	now := u32(g.snaps.render_tick)
	for i := 0; i < len(g.timeline); {
		te := g.timeline[i]
		if te.tick > now {
			i += 1
			continue
		}
		if !mine_event(g, te.e) do sim.emit(&g.events, te.e)
		ordered_remove(&g.timeline, i)
	}
	// the counts the debug summary shows: what I predicted against what the server ruled
	for e in sim.events_slice(&g.frontier) {
		if v, is_hit := e.(sim.Hit); is_hit && v.shooter == g.me && v.target != g.me do g.hits_predicted += 1
	}
	for e in sim.events_slice(&g.events) {
		#partial switch v in e {
		case sim.Fire:   if v.player == g.me do g.shots_fired += 1
		case sim.Damage: if v.attacker == g.me && v.target != g.me do g.hits_confirmed += 1
		}
	}
}

// ---- sending ----

// My newest commands, a few packets running so a lost one loses nothing, and the tick
// I show the others at.
send :: proc(g: ^Game, conn: ^connection.Connection) {
	m := net.Input{view_tick = u32(g.snaps.render_tick), have = g.snaps.any ? g.snaps.latest : 0}
	first := max(len(g.pending) - net.MAX_COMMANDS_PER_INPUT, 0)
	for cmd in g.pending[first:] {
		m.commands[m.count] = cmd
		m.count += 1
	}
	w: net.Writer
	net.encode_input(&w, &m)
	connection.send(conn, net.writer_bytes(&w), reliable = false)
}

// ---- drawing ----

// Where a soldier is drawn this frame: between its last two ticks.
drawn_pos :: proc(g: ^Game, slot: int, alpha: f32) -> sim.Vec2 {
	s := &g.world.soldiers[slot]
	if s.dead {
		if r := &g.world.ragdolls[slot]; r.active do return r.old_pos[sim.RAGDOLL_HEAD] + (r.pos[sim.RAGDOLL_HEAD] - r.old_pos[sim.RAGDOLL_HEAD]) * alpha
		return s.pos
	}
	if mine_soldier(g, slot) do return g.my_prev + (s.pos - g.my_prev) * alpha + g.smooth
	return s.old_pos + (s.pos - s.old_pos) * alpha
}
