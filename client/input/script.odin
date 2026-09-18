package input

import "../../shared/sim"

// Scripted input for the headless client (-headless), to test the netcode without a
// person: the bots' brain (sim/bot.odin) playing this client's soldier on the world as
// this client shows it. It hunts, dodges and shoots like the server's bots, but through
// a real client and a real connection, so the server's judging of its shots and the
// flight of the bullets fired at it have something to do. Seeded, so a run can be
// repeated.
Script :: struct {
	brain: sim.Bot,
}

script_init :: proc(s: ^Script, seed: u64) {
	sim.bot_init(&s.brain, seed, dodge = true)
}

// This tick's keys, and the aim, for the soldier in slot `me` of `w`.
script_sample :: proc(s: ^Script, in_: ^Input, ctx: ^sim.Context, w: ^sim.World, me: u8) {
	cmd := sim.bot_command(&s.brain, ctx, w, me)
	in_.pressed += (cmd.buttons - in_.held) & sim.ONE_SHOT
	in_.held = cmd.buttons
	in_.aim = cmd.aim
}
