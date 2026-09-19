#+private
package hud

import "core:fmt"
import rl "vendor:raylib"
import "../game"
import "../../shared/net"
import "../../shared/sim"

// The kill feed, down the right of the screen (the original's kill console): the killer
// with its tally and the weapon's icon, the victim on the line below, each in its
// team's colour. The oldest kill scrolls off every four seconds, a little later when
// one has just come.
Kill_Feed :: struct {
	kills:  [FEED_KILLS]Feed_Kill, // oldest first
	count:  int,
	scroll: int, // ticks since the last one scrolled off, or came
}

// As it was when it happened: the names and teams are copied, since a slot's may change.
Feed_Kill :: struct {
	killer, victim:           net.Name,
	killer_team, victim_team: sim.Team,
	weapon: sim.Weapon_Id,
	tally:  i32, // the killer's kills with this one
	self:   bool,
}

FEED_KILLS       :: 7
FEED_SCROLL      :: 240 // ticks a kill stays at the top of the feed
FEED_NEW_WAIT    :: 70  // and these more after a new one came
FEED_LINE        :: 10.0 // units between lines
FEED_GAP         :: 8.0  // and these more between kills
FEED_ICON_SHRINK :: 0.8

feed_add :: proc(f: ^Kill_Feed, g: ^game.Game, kill: sim.Kill) {
	if f.count == FEED_KILLS do feed_scroll(f)
	w := &g.world
	f.kills[f.count] = {
		killer = g.names[kill.killer], victim = g.names[kill.target],
		killer_team = w.soldiers[kill.killer].team, victim_team = w.soldiers[kill.target].team,
		weapon = kill.weapon, tally = kill.kills, self = kill.killer == kill.target,
	}
	f.count += 1
	f.scroll = -FEED_NEW_WAIT
}

feed_tick :: proc(f: ^Kill_Feed) {
	if f.count == 0 do return
	f.scroll += 1
	if f.scroll >= FEED_SCROLL do feed_scroll(f)
}

@(private = "file")
feed_scroll :: proc(f: ^Kill_Feed) {
	copy(f.kills[:], f.kills[1:f.count])
	f.count -= 1
	f.scroll = 0
}

feed_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen) {
	y: f32 = 60
	for &k in h.feed.kills[:h.feed.count] {
		y += FEED_GAP
		killer_color := k.self ? rl.Color{211, 183, 39, 235} : killer_colors(k.killer_team)
		text(h, sc, .Tiny, fmt.tprintf("%s (%d)", net.text_string(&k.killer), k.tally), spread(sc, 595), y, killer_color, .Right)
		draw_art(h.guns[k.weapon], sc, spread(sc, 605), y - 1, ART_SCALE, rl.WHITE, FEED_ICON_SHRINK)
		y += FEED_LINE
		if k.self do continue
		text(h, sc, .Tiny, net.text_string(&k.victim), spread(sc, 595), y, victim_colors(k.victim_team), .Right)
		y += FEED_LINE
	}
}

@(private = "file")
killer_colors :: proc(team: sim.Team) -> rl.Color {
	#partial switch team {
	case .Alpha:   return {255, 227, 227, 235}
	case .Bravo:   return {211, 227, 255, 235}
	case .Charlie: return {255, 255, 227, 235}
	case .Delta:   return {211, 255, 227, 235}
	}
	return {82, 209, 25, 238}
}

@(private = "file")
victim_colors :: proc(team: sim.Team) -> rl.Color {
	#partial switch team {
	case .Alpha:   return {218, 176, 176, 235}
	case .Bravo:   return {160, 176, 218, 235}
	case .Charlie: return {208, 208, 176, 235}
	case .Delta:   return {160, 208, 186, 235}
	}
	return {128, 19, 4, 238}
}
