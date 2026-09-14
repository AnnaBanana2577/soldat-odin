// Package net is the wire protocol. Transport is ENet (vendor:ENet); this package only
// encodes and decodes messages.
//
// Client -> server: an Update per tick (my soldier's owned fields, my recent shots), a
// Throw for a gun let go of, and Claims for what someone else could contest (a hit I
// scored, a thing I took). Server -> clients: everyone's State with its age, Shots,
// Commits (claims settled), Rejects, the Things and the Clock.
package net

import "../sim"

VERSION      :: 1
DEFAULT_PORT :: 23073

CHANNEL_UNRELIABLE :: 0 // updates, states, shots, clock
CHANNEL_RELIABLE   :: 1 // handshake, lobby, claims, commits, rejects
CHANNEL_COUNT      :: 2

MAX_SHOTS_PER_PACKET :: 16

Msg :: enum u8 {
	None,
	// the lobby, reliable
	Hello, Welcome, Denied, Roster, Chat, Leave, Map_Change, Settings,
	// the game
	Update, // client -> server: my soldier and my shots
	Throw,  // client -> server: the gun I threw, an event like a shot, never refused
	State,  // server -> clients: one soldier as its owner last sent it, and how old that is
	Shot,   // server -> clients: a bullet someone fired, as they fired it
	Claim,  // client -> server: a change I want beyond my own soldier
	Commit, // server -> clients: a claim settled, applied the same way in every world
	Reject, // server -> the claimant: a claim refused; nothing to undo, it changed nothing
	Clock,  // server -> clients: the round as it stands
	Things, // server -> clients: things whole, each when it changes, all on joining
}

Shot :: struct {
	id:       u32,
	sends:    u8, // the shooter's own bookkeeping, not on the wire: packets it has ridden in
	weapon:   sim.Weapon_Id,
	pos, vel: sim.Vec2,
	damage:   f32,
}

Update :: struct {
	seq:        u32,
	has_state:  bool,
	state:      sim.Soldier, // only the owned fields cross the wire
	shots:      [MAX_SHOTS_PER_PACKET]Shot,
	shot_count: int,
}

// Only what another player could contest is claimed: a hit (target, weapon, amount,
// part, pos and vel, the knockback) and a pickup (the thing).
Claim_Kind :: enum u8 { Hit, Pickup }

// Numbered by the claimant; the server answers each once, in arrival order.
Claim :: struct {
	id:       u32,
	kind:     Claim_Kind,
	target:   u8, // the soldier hit, or the thing
	weapon:   sim.Weapon_Id,
	amount:   f32,
	part:     u8,
	pos, vel: sim.Vec2,
	sent:     bool, // the claimant's own bookkeeping, not on the wire
}

Commit :: struct {
	tick:   u32,
	player: u8, // the claimant, or 0 for the server's own changes
	claim:  Claim,
}

State :: struct {
	slot:    u8,
	age:     u8, // ticks since the owner's packet arrived at the server
	soldier: sim.Soldier,
}

// ---- the owned soldier fields, in wire order ----

write_owned :: proc(w: ^Writer, s: ^sim.Soldier) {
	write_f32(w, s.pos.x)
	write_f32(w, s.pos.y)
	write_f32(w, s.vel.x)
	write_f32(w, s.vel.y)
	write_f32(w, s.next_push.x)
	write_f32(w, s.next_push.y)
	write_u16(w, transmute(u16)s.controls)
	write_f32(w, s.aim.x)
	write_f32(w, s.aim.y)
	write_u8(w, u8(s.direction))
	write_bool(w, s.on_ground)
	write_u32(w, u32(s.jets))
	write_u8(w, u8(s.legs.id))
	write_u32(w, u32(s.legs.frame))
	write_u8(w, u8(s.body.id))
	write_u32(w, u32(s.body.frame))
	write_u8(w, u8(s.weapon.id))
	write_u32(w, u32(s.weapon.ammo))
	write_u8(w, u8(s.secondary.id))
	write_u32(w, u32(s.secondary.ammo))
	write_u8(w, u8(s.grenades))
	write_bool(w, s.spawn_still)
	write_u8(w, s.para)
	write_u8(w, s.stat)
}

read_owned :: proc(r: ^Reader, s: ^sim.Soldier) {
	s.pos = {read_f32(r), read_f32(r)}
	s.vel = {read_f32(r), read_f32(r)}
	s.next_push = {read_f32(r), read_f32(r)}
	s.controls = transmute(sim.Buttons)read_u16(r)
	s.aim = {read_f32(r), read_f32(r)}
	s.direction = i8(read_u8(r))
	s.on_ground = read_bool(r)
	s.jets = i32(read_u32(r))
	s.legs.id = sim.Anim_Id(read_u8(r))
	s.legs.frame = i32(read_u32(r))
	s.body.id = sim.Anim_Id(read_u8(r))
	s.body.frame = i32(read_u32(r))
	s.weapon.id = sim.Weapon_Id(read_u8(r))
	s.weapon.ammo = i32(read_u32(r))
	s.secondary.id = sim.Weapon_Id(read_u8(r))
	s.secondary.ammo = i32(read_u32(r))
	s.grenades = i32(read_u8(r))
	s.spawn_still = read_bool(r)
	s.para = read_u8(r)
	s.stat = read_u8(r)
}

// ---- update ----

write_shot :: proc(w: ^Writer, s: ^Shot) {
	write_u32(w, s.id)
	write_u8(w, u8(s.weapon))
	write_f32(w, s.pos.x)
	write_f32(w, s.pos.y)
	write_f32(w, s.vel.x)
	write_f32(w, s.vel.y)
	write_f32(w, s.damage)
}

read_shot :: proc(r: ^Reader) -> (s: Shot) {
	s.id = read_u32(r)
	s.weapon = sim.Weapon_Id(read_u8(r))
	s.pos = {read_f32(r), read_f32(r)}
	s.vel = {read_f32(r), read_f32(r)}
	s.damage = read_f32(r)
	return
}

encode_update :: proc(w: ^Writer, m: ^Update) {
	write_u8(w, u8(Msg.Update))
	write_u32(w, m.seq)
	write_bool(w, m.has_state)
	if m.has_state do write_owned(w, &m.state)
	write_u8(w, u8(m.shot_count))
	for i in 0 ..< m.shot_count do write_shot(w, &m.shots[i])
}

decode_update :: proc(r: ^Reader) -> (m: Update, ok: bool) {
	m.seq = read_u32(r)
	m.has_state = read_bool(r)
	if m.has_state do read_owned(r, &m.state)
	m.shot_count = min(int(read_u8(r)), MAX_SHOTS_PER_PACKET)
	for i in 0 ..< m.shot_count do m.shots[i] = read_shot(r)
	return m, r.ok
}

// ---- state (server -> clients) ----

// The server's fields ride with the owned ones: what the server decided about the soldier.
write_served :: proc(w: ^Writer, s: ^sim.Soldier) {
	write_bool(w, s.active)
	write_bool(w, s.dead)
	write_u8(w, u8(s.team))
	write_f32(w, s.health)
	write_u32(w, u32(s.respawn_counter))
	write_u32(w, u32(s.cease_fire_counter))
	write_f32(w, s.vest)
	write_u8(w, u8(s.bonus))
	write_u32(w, u32(s.bonus_time))
	write_bool(w, s.holding_flag)
	write_u32(w, u32(s.kills))
	write_u32(w, u32(s.deaths))
	write_u32(w, u32(s.flags))
}

read_served :: proc(r: ^Reader, s: ^sim.Soldier) {
	s.active = read_bool(r)
	s.dead = read_bool(r)
	s.team = sim.Team(read_u8(r))
	s.health = read_f32(r)
	s.respawn_counter = i32(read_u32(r))
	s.cease_fire_counter = i32(read_u32(r))
	s.vest = read_f32(r)
	s.bonus = sim.Bonus(read_u8(r))
	s.bonus_time = i32(read_u32(r))
	s.holding_flag = read_bool(r)
	s.kills = i32(read_u32(r))
	s.deaths = i32(read_u32(r))
	s.flags = i32(read_u32(r))
}

encode_state :: proc(w: ^Writer, m: ^State) {
	write_u8(w, u8(Msg.State))
	write_u8(w, m.slot)
	write_u8(w, m.age)
	write_served(w, &m.soldier)
	write_owned(w, &m.soldier)
}

decode_state :: proc(r: ^Reader) -> (m: State, ok: bool) {
	m.slot = read_u8(r)
	m.age = read_u8(r)
	read_served(r, &m.soldier)
	read_owned(r, &m.soldier)
	return m, r.ok
}

// ---- claims and commits ----

write_claim :: proc(w: ^Writer, c: ^Claim) {
	write_u32(w, c.id)
	write_u8(w, u8(c.kind))
	write_u8(w, c.target)
	write_u8(w, u8(c.weapon))
	write_f32(w, c.amount)
	write_u8(w, c.part)
	write_f32(w, c.pos.x)
	write_f32(w, c.pos.y)
	write_f32(w, c.vel.x)
	write_f32(w, c.vel.y)
}

read_claim :: proc(r: ^Reader) -> (c: Claim) {
	c.id = read_u32(r)
	c.kind = Claim_Kind(read_u8(r))
	c.target = read_u8(r)
	c.weapon = sim.Weapon_Id(read_u8(r))
	c.amount = read_f32(r)
	c.part = read_u8(r)
	c.pos = {read_f32(r), read_f32(r)}
	c.vel = {read_f32(r), read_f32(r)}
	return
}

encode_claim :: proc(w: ^Writer, c: ^Claim) {
	write_u8(w, u8(Msg.Claim))
	write_claim(w, c)
}

decode_claim :: proc(r: ^Reader) -> (c: Claim, ok: bool) {
	c = read_claim(r)
	return c, r.ok
}

encode_commit :: proc(w: ^Writer, m: ^Commit) {
	write_u8(w, u8(Msg.Commit))
	write_u32(w, m.tick)
	write_u8(w, m.player)
	write_claim(w, &m.claim)
}

decode_commit :: proc(r: ^Reader) -> (m: Commit, ok: bool) {
	m.tick = read_u32(r)
	m.player = read_u8(r)
	m.claim = read_claim(r)
	return m, r.ok
}

encode_reject :: proc(w: ^Writer, id: u32) {
	write_u8(w, u8(Msg.Reject))
	write_u32(w, id)
}

decode_reject :: proc(r: ^Reader) -> (id: u32, ok: bool) {
	id = read_u32(r)
	return id, r.ok
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

write_string :: proc(w: ^Writer, s: string, limit: int) {
	n := min(len(s), limit, 255)
	write_u8(w, u8(n))
	for i in 0 ..< n do write_u8(w, s[i])
}

// Into the reader's own bytes: valid as long as the packet is.
read_string :: proc(r: ^Reader) -> string {
	n := int(read_u8(r))
	if r.pos + n > len(r.data) {
		r.ok = false
		return ""
	}
	s := string(r.data[r.pos:r.pos + n])
	r.pos += n
	return s
}

encode_hello :: proc(w: ^Writer, name: string) {
	write_u8(w, u8(Msg.Hello))
	write_u16(w, VERSION)
	write_string(w, name, MAX_NAME)
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
	write_string(w, m.map_name, 64)
}

decode_welcome :: proc(r: ^Reader) -> (m: Welcome, ok: bool) {
	m.slot = read_u8(r)
	m.tick = read_u32(r)
	m.map_name = read_string(r)
	return m, r.ok
}

encode_denied :: proc(w: ^Writer, reason: string) {
	write_u8(w, u8(Msg.Denied))
	write_string(w, reason, 200)
}

// ---- a shot relayed (server -> clients, unreliable) ----

Shot_Relay :: struct {
	player: u8,
	shot:   Shot,
}

encode_shot :: proc(w: ^Writer, m: Shot_Relay) {
	m := m
	write_u8(w, u8(Msg.Shot))
	write_u8(w, m.player)
	write_shot(w, &m.shot)
}

decode_shot :: proc(r: ^Reader) -> (m: Shot_Relay, ok: bool) {
	m.player = read_u8(r)
	m.shot = read_shot(r)
	return m, r.ok
}

// ---- things (server -> clients, reliable) ----
//
// A thing goes whole, both positions of every point, so the receiver runs the same
// physics on from the same numbers. One goes when it changes (appears, goes, changes
// hands, starts or stops moving), all of them once to a newcomer.

MAX_THINGS_PER_PACKET :: 12

Thing_State :: struct {
	index: u8,
	thing: sim.Thing,
}

Things_Relay :: struct {
	items: [MAX_THINGS_PER_PACKET]Thing_State,
	count: int,
}

write_thing :: proc(w: ^Writer, t: ^sim.Thing) {
	write_u8(w, u8(t.style))
	write_u8(w, u8(t.weapon))
	write_u32(w, u32(t.ammo))
	write_bool(w, t.flip)
	write_u8(w, t.holder)
	write_u8(w, t.owner)
	write_u32(w, u32(t.timeout))
	write_bool(w, t.static)
	write_u8(w, u8(t.points))
	write_bool(w, t.in_base)
	write_u8(w, u8(t.interest))
	for k in 0 ..< 4 {
		write_f32(w, t.pos[k].x)
		write_f32(w, t.pos[k].y)
		write_f32(w, t.old_pos[k].x)
		write_f32(w, t.old_pos[k].y)
	}
}

read_thing :: proc(r: ^Reader) -> (t: sim.Thing) {
	t.style = sim.Thing_Style(read_u8(r))
	t.weapon = sim.Weapon_Id(read_u8(r))
	t.ammo = i32(read_u32(r))
	t.flip = read_bool(r)
	t.holder = read_u8(r)
	t.owner = read_u8(r)
	t.timeout = i32(read_u32(r))
	t.static = read_bool(r)
	t.points = int(read_u8(r))
	t.in_base = read_bool(r)
	t.interest = i32(read_u8(r))
	for k in 0 ..< 4 {
		t.pos[k] = {read_f32(r), read_f32(r)}
		t.old_pos[k] = {read_f32(r), read_f32(r)}
	}
	return
}

encode_things :: proc(w: ^Writer, m: ^Things_Relay) {
	write_u8(w, u8(Msg.Things))
	write_u8(w, u8(m.count))
	for i in 0 ..< m.count {
		write_u8(w, m.items[i].index)
		write_thing(w, &m.items[i].thing)
	}
}

decode_things :: proc(r: ^Reader) -> (m: Things_Relay, ok: bool) {
	m.count = min(int(read_u8(r)), MAX_THINGS_PER_PACKET)
	for i in 0 ..< m.count {
		m.items[i].index = read_u8(r)
		m.items[i].thing = read_thing(r)
	}
	return m, r.ok
}

// ---- the clock (server -> clients, unreliable, every tick) ----

Clock :: struct {
	tick:  u32,
	round: sim.Round, // state, scores, time left; the rest is the server's
}

encode_clock :: proc(w: ^Writer, m: ^Clock) {
	write_u8(w, u8(Msg.Clock))
	write_u32(w, m.tick)
	write_u8(w, u8(m.round.state))
	write_u32(w, u32(m.round.time_left))
	write_u16(w, u16(m.round.scores[.Alpha]))
	write_u16(w, u16(m.round.scores[.Bravo]))
}

decode_clock :: proc(r: ^Reader) -> (m: Clock, ok: bool) {
	m.tick = read_u32(r)
	m.round.state = sim.Match_State(read_u8(r))
	m.round.time_left = i32(read_u32(r))
	m.round.scores[.Alpha] = i32(read_u16(r))
	m.round.scores[.Bravo] = i32(read_u16(r))
	return m, r.ok
}

// ---- a gun thrown (client -> server, reliable) ----

Throw :: struct {
	weapon: sim.Weapon_Id,
	ammo:   i32,
}

encode_throw :: proc(w: ^Writer, m: ^Throw) {
	write_u8(w, u8(Msg.Throw))
	write_u8(w, u8(m.weapon))
	write_u32(w, u32(m.ammo))
}

decode_throw :: proc(r: ^Reader) -> (m: Throw, ok: bool) {
	m.weapon = sim.Weapon_Id(read_u8(r))
	m.ammo = i32(read_u32(r))
	return m, r.ok
}
