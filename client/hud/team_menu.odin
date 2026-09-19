#+private
package hud

import "core:fmt"
import rl "vendor:raylib"
import "../game"
import "../../shared/sim"

// The team menu, the original's: Alpha and Bravo, with how many play on each. M opens
// and closes it (the original has it on its Esc menu); a click, or 1 or 2, picks. The
// server moves me if the teams stay even, and then the weapons menu opens for the new
// life (hud.tick sees the move).
// It and the weapons menu are never open at once.
Team_Menu :: struct {
	open:    bool,
	hovered: int, // the row under the cursor, or -1
}

TEAM_CHOICES :: [?]sim.Team{.Alpha, .Bravo}

// The original's buttons: 215 by 35, 40 apart, the first at y 180.
TEAM_X, TEAM_W, TEAM_H, TEAM_STEP :: 40.0, 215.0, 35.0, 40.0
TEAM_PANEL :: [4]f32{45, 140, 262, 130} // the original's is taller: it has Charlie, Delta and Spectator too

@(private = "file")
team_row_top :: proc(row: int) -> f32 {
	return 140 + TEAM_STEP * f32(row + 1)
}

team_menu_covers :: proc(sc: Screen, cursor: sim.Vec2) -> bool {
	x, y := cursor.x / sc.scale, cursor.y / sc.scale
	p := TEAM_PANEL
	return x >= p[0] && x <= p[0] + p[2] && y >= p[1] && y <= p[1] + p[3]
}

// This frame's keys and mouse for the team menu. Returns whether the mouse is the menu's.
team_menu_input :: proc(h: ^Hud, g: ^game.Game, cursor: sim.Vec2) -> (mouse_taken: bool) {
	t := &h.team
	if rl.IsKeyPressed(.M) {
		t.open = !t.open
		if t.open do h.menu.open = false
	}
	t.hovered = -1
	if !t.open do return false

	choices := TEAM_CHOICES
	number_keys := [?]rl.KeyboardKey{.ONE, .TWO}
	for key, row in number_keys do if rl.IsKeyPressed(key) do team_pick(h, g, choices[row])

	sc := screen()
	x, y := cursor.x / sc.scale, cursor.y / sc.scale
	for row in 0 ..< len(choices) {
		top := team_row_top(row)
		if x >= TEAM_X && x <= TEAM_X + TEAM_W && y >= top && y < top + TEAM_H do t.hovered = row
	}
	if t.hovered >= 0 && rl.IsMouseButtonPressed(.LEFT) do team_pick(h, g, choices[t.hovered])
	return team_menu_covers(sc, cursor)
}

@(private = "file")
team_pick :: proc(h: ^Hud, g: ^game.Game, team: sim.Team) {
	h.team.open = false
	if team != g.world.soldiers[g.me].team do game.choose_team(g, team)
}

team_menu_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen) {
	t := &h.team
	p := TEAM_PANEL
	draw_panel(h, sc, p[0], p[1], p[2], p[3])
	text(h, sc, .Menu, "Select Team:", 55, 165, {234, 234, 234, 255})

	on_team: [sim.Team]int
	for &s in g.world.soldiers do if s.active do on_team[s.team] += 1

	for team, row in TEAM_CHOICES {
		hovered := f32(row == t.hovered ? 1 : 0)
		color: rl.Color = team == .Alpha ? {210, 15, 5, 255} : {5, 15, 205, 255}
		y := team_row_top(row) + (TEAM_H - FONT_UNITS[.Menu]) / 2 - hovered
		text(h, sc, .Menu, fmt.tprintf("%d %v Team", row + 1, team), TEAM_X + 10 + hovered, y, color)
		text(h, sc, .Menu, fmt.tprintf("(%d)", on_team[team]), 269 + hovered, y, color)
	}
}
