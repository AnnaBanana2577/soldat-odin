package server

import "core:fmt"
import enet "vendor:ENet"
import "../shared/net"
import "../shared/sim"

// The one true world. Every tick: one command per client (the next it queued, or the
// last one again with its one-shot buttons dropped when none has arrived), the whole
// world stepped, the hits it produced applied, and a snapshot of it all to every
// client. The server decides everything; clients only send what they press.
Game :: struct {
	ctx:       sim.Context,
	level:     sim.Level,
	anims:     ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:     sim.World,
	events:    sim.Events,
	map_name:  string,
	clients:   [sim.MAX_PLAYERS]Client,
	history:   sim.History,   // the last second of soldiers, for judging shots as their shooters saw
	snapshot:  net.Snapshot,  // this tick's, filled once and sent to each client with its own ack
	writer:    net.Writer,
}

// A client's commands wait here in order until their tick comes. Steady play keeps a
// couple queued; the snapshot tells the client how many, and it runs its clock a
// little faster or slower to hold that.
Client :: struct {
	connected: bool,
	queue:     [dynamic]sim.Command, // by seq, all newer than ack
	last:      sim.Command,          // the command applied last tick
	ack:       u32,                  // the seq of `last`
	depth:     u8,                   // how many were waiting when this tick began
	view_tick: u32,                  // the tick the client shows the others at
}

MAX_QUEUE :: 30 // commands a client may have waiting; older ones beyond this are dropped

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
	g.world.history = &g.history
	sim.round_init(&g.world.round)
	sim.things_spawn(&g.ctx, &g.world)
}

// Every packet since the last tick: a hello joins, inputs queue their commands. Peers
// that left leave.
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
		if kind == .Input {
			if m, ok := net.decode_input(&r); ok do enqueue(&g.clients[p.slot], &m)
		}
	}
	for slot in host.left do leave(g, slot)
}

// The commands not seen yet, in order; a lost packet costs nothing because the next
// one carries them again.
enqueue :: proc(c: ^Client, m: ^net.Input) {
	c.view_tick = m.view_tick
	for cmd in m.commands[:m.count] {
		if cmd.seq <= c.ack do continue
		at := len(c.queue)
		for q, i in c.queue {
			if q.seq == cmd.seq do at = -1
			if q.seq > cmd.seq {
				at = i
				break
			}
		}
		if at == -1 do continue
		inject_at(&c.queue, at, cmd)
	}
	for len(c.queue) > MAX_QUEUE do ordered_remove(&c.queue, 0)
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
	g.clients[slot] = {connected = true}
	fmt.printfln("%s joined as slot %d on %v", m.name, slot, team)
	w: net.Writer
	net.encode_welcome(&w, {slot = slot, tick = g.world.tick, map_name = g.map_name})
	host_send(host, slot, net.writer_bytes(&w), reliable = true)
}

leave :: proc(g: ^Game, slot: u8) {
	g.world.soldiers[slot].active = false
	delete(g.clients[slot].queue)
	g.clients[slot] = {}
	fmt.printfln("slot %d left", slot)
}

// One tick of the world on this tick's commands, then the wounds the step reported.
// Each soldier carries how far behind the present its client shows the others, so
// the shots it fires this tick are judged against the soldiers of that moment.
tick :: proc(g: ^Game) {
	cmds: [sim.MAX_PLAYERS]sim.Command
	for &c, i in g.clients {
		if !c.connected do continue
		c.depth = u8(min(len(c.queue), 255))
		if len(c.queue) > 0 {
			c.last = c.queue[0]
			ordered_remove(&c.queue, 0)
			c.ack = c.last.seq
		} else {
			c.last.buttons -= sim.ONE_SHOT // a press counts once, however long the gap
		}
		cmds[i] = c.last
		behind := g.world.tick > c.view_tick ? g.world.tick - c.view_tick : 0
		g.world.soldiers[i].view_lag = u8(min(behind, sim.HISTORY_TICKS - 1))
	}
	sim.step(&g.ctx, &g.world, cmds[:], &g.events)
	sim.history_record(&g.history, &g.world)
	// the hits become wounds here and nowhere else; what they cause joins the events
	reported := g.events.count
	for i in 0 ..< reported {
		if hit, is_hit := g.events.items[i].(sim.Hit); is_hit do sim.damage_apply(&g.ctx, &g.world, hit, &g.events)
	}
}

// The world as it stands to every client, each with its own ack and queue depth.
send_snapshots :: proc(g: ^Game, host: ^Host) {
	snap := &g.snapshot
	snap.tick = g.world.tick
	snap.round = g.world.round
	snap.soldiers = g.world.soldiers
	snap.things = g.world.things
	snap.bullets = g.world.bullets
	snap.events = g.events
	for &c, i in g.clients {
		if !c.connected do continue
		snap.ack = c.ack
		snap.queue_depth = c.depth
		g.writer.len = 0
		g.writer.overflow = false
		net.encode_snapshot(&g.writer, snap)
		if g.writer.overflow {
			fmt.eprintln("snapshot too large to send")
			return
		}
		host_send(host, u8(i), net.writer_bytes(&g.writer), reliable = false)
	}
}
