package server

import "../shared/net"
import "../shared/sim"

// What the server keeps for talking to its clients, as against what it keeps for
// simulating the game. The host below this (sv_connection) carries bytes; this is what
// is owed to whom: who is in which slot, what each of them has yet to be told of, and
// the scratch an Update is built in.
//
// The bots take slots here too, with no peer behind them, so the game can step a bot
// and a player the same way and only the sending has to know the difference.
Wire :: struct {
	clients:     [sim.MAX_PLAYERS]Client,
	born:        [dynamic]Born,            // bullets born lately, each told a few updates running
	ends:        [dynamic]Ended,           // where the clients' own bullets ended, told back
	shot_seq:    [sim.MAX_PLAYERS]u32,     // the last number given to each shooter's bullets
	things_sent: [sim.MAX_THINGS]sim.Thing, // as the clients last heard them

	incoming, outgoing: net.Message, // scratch: an Update is too large for the stack
	buf: [net.MAX_PACKET]u8,
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

wire_destroy :: proc(w: ^Wire) {
	delete(w.born)
	delete(w.ends)
}
