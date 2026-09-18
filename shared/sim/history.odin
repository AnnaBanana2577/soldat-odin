package sim

// Where everyone was over the last second, kept on the server so a shot is judged
// against the soldiers as its shooter saw them. A client shows the others some ticks
// behind the present and says how many with each command; a bullet it fires carries
// that lag and meets the soldiers from that many ticks ago, out of this ring, for
// as long as it flies. A world without a history (a client's) judges against the
// present.

HISTORY_TICKS :: 64

History :: struct {
	frames: [HISTORY_TICKS][MAX_PLAYERS]Soldier, // by tick modulo the ring
	tick:   u32, // the newest frame's
	count:  u32,
}

// The soldiers as they stand, filed under the world's tick.
history_record :: proc(h: ^History, w: ^World) {
	h.frames[w.tick % HISTORY_TICKS] = w.soldiers
	h.tick = w.tick
	h.count = min(h.count + 1, HISTORY_TICKS)
}

// The soldiers a bullet with this lag meets: the frame that many ticks before the
// present, or the present itself where there is no history to rewind.
targets :: proc(w: ^World, lag: u8) -> ^[MAX_PLAYERS]Soldier {
	h := w.history
	if h == nil || lag == 0 || u32(lag) >= h.count || u32(lag) > w.tick do return &w.soldiers
	return &h.frames[(w.tick - u32(lag)) % HISTORY_TICKS]
}

// One of the soldiers a bullet meets, out of the frame `targets` gave. Its own shooter
// is the exception: a client sees the others its lag ago but itself where it is, so
// the shooter is taken from the present. Rewound with the rest, a thrower who backed
// off from its grenade stood in the blast on the server alone.
target_soldier :: proc(w: ^World, frame: ^[MAX_PLAYERS]Soldier, owner: u8, i: int) -> ^Soldier {
	return i == int(owner) ? &w.soldiers[i] : &frame[i]
}
