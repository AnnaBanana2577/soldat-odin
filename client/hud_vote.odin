#+private
package client

import "core:fmt"
import rl "vendor:raylib"
import "../shared/net"
import "../shared/sim"

// The vote box (RenderVoteMenuTexts): while a vote is running everyone sees what it is
// about, who called it and why, and presses F12 to agree or F11 to have none of it.
// The vote itself is the server's (server/vote.odin); this is the corner of the screen
// it is shown in.

VOTE_X, VOTE_Y :: f32(45), f32(400)

// This frame's keys for a vote. Returns whether they were taken.
vote_input :: proc(h: ^Hud, g: ^Game) -> (keys_taken: bool) {
	if !g.vote.active do return false
	if rl.IsKeyPressed(.F12) {
		vote_yes(g)
		return true
	}
	if rl.IsKeyPressed(.F11) {
		vote_no(g)
		return true
	}
	return false
}

vote_draw :: proc(h: ^Hud, g: ^Game, sc: Screen) {
	v := &g.vote
	if !v.active do return
	x, y := VOTE_X, VOTE_Y
	about := v.kind == .Kick ? "Kick" : "Map"
	target := net.text_string(&v.name)
	if v.kind == .Kick && v.target < sim.MAX_PLAYERS do target = name_of(g, v.target)

	text(h, sc, .Small, about, x + 30, y, {254, 104, 104, 225})
	text(h, sc, .Small, target, x + 65, y, {244, 244, 244, 225})
	starter := v.starter < sim.MAX_PLAYERS ? name_of(g, v.starter) : "Server"
	text(h, sc, .Small, fmt.tprintf("Voter: %s", starter), x + 10, y + 11, {224, 218, 244, 205})
	text(h, sc, .Small, fmt.tprintf("Reason:%s", net.text_string(&v.reason)), x + 10, y + 20, {224, 218, 244, 205})
	text(h, sc, .Small, "F12 - Yes   F11 - No", x + 50, y + 31, {234, 234, 114, 205})
}

// While a reason for a kick is being typed, in place of the chat's own prompt.
vote_reason_draw :: proc(h: ^Hud, sc: Screen) {
	if !h.chat.reason do return
	text(h, sc, .Small, "Type reason for vote:", 5, 390, {254, 124, 124, 255})
}
