package client

import "../shared/net"
import "../shared/sim"

// The game as this client plays it. The server's latest snapshot is the world; on top
// of it the client replays the commands the server has not applied yet, which
// predicts everything those commands touch: my soldier, my shots, my pickups, the
// things I hold. Everyone else and their bullets are shown from older snapshots,
// interpolated. Nothing is kept across ticks but the pending commands and the
// corpses: every tick rebuilds the world from the newest truth, so a correction is
// just the truth having changed.
Game :: struct {
	ctx:     ^sim.Context,
	world:   sim.World,
	me:      u8,
	seq:     u32, // my command count
	pending: [dynamic]sim.Command, // not yet applied by the server, oldest first
	snaps:   Snapshots,
	passed:  [dynamic]^net.Snapshot, // scratch: the snapshots the render clock passed this tick

	events:     sim.Events, // this tick's effects: mine predicted, the others' as the server reported
	frontier:   sim.Events, // scratch: what the newest command's step produced
	time_scale: f64,        // my tick rate against the server's, steering the queue depth
	camera:     Camera,
	shots_fired: int,      // ours, for the HUD
	my_prev:    sim.Vec2,  // my position a tick ago, for drawing between ticks

	// a correction: the server put my soldier elsewhere than I predicted for the same
	// command; the difference is drawn as an offset that blends out
	predicted: [PREDICTED_KEPT]sim.Vec2, // my position after each command, by seq
	checked:   u32,      // the newest ack compared
	smooth:    sim.Vec2, // the drawn offset
}

PREDICTED_KEPT :: 64
SMOOTH_DECAY   :: 0.8  // share of the offset kept per tick
SMOOTH_SNAP    :: 60.0 // a correction this large is shown at once

game_init :: proc(g: ^Game, ctx: ^sim.Context, me: u8) {
	g.ctx = ctx
	g.me = me
	sim.world_init(&g.world, 0)
	sim.round_init(&g.world.round)
	snapshots_init(&g.snaps)
	g.time_scale = 1
	g.camera.zoom = 1
}

game_destroy :: proc(g: ^Game) {
	delete(g.pending)
	delete(g.passed)
	snapshots_destroy(&g.snaps)
}

// Every snapshot that arrived since the last tick. Its ack retires my commands; its
// queue depth sets my clock: slower with too many waiting, faster with too few, and
// exactly the server's when the queue is near the target, so ticks and frames keep step.
process_server_messages :: proc(g: ^Game, conn: ^Connection) {
	for data in conn_receive(conn) {
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
	}
}

// One tick: this tick's command joins the pending ones; the world becomes the latest
// snapshot; the others are placed at the render tick; the pending commands are
// replayed; the corpses move; and the effects are gathered.
simulate :: proc(g: ^Game, in_: ^Input) {
	g.seq += 1
	append(&g.pending, command_for_tick(in_, g.seq))
	latest := snapshots_latest(&g.snaps)
	if latest == nil do return

	g.my_prev = g.world.soldiers[g.me].pos
	world_reset(&g.world, latest)
	snapshots_advance(&g.snaps)
	place_others(g)
	replay(g)
	sim.ragdolls_update(g.ctx, &g.world)
	gather_effects(g)
	g.smooth *= SMOOTH_DECAY
}

// The authoritative state over the world; the corpses and the rng are the client's own.
world_reset :: proc(w: ^sim.World, snap: ^net.Snapshot) {
	w.tick = snap.tick
	w.round = snap.round
	w.soldiers = snap.soldiers
	w.things = snap.things
	w.bullets = snap.bullets
}

// Everyone but me, and their bullets, as they were at the render tick: blended between
// the two snapshots around it, a tick's worth of motion behind for the frame blend.
// Comes before the replay so what hangs from them (a carried flag) hangs from where
// they are shown.
place_others :: proc(g: ^Game) {
	a, b, t := snapshots_bracket(&g.snaps)
	if a == nil do return
	w := &g.world
	for i in 0 ..< sim.MAX_PLAYERS {
		if u8(i) == g.me do continue
		sa, sb := &a.soldiers[i], &b.soldiers[i]
		w.soldiers[i] = sa^
		if !sa.active || sa.dead || !sb.active do continue
		step := sb.pos - sa.pos
		w.soldiers[i].pos = sa.pos + step * t
		w.soldiers[i].old_pos = w.soldiers[i].pos - step
		w.soldiers[i].aim = sa.aim + (sb.aim - sa.aim) * t
	}
	for &bl in w.bullets do if bl.active && bl.owner != g.me do bl = {}
	for k in 0 ..< sim.MAX_BULLETS {
		ba, bb := &a.bullets[k], &b.bullets[k]
		if !ba.active || ba.owner == g.me || w.bullets[k].active do continue
		w.bullets[k] = ba^
		if bb.active && bb.owner == ba.owner {
			step := bb.pos - ba.pos
			w.bullets[k].pos = ba.pos + step * t
			w.bullets[k].old_pos = w.bullets[k].pos - step
		}
	}
}

// My pending commands, oldest first, each a tick of my soldier, my pickups, the things
// and the bullets. Only the newest command's step is new this tick: its events are the
// frontier, the earlier ones were the frontier of earlier ticks.
replay :: proc(g: ^Game) {
	scratch: sim.Events
	for cmd, i in g.pending {
		events := i == len(g.pending) - 1 ? &g.frontier : &scratch
		sim.events_clear(events)
		sim.soldier_step(g.ctx, &g.world, g.me, cmd, events)
		g.predicted[cmd.seq % PREDICTED_KEPT] = g.world.soldiers[g.me].pos
		for k in 0 ..< sim.MAX_THINGS do sim.thing_claim(g.ctx, &g.world, g.me, u8(k), events)
		sim.things_update(g.ctx, &g.world, events)
		sim.bullets_update(g.ctx, &g.world, events)
	}
}

// This tick's effects for the sparks and sounds: from the frontier, what my own
// actions caused, which I predicted; from the snapshots the render clock passed, what
// the server reported, except what I predicted already. A kill starts the corpse.
gather_effects :: proc(g: ^Game) {
	sim.events_clear(&g.events)
	for e in sim.events_slice(&g.frontier) {
		if owner, predictable := sim.event_owner(e); predictable && owner == g.me do sim.emit(&g.events, e)
	}
	snapshots_passed(&g.snaps, &g.passed)
	for snap in g.passed {
		for e in sim.events_slice(&snap.events) {
			if owner, predictable := sim.event_owner(e); predictable && owner == g.me do continue
			sim.emit(&g.events, e)
		}
	}
	for e in sim.events_slice(&g.events) {
		#partial switch v in e {
		case sim.Fire:
			if v.player == g.me do g.shots_fired += 1
		case sim.Kill:
			s := &g.world.soldiers[v.target]
			if s.active && s.dead && !g.world.ragdolls[v.target].active {
				s.vel = v.vel
				sim.ragdoll_start(g.ctx, &g.world, v.target)
				sim.ragdoll_tear(&g.world, v.target, v.health, v.part)
			}
		}
	}
}

// My newest commands, a few packets running so a lost one loses nothing, and the tick
// I show the others at.
send_to_server :: proc(g: ^Game, conn: ^Connection) {
	m := net.Input{view_tick = u32(g.snaps.render_tick)}
	first := max(len(g.pending) - net.MAX_COMMANDS_PER_INPUT, 0)
	for cmd in g.pending[first:] {
		m.commands[m.count] = cmd
		m.count += 1
	}
	w: net.Writer
	net.encode_input(&w, &m)
	conn_send(conn, net.writer_bytes(&w), reliable = false)
}

// Where a soldier is drawn this frame: between its last two ticks.
drawn_pos :: proc(g: ^Game, slot: int, alpha: f32) -> sim.Vec2 {
	s := &g.world.soldiers[slot]
	if s.dead {
		if r := &g.world.ragdolls[slot]; r.active do return r.old_pos[sim.RAGDOLL_HEAD] + (r.pos[sim.RAGDOLL_HEAD] - r.old_pos[sim.RAGDOLL_HEAD]) * alpha
		return s.pos
	}
	if u8(slot) == g.me do return g.my_prev + (s.pos - g.my_prev) * alpha + g.smooth
	return s.old_pos + (s.pos - s.old_pos) * alpha
}

// The camera chasing us; dt is the frame's seconds, for the chase.
interpolate :: proc(g: ^Game, alpha: f32, dt: f64, cursor: sim.Vec2) {
	camera_follow(&g.camera, drawn_pos(g, int(g.me), alpha), cursor, dt)
}
