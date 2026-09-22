// Package net is the wire protocol. Transport is ENet (vendor:ENet); this package only
// says what the messages are and how they are laid out.
//
// Every machine runs the same simulation, so most of what happens is never sent. A
// client says which keys it held; the server runs every soldier and says where they
// are, which bullets were born, and what only it could decide. A client predicts its
// own soldier by replaying the commands the server has not run yet.
//
//   client -> server   Input    every tick: my recent commands (the unrun ones, so a
//                               lost packet costs nothing) and the tick I show the
//                               others at
//                      Act      what I chose outside the keys: my weapons, my team
//                      Chat     a line I said, to everyone or to my team
//                      Vote     a vote I called, or my vote for one already running
//                      Map_Query one of the server's maps, named for the map window
//   server -> client   Map      the map to play, and where its flags stand: on joining,
//                               and at the start of every round
//                      Roster   who plays in which slot, by name
//                      Chat     a line someone said, or the server
//                      Vote_State what vote is running, against whom or what
//                      Map_Name the map a Map_Query asked for, and how many there are
//                      Update   every other tick: the soldiers in my view, the bullets
//                               born lately (each in a few updates running), the round
//                      Things   a thing, whole, when something happened to it
//                      Facts    what the server decided: a death, a respawn, a pickup,
//                               a score
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

VERSION      :: 13 // the Map carries the match rules
DEFAULT_PORT :: 23073

CHANNEL_UNRELIABLE :: 0 // state: the newest replaces the last
CHANNEL_RELIABLE   :: 1 // news: losing one is a desync
CHANNEL_COUNT      :: 2

Msg_Kind :: enum u8 {
	Invalid, Hello, Welcome, Denied, Map, Roster, Input, Act, Chat, Update, Things, Facts,
	Vote, Vote_State, Map_Query, Map_Name,
}

RELIABLE := [Msg_Kind]bool {
	.Invalid = false, .Hello = true, .Welcome = true, .Denied = true, .Map = true, .Roster = true,
	.Input = false, .Act = true, .Chat = true,
	.Update = false, .Things = true, .Facts = true,
	.Vote = true, .Vote_State = true, .Map_Query = true, .Map_Name = true,
}

MAX_CMDS_PER_INPUT   :: 32 // the unrun commands repeat in every packet: half a second of them
MAX_SHOTS_PER_UPDATE :: 64
MAX_ENDS_PER_UPDATE  :: 16
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
	// the rules of the match played on it, so that a client simulates by the same ones
	// as the server rather than by whatever match_init leaves behind
	respawn_time:  i32,
	max_grenades:  i32,
	score_limit:   i32,
	friendly_fire: bool,
	kits_collide:  bool,
}

Denied :: struct {
	reason: string,
}

MAX_NAME :: 24
MAX_CHAT :: 85 // the original's MAXCHATTEXT

// Text kept without allocating: at most N bytes, printable ASCII, as the font has it.
Text :: struct($N: int) {
	bytes: [N]u8,
	len:   u8,
}

Name :: Text(MAX_NAME)
Line :: Text(MAX_CHAT)

// `s` cut to fit, with what the font cannot draw replaced.
text_set :: proc(t: ^Text($N), s: string) {
	t.len = u8(copy(t.bytes[:], s))
	for &b in t.bytes[:t.len] do if b < 32 || b > 126 do b = '?'
}

text_string :: proc(t: ^Text($N)) -> string {
	return string(t.bytes[:t.len])
}

name_make :: proc(s: string) -> (n: Name) {
	text_set(&n, s)
	return
}

// Who plays in which slot. A newcomer hears of everyone, and everyone of a newcomer.
Roster :: struct {
	slots: [sim.MAX_PLAYERS]u8,
	names: [sim.MAX_PLAYERS]Name,
	count: int,
	bots:  u32, // a bit for each slot the server plays itself
}

// My commands the server has not said it ran, oldest first, and the server tick I am
// showing the others at: the server judges what I fire against the soldiers of that
// tick, and measures my lag by it. Every packet carries them all again, so a lost one
// costs nothing.
Input :: struct {
	view_tick: u32,
	first:     u32, // the number of the first command; they run one per tick from there
	cmds:      [MAX_CMDS_PER_INPUT]sim.Command,
	count:     int,
}

// What a client chooses outside its keys: what its keys do is in its commands.
Action :: enum u8 { Loadout, Join_Team }

Act :: struct {
	action: Action,
	weapon: sim.Weapon_Id, // the primary I chose
	second: sim.Weapon_Id, // the secondary I chose
	team:   sim.Team,      // the team I would join
}

// A line said. From a client `slot` is not read: the server knows who sent it. From the
// server, 255 is the server itself. `team`: to the speaker's team alone.
Chat :: struct {
	slot: u8,
	team: bool,
	text: Line,
}

// A vote to send a player away or to play another map. One message does both jobs, as
// the original's votekick and votemap commands do: with no vote running it calls one,
// and with the same vote running it is this client's vote for it (Game.pas StartVote
// and CountVote).
Vote_Kind :: enum u8 { Kick, Map }

Vote :: struct {
	kind:   Vote_Kind,
	target: u8,   // the slot to send away
	name:   Name, // or the map to play
	reason: Line,
}

// What vote is running, to everyone: who called it, against whom or what, how far it
// has got and how long is left. The client counts the ticks down itself.
Vote_State :: struct {
	kind:    Vote_Kind,
	active:  bool,
	target:  u8,
	name:    Name,
	starter: u8, // 255: the server itself
	reason:  Line,
	ticks:   i32,
	votes:   u8,
	needed:  u8,
}

// The map window browsing the server's list: a client asks for the one at `index` and
// the server names it, with how many there are (TMsg_VoteMap and its reply).
Map_Query :: struct {
	index: u16,
}

Map_Name :: struct {
	index: u16,
	count: u16,
	name:  Name,
}

// A soldier in an update: always the server's half, and its player's half unless it is
// a corpse. The receiver's own carries the rest of it too (`has_rest`), because what it
// replays its commands over must be the whole soldier and not a part of one.
Entry :: struct {
	slot:      u8,
	has_owned: bool,
	has_rest:  bool,
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

// Where a bullet of the receiver's own ended, by the number its owner gave it
// (sim.Bullet.shot_id). Its client flew that bullet itself, from the same command; this
// is the server's word on where it stopped, which is where it was ruled to hit or miss.
End :: struct {
	shot:   u32,
	pos:    sim.Vec2,
	impact: bool,
}

// The world at `tick`. `active` has a bit for every slot in play; a soldier in play
// but not among the entries is out of the receiver's view, and heard of now and then.
// `lags` has for every slot in play how late the server finds its player sees the world,
// in ticks: the receiver's own tells it its lag, the rest are the scoreboard's pings.
// `ack` is the receiver's last command the server has run, and `depth` how many of its
// commands were waiting: what it replays from, and what it steers its clock by.
Update :: struct {
	tick:        u32,
	ack:         u32,
	depth:       u8,
	match:       sim.Match, // state, time left, the two scores
	active:      u32,
	lags:        [sim.MAX_PLAYERS]u8,
	entries:     [sim.MAX_PLAYERS]Entry,
	entry_count: int,
	fired:       [MAX_SHOTS_PER_UPDATE]Fired,
	fired_count: int,
	ends:        [MAX_ENDS_PER_UPDATE]End,
	end_count:   int,
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

Message :: union {
	Hello, Welcome, Denied, Map, Roster, Input, Act, Chat, Update, Things, Facts,
	Vote, Vote_State, Map_Query, Map_Name,
}

message_kind :: proc(m: ^Message) -> Msg_Kind {
	switch _ in m {
	case Hello:      return .Hello
	case Welcome:    return .Welcome
	case Denied:     return .Denied
	case Map:        return .Map
	case Roster:     return .Roster
	case Input:      return .Input
	case Act:        return .Act
	case Chat:       return .Chat
	case Update:     return .Update
	case Things:     return .Things
	case Facts:      return .Facts
	case Vote:       return .Vote
	case Vote_State: return .Vote_State
	case Map_Query:  return .Map_Query
	case Map_Name:   return .Map_Name
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
	ser_vec2(s, &v.death_pos)
	ser_vec2(s, &v.death_vel)
	ser_u8(s, &v.death_part)
	ser_u64(s, &v.rng)
	ser_u32(s, &v.cmd_seq)
	ser_u32(s, &v.shot_count)
	ser_u8(s, &v.view_lag)
	ser_enum(s, &v.primary_choice)
	ser_enum(s, &v.secondary_choice)
}

// The rest of a soldier: what only the machine playing it needs, and so what the server
// sends back to that machine alone. In step with sim.soldier_copy_rest.
ser_rest :: proc(s: ^Stream, v: ^sim.Soldier) {
	ser_vec2(s, &v.old_pos)
	ser_vec2(s, &v.forces)
	ser_as(s, &v.old_direction, u8)
	ser_bool(s, &v.was_running_left)
	ser_bool(s, &v.was_jumping)
	ser_bool(s, &v.on_ground_last)
	ser_bool(s, &v.on_ground_permanent)
	ser_bool(s, &v.on_ground_for_law)
	ser_u8(s, &v.bg.status)
	ser_as(s, &v.bg.poly, i16)
	ser_bool(s, &v.bg.test_result)
	ser_bool(s, &v.fired)
	ser_as(s, &v.burst_count, i16)
	ser_bool(s, &v.grenade_can_throw)
	ser_bool(s, &v.can_auto_reload_spas)
	ser_bool(s, &v.auto_reload_when_can_fire)
	ser_u8(s, &v.collider_distance)
	ser_u16(s, &v.hit_spray)
	ser_as(s, &v.idle.time, i16)
	ser_as(s, &v.idle.random, u8)
	ser_as(s, &v.legs.count, u8)
	ser_as(s, &v.body.count, u8)
}

// A command without its number: they are consecutive, so the packet carries the first
// and the rest follow from it.
ser_cmd :: proc(s: ^Stream, v: ^sim.Command) {
	ser_buttons(s, &v.buttons)
	ser_vec2(s, &v.aim)
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
	ser_as(s, &m.respawn_time, i16)
	ser_as(s, &m.max_grenades, u8)
	ser_as(s, &m.score_limit, u16)
	ser_bool(s, &m.friendly_fire)
	ser_bool(s, &m.kits_collide)
}

ser_denied :: proc(s: ^Stream, m: ^Denied) {
	ser_string(s, &m.reason)
}

// Its length in a byte, then the bytes; read, filtered as text_set does.
ser_text :: proc(s: ^Stream, t: ^Text($N)) {
	ser_u8(s, &t.len)
	if !s.writing && int(t.len) > N {
		s.failed, t.len = true, 0
		return
	}
	b := take(s, int(t.len))
	if b == nil do return
	if s.writing do copy(b, t.bytes[:t.len])
	else do text_set(t, string(b))
}

ser_roster :: proc(s: ^Stream, m: ^Roster) {
	ser_u32(s, &m.bots)
	ser_count(s, &m.count, sim.MAX_PLAYERS)
	for i in 0 ..< m.count {
		ser_u8(s, &m.slots[i])
		if !s.writing && int(m.slots[i]) >= sim.MAX_PLAYERS do s.failed = true
		ser_text(s, &m.names[i])
	}
}

ser_input :: proc(s: ^Stream, m: ^Input) {
	ser_u32(s, &m.view_tick)
	ser_u32(s, &m.first)
	ser_count(s, &m.count, MAX_CMDS_PER_INPUT)
	for i in 0 ..< m.count {
		ser_cmd(s, &m.cmds[i])
		if !s.writing do m.cmds[i].seq = m.first + u32(i)
	}
}

ser_chat :: proc(s: ^Stream, m: ^Chat) {
	ser_u8(s, &m.slot)
	ser_bool(s, &m.team)
	ser_text(s, &m.text)
}

ser_act :: proc(s: ^Stream, m: ^Act) {
	ser_enum(s, &m.action)
	ser_enum(s, &m.weapon)
	ser_enum(s, &m.second)
	ser_enum(s, &m.team)
}

ser_vote :: proc(s: ^Stream, m: ^Vote) {
	ser_enum(s, &m.kind)
	ser_u8(s, &m.target)
	ser_text(s, &m.name)
	ser_text(s, &m.reason)
}

ser_vote_state :: proc(s: ^Stream, m: ^Vote_State) {
	ser_enum(s, &m.kind)
	ser_bool(s, &m.active)
	ser_u8(s, &m.target)
	ser_text(s, &m.name)
	ser_u8(s, &m.starter)
	ser_text(s, &m.reason)
	ser_as(s, &m.ticks, i32)
	ser_u8(s, &m.votes)
	ser_u8(s, &m.needed)
}

ser_map_name :: proc(s: ^Stream, m: ^Map_Name) {
	ser_u16(s, &m.index)
	ser_u16(s, &m.count)
	ser_text(s, &m.name)
}

ser_update :: proc(s: ^Stream, m: ^Update) {
	ser_u32(s, &m.tick)
	ser_u32(s, &m.ack)
	ser_u8(s, &m.depth)
	ser_enum(s, &m.match.state)
	ser_as(s, &m.match.time_left, i32)
	ser_as(s, &m.match.counter, i16)
	ser_as(s, &m.match.scores[.Alpha], u16)
	ser_as(s, &m.match.scores[.Bravo], u16)
	ser_u32(s, &m.active)
	for i in 0 ..< sim.MAX_PLAYERS do if m.active & (1 << u32(i)) != 0 do ser_u8(s, &m.lags[i])
	ser_count(s, &m.entry_count, sim.MAX_PLAYERS)
	for i in 0 ..< m.entry_count {
		e := &m.entries[i]
		ser_u8(s, &e.slot)
		if !s.writing && int(e.slot) >= sim.MAX_PLAYERS do s.failed = true
		ser_bool(s, &e.has_owned)
		ser_bool(s, &e.has_rest)
		ser_served(s, &e.soldier)
		if e.has_owned do ser_owned(s, &e.soldier)
		if e.has_rest do ser_rest(s, &e.soldier)
	}
	ser_count(s, &m.fired_count, MAX_SHOTS_PER_UPDATE)
	for i in 0 ..< m.fired_count do ser_fired(s, &m.fired[i])
	ser_count(s, &m.end_count, MAX_ENDS_PER_UPDATE)
	for i in 0 ..< m.end_count {
		e := &m.ends[i]
		ser_u32(s, &e.shot)
		ser_vec2(s, &e.pos)
		ser_bool(s, &e.impact)
	}
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
	case .Chat:       msg^ = Chat{}
	case .Update:     msg^ = Update{}
	case .Things:     msg^ = Things{}
	case .Facts:      msg^ = Facts{}
	case .Vote:       msg^ = Vote{}
	case .Vote_State: msg^ = Vote_State{}
	case .Map_Query:  msg^ = Map_Query{}
	case .Map_Name:   msg^ = Map_Name{}
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
	case Chat:       ser_chat(s, &m)
	case Update:     ser_update(s, &m)
	case Things:     ser_things(s, &m)
	case Facts:      ser_facts(s, &m)
	case Vote:       ser_vote(s, &m)
	case Vote_State: ser_vote_state(s, &m)
	case Map_Query:  ser_u16(s, &m.index)
	case Map_Name:   ser_map_name(s, &m)
	}
}
