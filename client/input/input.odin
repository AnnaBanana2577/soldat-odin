package input

import rl "vendor:raylib"
import "../../shared/sim"

// Input is sampled every frame and consumed every tick. Held buttons are whatever
// the keys say right now; one-shot presses (throw, change, prone, drop) are latched
// the frame they go down and cleared by `clear` after the tick that used them,
// so a press between two ticks is never lost and never counted twice.
Input :: struct {
	held:    sim.Buttons,
	pressed: sim.Buttons,
	aim:     sim.Vec2, // the cursor in world space
}

Bind :: struct {
	key:    rl.KeyboardKey,
	button: sim.Button,
}

// TODO binds from the config; these are the defaults
BINDS :: [?]Bind{
	{.A, .Left}, {.D, .Right}, {.W, .Jump}, {.S, .Crouch}, {.X, .Prone},
	{.SPACE, .Jet}, {.E, .Throw}, {.R, .Reload}, {.Q, .Change}, {.F, .Drop}, {.K, .Suicide},
}

// The keys and mouse buttons now, and `aim`, the cursor in world space. `scripted` is
// held the whole run by a debug option, on top of the keys.
sample :: proc(in_: ^Input, aim: sim.Vec2, scripted: sim.Buttons) {
	held := scripted
	for b in BINDS {
		if rl.IsKeyDown(b.key) do held += {b.button}
	}
	if rl.IsMouseButtonDown(.LEFT) do held += {.Fire}
	if rl.IsMouseButtonDown(.RIGHT) do held += {.Throw}
	// a one-shot button counts from the frame it goes down until a tick consumes it
	in_.pressed += (held - in_.held) & sim.ONE_SHOT
	in_.held = held
	in_.aim = aim
}

// The command for this tick.
command :: proc(in_: ^Input, seq: u32) -> sim.Command {
	return {seq = seq, buttons = in_.held + in_.pressed, aim = in_.aim}
}

clear :: proc(in_: ^Input) {
	in_.pressed = {}
}
