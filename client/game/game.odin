package game

import "core:fmt"
import "core:strings"
import "../connection"
import "../input"
import "../../shared/net"
import "../../shared/sim"

// The game as this client plays it. My soldier is stepped here the moment I press a
// key, on the same commands the server runs it on, and put right over the server's word
// when one comes (predict.odin). Everyone else is shown a little in the past and guessed
// on between the server's words (the View).
// Every bullet flies here and every thing moves here, so the blood, the sparks and the
// sounds are local and at once; but nobody is wounded here and nothing is taken here.
// Health, deaths, pickups and scores are the server's word, and arrive. The tick reads
// the way the server's does (server/game.odin):
//
//   view_advance   everyone else one tick on, as guessed
//   receive        the server's word over the guesses and over my own soldier, which my
//                  unrun commands are replayed on; the bullets others fired, flown on
//                  to where they are by now; the things; what the server decided
//   step_mine      my soldier on this tick's keys, which go to the server
//   step_world     the corpses, the things, every bullet
//   send           the commands the server has not run, and the tick I show the others at
//
// The game owns what the sim reads and never writes (the map, the animations, the
// weapons, the things' skeletons). The map is the one the server names, on joining and
// at every round (receive_map); until it has named one there is nothing to play.
Game :: struct {
	ctx:       sim.Context,
	base:      string,
	level:     sim.Level,
	map_name:  string, // the loaded map's
	maps_loaded: int,  // how many maps were loaded: what the picture is rebuilt by
	missing:   string, // a map the server named and that is not here
	anims:     ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:     sim.World,
	me:        u8,
	view:      View,       // the others
	names:     [sim.MAX_PLAYERS]net.Name, // who plays in which slot, from the server's roster
	bots:      u32, // a bit for each slot the server plays itself
	lags:      [sim.MAX_PLAYERS]u8, // how late the server finds each player sees the world, in ticks
	events:    sim.Events, // this tick's, for the sparks and the sounds
	heard:     [dynamic]net.Chat, // this tick's lines, for the HUD
	primary, secondary: sim.Weapon_Id, // the weapons I chose, for my next spawn

	pending:   [dynamic]sim.Command, // mine the server has not said it ran: what I replay
	seq:       u32,                  // my commands are numbered from here
	acts:      [dynamic]net.Act,     // what I chose, to tell once
	said:      [dynamic]net.Chat,    // what I said, to tell once
	seen_shot: [sim.MAX_PLAYERS]u32, // the newest of each shooter's bullets flown here
	newest:    u32, // the newest update taken: one that comes after a newer one is dropped
	my_lag:    int, // how late the server finds I see the world, in ticks

	my_prev:     sim.Vec2, // my position a tick ago, for drawing between ticks
	error:       sim.Vec2, // where the server put me against where I had myself, blending out
	server_depth: u8,      // my commands waiting there, as the last update reported
	depth:       f64,      // eased, which my clock steers by
	time_scale:  f64,      // my tick rate against the server's
	clock_target: f64,     // commands to keep waiting there (net_clock_target)
	// what the prediction cost: the error at the last update, the worst and the mean,
	// which the debug summary reports (it should be nil on a quiet line)
	error_now, error_worst: f32,
	error_sum:   f64,
	error_count: int,
	shots_fired: int,      // ours, for the HUD
	// the hits I gave and took as they showed here; the server's leave line has how
	// many of each it ruled, and the two agreeing is the measure of the netcode
	hits_given, hits_taken: int,
	incoming:    ^net.Message, // scratch: an Update is too large for the stack
}

MAX_FAST_FORWARD :: 40 // ticks another's bullet is flown on at most when it is heard of
PENDING_KEPT     :: 64 // commands kept waiting for the server's word on them: a second

// The sim's data every map shares, read from `base`, and an empty world for slot `me`.
// `interp_least` is how far behind the newest word of the others they are shown, at the
// least, and `clock_target` how many commands to keep waiting on the server.
init :: proc(g: ^Game, base: string, me: u8, interp_least: int, clock_target: f32) -> bool {
	ok: bool
	g.base = base
	if g.anims, ok = sim.anims_load_files(base); !ok do return false
	if g.skeletons, ok = sim.skeletons_load_files(base); !ok do return false
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	g.me = me
	g.primary, g.secondary = .AK74, .Colt // what the server arms a newcomer with
	sim.world_init(&g.world, 0)
	g.time_scale = 1
	sim.round_init(&g.world.round)
	view_init(&g.view, interp_least)
	g.clock_target = f64(clock_target)
	g.incoming = new(net.Message)
	return true
}

destroy :: proc(g: ^Game) {
	if g.maps_loaded > 0 do sim.level_destroy(&g.level)
	delete(g.map_name)
	delete(g.missing)
	free(g.anims)
	free(g.skeletons)
	delete(g.pending)
	delete(g.acts)
	delete(g.said)
	delete(g.heard)
	free(g.incoming)
}

tick :: proc(g: ^Game, conn: ^connection.Connection, in_: ^input.Input) {
	sim.events_clear(&g.events)
	clear(&g.heard)
	view_advance(&g.view, &g.ctx, &g.world, g.me)
	receive(g, conn)
	step_mine(g, in_)
	step_world(g)
	predict_tick(g)
	send(g, conn)
}

// ---- receiving ----

// Everything the server sent since the last tick, in order.
receive :: proc(g: ^Game, conn: ^connection.Connection) {
	for data in connection.receive(conn) {
		if !net.decode(data, g.incoming) do continue
		#partial switch &m in g.incoming {
		case net.Map:
			receive_map(g, &m)
		case net.Update:
			if g.maps_loaded > 0 do receive_update(g, &m)
		case net.Chat:
			append(&g.heard, m)
		case net.Roster:
			for i in 0 ..< m.count do g.names[m.slots[i]] = m.names[i]
			g.bots = m.bots
		case net.Things:
			for i in 0 ..< m.count do g.world.things[m.indices[i]] = m.things[i]
		case net.Facts:
			for i in 0 ..< m.count do receive_fact(g, m.events[i])
		}
	}
}

// A round on the map the server names: loaded, unless it is the one I have; the things,
// the bullets and the corpses gone; the scores nil. The soldiers are placed by the
// facts that follow it, and an update from before it speaks of the last round.
receive_map :: proc(g: ^Game, m: ^net.Map) {
	if m.name != g.map_name {
		level, ok := sim.level_load_file(g.base, m.name)
		if !ok {
			g.missing = strings.clone(m.name)
			return
		}
		if g.maps_loaded > 0 do sim.level_destroy(&g.level)
		g.level = level
		delete(g.map_name)
		g.map_name = strings.clone(m.name)
		g.maps_loaded += 1
		fmt.printfln("map %s: %d polys, %d props", g.map_name, len(g.level.polys), len(g.level.props))
	}
	w := &g.world
	w.things, w.bullets, w.ragdolls = {}, {}, {}
	w.flag_home = m.flag_home
	sim.round_init(&w.round)
	if m.tick > 0 do g.newest = max(g.newest, m.tick - 1)
}

// The world as the server has it: who is in play, the soldiers in my view, the
// bullets born lately, the round.
receive_update :: proc(g: ^Game, m: ^net.Update) {
	if m.tick <= g.newest do return
	g.newest = m.tick
	g.lags = m.lags
	g.my_lag = int(m.lags[g.me])
	g.server_depth = m.depth
	g.world.round.state = m.round.state
	g.world.round.time_left = m.round.time_left
	g.world.round.counter = m.round.counter
	g.world.round.scores = m.round.scores
	view_heard(&g.view, m.tick)
	for &s, i in g.world.soldiers {
		if m.active & (1 << u32(i)) == 0 do s = {}
	}
	for &e in m.entries[:m.entry_count] {
		if e.slot == g.me do reconcile(g, &e, m.tick, m.ack)
		else do view_receive(&g.view, &e, m.tick)
	}
	for &f in m.fired[:m.fired_count] do receive_fired(g, &f, m.tick)
	for &e in m.ends[:m.end_count] do receive_end(g, &e)
}

// Another's bullet, flown on from its birth to where it is for me. The server judges
// it against the soldiers as its shooter saw them, its lag ago; and it has me where I
// said I was, which it hears my own lag after I showed the tick I was looking at. So
// the bullet that will be ruled to hit me is both lags ahead of the one the server
// spawned, on top of the ticks since: Soldat's rule, my ping plus the shooter's.
receive_fired :: proc(g: ^Game, f: ^net.Fired, update_tick: u32) {
	if f.seq <= g.seen_shot[f.shooter] do return
	g.seen_shot[f.shooter] = f.seq
	index, ok := sim.bullet_spawn(&g.ctx, &g.world, f.pos, f.vel, f.weapon, f.shooter, g.ctx.weapons[f.weapon].damage, &g.events)
	if !ok do return
	since := int(g.view.tick - update_tick) + int(f.age)
	sim.bullet_fast_forward(&g.ctx, &g.world, index, min(since + int(f.lag) + g.my_lag, MAX_FAST_FORWARD), &g.events)
}

// Where one of my own bullets ended. I flew it myself from the same command, so it is
// usually where mine is anyway; where the server saw something I did not (a soldier my
// copy passed through), mine stops there too, and its spark is where the server put it.
receive_end :: proc(g: ^Game, e: ^net.End) {
	for &b, i in g.world.bullets {
		if !b.active || b.owner != g.me || b.shot_id != e.shot do continue
		if e.impact do b.pos = e.pos
		sim.bullet_end(&g.world, &b, u16(i), &g.events, e.impact ? e.pos : nil)
		return
	}
}

// What the server decided. It sounds and shows like anything else that happened. A
// placing of a soldier begins its next life here, mine or another's, unless an update
// has told of that life already; and what a pickup gives me of the things that are mine
// to say (a gun, grenades) I give myself.
receive_fact :: proc(g: ^Game, e: sim.Event) {
	sim.emit(&g.events, e)
	mine := &g.world.soldiers[g.me]
	#partial switch v in e {
	case sim.Respawn:
		s := &g.world.soldiers[v.target]
		if s.active && s.life == v.life do break
		sim.soldier_spawn(&g.ctx, s, v.pos, v.team, v.primary, v.secondary)
		s.life = v.life
		if v.target == g.me do g.my_prev = v.pos
		else do view_place(&g.view, v.target, v.pos)
	case sim.Kit_Pickup:
		if v.player == g.me do sim.kit_give(&g.ctx, &g.world, mine, v.kit)
	case sim.Weapon_Pickup:
		if v.player == g.me {
			mine.weapon = sim.weapon_state(&g.ctx, v.weapon)
			mine.weapon.ammo = v.ammo
		}
	}
}

// ---- what the player decides outside the tick ----

// The weapons menu's choice: the server hears of it for my next spawn, and a soldier
// of mine that has not moved since it spawned is armed with it at once (its weapons
// are mine to say).
choose_weapons :: proc(g: ^Game, primary, secondary: sim.Weapon_Id) {
	g.primary, g.secondary = primary, secondary
	append(&g.acts, net.Act{action = .Loadout, weapon = primary, second = secondary})
	mine := &g.world.soldiers[g.me]
	if mine.active && !mine.dead && mine.spawn_still do sim.soldier_arm(&g.ctx, mine, primary, secondary)
}

// Joining the other team: the server moves me if the teams stay even, and says so.
choose_team :: proc(g: ^Game, team: sim.Team) {
	append(&g.acts, net.Act{action = .Join_Team, team = team})
}

// A line to everyone, or to my team.
say :: proc(g: ^Game, line: string, team: bool) {
	chat := net.Chat{team = team}
	net.text_set(&chat.text, line)
	append(&g.said, chat)
}

name_of :: proc(g: ^Game, slot: u8) -> string {
	return net.text_string(&g.names[slot])
}

// ---- the tick ----

// This tick's keys as a command: kept to replay, sent to the server, and run here at
// once on my own soldier. What it does there it does here, from the throw of a gun to
// the bullets it fires, so nothing I press waits for the wire.
step_mine :: proc(g: ^Game, in_: ^input.Input) {
	mine := &g.world.soldiers[g.me]
	g.my_prev = mine.pos
	g.seq += 1
	cmd := input.command(in_, g.seq)
	append(&g.pending, cmd)
	// a second of them: a client further behind than that has lost its place anyway, and
	// dropping one the server has not run yet would leave my replay short of it
	if len(g.pending) > PENDING_KEPT do ordered_remove(&g.pending, 0)
	if !mine.active || mine.dead do return
	before := g.events.count
	sim.soldier_step(&g.ctx, &g.world, g.me, cmd, &g.events)
	for e in g.events.items[before:g.events.count] {
		if v, fired := e.(sim.Fire); fired && v.player == g.me do g.shots_fired += 1
	}
}

// The corpses, the things, every bullet. A hit shows here at once, on whoever it is; its
// wound is the server's to give, but the shove of one on me is felt here, where I am
// stepped. That goes for a bullet that reached me while it was flown on, too.
step_world :: proc(g: ^Game) {
	sim.ragdolls_update(&g.ctx, &g.world)
	sim.things_update(&g.ctx, &g.world, &g.events)
	sim.bullets_update(&g.ctx, &g.world, &g.events)
	g.world.tick += 1
	// A hit here is blood and a sound and nothing else, my own included: the wound is the
	// server's to give and so is the shove, which arrives with my soldier. Shoving myself
	// where I see the bullet land would be a guess at a tick the server has not reached,
	// and every such guess is a correction to swallow.
	for e in sim.events_slice(&g.events) {
		hit, is_hit := e.(sim.Hit)
		if !is_hit do continue
		if hit.target == g.me && hit.shooter != g.me && wounds(g, hit.shooter, g.me) do g.hits_taken += 1
		else if hit.shooter == g.me && hit.target != g.me && wounds(g, g.me, hit.target) do g.hits_given += 1
	}
}

// Whether a hit of `shooter` on `target` would wound it: on the other team, unless
// friendly fire is on (damage_apply's rule).
@(private)
wounds :: proc(g: ^Game, shooter, target: u8) -> bool {
	a, b := &g.world.soldiers[shooter], &g.world.soldiers[target]
	return g.world.round.friendly_fire || a.team == .None || a.team != b.team
}

// ---- sending ----

// The commands the server has not said it ran, all of them every tick so a lost packet
// costs nothing, and the tick I show the others at; what I chose and what I said, once.
send :: proc(g: ^Game, conn: ^connection.Connection) {
	m := net.Input{view_tick = g.view.tick}
	if len(g.pending) > 0 do m.first = g.pending[0].seq
	for cmd in g.pending { // the oldest first: the server runs them in order
		if m.count == net.MAX_CMDS_PER_INPUT do break
		m.cmds[m.count] = cmd
		m.count += 1
	}
	connection.send_message(conn, m)

	for a in g.acts do connection.send_message(conn, a)
	for c in g.said do connection.send_message(conn, c)
	clear(&g.said)
	clear(&g.acts)
	connection.flush(conn)
}

// ---- drawing ----

// Where a soldier is drawn this frame: between its last two ticks, and for the others
// with the offset that blends a correction out.
drawn_pos :: proc(g: ^Game, slot: int, alpha: f32) -> sim.Vec2 {
	s := &g.world.soldiers[slot]
	if s.dead {
		if r := &g.world.ragdolls[slot]; r.active do return r.old_pos[sim.RAGDOLL_HEAD] + (r.pos[sim.RAGDOLL_HEAD] - r.old_pos[sim.RAGDOLL_HEAD]) * alpha
		return s.pos
	}
	if u8(slot) == g.me do return g.my_prev + (s.pos - g.my_prev) * alpha + g.error
	return view_drawn_pos(&g.view, &g.world, slot, alpha)
}
