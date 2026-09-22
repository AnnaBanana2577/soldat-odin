package client

// What a map holds but the game never draws: where players and things spawn, the
// colliders, and the paths the bots walk. These are the reason to open an editor rather
// than just play the map, so they are drawn on top of it and each has its own checkbox.
//
// Everything here is sized in *pixels* and converted to world units, so a marker stays
// the same size on screen however far the view is zoomed out. The one exception is a
// collider, whose radius is a real distance in the world and has to be drawn as one.

import rl "vendor:raylib"

import "../shared/pms"

SPAWN_RADIUS :: 7 // pixels
WAYPOINT_RADIUS :: 3

// Between the caller's BeginMode2D and EndMode2D, after the map.
@(private)
draw_overlays :: proc(e: ^Editor) {
	// World units per screen pixel: markers are drawn in these so they hold their size.
	px := 1 / pixels_per_unit(&e.camera)

	if .Waypoints in e.show do draw_waypoints(e, px)
	if .Colliders in e.show do draw_colliders(e, px)
	if .Spawns in e.show do draw_spawns(e, px)
}

// Bots walk these. Connections first so the dots sit on top of their own lines.
@(private)
draw_waypoints :: proc(e: ^Editor, px: f32) {
	points := e.level.waypoints
	line := theme_color(0x6ea8fe80)
	for &w, i in points {
		if !w.active do continue
		for k in 0 ..< w.count {
			to := int(w.connections[k])
			// The file numbers waypoints from 1, and points at ones that are not there.
			if to <= 0 || to >= len(points) || !points[to].active do continue
			rl.DrawLineV(w.pos, points[to].pos, line)
		}
		_ = i
	}
	for &w in points {
		if !w.active do continue
		rl.DrawCircleV(w.pos, WAYPOINT_RADIUS * px, theme_color(0x6ea8feff))
	}
}

// The circles the original uses to keep players out of places the polygons do not.
@(private)
draw_colliders :: proc(e: ^Editor, px: f32) {
	colour := theme_color(0xffb86cff)
	for &c in e.level.colliders {
		if !c.active do continue
		rl.DrawCircleLinesV(c.pos, c.radius, colour)
		rl.DrawCircleV(c.pos, 2 * px, colour)
	}
}

// Where players, flags and kits appear. Colour says which.
@(private)
draw_spawns :: proc(e: ^Editor, px: f32) {
	for &s in e.level.spawnpoints {
		if !s.active do continue
		colour := spawn_colour(s.team)
		rl.DrawCircleV(s.pos, SPAWN_RADIUS * px, colour)
		rl.DrawCircleLinesV(s.pos, SPAWN_RADIUS * px, theme_color(0x16181cff))
	}
}

// The teams keep their own colours; everything a round drops in is one neutral colour,
// because telling a medkit from a vest by shade is a worse idea than a label will be.
@(private)
spawn_colour :: proc(team: i32) -> rl.Color {
	switch pms.Spawn_Team(team) {
	case .Alpha, .Alpha_Flag:
		return theme_color(0xff6b6bff)
	case .Bravo, .Bravo_Flag:
		return theme_color(0x6ea8feff)
	case .Charlie:
		return theme_color(0xffd166ff)
	case .Delta:
		return theme_color(0x6bcB77ff)
	case .General:
		return theme_color(0xe6e8eaff)
	case .Grenade_Kit, .Medical_Kit, .Cluster_Kit, .Vest_Kit, .Flamer_Kit,
	     .Berserk_Kit, .Predator_Kit, .Rambo_Bow, .Stationary_Gun, .Pointmatch_Flag:
		return theme_color(0x9aa2adff)
	}
	return theme_color(0x9aa2adff) // a team number no version of the game defines
}
