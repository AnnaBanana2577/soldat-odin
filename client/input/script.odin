package input

import "../../shared/sim"

// Scripted input for the headless client (-headless), to test the netcode without a
// person: every quarter to three quarters of a second it picks new keys (running left
// or right or standing, now and then jumping or jetting), and it aims at the nearest
// enemy with some spread, firing in bursts. Barely a brain: the point is a player that
// moves and shoots like one, so the prediction and the server's judging of its hits
// have something to do. Seeded, so a run can be repeated.
Script :: struct {
	rng:    u64,
	held:   sim.Buttons,
	left:   int, // ticks until the next change
	firing: bool,
}

script_init :: proc(s: ^Script, seed: u64) {
	s^ = {rng = seed | 1}
}

// This tick's keys, and the aim, for the soldier in slot `me` of `w`.
script_sample :: proc(s: ^Script, in_: ^Input, w: ^sim.World, me: u8) {
	s.left -= 1
	if s.left <= 0 {
		s.left = 15 + sim.rand_int(&s.rng, 30)
		s.held = {}
		switch sim.rand_int(&s.rng, 3) {
		case 0: s.held += {.Left}
		case 1: s.held += {.Right}
		}
		if sim.rand_int(&s.rng, 4) == 0 do s.held += {.Jump}
		if sim.rand_int(&s.rng, 3) == 0 do s.held += {.Jet}
		s.firing = sim.rand_int(&s.rng, 2) == 0
	}
	held := s.held
	self := &w.soldiers[me]
	in_.aim = self.pos + {f32(self.direction) * 100, 0}
	if target := nearest_enemy(w, me); target != nil {
		in_.aim = target.pos + {(sim.rand_f32(&s.rng) * 2 - 1) * 12, -8 + (sim.rand_f32(&s.rng) * 2 - 1) * 10}
		if s.firing do held += {.Fire}
	}
	in_.pressed += (held - in_.held) & sim.ONE_SHOT
	in_.held = held
}

@(private = "file")
nearest_enemy :: proc(w: ^sim.World, me: u8) -> ^sim.Soldier {
	self := &w.soldiers[me]
	best: ^sim.Soldier
	best_d := f32(650) // no further than a bot fires
	for &o, i in w.soldiers {
		if u8(i) == me || !o.active || o.dead || o.team == self.team do continue
		if d := sim.vec2_length(o.pos - self.pos); d < best_d do best, best_d = &o, d
	}
	return best
}
