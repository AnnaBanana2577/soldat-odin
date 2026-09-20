package net

import "core:math"
import "core:slice"
import "core:testing"
import "../sim"

// What is written reads back, and what read back writes the same bytes.
@(test)
update_round_trip :: proc(t: ^testing.T) {
	sent, back := new(Message), new(Message)
	defer free(sent)
	defer free(back)

	u := Update{tick = 1234, ack = 99, depth = 3, active = 0b101}
	u.lags[0], u.lags[2] = 7, 9
	u.round.time_left = 99
	u.round.scores[.Bravo] = 3
	e := &u.entries[0]
	e^ = {slot = 2, has_owned = true}
	e.soldier.active = true
	e.soldier.life = 3
	e.soldier.team = .Bravo
	e.soldier.health = 61.5
	e.soldier.pos = {10.5, -3}
	e.soldier.controls = {.Left, .Jet, .Fire}
	e.soldier.direction = -1
	e.soldier.jets = 37
	e.soldier.legs = {id = .Run, frame = 5}
	e.soldier.weapon = {id = .AK74, ammo = 12}
	u.entry_count = 1
	u.fired[0] = {shooter = 1, seq = 9, age = 2, lag = 5, weapon = .Barrett, pos = {1, 2}, vel = {3, 4}}
	u.fired_count = 1
	sent^ = u

	first, second: [MAX_PACKET]u8
	size, ok := encode(first[:], sent)
	testing.expect(t, ok, "an update encodes")
	testing.expect(t, decode(first[:size], back), "and decodes")
	size2, ok2 := encode(second[:], back)
	testing.expect(t, ok2 && slice.equal(first[:size], second[:size2]), "to the same bytes")

	got := back.(Update)
	s := &got.entries[0].soldier
	testing.expect(t, got.lags[0] == 7 && got.lags[2] == 9)
	testing.expect(t, got.ack == 99 && got.depth == 3)
	testing.expect(t, got.tick == 1234 && got.active == 0b101 && got.entry_count == 1 && got.fired_count == 1)
	testing.expect(t, s.life == 3 && s.team == .Bravo && s.health == 61.5 && s.pos == {10.5, -3})
	testing.expect(t, s.controls == {.Left, .Jet, .Fire} && s.direction == -1 && s.jets == 37)
	testing.expect(t, s.legs.id == .Run && s.legs.frame == 5 && s.weapon.id == .AK74 && s.weapon.ammo == 12)
	testing.expect(t, got.fired[0].weapon == .Barrett && got.fired[0].seq == 9 && got.fired[0].vel == {3, 4})
}

@(test)
facts_round_trip :: proc(t: ^testing.T) {
	sent, back := new(Message), new(Message)
	defer free(sent)
	defer free(back)
	f: Facts
	f.events[0] = sim.Respawn{target = 4, life = 9, team = .Alpha, primary = .Steyr, secondary = .Knife, pos = {7, 8}}
	f.events[1] = sim.Flag_Return{player = 255, flag = .Alpha_Flag, pos = {1, 1}} // nobody: it timed out
	f.count = 2
	sent^ = f
	buf: [MAX_PACKET]u8
	size, ok := encode(buf[:], sent)
	testing.expect(t, ok && decode(buf[:size], back))
	got := back.(Facts)
	r, is_respawn := got.events[0].(sim.Respawn)
	testing.expect(t, is_respawn && r.target == 4 && r.life == 9 && r.primary == .Steyr && r.pos == {7, 8})
	ret, is_return := got.events[1].(sim.Flag_Return)
	testing.expect(t, is_return && ret.player == 255)
}

// A client's packet is never trusted: one that is short, long, or aims at
// not-a-number is refused whole.
@(test)
bad_input_refused :: proc(t: ^testing.T) {
	sent, back := new(Message), new(Message)
	defer free(sent)
	defer free(back)
	in_ := Input{view_tick = 50, first = 7, count = 2}
	in_.cmds[0] = {seq = 7, buttons = {.Left, .Fire}, aim = {5, 6}}
	in_.cmds[1] = {seq = 8, buttons = {.Jet}, aim = {7, 8}}
	sent^ = in_
	good: [MAX_PACKET]u8
	size, _ := encode(good[:], sent)
	testing.expect(t, decode(good[:size], back), "as written, it is taken")
	got := back.(Input)
	testing.expect(t, got.count == 2 && got.cmds[1].seq == 8 && got.cmds[0].buttons == {.Left, .Fire})

	testing.expect(t, !decode(good[:size - 1], back), "short")
	testing.expect(t, !decode(good[:size + 1], back), "long")

	in_.cmds[0].aim.x = math.nan_f32()
	sent^ = in_
	bad: [MAX_PACKET]u8
	size, _ = encode(bad[:], sent)
	testing.expect(t, !decode(bad[:size], back), "not a number")
}

// Names come back as they went, cut to what a Name holds and with what the font cannot
// draw replaced.
@(test)
roster_round_trip :: proc(t: ^testing.T) {
	sent, back := new(Message), new(Message)
	defer free(sent)
	defer free(back)
	r: Roster
	r.slots[0], r.names[0] = 3, name_make("Major")
	r.slots[1], r.names[1] = 9, name_make("a name much longer than a name may be")
	r.slots[2], r.names[2] = 0, name_make("tab\there")
	r.count = 3
	sent^ = r
	buf: [MAX_PACKET]u8
	size, ok := encode(buf[:], sent)
	testing.expect(t, ok && decode(buf[:size], back))
	got := back.(Roster)
	testing.expect(t, got.count == 3 && got.slots[1] == 9)
	testing.expect(t, text_string(&got.names[0]) == "Major")
	testing.expect(t, len(text_string(&got.names[1])) == MAX_NAME)
	testing.expect(t, text_string(&got.names[2]) == "tab?here")
}

// A line comes back as it was said, and a team request with its team.
@(test)
chat_and_team_round_trip :: proc(t: ^testing.T) {
	sent, back := new(Message), new(Message)
	defer free(sent)
	defer free(back)
	buf: [MAX_PACKET]u8

	chat := Chat{slot = 4, team = true}
	text_set(&chat.text, "gg, well played")
	sent^ = chat
	size, ok := encode(buf[:], sent)
	testing.expect(t, ok && decode(buf[:size], back))
	got := back.(Chat)
	testing.expect(t, got.slot == 4 && got.team && text_string(&got.text) == "gg, well played")

	sent^ = Act{action = .Join_Team, team = .Bravo}
	size, ok = encode(buf[:], sent)
	testing.expect(t, ok && decode(buf[:size], back))
	act := back.(Act)
	testing.expect(t, act.action == .Join_Team && act.team == .Bravo)
}
