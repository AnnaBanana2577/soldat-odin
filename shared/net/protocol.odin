// Package net is the wire protocol. Transport is ENet (vendor:ENet); this package only
// encodes and decodes messages.
//
// The server is authoritative: clients send Inputs (their commands, numbered by
// themselves), the server runs the one true world and sends every client a Snapshot
// of it each tick: the soldiers, things and bullets whole, the tick's events, and for
// the receiver its last applied command and how many were waiting. A client predicts
// itself by replaying its unacknowledged commands on the latest snapshot and shows
// everyone else interpolated between two older ones.
//
// The state goes as the sim's structs, byte for byte: the same build runs on both
// ends. A portable, delta-compressed encoding is a later step.
package net

import "../sim"

VERSION      :: 2
DEFAULT_PORT :: 23073

CHANNEL_UNRELIABLE :: 0 // inputs, snapshots
CHANNEL_RELIABLE   :: 1 // the handshake, the lobby
CHANNEL_COUNT      :: 2

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
	write_string(w, name[:min(len(name), MAX_NAME)])
}

decode_hello :: proc(r: ^Reader) -> (m: Hello, ok: bool) {
	m.version = read_u16(r)
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
// showing the others at, for the server to judge its shots against.
MAX_COMMANDS_PER_INPUT :: 8

Input :: struct {
	view_tick: u32,
	commands:  [MAX_COMMANDS_PER_INPUT]sim.Command,
	count:     int,
}

encode_input :: proc(w: ^Writer, m: ^Input) {
	write_u8(w, u8(Msg.Input))
	write_u32(w, m.view_tick)
	write_u8(w, u8(m.count))
	for i in 0 ..< m.count do write_raw(w, &m.commands[i], size_of(sim.Command))
}

decode_input :: proc(r: ^Reader) -> (m: Input, ok: bool) {
	m.view_tick = read_u32(r)
	m.count = min(int(read_u8(r)), MAX_COMMANDS_PER_INPUT)
	for i in 0 ..< m.count do read_raw(r, &m.commands[i], size_of(sim.Command))
	return m, r.ok
}

// ---- snapshots (server -> client, unreliable, every tick) ----

// The world as of `tick`: every active soldier, thing and bullet whole, the round, and
// what happened that tick. `ack` is the receiver's last command the server applied;
// `queue_depth` how many of its commands were waiting when the tick began, which
// the client steers toward a small target by running its clock faster or slower.
Snapshot :: struct {
	tick:        u32,
	ack:         u32,
	queue_depth: u8,
	round:       sim.Round,
	soldiers:    [sim.MAX_PLAYERS]sim.Soldier,
	things:      [sim.MAX_THINGS]sim.Thing,
	bullets:     [sim.MAX_BULLETS]sim.Bullet,
	events:      sim.Events,
}

encode_snapshot :: proc(w: ^Writer, m: ^Snapshot) {
	write_u8(w, u8(Msg.Snapshot))
	write_u32(w, m.tick)
	write_u32(w, m.ack)
	write_u8(w, m.queue_depth)
	write_raw(w, &m.round, size_of(sim.Round))

	count := 0
	for &s in m.soldiers do if s.active do count += 1
	write_u8(w, u8(count))
	for &s, i in m.soldiers {
		if !s.active do continue
		write_u8(w, u8(i))
		write_raw(w, &s, size_of(sim.Soldier))
	}
	count = 0
	for &t in m.things do if t.style != .None do count += 1
	write_u8(w, u8(count))
	for &t, i in m.things {
		if t.style == .None do continue
		write_u8(w, u8(i))
		write_raw(w, &t, size_of(sim.Thing))
	}
	count = 0
	for &b in m.bullets do if b.active do count += 1
	write_u16(w, u16(count))
	for &b, i in m.bullets {
		if !b.active do continue
		write_u16(w, u16(i))
		write_raw(w, &b, size_of(sim.Bullet))
	}
	write_u16(w, u16(m.events.count))
	for i in 0 ..< m.events.count do write_raw(w, &m.events.items[i], size_of(sim.Event))
}

decode_snapshot :: proc(r: ^Reader, m: ^Snapshot) -> bool {
	m^ = {}
	m.tick = read_u32(r)
	m.ack = read_u32(r)
	m.queue_depth = read_u8(r)
	read_raw(r, &m.round, size_of(sim.Round))
	soldiers := int(read_u8(r))
	for _ in 0 ..< soldiers {
		i := int(read_u8(r))
		if i >= sim.MAX_PLAYERS do return false
		read_raw(r, &m.soldiers[i], size_of(sim.Soldier))
	}
	things := int(read_u8(r))
	for _ in 0 ..< things {
		i := int(read_u8(r))
		if i >= sim.MAX_THINGS do return false
		read_raw(r, &m.things[i], size_of(sim.Thing))
	}
	bullets := int(read_u16(r))
	for _ in 0 ..< bullets {
		i := int(read_u16(r))
		if i >= sim.MAX_BULLETS do return false
		read_raw(r, &m.bullets[i], size_of(sim.Bullet))
	}
	m.events.count = min(int(read_u16(r)), sim.MAX_EVENTS)
	for i in 0 ..< m.events.count do read_raw(r, &m.events.items[i], size_of(sim.Event))
	return r.ok
}
