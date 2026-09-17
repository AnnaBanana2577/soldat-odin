// Package net is the wire protocol. Transport is ENet (vendor:ENet); this package only
// encodes and decodes messages.
//
// The server is authoritative: clients send Inputs (their commands, numbered by
// themselves), the server runs the one true world and sends every client a Snapshot
// of it every SNAPSHOT_EVERY ticks: the soldiers, things and bullets whole, the
// events since the last one, and for the receiver its last applied command and how
// many were waiting. A client predicts itself by replaying its unacknowledged
// commands on the latest snapshot and shows everyone else interpolated between two
// older ones.
//
// A snapshot goes as a delta against the newest one the client says it holds: only
// the entities that changed, and of those only the 4-byte words that changed, under
// a mask. A client that holds nothing useful gets it whole. The state goes as the
// sim's structs, byte for byte, so the same build must run on both ends; the hello
// carries the build's layout so a mismatch is refused rather than misread.
package net

import "../sim"

VERSION      :: 3
DEFAULT_PORT :: 23073

SNAPSHOT_EVERY :: 2 // ticks between snapshots: 30 a second at 60 ticks

CHANNEL_UNRELIABLE :: 0 // inputs, snapshots
CHANNEL_RELIABLE   :: 1 // the handshake, the lobby
CHANNEL_COUNT      :: 2

// The layout the state crosses the wire in, checked at the hello.
LAYOUT :: u32(size_of(sim.Soldier)) << 16 | u32(size_of(sim.Thing)) << 8 | u32(size_of(sim.Bullet))

Msg :: enum u8 {
	None,
	// the lobby, reliable
	Hello, Welcome, Denied, Roster, Chat, Leave, Map_Change, Settings,
	// the game, unreliable
	Input,    // client -> server: my recent commands
	Snapshot, // server -> client: the world as of one tick
}

// ---- the handshake (reliable) ----

MAX_NAME :: 24

Hello :: struct {
	version: u16,
	layout:  u32,
	name:    string,
}

Welcome :: struct {
	slot:     u8,
	tick:     u32,
	map_name: string,
}

encode_hello :: proc(w: ^Writer, name: string) {
	write_u8(w, u8(Msg.Hello))
	write_u16(w, VERSION)
	write_u32(w, LAYOUT)
	write_string(w, name[:min(len(name), MAX_NAME)])
}

decode_hello :: proc(r: ^Reader) -> (m: Hello, ok: bool) {
	m.version = read_u16(r)
	m.layout = read_u32(r)
	m.name = read_string(r)
	return m, r.ok
}

encode_welcome :: proc(w: ^Writer, m: Welcome) {
	write_u8(w, u8(Msg.Welcome))
	write_u8(w, m.slot)
	write_u32(w, m.tick)
	write_string(w, m.map_name)
}

decode_welcome :: proc(r: ^Reader) -> (m: Welcome, ok: bool) {
	m.slot = read_u8(r)
	m.tick = read_u32(r)
	m.map_name = read_string(r)
	return m, r.ok
}

encode_denied :: proc(w: ^Writer, reason: string) {
	write_u8(w, u8(Msg.Denied))
	write_string(w, reason)
}

// ---- inputs (client -> server, unreliable, every tick) ----

// The last few commands, oldest first, so a lost packet loses nothing: the server
// keeps the ones it has not seen. `view_tick` is the server tick the client is
// showing the others at, for the server to judge its shots against; `have` the
// newest snapshot it holds, for the server to send the next as a delta against.
MAX_COMMANDS_PER_INPUT :: 8

Input :: struct {
	view_tick: u32,
	have:      u32,
	commands:  [MAX_COMMANDS_PER_INPUT]sim.Command,
	count:     int,
}

encode_input :: proc(w: ^Writer, m: ^Input) {
	write_u8(w, u8(Msg.Input))
	write_u32(w, m.view_tick)
	write_u32(w, m.have)
	write_u8(w, u8(m.count))
	for i in 0 ..< m.count do write_raw(w, &m.commands[i], size_of(sim.Command))
}

decode_input :: proc(r: ^Reader) -> (m: Input, ok: bool) {
	m.view_tick = read_u32(r)
	m.have = read_u32(r)
	m.count = min(int(read_u8(r)), MAX_COMMANDS_PER_INPUT)
	for i in 0 ..< m.count do read_raw(r, &m.commands[i], size_of(sim.Command))
	return m, r.ok
}

// ---- snapshots (server -> client, unreliable) ----

// The world as of `tick`: every active soldier, thing and bullet whole, the round, and
// what happened since the last snapshot. `ack` is the receiver's last command the
// server applied; `queue_depth` how many of its commands were waiting when the tick
// began, which the client steers toward a small target by running its clock faster
// or slower. `base` is the tick this one was sent as a delta against, 0 for whole.
Snapshot :: struct {
	tick:        u32,
	base:        u32,
	ack:         u32,
	queue_depth: u8,
	round:       sim.Round,
	soldiers:    [sim.MAX_PLAYERS]sim.Soldier,
	things:      [sim.MAX_THINGS]sim.Thing,
	bullets:     [sim.MAX_BULLETS]sim.Bullet,
	events:      sim.Events,
}

// Against `base` when there is one: an entity present in both goes as its changed
// words, one new to this snapshot whole, one gone from it by index; the rest are not
// mentioned and the receiver keeps its copy. Without a base everything goes whole.
encode_snapshot :: proc(w: ^Writer, m: ^Snapshot, base: ^Snapshot) {
	write_u8(w, u8(Msg.Snapshot))
	write_u32(w, m.tick)
	write_u32(w, base != nil ? base.tick : 0)
	write_u32(w, m.ack)
	write_u8(w, m.queue_depth)
	if base == nil do write_raw(w, &m.round, size_of(sim.Round))
	else do write_words(w, &m.round, &base.round, size_of(sim.Round))

	// the soldiers
	changed, gone: [sim.MAX_PLAYERS]u8
	n, g := 0, 0
	for &s, i in m.soldiers {
		had := base != nil && base.soldiers[i].active
		if s.active && (!had || differs(&s, &base.soldiers[i], size_of(sim.Soldier))) { changed[n] = u8(i); n += 1 }
		if !s.active && had { gone[g] = u8(i); g += 1 }
	}
	write_u8(w, u8(n))
	for i in changed[:n] {
		write_u8(w, i)
		if base != nil && base.soldiers[i].active do write_words(w, &m.soldiers[i], &base.soldiers[i], size_of(sim.Soldier))
		else do write_raw(w, &m.soldiers[i], size_of(sim.Soldier))
	}
	write_u8(w, u8(g))
	for i in gone[:g] do write_u8(w, i)

	// the things
	tchanged, tgone: [sim.MAX_THINGS]u8
	n, g = 0, 0
	for &t, i in m.things {
		had := base != nil && base.things[i].style != .None
		if t.style != .None && (!had || differs(&t, &base.things[i], size_of(sim.Thing))) { tchanged[n] = u8(i); n += 1 }
		if t.style == .None && had { tgone[g] = u8(i); g += 1 }
	}
	write_u8(w, u8(n))
	for i in tchanged[:n] {
		write_u8(w, i)
		if base != nil && base.things[i].style != .None do write_words(w, &m.things[i], &base.things[i], size_of(sim.Thing))
		else do write_raw(w, &m.things[i], size_of(sim.Thing))
	}
	write_u8(w, u8(g))
	for i in tgone[:g] do write_u8(w, i)

	// the bullets
	bchanged, bgone: [sim.MAX_BULLETS]u16
	n, g = 0, 0
	for &b, i in m.bullets {
		had := base != nil && base.bullets[i].active
		if b.active && (!had || differs(&b, &base.bullets[i], size_of(sim.Bullet))) { bchanged[n] = u16(i); n += 1 }
		if !b.active && had { bgone[g] = u16(i); g += 1 }
	}
	write_u16(w, u16(n))
	for i in bchanged[:n] {
		write_u16(w, i)
		if base != nil && base.bullets[i].active do write_words(w, &m.bullets[i], &base.bullets[i], size_of(sim.Bullet))
		else do write_raw(w, &m.bullets[i], size_of(sim.Bullet))
	}
	write_u16(w, u16(g))
	for i in bgone[:g] do write_u16(w, i)

	write_u16(w, u16(m.events.count))
	for i in 0 ..< m.events.count do write_raw(w, &m.events.items[i], size_of(sim.Event))
}

// The header alone: which base the rest needs.
decode_snapshot_head :: proc(r: ^Reader) -> (tick, base: u32) {
	tick = read_u32(r)
	base = read_u32(r)
	return
}

// The rest, after the head, into `m`, which must hold a copy of the base (or be
// cleared when there is none).
decode_snapshot :: proc(r: ^Reader, m: ^Snapshot, tick, base_tick: u32, base: ^Snapshot) -> bool {
	m.tick = tick
	m.base = base_tick
	m.ack = read_u32(r)
	m.queue_depth = read_u8(r)
	if base == nil do read_raw(r, &m.round, size_of(sim.Round))
	else do read_words(r, &m.round, size_of(sim.Round))

	soldiers := int(read_u8(r))
	for _ in 0 ..< soldiers {
		i := int(read_u8(r))
		if i >= sim.MAX_PLAYERS do return false
		if base != nil && base.soldiers[i].active do read_words(r, &m.soldiers[i], size_of(sim.Soldier))
		else do read_raw(r, &m.soldiers[i], size_of(sim.Soldier))
	}
	gone := int(read_u8(r))
	for _ in 0 ..< gone {
		i := int(read_u8(r))
		if i >= sim.MAX_PLAYERS do return false
		m.soldiers[i] = {}
	}

	things := int(read_u8(r))
	for _ in 0 ..< things {
		i := int(read_u8(r))
		if i >= sim.MAX_THINGS do return false
		if base != nil && base.things[i].style != .None do read_words(r, &m.things[i], size_of(sim.Thing))
		else do read_raw(r, &m.things[i], size_of(sim.Thing))
	}
	gone = int(read_u8(r))
	for _ in 0 ..< gone {
		i := int(read_u8(r))
		if i >= sim.MAX_THINGS do return false
		m.things[i] = {}
	}

	bullets := int(read_u16(r))
	for _ in 0 ..< bullets {
		i := int(read_u16(r))
		if i >= sim.MAX_BULLETS do return false
		if base != nil && base.bullets[i].active do read_words(r, &m.bullets[i], size_of(sim.Bullet))
		else do read_raw(r, &m.bullets[i], size_of(sim.Bullet))
	}
	gone = int(read_u16(r))
	for _ in 0 ..< gone {
		i := int(read_u16(r))
		if i >= sim.MAX_BULLETS do return false
		m.bullets[i] = {}
	}

	m.events.count = min(int(read_u16(r)), sim.MAX_EVENTS)
	for i in 0 ..< m.events.count do read_raw(r, &m.events.items[i], size_of(sim.Event))
	return r.ok
}
