package input

import "../../shared/sim"

// Input is sampled every frame and consumed every tick. Held buttons are whatever
// the keys say right now; one-shot presses (throw, change, prone, drop) are latched
// the frame they go down and cleared by `clear` after the tick that used them,
// so a press between two ticks is never lost and never counted twice.
Input :: struct {
	held:    sim.Buttons,
	pressed: sim.Buttons,
	aim:     sim.Vec2, // the cursor in world space
	binds:   [sim.Button]Keys, // what presses each button: the bind_ settings (binds.odin)
}

// The keys and mouse buttons now, and `aim`, the cursor in world space. `scripted` is
// held the whole run by a debug option, on top of the keys. The mouse is the soldier's
// unless a menu has it (`mouse_free`), and the keys are unless a line is being typed
// (`keys_free`).
sample :: proc(in_: ^Input, aim: sim.Vec2, scripted: sim.Buttons, mouse_free, keys_free: bool) {
	held := scripted
	for keys, button in in_.binds do if keys_down(keys, keys_free, mouse_free) do held += {button}
	// a one-shot button counts from the frame it goes down until a tick consumes it
	in_.pressed += (held - in_.held) & sim.ONE_SHOT
	in_.held = held
	in_.aim = aim
}

// The command for this tick, numbered: the server runs them in order and says which it
// has run, and the client replays the rest (client/game/predict.odin).
command :: proc(in_: ^Input, seq: u32) -> sim.Command {
	return {seq = seq, buttons = in_.held + in_.pressed, aim = in_.aim}
}

clear :: proc(in_: ^Input) {
	in_.pressed = {}
}
