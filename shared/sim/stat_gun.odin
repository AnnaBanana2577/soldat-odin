package sim

// The stationary gun (M2): a standing soldier in reach takes it, fires it instead of
// the rifle, and leaves it by jumping or walking off. The soldier owns taking and
// leaving (stat is a client-owned field); the gun's own bullets are spawned by
// whoever runs the gun's world.
// Port of updateStatGun in things.lua.

STAT_RADIUS   :: 24.0
STAT_FIRE     :: 8
STAT_OVERHEAT :: 160

stat_gun_update :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, events: ^Events) {
	if !t.static do thing_physics(ctx, w, t, events)
	for &s in w.soldiers {
		if !s.active || s.dead || s.stat != index + 1 do continue
		if vec2_length(thing_center(t) - s.pos) >= STAT_RADIUS {
			s.stat = 0
			continue
		}
		t.static = true
		if .Fire in s.controls {
			// TODO the M2 burst from the barrel toward the aim, the heat, the overheat
		}
		return
	}
	t.static = false
}

// The soldier's side, in its own step: take a free gun in reach when standing.
stat_gun_take :: proc(w: ^World, index: u8, s: ^Soldier, events: ^Events) {
	if s.stat != 0 || s.legs.id != .Stand do return
	for &t, i in w.things {
		if t.style != .Stat_Gun || vec2_length(thing_center(&t) - s.pos) >= STAT_RADIUS do continue
		for &o, j in w.soldiers {
			if u8(j) != index && o.active && !o.dead && o.stat == u8(i) + 1 do return
		}
		s.stat = u8(i) + 1
		return
	}
}
