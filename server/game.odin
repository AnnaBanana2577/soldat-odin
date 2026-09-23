package server

import "core:fmt"
import "core:time"
import enet "vendor:ENet"
import "../shared/net"
import "../shared/geom"
import "../shared/sim"

// The server's world is the one that decides (world.authority): it runs every soldier,
// on the commands its client sent (queue.odin) or on a bot's brain, and owns everything
// that follows. A client predicts its own soldier by replaying the commands the server
// has not run yet, so what it presses shows at once and what counts is still the
// server's. Its tick reads the way a client's does (client/game/game.odin):
//
//   next_round     once the last round's scores have stood long enough: the next map,
//                  its things, everyone placed anew
//   receive        what the clients pressed, into their queues, and what they chose
//   step_soldiers  every soldier on its commands: a bot on its brain's, a player on
//                  the ones its queue gives for this tick
//   step_world     the things, every bullet against the soldiers as its shooter saw
//                  them, the round; the hits become wounds here and nowhere else
//   send           the things that changed, what was decided, and every other tick
//                  the soldiers and the bullets born
//
// Time. A client shows the others a little in the past, and says with every packet
// which server tick that is. The difference from the tick its packet arrives in is its
// lag. A bullet keeps its shooter's lag and meets the soldiers as they were that long
// ago, all the way (sim/history.odin), so a shot lands where its shooter aimed it. The
// other clients fly that bullet on by its shooter's lag plus their own (client/game),
// so the bullet each of them sees is the one that will be ruled on.
Game :: struct {
	ctx:        sim.Context,
	level:      sim.Level,
	anims:      ^sim.Anims,
	skeletons:  ^sim.Skeletons,
	world:      sim.World,
	history:    sim.History, // the last second of soldiers, for judging shots as their shooters saw
	max_rewind: u32,         // ticks: how far back a shot is judged at most; a slower shooter leads
	base:       string,      // where the maps are
	rules:      Rules,
	map_index:  int,         // of the one being played, in rules.maps
	events:     sim.Events,  // this tick's
	map_name:   string,
	clients:    [sim.MAX_PLAYERS]Client,
	bots:       sim.Bots,           // the brains of the slots the server plays itself
	profiles:   []sim.Bot_Profile, // the personality files they are drawn from
	vote:       Vote,              // what is being voted on, if anything (vote.odin)
	born:       [dynamic]Born,            // the bullets born lately, each told a few updates running
	ends:       [dynamic]Ended,           // and where the clients' own ended, told back to them
	shot_seq:   [sim.MAX_PLAYERS]u32,     // the last number given to each shooter's bullets
	things_sent: [sim.MAX_THINGS]sim.Thing, // as the clients last heard them

	incoming, outgoing: net.Message, // scratch: an Update is too large for the stack
	buf: [net.MAX_PACKET]u8,
}

// What the server was started with.
Rules :: struct {
	maps:          []string, // played in turn, a round each
	time_limit:    i32,      // ticks a round lasts at most
	score_limit:   i32,      // captures that win a round
	respawn_time:  i32,      // ticks a soldier waits to be placed again
	max_grenades:  i32,
	friendly_fire: bool,
	kits_collide:  bool,
	max_rewind:    u32,      // ticks: how far back a shot is judged at most
	update_others: u32,      // ticks between words of the soldiers that are not the receiver's
	bots_difficulty: int,    // 300 stupid, 100 normal, 10 impossible
	bots_chat:     bool,     // the bots say what their files give them to say
	vote_percent:  int,      // of the players who can vote, how many must agree for one to pass
}

Client :: struct {
	connected:  bool,
	name:       net.Name,
	last_chat:  u32, // the tick it last said something
	bot:        bool, // played by the server itself (sim/bot.odin): no peer, nothing received or sent
	queue:      Queue, // what it pressed, and what of that the sim has yet to run
	lag:        f32,   // how late it sees the world, in ticks, smoothed: told back to it
	// for the leave line: the hits it gave and took as ruled here, which its own summary
	// has as it saw them; `judged` sums how far back its shots were ruled
	shots, hits_given, hits_taken, judged: int,
}

// Where a client's own bullet ended, kept while it is being told to that client.
Ended :: struct {
	owner: u8,
	end:   net.End,
	tick:  u32,
}

// The birth of a bullet, kept while it is being told.
Born :: struct {
	fired:      net.Fired,
	tick:       u32,
	to_shooter: bool, // the server's own making (a bot's, the map's): its soldier's client has not seen it
}


OFFSCREEN_EVERY :: 15 // updates between words of a soldier out of the receiver's view: twice a second
BORN_TOLD       :: 6  // ticks a bullet's birth keeps being told: three updates, so a lost one loses no bullet
VIEW_HALF       :: sim.Vec2{900, 700} // of a client's view; generous: the camera leads toward the cursor
SHOT_REACH      :: 1200.0 // a bullet whose line of flight passes this near a client is told to it
LAG_SMOOTHING   :: 0.1 // share of each new measure in the lag a client is told
CHAT_EVERY      :: 30  // ticks a client must wait between two lines: half a second

// The first map, and the data every map shares. False when the first map will not load.
game_init :: proc(g: ^Game, base: string, rules: Rules) -> bool {
	g.base, g.rules = base, rules
	g.max_rewind = min(rules.max_rewind, sim.HISTORY_TICKS - 1)
	if anims, ok := sim.anims_load_files(base); ok do g.anims = anims
	if sk, ok := sim.skeletons_load_files(base); ok do g.skeletons = sk
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	g.profiles = sim.bot_profiles_load(base)
	sim.world_init(&g.world, 1)
	g.world.authority = true
	g.world.history = &g.history
	if !map_load(g, rules.maps[0]) do return false
	round_start(g)
	return true
}

// ---- the rounds ----

// The next map of the rotation, or the same one again when it is the only one or the
// next will not load; its things; everyone placed anew with a nil tally. Everyone
// hears of the map first, and then, in that order on the same channel, of the things
// and the placings, which go out with this tick's news.
next_round :: proc(g: ^Game, host: ^Host) {
	g.map_index = (g.map_index + 1) % len(g.rules.maps)
	if !map_load(g, g.rules.maps[g.map_index]) do fmt.eprintfln("could not load %s; %s again", g.rules.maps[g.map_index], g.map_name)
	round_start(g)
	g.outgoing = map_message(g)
	send_message(g, host, EVERYONE)
	for &s, i in g.world.soldiers {
		if !s.active do continue
		s.kills, s.deaths, s.flags, s.dead = 0, 0, 0, false
		sim.soldier_respawn(&g.ctx, &g.world, u8(i), &g.events)
	}
	fmt.printfln("a round on %s", g.map_name)
}

map_load :: proc(g: ^Game, name: string) -> bool {
	level, ok := sim.level_load_file(g.base, name)
	if !ok do return false
	if g.map_name != "" do sim.level_destroy(&g.level)
	g.level, g.map_name = level, name
	return true
}

// A round on the loaded map: no bullets and no corpses, its things placed, the scores
// nil, the limits the server was given.
round_start :: proc(g: ^Game) {
	w := &g.world
	w.bullets, w.ragdolls = {}, {}
	g.history.count = 0 // what the soldiers did on the last map is no target
	sim.round_init(&w.round)
	if g.rules.time_limit > 0 do w.round.time_left = g.rules.time_limit
	if g.rules.score_limit > 0 do w.round.score_limit = g.rules.score_limit
	if g.rules.respawn_time > 0 do w.round.respawn_time = g.rules.respawn_time
	w.round.max_grenades = g.rules.max_grenades
	w.round.friendly_fire = g.rules.friendly_fire
	w.round.kits_collide = g.rules.kits_collide
	sim.things_spawn(&g.ctx, w)
	g.things_sent = {} // the clients drop theirs on hearing of the map: every thing goes again
	clear(&g.born)
}

map_message :: proc(g: ^Game) -> net.Message {
	return net.Map{name = g.map_name, flag_home = g.world.flag_home, tick = g.world.tick}
}

tick :: proc(g: ^Game, host: ^Host) {
	if sim.round_over(&g.world.round) do next_round(g, host)
	step_soldiers(g)
	receive(g, host)
	step_world(g)
	vote_tick(g, host)
	sim.history_record(&g.history, &g.world) // under this tick, as the update of this tick tells them
	bot_chat(g, host)
	send(g, host)
	sim.events_clear(&g.events)
	g.world.tick += 1
}

// ---- the soldiers ----

// Every soldier on this tick's commands: a bot on its brain's, a player on what its
// queue gives (usually one, several after a stall, none at all while its commands are
// in flight). What a step causes counts here, and a bullet it makes is told to everyone
// but its owner, whose client fired it already.
step_soldiers :: proc(g: ^Game) {
	w := &g.world
	buf: [MAX_CATCH_UP]sim.Command
	for &c, i in g.clients {
		if !c.connected do continue
		slot := u8(i)
		before := g.events.count
		if c.bot {
			sim.soldier_step(&g.ctx, w, slot, sim.bot_command(&g.bots, &g.ctx, w, slot), &g.events)
		} else {
			for cmd in queue_take(&c.queue, buf[:]) do sim.soldier_step(&g.ctx, w, slot, cmd, &g.events)
		}
		// its own client fired these already; everyone else hears of them
		for k in before ..< g.events.count {
			#partial switch v in g.events.items[k] {
			case sim.Bullet_Spawn:
				tell_born(g, int(v.id), to_shooter = false)
			case sim.Fire:
				c.shots += 1
				c.judged += int(w.soldiers[slot].view_lag)
			}
		}
	}
}

// ---- receiving ----

// Every packet since the last tick, in the order it came. Peers that left leave.
receive :: proc(g: ^Game, host: ^Host) {
	for p in host_receive(host) {
		if !net.decode(p.data, &g.incoming) do continue
		if p.slot == NO_SLOT {
			if m, is_hello := g.incoming.(net.Hello); is_hello do join(g, host, p.peer, m)
			continue
		}
		#partial switch &m in g.incoming {
		case net.Input: receive_input(g, p.slot, &m)
		case net.Act:   receive_act(g, host, p.slot, m)
		case net.Chat:  receive_chat(g, host, p.slot, &m)
		case net.Vote:  receive_vote(g, host, p.slot, &m)
		case net.Map_Query: receive_map_query(g, host, p.slot, &m)
		}
	}
	for slot in host.left do leave(g, host, slot)
}

// A client's commands into its queue, and how late it sees the world: the difference
// between the tick it says it is showing the others at and the tick its packet lands in.
// What it fires is judged that far back (sim/history.odin).
receive_input :: proc(g: ^Game, slot: u8, m: ^net.Input) {
	c := &g.clients[slot]
	tick := g.world.tick
	behind := tick > m.view_tick ? tick - m.view_tick : 0
	c.lag += (f32(behind) - c.lag) * LAG_SMOOTHING
	g.world.soldiers[slot].view_lag = u8(min(behind, g.max_rewind))
	queue_push(&c.queue, m.cmds[:m.count])
}


// A move to the other team, unless it would leave that team with more players than
// this one (Soldat's team balance): the flag let go of, a new life on the new team's
// spawn, and everyone told.
join_team :: proc(g: ^Game, host: ^Host, slot: u8, team: sim.Team) {
	s := &g.world.soldiers[slot]
	if (team != .Alpha && team != .Bravo) || team == s.team do return
	count: [sim.Team]int
	for &o in g.world.soldiers do if o.active do count[o.team] += 1
	if count[team] >= count[s.team] {
		server_says(g, host, slot, fmt.tprintf("%v team is full", team))
		return
	}
	sim.flag_let_go(&g.world, slot)
	s.team, s.dead = team, false
	sim.soldier_respawn(&g.ctx, &g.world, slot, &g.events)
	server_says(g, host, EVERYONE, fmt.tprintf("%s has joined %v team", net.text_string(&g.clients[slot].name), team))
}

// A line from a client, to everyone or to its team, half a second at least after its
// last. Who said it is the server's to say.
receive_chat :: proc(g: ^Game, host: ^Host, slot: u8, m: ^net.Chat) {
	c := &g.clients[slot]
	if m.text.len == 0 || (c.last_chat != 0 && g.world.tick - c.last_chat < CHAT_EVERY) do return
	c.last_chat = g.world.tick
	m.slot = slot
	fmt.printfln("%s[%s] %s", m.team ? "(TEAM) " : "", net.text_string(&c.name), net.text_string(&m.text))
	g.outgoing = m^
	if !m.team {
		send_message(g, host, EVERYONE)
		return
	}
	team := g.world.soldiers[slot].team
	for &o, i in g.clients {
		if o.connected && !o.bot && g.world.soldiers[i].team == team do send_message(g, host, u8(i))
	}
}

// A line from the server itself, to one client or to EVERYONE.
server_says :: proc(g: ^Game, host: ^Host, to: u8, line: string) {
	chat := net.Chat{slot = SERVER_SLOT}
	net.text_set(&chat.text, line)
	g.outgoing = chat
	send_message(g, host, to)
}

SERVER_SLOT :: 255


// What a client did that only the server can make happen.
receive_act :: proc(g: ^Game, host: ^Host, slot: u8, m: net.Act) {
	s := &g.world.soldiers[slot]
	if !s.active do return
	if s.dead && m.action != .Loadout && m.action != .Join_Team do return // the dead only choose
	switch m.action {
	case .Join_Team:
		join_team(g, host, slot, m.team)
	case .Loadout:
		if m.weapon in sim.PRIMARY_WEAPONS && m.second in sim.SECONDARY_WEAPONS {
			s.primary_choice, s.secondary_choice = m.weapon, m.second
			// and into its hands at once in a life it has not moved in yet, which is
			// what its client has already done with it: a soldier's weapons are its
			// own client's to say for as long as the menu is still up
			if !s.dead && s.spawn_still do sim.soldier_arm(&g.ctx, s, m.weapon, m.second)
		}
	}
}

// A bullet just born here, for the clients to hear of: numbered for its shooter, with
// the lag it is judged by.
tell_born :: proc(g: ^Game, index: int, to_shooter: bool) {
	b := &g.world.bullets[index]
	g.shot_seq[b.owner] += 1
	fired := net.Fired{shooter = b.owner, seq = g.shot_seq[b.owner], lag = b.lag, weapon = b.weapon, pos = b.pos, vel = b.vel}
	append(&g.born, Born{fired = fired, tick = g.world.tick, to_shooter = to_shooter})
}

// ---- joining and leaving ----

// A newcomer: a slot, the welcome, the map, the things as they stand, and a soldier on
// the smaller team, whose placing goes out with this tick's facts like any respawn.
join :: proc(g: ^Game, host: ^Host, peer: ^enet.Peer, m: net.Hello) {
	slot := m.version == net.VERSION ? free_slot(g) : NO_SLOT
	if slot == NO_SLOT {
		g.outgoing = net.Denied{reason = m.version != net.VERSION ? "wrong version" : "server full"}
		if size, ok := net.encode(g.buf[:], &g.outgoing); ok do peer_send(peer, g.buf[:size], reliable = true)
		return
	}
	host_bind(host, slot, peer)
	g.clients[slot] = {connected = true, name = net.name_make(m.name)}
	bot_friends(g) // one of them may have named this player as its friend
	g.outgoing = net.Welcome{slot = slot}
	send_message(g, host, slot)
	g.outgoing = map_message(g)
	send_message(g, host, slot)
	things: net.Things
	for &t, i in g.world.things {
		if t.style != .None do things_add(g, host, slot, &things, i, &t)
	}
	things_flush(g, host, slot, &things)
	send_roster(g, host)
	team := spawn_newcomer(g, slot)
	fmt.printfln("%s joined as slot %d on %v", m.name, slot, team)
	server_says(g, host, EVERYONE, fmt.tprintf("%s has joined %v team", m.name, team))
}

// A bot, in the first free slot, on the smaller team: a personality file at random
// that nobody here is playing already, and a brain to go with it.
add_bot :: proc(g: ^Game) {
	slot := free_slot(g)
	if slot == NO_SLOT do return
	seed := u64(time.now()._nsec)
	prof: sim.Bot_Profile
	for _ in 0 ..< 16 {
		prof = sim.bot_profile_any(g.profiles, &seed)
		if !name_taken(g, prof.name) do break
	}
	sim.bot_init(&g.bots[slot], prof, seed, g.rules.bots_difficulty, g.rules.bots_chat)
	g.clients[slot] = {connected = true, bot = true, name = net.name_make(prof.name)}
	bot_friends(g)
	team := spawn_newcomer(g, slot)
	fmt.printfln("%s joined as slot %d on %v", prof.name, slot, team)
}

name_taken :: proc(g: ^Game, name: string) -> bool {
	for &c in g.clients do if c.connected && net.text_string(&c.name) == name do return true
	return false
}

// The friend each bot's file names, as a slot: it will not shoot at them. Worked out
// whenever the roster changes, since a name is all the file has.
bot_friends :: proc(g: ^Game) {
	for &b, i in g.bots {
		if !b.playing do continue
		b.friend = sim.NOBODY
		if b.prof.friend == "" do continue
		for &c, k in g.clients {
			if c.connected && k != i && net.text_string(&c.name) == b.prof.friend do b.friend = u8(k)
		}
	}
}

// What the bots want to say, once a tick: their own lines, and the taunt that names
// whoever they are shooting at.
bot_chat :: proc(g: ^Game, host: ^Host) {
	for &b, i in g.bots {
		if !b.playing do continue
		line := b.says
		if b.taunts != sim.NOBODY {
			if b.taunts < sim.MAX_PLAYERS && g.clients[b.taunts].connected {
				line = fmt.tprintf("Die %s!", net.text_string(&g.clients[b.taunts].name))
			}
			b.taunts = sim.NOBODY
		}
		b.says = ""
		c := &g.clients[i]
		if line == "" || (c.last_chat != 0 && g.world.tick - c.last_chat < CHAT_EVERY) do continue
		c.last_chat = g.world.tick
		chat := net.Chat{slot = u8(i)}
		net.text_set(&chat.text, line)
		fmt.printfln("[%s] %s", net.text_string(&c.name), line)
		g.outgoing = chat
		send_message(g, host, EVERYONE)
	}
}

// Who plays in which slot, to everyone, whenever someone joins. It is small.
send_roster :: proc(g: ^Game, host: ^Host) {
	roster: net.Roster
	for &c, i in g.clients {
		if !c.connected do continue
		roster.slots[roster.count] = u8(i)
		roster.names[roster.count] = c.name
		if c.bot do roster.bots |= 1 << u32(i)
		roster.count += 1
	}
	g.outgoing = roster
	send_message(g, host, EVERYONE)
}

// The first slot nobody plays, or NO_SLOT when the server is full.
free_slot :: proc(g: ^Game) -> u8 {
	for &c, i in g.clients do if !c.connected do return u8(i)
	return NO_SLOT
}

// A soldier for a newcomer, placed on the smaller team's spawn: its first life.
spawn_newcomer :: proc(g: ^Game, slot: u8) -> sim.Team {
	alpha, bravo := 0, 0
	for &s in g.world.soldiers {
		if !s.active do continue
		if s.team == .Alpha do alpha += 1
		if s.team == .Bravo do bravo += 1
	}
	team := alpha <= bravo ? sim.Team.Alpha : sim.Team.Bravo
	g.world.soldiers[slot] = {team = team, primary_choice = .AK74, secondary_choice = .Colt}
	sim.soldier_respawn(&g.ctx, &g.world, slot, &g.events)
	return team
}

leave :: proc(g: ^Game, host: ^Host, slot: u8) {
	c := &g.clients[slot]
	server_says(g, host, EVERYONE, fmt.tprintf("%s has left the game", net.text_string(&c.name)))
	fmt.printfln("slot %d left: %d shots, %d hits given and %d taken as ruled here, judged %.0f ms back on average",
		slot, c.shots, c.hits_given, c.hits_taken, f64(c.judged) / f64(max(c.shots, 1)) * 1000 / sim.TICK_RATE)
	g.world.soldiers[slot].active = false
	g.bots[slot] = {}
	if g.vote.active && g.vote.kind == .Kick && g.vote.target == slot do stop_vote(g, host) // it left of its own accord
	c^ = {}
	bot_friends(g)
}

// ---- the world ----

// The corpses, the things, the bullets and the round, and then the hits become wounds,
// here and nowhere else. What the wounds cause (a death, a dropped gun) joins the
// events. The corpses are stepped here as well as on every client, from the same word,
// so that a bullet meets a body on the server as it does on the screen that fired it.
step_world :: proc(g: ^Game) {
	w := &g.world
	sim.ragdolls_update(&g.ctx, w, &g.events)
	sim.things_update(&g.ctx, w, &g.events)
	sim.bullets_update(&g.ctx, w, &g.events)
	sim.round_tick(&g.ctx, w, &g.events)
	reported := g.events.count
	for i in 0 ..< reported {
		if hit, is_hit := g.events.items[i].(sim.Hit); is_hit do sim.damage_apply(&g.ctx, w, hit, &g.events)
	}
	for e in sim.events_slice(&g.events) {
		if v, gone := e.(sim.Bullet_End); gone && g.clients[v.owner].connected && !g.clients[v.owner].bot {
			append(&g.ends, Ended{owner = v.owner, end = {shot = v.shot, pos = v.pos, impact = v.impact}, tick = g.world.tick})
		}
		sim.bot_event(&g.bots, w, e)
		if v, wounded := e.(sim.Damage); wounded && v.attacker != v.target {
			g.clients[v.attacker].hits_given += 1
			g.clients[v.target].hits_taken += 1
		}
	}
}

// ---- sending ----

send :: proc(g: ^Game, host: ^Host) {
	send_things(g, host)
	send_facts(g, host)
	send_updates(g, host)
	for len(g.born) > 0 && g.world.tick - g.born[0].tick >= BORN_TOLD do ordered_remove(&g.born, 0)
	for len(g.ends) > 0 && g.world.tick - g.ends[0].tick >= BORN_TOLD do ordered_remove(&g.ends, 0)
	host_flush(host)
}

// A thing goes out whole, to everyone, when it appears or goes, changes hands, or
// starts or stops moving. From those numbers every client runs the same physics
// until the next change.
send_things :: proc(g: ^Game, host: ^Host) {
	things: net.Things
	for &t, i in g.world.things {
		last := &g.things_sent[i]
		if t.style == last.style && t.holder == last.holder && t.static == last.static do continue
		things_add(g, host, EVERYONE, &things, i, &t)
		last^ = t
	}
	things_flush(g, host, EVERYONE, &things)
}

things_add :: proc(g: ^Game, host: ^Host, to: u8, m: ^net.Things, index: int, t: ^sim.Thing) {
	m.indices[m.count] = u8(index)
	m.things[m.count] = t^
	m.count += 1
	if m.count == net.MAX_THINGS_PER_MSG do things_flush(g, host, to, m)
}

things_flush :: proc(g: ^Game, host: ^Host, to: u8, m: ^net.Things) {
	if m.count == 0 do return
	g.outgoing = m^
	send_message(g, host, to)
	m.count = 0
}

// What only the server could decide this tick: deaths, respawns, pickups, scores.
send_facts :: proc(g: ^Game, host: ^Host) {
	facts: net.Facts
	for e in sim.events_slice(&g.events) {
		if net.fact_kind(e) == .None do continue
		facts.events[facts.count] = e
		facts.count += 1
		if facts.count == net.MAX_FACTS_PER_MSG {
			g.outgoing = facts
			send_message(g, host, EVERYONE)
			facts.count = 0
		}
	}
	if facts.count > 0 {
		g.outgoing = facts
		send_message(g, host, EVERYONE)
	}
}

// To each client, the world as it stands: which slots are in play, its own soldier
// whole and every tick (what it replays its unrun commands over), the others in its
// view every second tick, those out of view now and then, and the bullets born lately
// that could come into its view.
send_updates :: proc(g: ^Game, host: ^Host) {
	w := &g.world
	active: u32
	lags: [sim.MAX_PLAYERS]u8
	for &s, i in w.soldiers {
		if !s.active do continue
		active |= 1 << u32(i)
		lags[i] = u8(min(g.clients[i].lag + 0.5, 255))
	}
	every := g.rules.update_others // a client hears of its own every tick: what it replays from
	turn := w.tick / every
	others := w.tick % every == 0
	for &c, ri in g.clients {
		if !c.connected || c.bot do continue
		me := &w.soldiers[ri]
		watching := me.active && !me.dead // from somewhere: a client without a soldier sees it all
		g.outgoing = net.Update{tick = w.tick, ack = c.queue.last_seq, depth = c.queue.depth, round = w.round, active = active, lags = lags}
		m := &g.outgoing.(net.Update)
		for &s, i in w.soldiers {
			if !s.active do continue
			mine := i == ri
			if !mine && !others do continue
			seen := mine || !watching || in_view(me.pos, s.pos)
			if !seen && (turn + u32(i)) % OFFSCREEN_EVERY != 0 do continue
			m.entries[m.entry_count] = {slot = u8(i), has_owned = !s.dead, has_rest = mine, soldier = s}
			m.entry_count += 1
		}
		for &b in g.born {
			if m.fired_count == net.MAX_SHOTS_PER_UPDATE do break
			if int(b.fired.shooter) == ri && !b.to_shooter do continue
			if watching && !could_reach(me.pos, b.fired.pos, b.fired.vel) do continue
			m.fired[m.fired_count] = b.fired
			m.fired[m.fired_count].age = u8(w.tick - b.tick)
			m.fired_count += 1
		}
		for &e in g.ends {
			if int(e.owner) != ri || m.end_count == net.MAX_ENDS_PER_UPDATE do continue
			m.ends[m.end_count] = e.end
			m.end_count += 1
		}
		send_message(g, host, u8(ri))
	}
}

in_view :: proc(eye, point: sim.Vec2) -> bool {
	d := point - eye
	return abs(d.x) <= VIEW_HALF.x && abs(d.y) <= VIEW_HALF.y
}

// Could a bullet born at `pos` flying along `vel` come into the view around `eye`:
// does its line of flight pass near?
could_reach :: proc(eye, pos, vel: sim.Vec2) -> bool {
	dir := geom.vec2_normalize(vel)
	along := max(geom.vec2_dot(eye - pos, dir), 0)
	return geom.vec2_length(eye - (pos + dir * along)) <= SHOT_REACH
}

EVERYONE :: NO_SLOT

// g.outgoing, on the delivery its kind has, to a slot or to EVERYONE.
send_message :: proc(g: ^Game, host: ^Host, to: u8) {
	size, ok := net.encode(g.buf[:], &g.outgoing)
	if !ok {
		fmt.eprintln("a message did not fit its packet:", net.message_kind(&g.outgoing))
		return
	}
	reliable := net.RELIABLE[net.message_kind(&g.outgoing)]
	if to == EVERYONE do host_broadcast(host, g.buf[:size], reliable)
	else do host_send(host, to, g.buf[:size], reliable)
}
