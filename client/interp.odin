package client

import "../shared/net"

// The snapshots as they arrive, and the delayed clock the others are shown on.
//
// The latest snapshot is where prediction starts from. The others are shown a few
// ticks behind it, at the render tick, blended between the two snapshots around it,
// so a snapshot lost or late leaves nothing to guess. The render tick runs at one tick
// per tick, nudged faster or slower to stay the target distance behind whatever is
// newest, and the events are applied as the render tick passes their snapshots. The
// client and server never agree on a clock: the render tick is the only one that
// counts, and it is measured in the server's ticks as the snapshots name them.
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
	applied:     u32, // events applied up to this tick
}

SNAPSHOT_RING :: 64
TARGET_BEHIND :: 2 * net.SNAPSHOT_EVERY + 1 // render ticks behind the latest snapshot: two snapshots and a little
TARGET_QUEUE  :: 2 // commands waiting at the server when a tick begins

snapshots_init :: proc(s: ^Snapshots) {
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
		s.latest = tick
		if !s.any {
			s.render_tick = f64(tick) - TARGET_BEHIND
			s.applied = tick
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
snapshots_advance :: proc(s: ^Snapshots) {
	if !s.any do return
	want := f64(s.latest) - TARGET_BEHIND
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

// The snapshots whose tick the render clock passed since the last call, oldest first,
// for their events.
snapshots_passed :: proc(s: ^Snapshots, out: ^[dynamic]^net.Snapshot) {
	clear(out)
	if !s.any do return
	upto := u32(s.render_tick)
	for tick := s.applied + 1; tick <= upto; tick += 1 {
		if snap := snapshots_at(s, tick); snap != nil do append(out, snap)
	}
	if upto > s.applied do s.applied = upto
}
