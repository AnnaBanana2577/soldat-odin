package sim

// The idle antics: a soldier standing still long enough smokes, wipes its brow or
// scratches; /mercy, /pwn, /smoke and the rest. Port of idleControl in soldier.lua.

DEFAULT_IDLE_TIME :: 1800 // ticks standing still before an antic

Idle :: struct {
	time:   i32,
	random: i8, // which antic, rolled once
}

antics_apply :: proc(ctx: ^Context, w: ^World, s: ^Soldier) {
	if s.stat != 0 do return
	if s.legs.id == .Stand && s.body.id == .Stand && !s.dead {
		s.idle.time += 1
		if s.idle.time > DEFAULT_IDLE_TIME {
			// TODO pick and play the antic on the body animation
			s.idle.time = 0
		}
	} else {
		s.idle.time = 0
	}
}
