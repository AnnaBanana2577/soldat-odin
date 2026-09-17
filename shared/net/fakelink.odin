package net

import "core:time"
import "../sim"

// A simulated bad line for testing, on one side of a connection: every packet it
// sends or receives waits the one-way delay plus a random share of the jitter, and
// unreliable ones are lost at the loss rate. Reliable packets are never lost and
// never overtake each other, as ENet delivers them; unreliable ones may arrive out
// of order, as they do on a real line.
Fake_Link :: struct {
	on:       bool,
	one_way:  time.Duration,
	jitter:   time.Duration,
	loss:     f32, // 0..1
	rng:      u64,
	outgoing: [dynamic]Held, // waiting to go out
	incoming: [dynamic]Held, // arrived, waiting to be handed over
	reliable_out, reliable_in: time.Tick, // the last reliable due, so the next is not sooner
}

Held :: struct {
	due:      time.Tick,
	data:     []u8, // owned by the queue until released
	reliable: bool,
}

// `ping` is the round trip; half of it is spent each way.
fake_init :: proc(l: ^Fake_Link, ping_ms, jitter_ms, loss_percent: f64) {
	l.on = ping_ms > 0 || jitter_ms > 0 || loss_percent > 0
	l.one_way = time.Duration(ping_ms / 2 * f64(time.Millisecond))
	l.jitter = time.Duration(jitter_ms * f64(time.Millisecond))
	l.loss = f32(clamp(loss_percent / 100, 0, 1))
	l.rng = 0x2545F4914F6CDD1D
}

fake_destroy :: proc(l: ^Fake_Link) {
	for h in l.outgoing do delete(h.data)
	for h in l.incoming do delete(h.data)
	delete(l.outgoing)
	delete(l.incoming)
}

// Queues a packet, or drops it: false means the queue did not take `data`.
fake_hold :: proc(l: ^Fake_Link, queue: ^[dynamic]Held, last_reliable: ^time.Tick, data: []u8, reliable: bool) -> bool {
	if !reliable && sim.rand_f32(&l.rng) < l.loss do return false
	delay := l.one_way + time.Duration(sim.rand_f32(&l.rng) * f32(l.jitter))
	due := time.Tick{_nsec = time.tick_now()._nsec + i64(delay)}
	if reliable {
		if due._nsec < last_reliable._nsec do due = last_reliable^
		last_reliable^ = due
	}
	append(queue, Held{due, data, reliable})
	return true
}

// Moves what is due into `out`, earliest first; the caller owns their data now.
fake_release :: proc(queue: ^[dynamic]Held, out: ^[dynamic]Held) {
	now := time.tick_now()._nsec
	for {
		best := -1
		for h, i in queue {
			if h.due._nsec > now do continue
			if best < 0 || h.due._nsec < queue[best].due._nsec do best = i
		}
		if best < 0 do return
		append(out, queue[best])
		ordered_remove(queue, best)
	}
}
