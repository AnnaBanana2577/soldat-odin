package server

import "core:fmt"
import enet "vendor:ENet"
import "../shared/net"
import "../shared/sim"

// The game as the server sees it: every client's soldier as last sent, the things
// (the one piece of physics it owns), the clock, and a queue of claims to settle.
Game :: struct {
	ctx:    sim.Context,
	level:  sim.Level,
	anims:  ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:  sim.World,
	events: sim.Events,

	map_name: string,
	clients:  [sim.MAX_PLAYERS]Client,
	claims:   [dynamic]Pending_Claim, // in arrival order
	commits:  [dynamic]net.Commit,    // this tick's, to relay
	rejects:  [dynamic]Reject,
	next_commit: u32,
	things_sent: [sim.MAX_THINGS]sim.Thing, // as the clients last heard them
}

Client :: struct {
	connected:  bool,
	seq:        u32, // newest update applied
	state_tick: u32, // when it arrived: the age everyone else extrapolates from
	last_shot:  u32,
	last_claim: u32,
}

Pending_Claim :: struct {
	player: u8,
	claim:  net.Claim,
}

Reject :: struct {
	player: u8,
	claim:  net.Claim,
}

game_init :: proc(g: ^Game, base, map_name: string) {
	g.map_name = map_name
	if level, ok := sim.level_load_file(base, map_name); ok do g.level = level
	if anims, ok := sim.anims_load_files(base); ok do g.anims = anims
	if sk, ok := sim.skeletons_load_files(base); ok do g.skeletons = sk
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	sim.world_init(&g.world, 1)
	sim.round_init(&g.world.round)
	sim.things_spawn(&g.ctx, &g.world)
}

// Every packet since the last tick: a hello joins, updates replace the sender's
// soldier and spawn its shots, a throw drops its gun, claims queue for the referee.
// Peers that left leave.
receive_client_messages :: proc(g: ^Game, host: ^Host) {
	for p in host_receive(host) {
		r := net.reader_make(p.data)
		kind := net.Msg(net.read_u8(&r))
		if p.slot == NO_SLOT {
			if kind == .Hello {
				if m, ok := net.decode_hello(&r); ok do join(g, host, p.peer, m)
			}
			continue
		}
		c := &g.clients[p.slot]
		#partial switch kind {
		case .Update:
			if m, ok := net.decode_update(&r); ok do apply_update(g, p.slot, c, &m)
		case .Throw:
			// the gun as the thrower held it, from its soldier as relayed; the thing
			// reaches everyone with the things
			if m, ok := net.decode_throw(&r); ok && m.weapon != .None do throw_gun(g, p.slot, m)
		case .Claim:
			if m, ok := net.decode_claim(&r); ok && m.id > c.last_claim {
				c.last_claim = m.id
				append(&g.claims, Pending_Claim{p.slot, m})
			}
		}
	}
	for slot in host.left do leave(g, slot)
}

// A newcomer: a slot, a soldier on the smaller team's spawn, and the welcome.
join :: proc(g: ^Game, host: ^Host, peer: ^enet.Peer, m: net.Hello) {
	if m.version != net.VERSION {
		w: net.Writer
		net.encode_denied(&w, "wrong version")
		peer_send(peer, net.writer_bytes(&w), reliable = true)
		return
	}
	slot := host_assign(host, peer)
	if slot == NO_SLOT {
		w: net.Writer
		net.encode_denied(&w, "server full")
		peer_send(peer, net.writer_bytes(&w), reliable = true)
		return
	}
	alpha, bravo := 0, 0
	for &s in g.world.soldiers {
		if !s.active do continue
		if s.team == .Alpha do alpha += 1
		if s.team == .Bravo do bravo += 1
	}
	team := alpha <= bravo ? sim.Team.Alpha : sim.Team.Bravo
	pos := sim.level_spawn_point(g.ctx.level, team, &g.world.rng)
	sim.soldier_spawn(&g.ctx, &g.world.soldiers[slot], pos, team, .AK74, .Colt)
	g.world.humans += {int(slot)}
	g.clients[slot] = {connected = true, state_tick = g.world.tick}
	fmt.printfln("%s joined as slot %d on %v", m.name, slot, team)
	w: net.Writer
	net.encode_welcome(&w, {slot = slot, tick = g.world.tick, map_name = g.map_name})
	host_send(host, slot, net.writer_bytes(&w), reliable = true)
	// the things as they stand, once; from here on only their changes
	all: net.Things_Relay
	for &t, i in g.world.things {
		if t.style != .None do things_add(host, slot, &all, i, &t)
	}
	things_send(host, slot, &all)
}

leave :: proc(g: ^Game, slot: u8) {
	g.world.soldiers[slot].active = false
	g.world.humans -= {int(slot)}
	g.clients[slot] = {}
	fmt.printfln("slot %d left", slot)
}

apply_update :: proc(g: ^Game, slot: u8, c: ^Client, m: ^net.Update) {
	if m.seq <= c.seq do return // out of order: older than what we hold
	c.seq = m.seq
	s := &g.world.soldiers[slot]
	if m.has_state && s.active && !s.dead {
		copy_owned(s, &m.state)
		c.state_tick = g.world.tick
	}
	for i in 0 ..< m.shot_count {
		shot := m.shots[i]
		if shot.id <= c.last_shot do continue
		c.last_shot = shot.id
		// flown here for the things it knocks and relayed to everyone as it was fired;
		// it never touches soldiers here (the shooter reports its hits)
		sim.bullet_spawn(&g.ctx, &g.world, shot.pos, shot.vel, shot.weapon, slot, shot.damage, &g.events)
	}
}

throw_gun :: proc(g: ^Game, slot: u8, m: net.Throw) {
	s := &g.world.soldiers[slot]
	if !s.active || s.dead do return
	sim.dropped_gun_throw(&g.ctx, &g.world, slot, s, m.weapon, m.ammo, &g.events)
}

// The things are event driven: one goes out whole, to everyone, when it appears or
// goes, changes hands, or starts or stops moving. From those numbers every client
// runs the same physics until the next change; nothing is sent in between.
relay_things :: proc(g: ^Game, host: ^Host) {
	m: net.Things_Relay
	for &t, i in g.world.things {
		last := &g.things_sent[i]
		if t.style == last.style && t.holder == last.holder && t.static == last.static do continue
		things_add(host, EVERYONE, &m, i, &t)
		last^ = t
	}
	things_send(host, EVERYONE, &m)
}

EVERYONE :: NO_SLOT

// Things go in packets of a few; `to` is a slot, or EVERYONE.
things_add :: proc(host: ^Host, to: u8, m: ^net.Things_Relay, index: int, t: ^sim.Thing) {
	m.items[m.count] = {u8(index), t^}
	m.count += 1
	if m.count == net.MAX_THINGS_PER_PACKET do things_send(host, to, m)
}

things_send :: proc(host: ^Host, to: u8, m: ^net.Things_Relay) {
	if m.count == 0 do return
	w: net.Writer
	net.encode_things(&w, m)
	if to == EVERYONE do host_broadcast(host, net.writer_bytes(&w), reliable = true)
	else do host_send(host, to, net.writer_bytes(&w), reliable = true)
	m.count = 0
}

// The owned fields, and nothing else, over the server's copy.
copy_owned :: proc(dst, src: ^sim.Soldier) {
	dst.pos, dst.old_pos = src.pos, src.old_pos
	dst.vel, dst.forces = src.vel, src.forces
	dst.next_push = src.next_push
	dst.controls, dst.aim = src.controls, src.aim
	dst.direction, dst.on_ground, dst.jets = src.direction, src.on_ground, src.jets
	dst.legs, dst.body = src.legs, src.body
	dst.weapon, dst.secondary, dst.grenades = src.weapon, src.secondary, src.grenades
	dst.spawn_still, dst.para, dst.stat = src.spawn_still, src.para, src.stat
}

// Settles the claims in arrival order (first one wins), then the clock: respawns,
// timers, captures, the round. Every change goes out as a commit.
referee :: proc(g: ^Game) {
	for &pc in g.claims {
		if settle(g, pc.player, &pc.claim) {
			g.next_commit += 1
			c := pc.claim
			c.id = g.next_commit
			append(&g.commits, net.Commit{tick = g.world.tick, player = pc.player, claim = c})
		} else {
			append(&g.rejects, Reject{pc.player, pc.claim})
		}
	}
	clear(&g.claims)
	sim.round_tick(&g.ctx, &g.world, &g.events)
}

settle :: proc(g: ^Game, player: u8, c: ^net.Claim) -> bool {
	shooter := &g.world.soldiers[player]
	if !shooter.active || shooter.dead do return false
	switch c.kind {
	case .Hit:
		target := &g.world.soldiers[c.target]
		if !target.active || c.amount < 0 || c.amount > 1000 do return false
		// the amount and the knockback are the claimant's word, as its movement is
		hit := sim.Hit{shooter = player, target = c.target, weapon = c.weapon, amount = c.amount, part = c.part, pos = c.pos, push = c.vel}
		sim.damage_apply(&g.ctx, &g.world, hit, &g.events)
		return true
	case .Pickup:
		return sim.thing_grant(&g.ctx, &g.world, player, c.target, &g.events)
	}
	return false
}

step_things :: proc(g: ^Game) {
	sim.things_update(&g.ctx, &g.world, &g.events)
	sim.bullets_update(&g.ctx, &g.world, &g.events)
	g.world.tick += 1
}

// Everyone's soldier with its age, the commits and rejects, the shots, the things that
// changed, the clock.
relay :: proc(g: ^Game, host: ^Host) {
	for &s, i in g.world.soldiers {
		if !s.active do continue
		c := &g.clients[i]
		age := c.connected ? min(g.world.tick - c.state_tick, 255) : 0
		w: net.Writer
		net.encode_state(&w, &net.State{slot = u8(i), age = u8(age), soldier = s})
		host_broadcast(host, net.writer_bytes(&w), reliable = false)
	}
	for &m in g.commits {
		w: net.Writer
		net.encode_commit(&w, &m)
		host_broadcast(host, net.writer_bytes(&w), reliable = true)
	}
	clear(&g.commits)
	for &r in g.rejects {
		w: net.Writer
		net.encode_reject(&w, r.claim.id)
		host_send(host, r.player, net.writer_bytes(&w), reliable = true)
		// a refused pickup was predicted: the thing as it is, to undo that
		if r.claim.kind == .Pickup {
			m: net.Things_Relay
			things_add(host, r.player, &m, int(r.claim.target), &g.world.things[r.claim.target])
			things_send(host, r.player, &m)
		}
	}
	clear(&g.rejects)
	// the shots fired this tick, for the other clients' copies
	for e in sim.events_slice(&g.events) {
		if v, is_spawn := e.(sim.Bullet_Spawn); is_spawn {
			w: net.Writer
			net.encode_shot(&w, {player = v.player, shot = {weapon = v.weapon, pos = v.pos, vel = v.vel, damage = v.damage}})
			host_broadcast(host, net.writer_bytes(&w), reliable = false)
		}
	}
	relay_things(g, host)
	w: net.Writer
	net.encode_clock(&w, &net.Clock{tick = g.world.tick, round = g.world.round})
	host_broadcast(host, net.writer_bytes(&w), reliable = false)
	sim.events_clear(&g.events)
}
