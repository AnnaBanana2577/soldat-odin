// Package net is the wire protocol. Transport is ENet (vendor:ENet); this package only
// says what the messages are and how they are laid out.
//
// Every machine runs the same simulation, so most of what happens is never sent. A
// client says where its own soldier is and what it fired; the server says where
// everyone is, which bullets were born, and what only it could decide.
//
//   client -> server   Input    every tick: my soldier, the tick I show the others at,
//                               my recent shots (each in a few packets running)
//                      Act      what I did that the server must not miss: a gun or a
//                               flag thrown, a suicide, the weapons I chose
//   server -> client   Map      the map to play, and where its flags stand: on joining,
//                               and at the start of every round
//                      Roster   who plays in which slot, by name
//                      Update   every other tick: the soldiers in my view, the bullets
//                               born lately (each in a few updates running), the round
//                      Things   a thing, whole, when something happened to it
//                      Facts    what the server decided: a death, a respawn, a pickup,
//                               a score
//                      Correction  where my soldier is, when the server refused where I
//                               said it was
//
// A message is state or it is news. State (Input, Update) is sent over and over,
// unreliably: a lost one is replaced by the next, and nothing in one is needed to read
// another. News (everything else) is sent once, reliably and in order. RELIABLE says
// which is which, never a call site. Each message has one serialize procedure, used
// for both reading and writing, that checks every bound and refuses what it cannot
// trust: a float that is not a number, an enum out of range, a count too large, bytes
// left over.
package net

import "../sim"

VERSION      :: 9
DEFAULT_PORT :: 23073

CHANNEL_UNRELIABLE :: 0 // state: the newest replaces the last
CHANNEL_RELIABLE   :: 1 // news: losing one is a desync
CHANNEL_COUNT      :: 2

Msg_Kind :: enum u8 { Invalid, Hello, Welcome, Denied, Map, Roster, Input, Act, Update, Things, Facts, Correction }

RELIABLE := [Msg_Kind]bool {
	.Invalid = false, .Hello = true, .Welcome = true, .Denied = true, .Map = true, .Roster = true,
	.Input = false, .Act = true,
	.Update = false, .Things = true, .Facts = true, .Correction = true,
}

MAX_SHOTS_PER_INPUT  :: 16
MAX_SHOTS_PER_UPDATE :: 64
MAX_THINGS_PER_MSG   :: 12
MAX_FACTS_PER_MSG    :: 16

// ---- the messages ----

Hello :: struct {
	version: u16,
	name:    string,
}

Welcome :: struct {
	slot: u8,
}

// The map to play, and where its flags stand (they are placed at random among the
// map's spawn points). A client that hears it starts a round on that map: the things
// and bullets gone, the scores nil; the soldiers are placed by the facts that follow.
// Joining is hearing of the first.
Map :: struct {
	name:      string,
	flag_home: [2]sim.Vec2,
	tick:      u32, // the server tick the round starts at
}

Denied :: struct {
	reason: string,
}

MAX_NAME :: 24

// A player's name, kept without allocating: printable ASCII, as the font has it.
Name :: struct {
	bytes: [MAX_NAME]u8,
	len:   u8,
}

name_make :: proc(s: string) -> (n: Name) {
	n.len = u8(copy(n.bytes[:], s))
	for &b in n.bytes[:n.len] do if b < 32 || b > 126 do b = '?' // what the font can draw
	return
}

name_string :: proc(n: ^Name) -> string {
	return string(n.bytes[:n.len])
}

// Who plays in which slot. A newcomer hears of everyone, and everyone of a newcomer.
Roster :: struct {
	slots: [sim.MAX_PLAYERS]u8,
	names: [sim.MAX_PLAYERS]Name,
	count: int,
	bots:  u32, // a bit for each slot the server plays itself
}

// A bullet at birth, which is all of it that ever crosses the wire: every machine flies
// it from here. `id` numbers the shooter's shots so one sent twice counts once.
Shot :: struct {
	id:       u32,
	weapon:   sim.Weapon_Id,
	pos, vel: sim.Vec2,
	sends:    u8, // the shooter's own bookkeeping, not on the wire
}

// `life` is the life of my soldier this speaks of (sim.Soldier.life): the server takes
// no word of a life it has ended. `view_tick` is the server tick I am showing the
// others at: the server judges the shots in this packet against the soldiers of that
// tick, and measures my lag by it.
Input :: struct {
	life:       u8,
	view_tick:  u32,
	has_state:  bool,        // false while I have no living soldier
	soldier:    sim.Soldier, // the half of it that is mine to say (ser_owned)
	shots:      [MAX_SHOTS_PER_INPUT]Shot,
	shot_count: int,
}

Action :: enum u8 { Throw_Gun, Throw_Flag, Suicide, Loadout }

Act :: struct {
	action: Action,
	weapon: sim.Weapon_Id, // a thrown gun, as it left my hand; or the primary I chose
	second: sim.Weapon_Id, // the secondary I chose
	ammo:   i32,
}

// A soldier in an update: always the server's half, and its player's half unless it
// is the receiver's own soldier or a corpse.
Entry :: struct {
	slot:      u8,
	has_owned: bool,
	soldier:   sim.Soldier,
}

// A bullet someone else fired. `seq` numbers the shooter's bullets as the server took
// them, so one told in several updates flies once. `age` is how many ticks before the
// update's tick the server spawned it, and `lag` how far back it judges it (how late
// its shooter sees the world): what the receiver needs to fly it on to where it is.
Fired :: struct {
	shooter:  u8,
	seq:      u32,
	age:      u8,
	lag:      u8,
	weapon:   sim.Weapon_Id,
	pos, vel: sim.Vec2,
}

// The world at `tick`. `active` has a bit for every slot in play; a soldier in play
// but not among the entries is out of the receiver's view, and heard of now and then.
// `lags` has for every slot in play how late the server finds its player sees the world,
// in ticks: the receiver's own tells it its lag, the rest are the scoreboard's pings.
Update :: struct {
	tick:        u32,
	round:       sim.Round, // state, time left, the two scores
	active:      u32,
	lags:        [sim.MAX_PLAYERS]u8,
	entries:     [sim.MAX_PLAYERS]Entry,
	entry_count: int,
	fired:       [MAX_SHOTS_PER_UPDATE]Fired,
	fired_count: int,
}

#assert(sim.MAX_PLAYERS <= 32) // a bit each in Update.active

Things :: struct {
	indices: [MAX_THINGS_PER_MSG]u8,
	things:  [MAX_THINGS_PER_MSG]sim.Thing,
	count:   int,
}

Facts :: struct {
	events: [MAX_FACTS_PER_MSG]sim.Event,
	count:  int,
}

// The server refused where a client said its soldier was (further than a soldier can
// move) and puts it back: a new life, as every placing is.
Correction :: struct {
	life:     u8,
	pos, vel: sim.Vec2,
}

Message :: union { Hello, Welcome, Denied, Map, Roster, Input, Act, Update, Things, Facts, Correction }

message_kind :: proc(m: ^Message) -> Msg_Kind {
	switch _ in m {
	case Hello:      return .Hello
	case Welcome:    return .Welcome
	case Denied:     return .Denied
	case Map:        return .Map
	case Roster:     return .Roster
	case Input:      return .Input
	case Act:        return .Act
	case Update:     return .Update
	case Things:     return .Things
	case Facts:      return .Facts
	case Correction: return .Correction
	}
	return .Invalid
}

// ---- the parts ----

// A soldier's player's half: where it is, how it moves, what it holds. In step with
// sim.soldier_copy_owned.
ser_owned :: proc(s: ^Stream, v: ^sim.Soldier) {
	ser_vec2(s, &v.pos)
	ser_vec2(s, &v.vel)
	ser_vec2(s, &v.next_push)
	ser_buttons(s, &v.controls)
	ser_vec2(s, &v.aim)
	ser_as(s, &v.direction, u8)
	ser_enum(s, &v.stance)
	ser_bool(s, &v.on_ground)
	ser_as(s, &v.jets, i16)
	ser_enum(s, &v.legs.id)
	ser_as(s, &v.legs.frame, u8)
	ser_enum(s, &v.body.id)
	ser_as(s, &v.body.frame, u8)
	ser_weapon(s, &v.weapon)
	ser_weapon(s, &v.secondary)
	ser_as(s, &v.grenades, u8)
	ser_bool(s, &v.spawn_still)
	ser_u8(s, &v.para)
	ser_u8(s, &v.stat)
	if !s.writing && (int(v.para) > sim.MAX_THINGS || int(v.stat) > sim.MAX_THINGS) do s.failed = true
}

ser_weapon :: proc(s: ^Stream, v: ^sim.Weapon) {
	ser_enum(s, &v.id)
	ser_as(s, &v.ammo, i16)
	ser_as(s, &v.fire_count, i16)
	ser_as(s, &v.reload_count, i16)
	ser_as(s, &v.startup_count, i16)
}

// The server's half of a soldier. In step with sim.soldier_copy_served.
ser_served :: proc(s: ^Stream, v: ^sim.Soldier) {
	ser_bool(s, &v.active)
	ser_bool(s, &v.dead)
	ser_enum(s, &v.team)
	ser_u8(s, &v.life)
	ser_f32(s, &v.health)
	ser_f32(s, &v.vest)
	ser_as(s, &v.respawn_counter, i16)
	ser_as(s, &v.cease_fire_counter, i16)
	ser_enum(s, &v.bonus)
	ser_as(s, &v.bonus_time, i16)
	ser_bool(s, &v.holding_flag)
	ser_as(s, &v.kills, u16)
	ser_as(s, &v.deaths, u16)
	ser_as(s, &v.flags, u16)
	ser_vec2(s, &v.death_vel)
	ser_u8(s, &v.death_part)
}

ser_shot :: proc(s: ^Stream, v: ^Shot) {
	ser_u32(s, &v.id)
	ser_enum(s, &v.weapon)
	ser_vec2(s, &v.pos)
	ser_vec2(s, &v.vel)
}

ser_fired :: proc(s: ^Stream, v: ^Fired) {
	ser_u8(s, &v.shooter)
	ser_u32(s, &v.seq)
	ser_u8(s, &v.age)
	ser_u8(s, &v.lag)
	ser_enum(s, &v.weapon)
	ser_vec2(s, &v.pos)
	ser_vec2(s, &v.vel)
	if !s.writing && int(v.shooter) >= sim.MAX_PLAYERS do s.failed = true
}

ser_thing :: proc(s: ^Stream, v: ^sim.Thing) {
	ser_enum(s, &v.style)
	ser_enum(s, &v.weapon)
	ser_as(s, &v.ammo, i16)
	ser_bool(s, &v.flip)
	ser_u8(s, &v.holder)
	ser_u8(s, &v.owner)
	ser_as(s, &v.timeout, i32)
	ser_bool(s, &v.static)
	ser_as(s, &v.points, u8)
	ser_bool(s, &v.in_base)
	ser_as(s, &v.interest, i16)
	for k in 0 ..< 4 {
		ser_vec2(s, &v.pos[k])
		ser_vec2(s, &v.old_pos[k])
	}
	if !s.writing && (int(v.holder) > sim.MAX_PLAYERS || int(v.owner) > sim.MAX_PLAYERS || v.points > 4) do s.failed = true
}

// ---- facts: the events only the server can decide ----

Fact_Kind :: enum u8 { None, Kill, Respawn, Kit_Pickup, Weapon_Pickup, Flag_Grab, Flag_Return, Flag_Score, Match_End }

fact_kind :: proc(e: sim.Event) -> Fact_Kind {
	#partial switch _ in e {
	case sim.Kill:          return .Kill
	case sim.Respawn:       return .Respawn
	case sim.Kit_Pickup:    return .Kit_Pickup
	case sim.Weapon_Pickup: return .Weapon_Pickup
	case sim.Flag_Grab:     return .Flag_Grab
	case sim.Flag_Return:   return .Flag_Return
	case sim.Flag_Score:    return .Flag_Score
	case sim.Match_End:     return .Match_End
	}
	return .None
}

// A soldier named in a fact; 255 names nobody (a flag that timed out).
@(private)
ser_slot :: proc(s: ^Stream, v: ^u8) {
	ser_u8(s, v)
	if !s.writing && int(v^) >= sim.MAX_PLAYERS && v^ != 255 do s.failed = true
}

ser_fact :: proc(s: ^Stream, e: ^sim.Event) {
	kind := fact_kind(e^)
	ser_enum(s, &kind)
	switch kind {
	case .None:
		s.failed = true
	case .Kill:
		v := e.(sim.Kill) or_else sim.Kill{}
		ser_slot(s, &v.killer); ser_slot(s, &v.target); ser_enum(s, &v.weapon)
		ser_vec2(s, &v.pos); ser_f32(s, &v.health); ser_u8(s, &v.part); ser_as(s, &v.kills, i16)
		e^ = v
	case .Respawn:
		v := e.(sim.Respawn) or_else sim.Respawn{}
		ser_slot(s, &v.target); ser_u8(s, &v.life); ser_enum(s, &v.team)
		ser_enum(s, &v.primary); ser_enum(s, &v.secondary); ser_vec2(s, &v.pos)
		e^ = v
	case .Kit_Pickup:
		v := e.(sim.Kit_Pickup) or_else sim.Kit_Pickup{}
		ser_slot(s, &v.player); ser_u8(s, &v.thing); ser_enum(s, &v.kit); ser_vec2(s, &v.pos)
		e^ = v
	case .Weapon_Pickup:
		v := e.(sim.Weapon_Pickup) or_else sim.Weapon_Pickup{}
		ser_slot(s, &v.player); ser_u8(s, &v.thing); ser_enum(s, &v.weapon); ser_as(s, &v.ammo, i16); ser_vec2(s, &v.pos)
		e^ = v
	case .Flag_Grab:
		v := e.(sim.Flag_Grab) or_else sim.Flag_Grab{}
		ser_slot(s, &v.player); ser_u8(s, &v.thing); ser_enum(s, &v.flag); ser_vec2(s, &v.pos)
		e^ = v
	case .Flag_Return:
		v := e.(sim.Flag_Return) or_else sim.Flag_Return{}
		ser_slot(s, &v.player); ser_enum(s, &v.flag); ser_vec2(s, &v.pos)
		e^ = v
	case .Flag_Score:
		v := e.(sim.Flag_Score) or_else sim.Flag_Score{}
		ser_slot(s, &v.player); ser_enum(s, &v.flag); ser_vec2(s, &v.pos)
		e^ = v
	case .Match_End:
		v := e.(sim.Match_End) or_else sim.Match_End{}
		ser_enum(s, &v.winner)
		e^ = v
	}
}

// ---- one serializer per message ----

ser_hello :: proc(s: ^Stream, m: ^Hello) {
	ser_u16(s, &m.version)
	ser_string(s, &m.name)
}

ser_welcome :: proc(s: ^Stream, m: ^Welcome) {
	ser_u8(s, &m.slot)
	if !s.writing && int(m.slot) >= sim.MAX_PLAYERS do s.failed = true
}

ser_map :: proc(s: ^Stream, m: ^Map) {
	ser_string(s, &m.name)
	ser_vec2(s, &m.flag_home[0])
	ser_vec2(s, &m.flag_home[1])
	ser_u32(s, &m.tick)
}

ser_denied :: proc(s: ^Stream, m: ^Denied) {
	ser_string(s, &m.reason)
}

ser_roster :: proc(s: ^Stream, m: ^Roster) {
	ser_u32(s, &m.bots)
	ser_count(s, &m.count, sim.MAX_PLAYERS)
	for i in 0 ..< m.count {
		ser_u8(s, &m.slots[i])
		if !s.writing && int(m.slots[i]) >= sim.MAX_PLAYERS do s.failed = true
		n := &m.names[i]
		ser_u8(s, &n.len)
		if !s.writing && int(n.len) > MAX_NAME do s.failed, n.len = true, 0
		b := take(s, int(n.len))
		if b == nil do continue
		if s.writing do copy(b, n.bytes[:n.len])
		else do n^ = name_make(string(b))
	}
}

ser_input :: proc(s: ^Stream, m: ^Input) {
	ser_u8(s, &m.life)
	ser_u32(s, &m.view_tick)
	ser_bool(s, &m.has_state)
	if m.has_state do ser_owned(s, &m.soldier)
	ser_count(s, &m.shot_count, MAX_SHOTS_PER_INPUT)
	for i in 0 ..< m.shot_count do ser_shot(s, &m.shots[i])
}

ser_act :: proc(s: ^Stream, m: ^Act) {
	ser_enum(s, &m.action)
	ser_enum(s, &m.weapon)
	ser_enum(s, &m.second)
	ser_as(s, &m.ammo, i16)
}

ser_update :: proc(s: ^Stream, m: ^Update) {
	ser_u32(s, &m.tick)
	ser_enum(s, &m.round.state)
	ser_as(s, &m.round.time_left, i32)
	ser_as(s, &m.round.counter, i16)
	ser_as(s, &m.round.scores[.Alpha], u16)
	ser_as(s, &m.round.scores[.Bravo], u16)
	ser_u32(s, &m.active)
	for i in 0 ..< sim.MAX_PLAYERS do if m.active & (1 << u32(i)) != 0 do ser_u8(s, &m.lags[i])
	ser_count(s, &m.entry_count, sim.MAX_PLAYERS)
	for i in 0 ..< m.entry_count {
		e := &m.entries[i]
		ser_u8(s, &e.slot)
		if !s.writing && int(e.slot) >= sim.MAX_PLAYERS do s.failed = true
		ser_bool(s, &e.has_owned)
		ser_served(s, &e.soldier)
		if e.has_owned do ser_owned(s, &e.soldier)
	}
	ser_count(s, &m.fired_count, MAX_SHOTS_PER_UPDATE)
	for i in 0 ..< m.fired_count do ser_fired(s, &m.fired[i])
}

ser_things :: proc(s: ^Stream, m: ^Things) {
	ser_count(s, &m.count, MAX_THINGS_PER_MSG)
	for i in 0 ..< m.count {
		ser_u8(s, &m.indices[i])
		if !s.writing && int(m.indices[i]) >= sim.MAX_THINGS do s.failed = true
		ser_thing(s, &m.things[i])
	}
}

ser_facts :: proc(s: ^Stream, m: ^Facts) {
	ser_count(s, &m.count, MAX_FACTS_PER_MSG)
	for i in 0 ..< m.count do ser_fact(s, &m.events[i])
}

ser_correction :: proc(s: ^Stream, m: ^Correction) {
	ser_u8(s, &m.life)
	ser_vec2(s, &m.pos)
	ser_vec2(s, &m.vel)
}

// ---- encode and decode ----

encode :: proc(buf: []u8, msg: ^Message) -> (size: int, ok: bool) {
	s := stream_writer(buf)
	kind := message_kind(msg)
	if kind == .Invalid do return 0, false
	ser_enum(&s, &kind)
	ser_message(&s, msg)
	return s.pos, stream_finish(&s)
}

// Into `msg`, which the caller keeps: an Update is too large to pass around by value.
decode :: proc(data: []u8, msg: ^Message) -> bool {
	s := stream_reader(data)
	kind: Msg_Kind
	ser_enum(&s, &kind)
	switch kind {
	case .Invalid:    return false
	case .Hello:      msg^ = Hello{}
	case .Welcome:    msg^ = Welcome{}
	case .Denied:     msg^ = Denied{}
	case .Map:        msg^ = Map{}
	case .Roster:     msg^ = Roster{}
	case .Input:      msg^ = Input{}
	case .Act:        msg^ = Act{}
	case .Update:     msg^ = Update{}
	case .Things:     msg^ = Things{}
	case .Facts:      msg^ = Facts{}
	case .Correction: msg^ = Correction{}
	}
	ser_message(&s, msg)
	return stream_finish(&s)
}

@(private)
ser_message :: proc(s: ^Stream, msg: ^Message) {
	switch &m in msg {
	case Hello:      ser_hello(s, &m)
	case Welcome:    ser_welcome(s, &m)
	case Denied:     ser_denied(s, &m)
	case Map:        ser_map(s, &m)
	case Roster:     ser_roster(s, &m)
	case Input:      ser_input(s, &m)
	case Act:        ser_act(s, &m)
	case Update:     ser_update(s, &m)
	case Things:     ser_things(s, &m)
	case Facts:      ser_facts(s, &m)
	case Correction: ser_correction(s, &m)
	}
}
