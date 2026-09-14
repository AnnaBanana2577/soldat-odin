package net

// A simulated link for testing at a chosen ping: packets are held for the one-way
// lag plus jitter and unreliable ones are dropped at the loss rate. Wraps sending and
// receiving on the client's side.
Fake_Link :: struct {
	lag:    f64, // one-way seconds
	jitter: f64, // up to this much more, at random
	loss:   f64, // 0..1
	rng:    u64,
	inbox:  [dynamic]Held_Packet,
	outbox: [dynamic]Held_Packet,
}

Held_Packet :: struct {
	at:       f64, // when it may be delivered
	data:     []u8,
	channel:  u8,
	reliable: bool,
}

fakelink_enabled :: proc(l: ^Fake_Link) -> bool {
	return l.lag > 0 || l.jitter > 0 || l.loss > 0
}

// TODO hold and release: see shared/net/fakelink.lua for the reliable-channel stall
// model (a lost reliable packet costs a doubling retransmit timeout).
fakelink_delay :: proc(l: ^Fake_Link, reliable: bool) -> (delay: f64, dropped: bool) {
	return l.lag, false
}
