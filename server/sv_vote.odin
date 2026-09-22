package server

import "core:fmt"
import "core:strings"
import "../shared/net"
import "../shared/sim"

// Votes, ported from Game.pas (StartVote, CountVote, StopVote, TimerVote): a player
// calls one to send someone away or to play another map, everyone hears what is being
// voted on and presses F12 to agree, and the vote passes as soon as enough of them
// have. Bots neither vote nor count, so a server full of them needs one player.
//
// One message does both jobs, as the original's votekick and votemap commands do: with
// no vote running it calls one, and with the same vote running it is that client's
// vote for it.

VOTE_TIME     :: 20 * sim.TICK_RATE      // DEFAULT_VOTING_TIME: how long one runs
VOTE_COOLDOWN :: 2 * 60 * sim.TICK_RATE  // DEFAULT_VOTE_TIME: before the caller may call another

Vote :: struct {
	active:   bool,
	kind:     net.Vote_Kind,
	target:   u8,       // the slot to send away
	name:     net.Name, // or the map to play
	starter:  u8,
	reason:   net.Line,
	ticks:    i32,
	voted:    [sim.MAX_PLAYERS]bool,
	votes:    int,
	most:     int, // players who could vote when it was called
	cooldown: [sim.MAX_PLAYERS]i32,
}

// A client calling a vote, or voting for the one running.
receive_vote :: proc(g: ^Game, host: ^Host, slot: u8, m: ^net.Vote) {
	v := &g.vote
	if v.active {
		if m.kind == v.kind && m.target == v.target && m.name == v.name do count_vote(g, host, slot)
		return
	}
	if v.cooldown[slot] > 0 {
		server_says(g, host, slot, fmt.tprintf("you may call another vote in %d seconds", v.cooldown[slot] / sim.TICK_RATE))
		return
	}
	switch m.kind {
	case .Kick:
		if m.target >= sim.MAX_PLAYERS || !g.wire.clients[m.target].connected || m.target == slot do return
	case .Map:
		if map_index(g, net.text_string(&m.name)) < 0 {
			server_says(g, host, slot, fmt.tprintf("no map here is called %s", net.text_string(&m.name)))
			return
		}
	}
	start_vote(g, host, slot, m.kind, m.target, m.name, m.reason)
	count_vote(g, host, slot) // the caller votes for it by calling it
}

// A vote begins: everyone hears what it is about, and how many of them must agree.
start_vote :: proc(g: ^Game, host: ^Host, starter: u8, kind: net.Vote_Kind, target: u8, name: net.Name, reason: net.Line) {
	v := &g.vote
	v^ = {
		active   = true,
		kind     = kind,
		target   = target,
		name     = name,
		starter  = starter,
		reason   = reason,
		ticks    = VOTE_TIME,
		most     = voters(g),
		cooldown = v.cooldown,
	}
	if starter < sim.MAX_PLAYERS do v.cooldown[starter] = VOTE_COOLDOWN
	about := kind == .Kick ? net.text_string(&g.wire.clients[target].name) : net.text_string(&v.name)
	server_says(g, host, EVERYONE, fmt.tprintf("%s called a vote to %s %s",
		net.text_string(&g.wire.clients[starter].name), kind == .Kick ? "kick" : "play", about))
	send_vote(g, host)
}

// One more for it. Enough of them and it passes at once, as the original does.
count_vote :: proc(g: ^Game, host: ^Host, slot: u8) {
	v := &g.vote
	if !v.active || v.voted[slot] do return
	v.voted[slot] = true
	v.votes += 1
	send_vote(g, host)
	if v.votes * 100 >= max(v.most, 1) * g.rules.vote_percent do pass_vote(g, host)
}

// It passed: the player goes, or the next round is on the map that was voted for.
pass_vote :: proc(g: ^Game, host: ^Host) {
	v := &g.vote
	switch v.kind {
	case .Kick:
		if v.target < sim.MAX_PLAYERS && g.wire.clients[v.target].connected {
			server_says(g, host, EVERYONE, fmt.tprintf("%s was voted out", net.text_string(&g.wire.clients[v.target].name)))
			kick(g, host, v.target)
		}
	case .Map:
		if at := map_index(g, net.text_string(&v.name)); at >= 0 {
			server_says(g, host, EVERYONE, fmt.tprintf("%s was voted in", net.text_string(&v.name)))
			g.map_index = at - 1 // next_round takes the one after this
			sim.match_end(&g.world, &g.events)
		}
	}
	stop_vote(g, host)
}

stop_vote :: proc(g: ^Game, host: ^Host) {
	v := &g.vote
	v^ = {cooldown = v.cooldown}
	send_vote(g, host)
}

// Once a tick: the cooldowns run down, and a vote nobody agreed to in time is dropped.
vote_tick :: proc(g: ^Game, host: ^Host) {
	v := &g.vote
	for &left in v.cooldown do if left > 0 do left -= 1
	if !v.active do return
	v.ticks -= 1
	if v.ticks <= 0 {
		server_says(g, host, EVERYONE, "the vote ran out")
		stop_vote(g, host)
	}
}

// Whoever is playing and could vote: the bots never do.
voters :: proc(g: ^Game) -> (count: int) {
	for &c in g.wire.clients do if c.connected && !c.bot do count += 1
	return
}

send_vote :: proc(g: ^Game, host: ^Host) {
	v := &g.vote
	g.wire.outgoing = net.Vote_State{
		kind = v.kind, active = v.active, target = v.target, name = v.name,
		starter = v.starter, reason = v.reason, ticks = v.ticks,
		votes = u8(min(v.votes, 255)), needed = u8(min(needed(g), 255)),
	}
	send_message(g, host, EVERYONE)
}

// How many must agree for it to pass (sv_votepercent of those who can vote).
needed :: proc(g: ^Game) -> int {
	want := (max(g.vote.most, 1) * g.rules.vote_percent + 99) / 100
	return max(want, 1)
}

// Shown the door: a bot is simply taken out, a player is disconnected and leaves the
// ordinary way when ENet says so.
kick :: proc(g: ^Game, host: ^Host, slot: u8) {
	if g.wire.clients[slot].bot {
		leave(g, host, slot)
		send_roster(g, host)
		return
	}
	host_kick(host, slot)
}

// The server's map list, by name: what the map window browses and a map vote names.
map_index :: proc(g: ^Game, name: string) -> int {
	for m, i in g.rules.maps do if strings.equal_fold(m, name) do return i
	return -1
}

// A client browsing the list for the map window.
receive_map_query :: proc(g: ^Game, host: ^Host, slot: u8, m: ^net.Map_Query) {
	count := len(g.rules.maps)
	if count == 0 do return
	at := int(m.index) % count
	g.wire.outgoing = net.Map_Name{index = u16(at), count = u16(count), name = net.name_make(g.rules.maps[at])}
	send_message(g, host, slot)
}
