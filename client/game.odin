package client

import "../shared/net"
import "../shared/sim"

// The game as this client plays it: my soldier, simulated here and only here; the
// bullets, all of them, my own judged for hits; the things, run on from what the
// server last sent of each; and everyone else, dead-reckoned in the View.
Game :: struct {
	ctx:    ^sim.Context,
	world:  sim.World,
	me:     u8,
	seq:    u32, // my command count
	events: sim.Events, // this tick's, from the server's commits and my own step

	// what I owe the server: shots for a few packets, throws once, claims until answered
	shots:      [dynamic]net.Shot,
	throws:     [dynamic]net.Throw,
	claims:     [dynamic]net.Claim,
	next_shot:  u32,
	next_claim: u32,

	view:   View,
	camera: Camera,
	server_tick: u32, // as last heard
	shots_fired: int, // ours, for the HUD
	my_prev: sim.Vec2, // where our soldier was before its last step, for drawing between ticks
}

game_init :: proc(g: ^Game, ctx: ^sim.Context, me: u8) {
	g.ctx = ctx
	g.me = me
	sim.world_init(&g.world, 0)
	sim.round_init(&g.world.round)
	view_init(&g.view, &g.world, me)
	g.camera.zoom = 1
}

game_destroy :: proc(g: ^Game) {
	delete(g.shots)
	delete(g.throws)
	delete(g.claims)
	view_destroy(&g.view)
}

// Everything the server sent since the last tick, in order. What arrives is as old as
// half the round trip on top of the age it says: the lead every fresh state and thing
// is moved on by.
process_server_messages :: proc(g: ^Game, conn: ^Connection) {
	g.view.lead = int(f64(round_trip_ms(conn)) / 2 / (1000 * TICK))
	for data in conn_receive(conn) {
		r := net.reader_make(data)
		kind := net.Msg(net.read_u8(&r))
		#partial switch kind {
		case .State:
			if m, ok := net.decode_state(&r); ok {
				if m.slot != g.me do view_receive_state(&g.view, g.ctx, m.slot, &m.soldier, int(m.age))
				else do receive_own_state(g, &m.soldier)
			}
		case .Shot:
			// another's bullet, a copy for show; mine is already flying
			if m, ok := net.decode_shot(&r); ok && m.player != g.me {
				sim.bullet_spawn(g.ctx, &g.world, m.shot.pos, m.shot.vel, m.shot.weapon, m.player, m.shot.damage, &g.events)
			}
		case .Commit:
			if m, ok := net.decode_commit(&r); ok do apply_commit(g, &m)
		case .Reject:
			if id, ok := net.decode_reject(&r); ok do drop_claim(g, id)
		case .Things:
			if m, ok := net.decode_things(&r); ok {
				for &item in m.items[:m.count] do receive_thing(g, item.index, &item.thing)
			}
		case .Clock:
			if m, ok := net.decode_clock(&r); ok {
				g.server_tick = m.tick
				g.world.round.state = m.round.state
				g.world.round.scores = m.round.scores
				g.world.round.time_left = m.round.time_left
			}
		}
	}
}

// What the server owns about my soldier comes back through its state: health, death,
// the flag, scores. My movement and weapons stay as I simulated them. A death or a
// respawn replaces the soldier whole.
receive_own_state :: proc(g: ^Game, s: ^sim.Soldier) {
	mine := &g.world.soldiers[g.me]
	restart := !mine.active || mine.dead != s.dead || mine.team != s.team
	if restart {
		mine^ = s^
		return
	}
	mine.health = s.health
	mine.vest = s.vest
	mine.bonus, mine.bonus_time = s.bonus, s.bonus_time
	mine.cease_fire_counter = s.cease_fire_counter
	mine.respawn_counter = s.respawn_counter
	mine.holding_flag = s.holding_flag
	mine.kills, mine.deaths, mine.flags = s.kills, s.deaths, s.flags
}

// A thing as the server has it: sent when it appeared or went, changed hands, or
// started or stopped moving, and after a refused pickup. Moved on by the lead, then
// it runs on our own physics until the next change.
receive_thing :: proc(g: ^Game, index: u8, t: ^sim.Thing) {
	if int(index) >= sim.MAX_THINGS do return
	if !t.static {
		scratch: sim.Events
		sim.thing_advance(g.ctx, &g.world, t, g.view.lead, &scratch)
	}
	g.world.things[index] = t^
}

// A settled claim is applied the same way in every world: a hit wounds through
// damage_apply, a pickup through thing_grant, exactly as the server did it.
apply_commit :: proc(g: ^Game, m: ^net.Commit) {
	if m.player == g.me do drop_claim(g, m.claim.id)
	switch m.claim.kind {
	case .Hit:
		hit := sim.Hit{shooter = m.player, target = m.claim.target, weapon = m.claim.weapon, amount = m.claim.amount, part = m.claim.part, pos = m.claim.pos, push = m.claim.vel}
		sim.damage_apply(g.ctx, &g.world, hit, &g.events)
	case .Pickup:
		if m.player != g.me do sim.thing_grant(g.ctx, &g.world, m.player, m.claim.target, &g.events)
	}
}

drop_claim :: proc(g: ^Game, id: u32) {
	for c, i in g.claims {
		if c.id == id {
			ordered_remove(&g.claims, i)
			return
		}
	}
}

// One tick: my soldier on this tick's command, the corpses, what I walked into, the
// things, every bullet, the others. Then what of it is mine to tell the server.
simulate :: proc(g: ^Game, in_: ^Input) {
	g.seq += 1
	cmd := command_for_tick(in_, g.seq)
	g.my_prev = g.world.soldiers[g.me].pos
	sim.soldier_step(g.ctx, &g.world, g.me, cmd, &g.events)
	sim.ragdolls_update(g.ctx, &g.world)
	for i in 0 ..< sim.MAX_THINGS do sim.thing_claim(g.ctx, &g.world, g.me, u8(i), &g.events)
	sim.things_update(g.ctx, &g.world, &g.events)
	sim.bullets_update(g.ctx, &g.world, &g.events)
	dead_reckon(&g.view, g.ctx)
	g.world.tick += 1

	for e in sim.events_slice(&g.events) {
		#partial switch v in e {
		case sim.Bullet_Spawn:
			if v.player == g.me do queue_shot(g, v)
		case sim.Fire:
			if v.player == g.me do g.shots_fired += 1
		case sim.Hit:
			// my shot's hit is mine to report; another's is the server's to tell me about
			if v.shooter == g.me do queue_claim(g, {kind = .Hit, target = v.target, weapon = v.weapon, amount = v.amount, part = v.part, pos = v.pos, vel = v.push})
		case sim.Kit_Pickup:
			if v.player == g.me do queue_claim(g, {kind = .Pickup, target = v.thing})
		case sim.Weapon_Pickup:
			if v.player == g.me do queue_claim(g, {kind = .Pickup, target = v.thing})
		case sim.Flag_Grab:
			if v.player == g.me do queue_claim(g, {kind = .Pickup, target = v.thing})
		case sim.Weapon_Drop:
			// nobody can contest a throw: an event for the server, not a claim
			if v.player == g.me && v.thrown do append(&g.throws, net.Throw{v.weapon, v.ammo})
		}
	}
}

queue_shot :: proc(g: ^Game, e: sim.Bullet_Spawn) {
	g.next_shot += 1
	append(&g.shots, net.Shot{id = g.next_shot, weapon = e.weapon, pos = e.pos, vel = e.vel, damage = e.damage})
}

queue_claim :: proc(g: ^Game, c: net.Claim) {
	c := c
	g.next_claim += 1
	c.id = g.next_claim
	append(&g.claims, c)
}

// My soldier every tick, and each shot in a few packets running so one lost packet
// loses no shot; my throws and claims, reliable, once each.
SHOT_REPEATS :: 3

send_to_server :: proc(g: ^Game, conn: ^Connection) {
	mine := &g.world.soldiers[g.me]
	u := net.Update{seq = g.seq}
	if mine.active && !mine.dead {
		u.has_state = true
		u.state = mine^
	}
	for &s in g.shots {
		if u.shot_count == net.MAX_SHOTS_PER_PACKET do break
		u.shots[u.shot_count] = s
		u.shot_count += 1
		s.sends += 1
	}
	for len(g.shots) > 0 && g.shots[0].sends >= SHOT_REPEATS do ordered_remove(&g.shots, 0)
	w: net.Writer
	net.encode_update(&w, &u)
	conn_send(conn, net.writer_bytes(&w), reliable = false)

	for &t in g.throws {
		tw: net.Writer
		net.encode_throw(&tw, &t)
		conn_send(conn, net.writer_bytes(&tw), reliable = true)
	}
	clear(&g.throws)
	for &c in g.claims {
		if c.sent do continue
		c.sent = true
		cw: net.Writer
		net.encode_claim(&cw, &c)
		conn_send(conn, net.writer_bytes(&cw), reliable = true)
	}
}

// Where everyone is drawn this frame, between the last two ticks, and the camera
// chasing us; dt is the frame's seconds, for the chase.
interpolate :: proc(g: ^Game, alpha: f32, dt: f64, cursor: sim.Vec2) {
	view_interpolate(&g.view, alpha)
	mine := &g.world.soldiers[g.me]
	g.view.drawn[g.me] = g.my_prev + (mine.pos - g.my_prev) * alpha
	camera_follow(&g.camera, g.view.drawn[g.me], cursor, dt)
}
