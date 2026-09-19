package game

import "../connection"
import "../input"
import "../../shared/net"
import "../../shared/sim"

// The game as this client plays it. My soldier is mine: stepped here on my keys, never
// predicted and never corrected, and the server is told where it is. Everyone else is
// shown a little in the past and guessed on between the server's words (the View).
// Every bullet flies here and every thing moves here, so the blood, the sparks and the
// sounds are local and at once; but nobody is wounded here and nothing is taken here.
// Health, deaths, pickups and scores are the server's word, and arrive. The tick reads
// the way the server's does (server/game.odin):
//
//   view_advance   everyone else one tick on, as guessed
//   receive        the server's word over the guesses; the bullets others fired, flown
//                  on to where they are by now; the things; what the server decided
//   step_mine      my soldier on this tick's keys
//   step_world     the corpses, the things, every bullet
//   send           my soldier, the tick I show the others at, my recent shots
//
// The game owns what the sim reads and never writes (the map, the animations, the
// weapons, the things' skeletons), loaded for the map the server named.
Game :: struct {
	ctx:       sim.Context,
	level:     sim.Level,
	anims:     ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:     sim.World,
	me:        u8,
	view:      View,       // the others
	names:     [sim.MAX_PLAYERS]net.Name, // who plays in which slot, from the server's roster
	events:    sim.Events, // this tick's, for the sparks and the sounds
	primary, secondary: sim.Weapon_Id, // the weapons I chose, for my next spawn

	shots:     [dynamic]net.Shot, // mine, each riding in a few packets running
	acts:      [dynamic]net.Act,  // what I did that the server must not miss, to tell once
	next_shot: u32,
	seen_shot: [sim.MAX_PLAYERS]u32, // the newest of each shooter's bullets flown here
	newest:    u32, // the newest update taken: one that comes after a newer one is dropped
	my_lag:    int, // how late the server finds I see the world, in ticks

	my_prev:     sim.Vec2, // my position a tick ago, for drawing between ticks
	shots_fired: int,      // ours, for the HUD
	// the hits I gave and took as they showed here; the server's leave line has how
	// many of each it ruled, and the two agreeing is the measure of the netcode
	hits_given, hits_taken: int,
	incoming:    ^net.Message, // scratch: an Update is too large for the stack
}

SHOT_REPEATS     :: 3  // packets a shot rides in, so a lost packet loses no shot
MAX_FAST_FORWARD :: 40 // ticks another's bullet is flown on at most when it is heard of

// The sim's data for the map, read from `base`, and an empty world for slot `me`.
init :: proc(g: ^Game, base, map_name: string, me: u8) -> bool {
	ok: bool
	if g.level, ok = sim.level_load_file(base, map_name); !ok do return false
	if g.anims, ok = sim.anims_load_files(base); !ok do return false
	if g.skeletons, ok = sim.skeletons_load_files(base); !ok do return false
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	g.me = me
	g.primary, g.secondary = .AK74, .Colt // what the server arms a newcomer with
	sim.world_init(&g.world, 0)
	sim.round_init(&g.world.round)
	view_init(&g.view)
	g.incoming = new(net.Message)
	return true
}

destroy :: proc(g: ^Game) {
	sim.level_destroy(&g.level)
	free(g.anims)
	free(g.skeletons)
	delete(g.shots)
	delete(g.acts)
	free(g.incoming)
}

tick :: proc(g: ^Game, conn: ^connection.Connection, in_: ^input.Input) {
	sim.events_clear(&g.events)
	view_advance(&g.view, &g.ctx, &g.world, g.me)
	receive(g, conn)
	step_mine(g, in_)
	step_world(g)
	send(g, conn)
}

// ---- receiving ----

// Everything the server sent since the last tick, in order.
receive :: proc(g: ^Game, conn: ^connection.Connection) {
	for data in connection.receive(conn) {
		if !net.decode(data, g.incoming) do continue
		#partial switch &m in g.incoming {
		case net.Update:
			receive_update(g, &m)
		case net.Roster:
			for i in 0 ..< m.count do g.names[m.slots[i]] = m.names[i]
		case net.Things:
			for i in 0 ..< m.count do g.world.things[m.indices[i]] = m.things[i]
		case net.Facts:
			for i in 0 ..< m.count do receive_fact(g, m.events[i])
		case net.Correction:
			// the server refused where I said I was: I am where it says, in the life it says
			mine := &g.world.soldiers[g.me]
			mine.pos, mine.old_pos, mine.vel, mine.life = m.pos, m.pos, m.vel, m.life
			g.my_prev = m.pos
		}
	}
}

// The world as the server has it: who is in play, the soldiers in my view, the
// bullets born lately, the round.
receive_update :: proc(g: ^Game, m: ^net.Update) {
	if m.tick <= g.newest do return
	g.newest = m.tick
	g.my_lag = int(m.your_lag)
	g.world.round.state = m.round.state
	g.world.round.time_left = m.round.time_left
	g.world.round.scores = m.round.scores
	view_heard(&g.view, m.tick)
	for &s, i in g.world.soldiers {
		if m.active & (1 << u32(i)) == 0 do s = {}
	}
	for &e in m.entries[:m.entry_count] {
		if e.slot == g.me do receive_own(g, &e)
		else do view_receive(&g.view, &g.ctx, &g.world, &e, m.tick)
	}
	for &f in m.fired[:m.fired_count] do receive_fired(g, &f, m.tick)
}

// Of my own soldier I take the server's half: health, death, the flag, the tally. But
// only of the life I am living: an update from before the server placed me, or from
// after a placing I have not heard of yet, speaks of another life.
receive_own :: proc(g: ^Game, e: ^net.Entry) {
	mine := &g.world.soldiers[g.me]
	if e.soldier.life == mine.life do sim.soldier_copy_served(mine, &e.soldier)
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

// What the server decided. It sounds and shows like anything else that happened. A
// placing of my soldier begins its next life here; and what a pickup gives me of the
// things that are mine to say (a gun, grenades) I give myself.
receive_fact :: proc(g: ^Game, e: sim.Event) {
	sim.emit(&g.events, e)
	mine := &g.world.soldiers[g.me]
	#partial switch v in e {
	case sim.Respawn:
		if v.target == g.me {
			sim.soldier_spawn(&g.ctx, mine, v.pos, v.team, v.primary, v.secondary)
			mine.life = v.life
			g.my_prev = v.pos
		}
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

name_of :: proc(g: ^Game, slot: u8) -> string {
	return net.name_string(&g.names[slot])
}

// ---- the tick ----

// My soldier on this tick's keys, and what of it the server must hear.
step_mine :: proc(g: ^Game, in_: ^input.Input) {
	mine := &g.world.soldiers[g.me]
	g.my_prev = mine.pos
	if !mine.active || mine.dead do return
	cmd := input.command(in_)
	pressed := cmd.buttons - mine.controls // down this tick and not the last
	before := g.events.count
	sim.soldier_step(&g.ctx, &g.world, g.me, cmd, &g.events)
	for e in g.events.items[before:g.events.count] {
		#partial switch v in e {
		case sim.Bullet_Spawn:
			g.next_shot += 1
			append(&g.shots, net.Shot{id = g.next_shot, weapon = v.weapon, pos = v.pos, vel = v.vel})
		case sim.Fire:
			g.shots_fired += 1
		case sim.Weapon_Drop:
			if v.thrown do append(&g.acts, net.Act{action = .Throw_Gun, weapon = v.weapon, ammo = v.ammo})
		}
	}
	if .Suicide in pressed do append(&g.acts, net.Act{action = .Suicide})
	if .Flag_Throw in pressed && mine.holding_flag do append(&g.acts, net.Act{action = .Throw_Flag})
}

// The corpses, the things, every bullet. A hit shows here at once, on whoever it is; its
// wound is the server's to give, but the shove of one on me is felt here, where I am
// stepped. That goes for a bullet that reached me while it was flown on, too.
step_world :: proc(g: ^Game) {
	sim.ragdolls_update(&g.ctx, &g.world)
	sim.things_update(&g.ctx, &g.world, &g.events)
	sim.bullets_update(&g.ctx, &g.world, &g.events)
	g.world.tick += 1
	mine := &g.world.soldiers[g.me]
	for e in sim.events_slice(&g.events) {
		hit, is_hit := e.(sim.Hit)
		if !is_hit do continue
		if hit.target == g.me {
			mine.next_push += hit.push
			if hit.shooter != g.me && wounds(g, hit.shooter, g.me) do g.hits_taken += 1
		} else if hit.shooter == g.me && wounds(g, g.me, hit.target) {
			g.hits_given += 1
		}
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

// My soldier, the tick I show the others at, and my recent shots, every tick; what I
// did, once.
send :: proc(g: ^Game, conn: ^connection.Connection) {
	mine := &g.world.soldiers[g.me]
	m := net.Input{life = mine.life, view_tick = g.view.tick}
	if mine.active && !mine.dead {
		m.has_state = true
		m.soldier = mine^
	}
	for &s in g.shots {
		if m.shot_count == net.MAX_SHOTS_PER_INPUT do break
		m.shots[m.shot_count] = s
		m.shot_count += 1
		s.sends += 1
	}
	for len(g.shots) > 0 && g.shots[0].sends >= SHOT_REPEATS do ordered_remove(&g.shots, 0)
	connection.send_message(conn, m)

	for a in g.acts do connection.send_message(conn, a)
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
	if u8(slot) == g.me do return g.my_prev + (s.pos - g.my_prev) * alpha
	return view_drawn_pos(&g.view, &g.world, slot, alpha)
}
