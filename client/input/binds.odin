package input

import "core:reflect"
import "core:strings"
import rl "vendor:raylib"

// A binding: the keys, the mouse buttons and the mouse wheel that press one thing, read
// from the text of a bind_ setting. Names go by comma, as raylib names them, in any case:
//
//   bind_jump   w,up
//   bind_fire   mouse_left
//   bind_scores f1
//   bind_change wheel_up,wheel_down
//
// A letter, a digit (1 is ONE), space, tab, left_shift, left_control, f1..f12, kp_0..
// kp_9, up, down, left, right; mouse_left, mouse_right, mouse_middle, mouse_side,
// mouse_extra, mouse_forward, mouse_back; and wheel_up, wheel_down. An empty text binds
// nothing.
MAX_KEYS :: 4

Wheel :: enum {
	Up,
	Down,
}

Keys :: struct {
	keys:  [MAX_KEYS]rl.KeyboardKey,
	count: int,
	mouse: bit_set[rl.MouseButton],
	wheel: bit_set[Wheel],
}

// The text as keys, and the first name in it that is no key, which is skipped.
keys_parse :: proc(text: string) -> (k: Keys, bad: string, ok: bool) {
	for part in strings.split(text, ",", context.temp_allocator) {
		name := strings.trim_space(part)
		if name == "" do continue
		upper := strings.to_upper(name, context.temp_allocator)
		switch upper {
		case "WHEEL_UP", "MOUSE_WHEEL_UP":
			k.wheel += {.Up}
			continue
		case "WHEEL_DOWN", "MOUSE_WHEEL_DOWN":
			k.wheel += {.Down}
			continue
		}
		if strings.has_prefix(upper, "MOUSE_") {
			button, found := reflect.enum_from_name(rl.MouseButton, upper[len("MOUSE_"):])
			if !found {
				if bad == "" do bad = name
				continue
			}
			k.mouse += {button}
			continue
		}
		if len(upper) == 1 && upper[0] >= '0' && upper[0] <= '9' do upper = DIGITS[upper[0] - '0']
		key, found := reflect.enum_from_name(rl.KeyboardKey, upper)
		if !found || key == .KEY_NULL || k.count == MAX_KEYS {
			if bad == "" do bad = name
			continue
		}
		k.keys[k.count] = key
		k.count += 1
	}
	return k, bad, bad == ""
}

@(private = "file")
DIGITS := [10]string{"ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE"}

// The wheel is read once per rendered frame but the game moves in whole ticks, so a
// notch is remembered here until a tick has used it.
@(private = "file")
wheel_latch: [Wheel]int

// Call once per rendered frame, after raylib has polled its events. Not more than once,
// or a notch counts twice.
wheel_poll :: proc() {
	move := rl.GetMouseWheelMove()
	if move > 0 {
		wheel_latch[.Up] += 1
	} else if move < 0 {
		wheel_latch[.Down] += 1
	}
}

// Call after each tick's command is built, so a notch presses exactly one tick.
wheel_end_tick :: proc() {
	wheel_latch = {}
}

// Whether any of them is held now. The keys count only while they are free (no line
// being typed), the mouse buttons and the wheel only while the mouse is (no menu under
// it).
keys_down :: proc(k: Keys, keys_free := true, mouse_free := true) -> bool {
	if keys_free do for i in 0 ..< k.count do if rl.IsKeyDown(k.keys[i]) do return true
	if mouse_free {
		for button in k.mouse do if rl.IsMouseButtonDown(button) do return true
		for w in k.wheel do if wheel_latch[w] > 0 do return true
	}
	return false
}

// Whether any of them went down this frame: for what toggles, a menu or a board.
keys_pressed :: proc(k: Keys) -> bool {
	for i in 0 ..< k.count do if rl.IsKeyPressed(k.keys[i]) do return true
	for button in k.mouse do if rl.IsMouseButtonPressed(button) do return true
	return false
}
