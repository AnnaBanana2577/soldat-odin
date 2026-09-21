#+private
package hud

import "core:fmt"
import rl "vendor:raylib"
import "../game"
import "../render"
import "../../shared/sim"

// Names over the players, and the count of the spawn protection over mine
// (RenderPlayerNames and RenderCeaseFireCounter).
//
// The original shows a name only for a team mate, and only while it is off the screen:
// the name is then held against the edge it went out by, which is how a player knows
// where the rest of the team is. The colour says what it is doing and the fading says
// how far away it is.

NAME_OFFSCREEN :: rl.Color{0x99, 0xDF, 0x99, 255} // a team mate
NAME_DEAD      :: rl.Color{0x98, 0x33, 0x33, 255} // one waiting to be placed again
NAME_FLAG      :: rl.Color{0xDC, 0xDC, 0x33, 255} // one carrying a flag

names_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen, camera: ^render.Camera, alpha: f32) {
	mine := &g.world.soldiers[g.me]
	if !mine.active || mine.team == .Spectator do return
	for &s, i in g.world.soldiers {
		if !s.active || u8(i) == g.me || s.team != mine.team do continue
		name_draw(h, g, sc, camera, alpha, u8(i))
	}
}

@(private = "file")
name_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen, camera: ^render.Camera, alpha: f32, slot: u8) {
	s := &g.world.soldiers[slot]
	line := game.name_of(g, slot)
	if line == "" do return
	drawn := game.drawn_pos(g, int(slot), alpha)
	pose := sim.soldier_pose(g.ctx.anims, s, drawn)
	at := render.world_to_screen(camera, pose[6]) / sc.scale + {0, 5}

	width, height := text_width(h, sc, .Small, line), FONT_UNITS[.Small]
	if at.x >= 0 && at.x <= sc.width && at.y >= 0 && at.y <= 480 do return // it can be seen: no name

	// held against the edge it went out by
	x := clamp(at.x - width / 2, 0, sc.width - width)
	y := clamp(at.y, 0, 480 - height)

	// the further off, the fainter
	mine := &g.world.soldiers[g.me]
	dx := max(abs(mine.pos.x - s.pos.x), 1)
	dy := max(abs(mine.pos.y - s.pos.y), 1)
	faded := u8(min(255, 50 + 100000 / (dx + dy / 2)))

	color := NAME_OFFSCREEN
	if s.holding_flag do color = NAME_FLAG
	else if s.dead do color = NAME_DEAD
	color.a = faded
	text(h, sc, .Small, line, x, y, color)
}

// The seconds of spawn protection left, over my soldier's head. The original draws this
// in survival mode alone, which this game has not got; here it shows whenever the
// protection is on.
cease_fire_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen, camera: ^render.Camera, alpha: f32) {
	s := &g.world.soldiers[g.me]
	if !s.active || s.dead || s.cease_fire_counter < 0 do return
	drawn := game.drawn_pos(g, int(g.me), alpha)
	pose := sim.soldier_pose(g.ctx.anims, s, drawn)
	at := render.world_to_screen(camera, pose[8] - {2, 15}) / sc.scale
	text(h, sc, .Small, fmt.tprint(s.cease_fire_counter / sim.TICK_RATE + 1), at.x, at.y, {0x71, 0xF9, 0x81, 238})
}
