package server

import "../shared/sim"

// A client's commands, in order, and which of them the sim runs on a given tick.
//
// The rule that matters: when the queue is empty for a living soldier, the soldier is
// not stepped at all. Its commands are in flight, and a soldier left exactly as it is
// ends up where its client predicted, however late they come. Stepping it with anything
// else (the last command again, a neutral one) moves it here where the client did not,
// and every such tick is a correction the client has to swallow when the commands land:
// that is the pull-back a player feels under packet loss.
//
// A burst that lands after a stall runs in one tick, down to the depth the client's
// clock aims for, so the stall costs nothing lasting. A client that has said nothing
// for half a second has gone away (a hidden window, a dead link) and its keys are let
// go, so its soldier falls and stops instead of hanging in the air.
Queue :: struct {
	cmds:     [MAX_DEPTH]sim.Command, // oldest first
	count:    int,
	last:     sim.Command, // the newest run: what a quiet client's soldier holds
	last_seq: u32,         // its number, which the client hears back as the update's ack
	depth:    u8,          // the depth the last take saw: the client steers its clock by it
	starved:  int,         // ticks running with nothing to run
}

MAX_DEPTH     :: 64 // about a second: a client further behind than that has lost its place
CATCH_UP_FROM :: 4  // from this depth more than one command runs in a tick...
CATCH_UP_KEEP :: 2  // ...down to this, which is what the client's clock holds (CLOCK_TARGET)
MAX_CATCH_UP  :: 32
IDLE_AFTER    :: 30 // starved ticks before a quiet client's keys are let go: half a second

// The commands of a packet that the queue has not seen, in order. The oldest go when
// there is no room: a client that far behind has lost its place anyway.
queue_push :: proc(q: ^Queue, cmds: []sim.Command) {
	newest := q.count > 0 ? q.cmds[q.count - 1].seq : q.last_seq
	for cmd in cmds {
		if cmd.seq <= newest do continue
		if q.count == MAX_DEPTH {
			copy(q.cmds[:], q.cmds[1:])
			q.count -= 1
		}
		q.cmds[q.count] = cmd
		q.count += 1
		newest = cmd.seq
	}
}

// What to run this tick, into `buf`: usually one command, several when a burst has
// arrived after a stall, and none at all while a living soldier's commands are in
// flight.
queue_take :: proc(q: ^Queue, buf: []sim.Command) -> []sim.Command {
	q.depth = u8(min(q.count, 255))
	if q.count == 0 {
		q.starved += 1
		if q.starved <= IDLE_AFTER do return buf[:0] // in flight: the soldier waits where it is
		q.last.buttons = {}                          // gone quiet: the keys let go
		buf[0] = q.last
		return buf[:1]
	}
	q.starved = 0
	take := 1
	if q.count >= CATCH_UP_FROM do take = min(q.count - CATCH_UP_KEEP, min(MAX_CATCH_UP, len(buf)))
	copy(buf[:take], q.cmds[:take])
	copy(q.cmds[:], q.cmds[take:q.count])
	q.count -= take
	q.last = buf[take - 1]
	q.last_seq = q.last.seq
	return buf[:take]
}
