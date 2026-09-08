package sim

// The parachute a high spawn gets: carried until the ground, slowing the fall, then
// left behind to fade. The soldier owns its release (para is a client-owned field);
// the server only deploys it with the spawn. Port of the parachute parts of
// things.lua and soldier.lua.

PARA_SPEED   :: 0.15
PARA_TIMEOUT :: 180

parachute_deploy :: proc(ctx: ^Context, w: ^World, soldier: u8) {
	s := &w.soldiers[soldier]
	if s.para != 0 do return
	index, ok := thing_create(ctx, w, .Parachute, s.pos)
	if !ok do return
	w.things[index].holder = soldier + 1
	s.para = u8(index) + 1
}

parachute_update :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, events: ^Events) {
	if t.holder > 0 {
		h := &w.soldiers[t.holder - 1]
		if !h.active || h.dead || h.para != index + 1 {
			t.holder = 0
			t.timeout = PARA_TIMEOUT
		} else {
			t.pos[0] = h.pos // TODO the head from the pose; the canopy lifted by the fall speed
		}
	}
	if !t.static do thing_physics(ctx, w, t, events)
	if t.holder == 0 {
		t.timeout -= 1
		if t.timeout <= 0 do thing_clear(t)
	}
}

// The carrier's side, in its own step: slowed while falling, let go on the ground.
parachute_carry :: proc(w: ^World, s: ^Soldier) {
	if s.para == 0 do return
	t := &w.things[s.para - 1]
	if t.style != .Parachute do s.para = 0
	else if s.on_ground do s.para = 0
	else do s.forces.y = PARA_SPEED
}
