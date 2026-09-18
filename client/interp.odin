package client

import "../shared/net"

// The snapshots as they arrive, and the delayed clock the others are shown on.
//
// The latest snapshot is where prediction starts from. Everything not predicted is
// shown a few ticks behind it, at the render tick, blended between the two snapshots
// around it, so a snapshot lost or late leaves nothing to guess. The render tick runs
// at one tick per tick, nudged faster or slower to stay the target distance behind
// whatever is newest, and the server's events play as the render tick reaches their
// tick. The client and server never agree on a clock: the render tick is the only one
// that counts, and it is measured in the server's ticks as the snapshots name them.
//
// A snapshot arrives as a delta against an earlier one, so the ring keeps a second of
// them and a delta whose base is gone is dropped; the next input tells the server
// what is held and the next delta is against that.
Snapshots :: struct {
	ring:        ^[SNAPSHOT_RING]net.Snapshot, // by tick modulo the ring
	incoming:    ^net.Snapshot,                // decoded here first, so a bad packet touches nothing
	latest:      u32,                          // the newest tick held
	any:         bool,
	render_tick: f64,
	target:      f64,  // ticks behind the newest snapshot the render tick keeps
	fixed:       bool, // -interp-ticks: the target stays put
	margins:     [MARGIN_WINDOW]f32, // how far ahead of the render tick each newest snapshot arrived
	margin_n:    int,
	margin_at:   int,
}

SNAPSHOT_RING :: 64
TARGET_BEHIND :: 2 * net.SNAPSHOT_EVERY + 1 // render ticks behind the latest snapshot to start from: two snapshots and a little
MARGIN_WINDOW :: 60 // newest snapshots: two seconds of them
MARGIN_NEED   :: f32(net.SNAPSHOT_EVERY + 1) // a snapshot should arrive at least this far ahead of the render tick
TARGET_QUEUE  :: 2 // commands waiting at the server when a tick begins

snapshots_init :: proc(s: ^Snapshots, fixed_ticks: int) {
	s.target = fixed_ticks > 0 ? f64(fixed_ticks) : TARGET_BEHIND
	s.fixed = fixed_ticks > 0
	s.ring = new([SNAPSHOT_RING]net.Snapshot)
	s.incoming = new(net.Snapshot)
}

snapshots_destroy :: proc(s: ^Snapshots) {
	free(s.ring)
	free(s.incoming)
}

// Decodes a snapshot into the ring, over the copy of its base. Returns it, or nil for
// a bad, stale or undecodable packet.
snapshots_receive :: proc(s: ^Snapshots, r: ^net.Reader) -> ^net.Snapshot {
	tick, base_tick := net.decode_snapshot_head(r)
	if s.any && tick + SNAPSHOT_RING <= s.latest do return nil
	base: ^net.Snapshot
	if base_tick != 0 {
		base = snapshots_at(s, base_tick)
		if base == nil do return nil
		s.incoming^ = base^
	} else {
		s.incoming^ = {}
	}
	if !net.decode_snapshot(r, s.incoming, tick, base_tick, base) do return nil
	slot := &s.ring[tick % SNAPSHOT_RING]
	slot^ = s.incoming^
	if !s.any || tick > s.latest {
		if s.any {
			s.margins[s.margin_at] = f32(f64(tick) - s.render_tick)
			s.margin_at = (s.margin_at + 1) % MARGIN_WINDOW
			s.margin_n = min(s.margin_n + 1, MARGIN_WINDOW)
		}
		s.latest = tick
		if !s.any {
			s.render_tick = f64(tick) - s.target
		}
		s.any = true
	}
	return slot
}

snapshots_latest :: proc(s: ^Snapshots) -> ^net.Snapshot {
	return s.any ? snapshots_at(s, s.latest) : nil
}

// The snapshot of a tick, if it is still held.
snapshots_at :: proc(s: ^Snapshots, tick: u32) -> ^net.Snapshot {
	if !s.any || tick > s.latest || tick + SNAPSHOT_RING <= s.latest do return nil
	snap := &s.ring[tick % SNAPSHOT_RING]
	return snap.tick == tick ? snap : nil
}

// One tick of the render clock, leaning toward the target distance behind the latest.
// The target follows the line: each newest snapshot should arrive with the render tick
// still MARGIN_NEED behind it, so there is always one past it to blend toward. When the
// earliest arrival of the last two seconds cut it closer, the target grows by the
// shortfall; with room to spare it shrinks slowly. The more the line jitters, the
// further behind the world is shown, and no further.
snapshots_advance :: proc(s: ^Snapshots) {
	if !s.any do return
	if !s.fixed && s.margin_n >= 10 {
		lowest := max(f32)
		for m in s.margins[:s.margin_n] do lowest = min(lowest, m)
		if lowest < MARGIN_NEED do s.target += f64(MARGIN_NEED - lowest) * 0.05
		else if lowest > MARGIN_NEED + 2 do s.target -= 0.01
		s.target = clamp(s.target, f64(MARGIN_NEED), 60)
	}
	want := f64(s.latest) - s.target
	s.render_tick += 1 + clamp((want - s.render_tick) * 0.1, -0.25, 0.25)
}

// The snapshots on either side of the render tick, the nearest held, and how far
// between them it is. With nothing held past the render tick the earlier one stands
// in for both, so a gap holds still.
snapshots_bracket :: proc(s: ^Snapshots) -> (a, b: ^net.Snapshot, t: f32) {
	tick := u32(s.render_tick)
	for back in 0 ..< u32(SNAPSHOT_RING) {
		if back > tick do break
		if a = snapshots_at(s, tick - back); a != nil do break
	}
	if a == nil do return nil, nil, 0
	for ahead in 1 ..= u32(SNAPSHOT_RING) {
		if tick + ahead > s.latest do break
		if b = snapshots_at(s, tick + ahead); b != nil do break
	}
	if b == nil do return a, a, 0
	return a, b, f32((s.render_tick - f64(a.tick)) / f64(b.tick - a.tick))
}

// The world as it is shown: the snapshot before the render tick, its soldiers and
// bullets blended toward the one after, each with a tick's worth of motion behind it
// for drawing between ticks. False with nothing held yet.
snapshots_shown :: proc(s: ^Snapshots, out: ^net.Snapshot) -> bool {
	a, b, t := snapshots_bracket(s)
	if a == nil do return false
	out^ = a^
	span := f32(max(b.tick - a.tick, 1)) // ticks between the two, for a tick's worth of motion
	for &so, i in out.soldiers {
		sb := &b.soldiers[i]
		if !so.active || so.dead || !sb.active || sb.dead do continue
		step := sb.pos - so.pos
		so.pos += step * t
		so.old_pos = so.pos - step / span
		so.aim += (sb.aim - so.aim) * t
	}
	for &bl, i in out.bullets {
		bb := &b.bullets[i]
		if !bl.active || !bb.active || bb.owner != bl.owner do continue
		step := bb.pos - bl.pos
		bl.pos += step * t
		bl.old_pos = bl.pos - step / span
	}
	return true
}
