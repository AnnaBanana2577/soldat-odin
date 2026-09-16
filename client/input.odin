package client

import rl "vendor:raylib"
import "../shared/sim"

// Input is sampled every frame and consumed every tick. Held buttons are whatever
// the keys say right now; one-shot presses (throw, change, prone, drop) are latched
// the frame they go down and cleared by clear_input after the tick that used them,
// so a press between two ticks is never lost and never counted twice.
Input :: struct {
	held:    sim.Buttons,
	pressed: sim.Buttons,
	aim:     sim.Vec2, // the cursor in world space
}

ONE_SHOT :: sim.Buttons{.Throw, .Change, .Prone, .Drop, .Suicide, .Flag_Throw, .Reload}

Bind :: struct {
	key:    rl.KeyboardKey,
	button: sim.Button,
}

// TODO binds from the config; these are the defaults
BINDS :: [?]Bind{
	{.A, .Left}, {.D, .Right}, {.W, .Jump}, {.S, .Crouch}, {.X, .Prone},
	{.SPACE, .Jet}, {.E, .Throw}, {.R, .Reload}, {.Q, .Change}, {.F, .Drop}, {.K, .Suicide},
}

// `scripted` is held the whole run by a debug option, on top of the keys.
sample_input :: proc(in_: ^Input, camera: ^Camera, scripted: sim.Buttons) {
	held := scripted
	for b in BINDS {
		if rl.IsKeyDown(b.key) do held += {b.button}
	}
	if rl.IsMouseButtonDown(.LEFT) do held += {.Fire}
	if rl.IsMouseButtonDown(.RIGHT) do held += {.Throw}
	// a one-shot button counts from the frame it goes down until a tick consumes it
	in_.pressed += (held - in_.held) & ONE_SHOT
	in_.held = held
	m := rl.GetMousePosition()
	in_.aim = screen_to_world(camera, {m.x, m.y})
}

// The command for this tick.
command_for_tick :: proc(in_: ^Input, seq: u32) -> sim.Command {
	return {seq = seq, buttons = in_.held + in_.pressed, aim = in_.aim}
}

clear_input :: proc(in_: ^Input) {
	in_.pressed = {}
}
