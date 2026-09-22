package client

import "../shared/sim"

// Scripted input for the headless client (-cl_headless), to test the netcode without a
// person: the bots' brain (sim/bot.odin) playing this client's soldier on the world as
// this client shows it. It walks the map's waypoints, fetches flags and fights like the
// server's bots, but through a real client and a real connection, so the server's
// judging of its shots and the flight of the bullets fired at it have something to do.
// Seeded, so a run can be repeated.
// The brains are made only by script_init, which only the headless run calls: a client
// with a person at the keyboard carries none of this, and no client ever runs a brain
// for anyone but itself. The bots of a game are the server's, and run there alone.
Script :: struct {
	brains: ^sim.Bots, // this client's own brain, among the empty ones a brain reads
	seed:   u64,
	prof:   sim.Bot_Profile,
}

script_init :: proc(s: ^Script, seed: u64, profiles: []sim.Bot_Profile) {
	s.brains = new(sim.Bots)
	s.seed = seed
	s.prof = sim.bot_profile_any(profiles, &s.seed)
}

// This tick's keys, and the aim, for the soldier in slot `me` of `w`. The slot is the
// server's to give, so the brain starts on the first tick that has one.
script_sample :: proc(s: ^Script, in_: ^Input, ctx: ^sim.Context, w: ^sim.World, me: u8) {
	if !s.brains[me].playing do sim.bot_init(&s.brains[me], s.prof, s.seed)
	cmd := sim.bot_command(s.brains, ctx, w, me)
	in_.pressed += (cmd.buttons - in_.held) & sim.ONE_SHOT
	in_.held = cmd.buttons
	in_.aim = cmd.aim
}
