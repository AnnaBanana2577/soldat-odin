package client

import "../shared/net"

// The snapshots as they arrive, and the delayed clock the others are shown on.
//
// The latest snapshot is where prediction starts from. The others are shown a few
// ticks behind it, at the render tick, blended between the two snapshots around it,
// so a snapshot lost or late leaves nothing to guess. The render tick runs at one tick
// per tick, nudged faster or slower to stay the target distance behind whatever is
// newest, and the tick's events are applied as the render tick passes them. The
// client and server never agree on a clock: the render tick is the only one that
// counts, and it is measured in the server's ticks as the snapshots name them.
Snapshots :: struct {
	ring:        ^[SNAPSHOT_RING]net.Snapshot, // by tick modulo the ring
	incoming:    ^net.Snapshot,                // decoded here first, so a bad packet touches nothing
	latest:      u32,                          // the newest tick held
	any:         bool,
	render_tick: f64,
	applied:     u32, // events applied up to this tick
}

SNAPSHOT_RING :: 32
TARGET_BEHIND :: 3.0 // render ticks behind the latest snapshot
TARGET_QUEUE  :: 2   // commands waiting at the server when a tick begins

snapshots_init :: proc(s: ^Snapshots) {
	s.ring = new([SNAPSHOT_RING]net.Snapshot)
	s.incoming = new(net.Snapshot)
}

snapshots_destroy :: proc(s: ^Snapshots) {
	free(s.ring)
	free(s.incoming)
}

// Decodes a snapshot into the ring. Returns it, or nil for a bad or stale packet.
snapshots_receive :: proc(s: ^Snapshots, r: ^net.Reader) -> ^net.Snapshot {
	if !net.decode_snapshot(r, s.incoming) do return nil
	tick := s.incoming.tick
	if s.any && tick + SNAPSHOT_RING <= s.latest do return nil
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

// The two snapshots around the render tick and how far between them it is. The later
// one is the earlier again when nothing newer is held, so a gap holds still.
snapshots_bracket :: proc(s: ^Snapshots) -> (a, b: ^net.Snapshot, t: f32) {
	tick := u32(s.render_tick)
	a = snapshots_at(s, tick)
	if a == nil do return nil, nil, 0
	b = snapshots_at(s, tick + 1)
	if b == nil do b = a
	return a, b, f32(s.render_tick - f64(tick))
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
