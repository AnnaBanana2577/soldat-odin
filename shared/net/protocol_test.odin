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

	u := Update{tick = 1234, your_lag = 7, active = 0b101}
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

// A client's packet is never trusted: one that is short, long, names a weapon that does
// not exist or says it stands at not-a-number is refused whole.
@(test)
bad_input_refused :: proc(t: ^testing.T) {
	sent, back := new(Message), new(Message)
	defer free(sent)
	defer free(back)
	in_ := Input{life = 1, view_tick = 50, has_state = true}
	in_.soldier.pos = {5, 6}
	in_.shots[0] = {id = 1, weapon = .MP5, pos = {5, 6}, vel = {20, 0}}
	in_.shot_count = 1
	sent^ = in_
	good: [MAX_PACKET]u8
	size, _ := encode(good[:], sent)
	testing.expect(t, decode(good[:size], back), "as written, it is taken")

	testing.expect(t, !decode(good[:size - 1], back), "short")
	testing.expect(t, !decode(good[:size + 1], back), "long")

	bad := good
	weapon_at := size - 16 - 1 // the shot ends with its two vectors; its weapon is the byte before
	testing.expect(t, bad[weapon_at] == u8(sim.Weapon_Id.MP5))
	bad[weapon_at] = 200
	testing.expect(t, !decode(bad[:size], back), "a weapon that does not exist")

	in_.soldier.pos.x = math.nan_f32()
	sent^ = in_
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
	testing.expect(t, name_string(&got.names[0]) == "Major")
	testing.expect(t, len(name_string(&got.names[1])) == MAX_NAME)
	testing.expect(t, name_string(&got.names[2]) == "tab?here")
}
