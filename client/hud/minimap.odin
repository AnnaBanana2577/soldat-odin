#+private
package hud

import rl "vendor:raylib"
import "../game"
import "../render"
import "../../shared/sim"

// The minimap in the corner (InterfaceGraphics.pas, the Minimap part of RenderInterface):
// the map drawn small, with a dot for every soldier of my team, one for each flag that
// is at home, and a box around what the screen is showing. F3 shows and hides it, as
// the original's bind does.
//
// The picture itself is the renderer's, built when the map loads (render/minimap.odin).

MINIMAP_X, MINIMAP_Y :: f32(285), f32(5) // ui_minimap_posx, ui_minimap_posy
MINIMAP_ALPHA        :: u8(200 * 0.85)   // ui_status_transparency * 0.85
DOT_ALPHA            :: u8(230)          // ui_minimap_transparency

minimap_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen, r: ^render.Render, camera: ^render.Camera) {
	if !h.minimap_shown do return
	m := render.minimap(r)
	if m == nil do return
	x, y := spread(sc, MINIMAP_X), MINIMAP_Y
	render.minimap_draw(m, x, y, sc.scale, MINIMAP_ALPHA)

	// every flag standing at home, and then the soldiers
	for &t in g.world.things {
		if !sim.is_flag(t.style) || !t.in_base || t.holder != 0 do continue
		color: rl.Color = sim.flag_team(t.style) == .Alpha ? {255, 0, 0, DOT_ALPHA} : {19, 19, 255, DOT_ALPHA}
		dot(h, sc, x, y, render.minimap_place(m, t.pos[0]), 1, color)
	}
	mine := &g.world.soldiers[g.me]
	for &s, i in g.world.soldiers {
		if !s.active || s.team == .Spectator do continue
		if mine.team != .Spectator && s.team != mine.team do continue // only my own team
		at := render.minimap_place(m, s.pos)
		switch {
		case s.holding_flag:
			dot(h, sc, x, y, at, 1, {255, 255, 0, DOT_ALPHA})
		case u8(i) == g.me:
			dot(h, sc, x, y, at, 0.8, {255, 255, 255, DOT_ALPHA})
		case:
			color := rl.Color{0, 0, 0, DOT_ALPHA} // a body is a black dot
			if !s.dead do color = s.team == .Alpha ? {255, 0, 0, DOT_ALPHA} : {19, 19, 255, DOT_ALPHA}
			dot(h, sc, x, y, at, 0.65, color)
		}
	}

	// and the box around what the screen shows
	half := render.view_half(camera)
	min_x, min_y := render.minimap_place(m, camera.pos - half).x, render.minimap_place(m, camera.pos - half).y
	max_x, max_y := render.minimap_place(m, camera.pos + half).x, render.minimap_place(m, camera.pos + half).y
	min_x, min_y = max(min_x, 0), max(min_y, 0)
	max_x, max_y = min(max_x, m.width), min(max_y, m.height)
	if max_x <= min_x || max_y <= min_y do return
	box := rl.Rectangle{(x + min_x) * sc.scale, (y + min_y) * sc.scale, (max_x - min_x) * sc.scale, (max_y - min_y) * sc.scale}
	rl.DrawRectangleLinesEx(box, max(sc.scale * 0.5, 1), {255, 255, 255, 127})
}

// One dot, middled on where it stands.
@(private = "file")
dot :: proc(h: ^Hud, sc: Screen, x, y: f32, at: sim.Vec2, shrink: f32, color: rl.Color) {
	t := h.art[.Small_Dot]
	if t.id == 0 do return
	half := f32(t.width) / ART_SCALE * shrink / 2
	draw_art(t, sc, x + at.x - half, y + at.y - half, ART_SCALE, color, shrink)
}
