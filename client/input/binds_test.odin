package input

import "core:testing"
import rl "vendor:raylib"

@(test)
test_a_bind_reads_keys_and_mouse_buttons :: proc(t: ^testing.T) {
	k, bad, ok := keys_parse("W, up ,mouse_right")
	testing.expect(t, ok, bad)
	testing.expect_value(t, k.count, 2)
	testing.expect_value(t, k.keys[0], rl.KeyboardKey.W)
	testing.expect_value(t, k.keys[1], rl.KeyboardKey.UP)
	testing.expect(t, .RIGHT in k.mouse)
}

@(test)
test_a_digit_is_its_key :: proc(t: ^testing.T) {
	k, _, ok := keys_parse("1,kp_1")
	testing.expect(t, ok)
	testing.expect_value(t, k.keys[0], rl.KeyboardKey.ONE)
	testing.expect_value(t, k.keys[1], rl.KeyboardKey.KP_1)
}

@(test)
test_an_empty_bind_binds_nothing_and_a_wrong_name_is_said :: proc(t: ^testing.T) {
	k, _, ok := keys_parse("")
	testing.expect(t, ok && k.count == 0 && k.mouse == {})
	k2, bad, ok2 := keys_parse("a,jupm")
	testing.expect(t, !ok2)
	// the good names in it still bind
	testing.expect_value(t, k2.count, 1)
	testing.expect_value(t, bad, "jupm")
	_, bad, ok2 = keys_parse("mouse_sideways")
	testing.expect(t, !ok2)
	testing.expect_value(t, bad, "mouse_sideways")
}