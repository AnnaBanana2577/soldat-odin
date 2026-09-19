#+private
package hud

import "core:fmt"
import rl "vendor:raylib"
import "../game"
import "../../shared/sim"

// The scoreboard (the original's frags menu), shown while F1 is toggled on and at the
// end of every round: the map and the time left, how many play on each team, and under
// each team's caption and total its players, the best first, with their kills, flags,
// deaths and ping. Laid out as RenderFragsMenuTexts does, around the screen's middle.

SCORES_WIDTH  :: 590.0
SCORES_ROW    :: 15.0 // FRAGSMENU_PLAYER_HEIGHT
SCORES_TEAMS  :: [?]sim.Team{.Alpha, .Bravo, .None}

scoreboard_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen) {
	w := &g.world
	x := sc.width / 2 - 325 // the original's fragx: its columns are counted from here
	y: f32 = 10

	// the players in play, the best first
	order: [sim.MAX_PLAYERS]int
	count := 0
	on_team: [sim.Team]int
	for &s, i in w.soldiers {
		if !s.active || s.team == .Spectator do continue
		on_team[s.team] += 1
		// in among those already there: more kills first, then fewer deaths
		at := count
		for at > 0 && ahead(&s, &w.soldiers[order[at - 1]]) {
			order[at] = order[at - 1]
			at -= 1
		}
		order[at] = i
		count += 1
	}
	ahead :: proc(s, t: ^sim.Soldier) -> bool {
		return s.kills > t.kills || (s.kills == t.kills && s.deaths < t.deaths)
	}

	teams := 0
	for team in SCORES_TEAMS do if on_team[team] > 0 do teams += 1
	bottom := 70 + f32(count + 1) * SCORES_ROW + 15 * f32(teams)
	draw_panel(h, sc, x + 25, y + 5, SCORES_WIDTH, bottom)

	text(h, sc, .Small, g.map_name, x + 30, y + 15, {233, 180, 12, 255})
	seconds := max(w.round.time_left, 0) / sim.TICK_RATE
	text(h, sc, .Small, fmt.tprintf("Time %02d:%02d", seconds / 60, seconds % 60), x + 485, y + 15, {170, 160, 200, 230})
	text(h, sc, .Small, "Players", x + 330, y + 15, {200, 190, 180, 240})
	text(h, sc, .Small, fmt.tprint(on_team[.Alpha]), x + 440, y + 10, team_color(.Alpha))
	text(h, sc, .Small, fmt.tprint(on_team[.Bravo]), x + 440, y + 20, team_color(.Bravo))

	heading := rl.Color{255, 255, 230, 255}
	text(h, sc, .Menu, "Points:", x + 280, y + 40, heading)
	text(h, sc, .Menu, "Deaths:", x + 390, y + 40, heading)
	text(h, sc, .Menu, "Ping:", x + 530, y + 40, heading)

	// each team: its caption, its line and its total, then its players
	row := 0
	step: f32 = 0
	for team in SCORES_TEAMS {
		if on_team[team] == 0 do continue
		top := y + 50 + step + f32(row) * SCORES_ROW
		step += 20
		color := team_color(team)
		rl.DrawRectangleV({(x + 35) * sc.scale, (top + 15) * sc.scale}, {565 * sc.scale, max(sc.scale, 1)}, color)
		text(h, sc, .Small, team == .None ? "Player" : fmt.tprint(team), x + 35, top, color)
		total, index := 0, 0
		for i in order[:count] {
			s := &w.soldiers[i]
			if s.team != team do continue
			py := top + 20 + SCORES_ROW * f32(index)
			shirt := shirt_color(team)
			text(h, sc, .Small, game.name_of(g, u8(i)), x + 44, py, shirt)
			text(h, sc, .Small, fmt.tprint(s.kills), x + 284, py, shirt)
			if s.flags > 0 do text(h, sc, .Small, fmt.tprintf("x%d", s.flags), x + 348, py, shirt)
			text(h, sc, .Small, fmt.tprint(s.deaths), x + 394, py, shirt)
			if g.bots & (1 << u32(i)) == 0 do text(h, sc, .Small, fmt.tprint(int(g.lags[i]) * 1000 / sim.TICK_RATE), x + 534, py, shirt)
			total += int(s.kills)
			index += 1
		}
		if team != .None do text(h, sc, .Small, fmt.tprint(total), x + 284, top + 3, color)
		row += index
	}

	// the round is over: who won, and how long until the next
	if w.round.state == .Ended {
		r := &w.round
		alpha, bravo := r.scores[.Alpha], r.scores[.Bravo]
		middle := x + 25 + SCORES_WIDTH / 2
		under := y + 5 + bottom + 6
		switch {
		case alpha > bravo: text(h, sc, .Big, "Alpha team wins", middle, under, {210, 15, 5, 255}, .Center)
		case bravo > alpha: text(h, sc, .Big, "Bravo team wins", middle, under, {60, 90, 245, 255}, .Center)
		case:               text(h, sc, .Big, "It's a tie", middle, under, {245, 245, 245, 255}, .Center)
		}
		next := fmt.tprintf("Next round in %.0f", f32(max(r.counter, 0)) / sim.TICK_RATE + 0.5)
		text(h, sc, .Small, next, middle, under + 44, {200, 200, 200, 255}, .Center)
	}
}

@(private = "file")
team_color :: proc(team: sim.Team) -> rl.Color {
	#partial switch team {
	case .Alpha: return {255, 0, 0, 255}
	case .Bravo: return {40, 60, 255, 255}
	}
	return {205, 205, 205, 255}
}

// The shirts' colours, which the original takes from each player's profile: fixed by team
// until the roster carries them (as the gostek's are).
@(private = "file")
shirt_color :: proc(team: sim.Team) -> rl.Color {
	#partial switch team {
	case .Alpha: return {235, 90, 85, 255}
	case .Bravo: return {110, 150, 245, 255}
	}
	return {225, 225, 225, 255}
}

