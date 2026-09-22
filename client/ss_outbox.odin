package client

import "../shared/net"
import "../shared/sim"

// What a client has to tell the server that is not its keys: the weapons and the team it
// chose, the votes it called or agreed to, the maps it asked the name of, and what it
// said. Each of these is told once and cleared, where the commands go every tick and are
// the game's own (game/send).
//
// Nothing here knows what a Game is. The game holds an Outbox and puts things in it; the
// HUD, which is where most of them are chosen, reaches it the same way.
Outbox :: struct {
	acts:   [dynamic]net.Act,       // what I chose, to tell once
	called: [dynamic]net.Vote,      // the votes I called or agreed to
	asked:  [dynamic]net.Map_Query, // the maps I asked the name of
	said:   [dynamic]net.Chat,      // what I said
}

outbox_destroy :: proc(o: ^Outbox) {
	delete(o.acts)
	delete(o.called)
	delete(o.asked)
	delete(o.said)
}

outbox_loadout :: proc(o: ^Outbox, primary, secondary: sim.Weapon_Id) {
	append(&o.acts, net.Act{action = .Loadout, weapon = primary, second = secondary})
}

outbox_join_team :: proc(o: ^Outbox, team: sim.Team) {
	append(&o.acts, net.Act{action = .Join_Team, team = team})
}

outbox_say :: proc(o: ^Outbox, line: string, team: bool) {
	chat := net.Chat{team = team}
	net.text_set(&chat.text, line)
	append(&o.said, chat)
}

outbox_vote :: proc(o: ^Outbox, v: net.Vote) {
	append(&o.called, v)
}

outbox_ask_map :: proc(o: ^Outbox, index: int) {
	append(&o.asked, net.Map_Query{index = u16(max(index, 0))})
}

// Everything waiting, told and then forgotten, in the order it was told in before.
outbox_send :: proc(o: ^Outbox, c: ^Connection) {
	for a in o.acts do connection_send_message(c, a)
	for v in o.called do connection_send_message(c, v)
	for q in o.asked do connection_send_message(c, q)
	clear(&o.called)
	clear(&o.asked)
	for s in o.said do connection_send_message(c, s)
	clear(&o.said)
	clear(&o.acts)
}
