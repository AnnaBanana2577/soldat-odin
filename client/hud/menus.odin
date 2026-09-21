#+private
package hud

import rl "vendor:raylib"
import "../game"
import "../../shared/net"
import "../../shared/sim"

// The menus Escape opens over the game (GameMenus.pas): the escape menu, and the two
// windows it opens for calling a vote. The weapons menu (the original's limbo menu),
// the team menu and the scoreboard are its others, each in its own file.
//
// Escape opens and closes the escape menu, and goes back to it from one of the windows.
// The keys 1 to 4 press its buttons, and so does a click.
Menus :: struct {
	esc, kick, maps: bool,
	slot:    u8,  // the player the kick window is showing
	index:   int, // and where the map window is in the server's list
	hovered: Hover,
	leaving: bool, // Exit to menu was pressed: the game closes
}

Menu :: enum { None, Esc, Kick, Maps }

Hover :: struct {
	menu:   Menu,
	button: int,
}

ESC_W, ESC_H       :: f32(300), f32(200)
WINDOW_X, WINDOW_Y :: f32(125), f32(355)
WINDOW_W, WINDOW_H :: f32(370), f32(90)
BUTTON_H           :: f32(25)
REASON_LONGEST     :: 30 // REASON_CHARS: the reason typed for a kick

ESC_BUTTONS  := [?]string{"1 Exit to menu", "2 Change map", "3 Kick player", "4 Change team"}
KICK_BUTTONS := [?]string{"<<<<", ">>>>", "Kick", "Ban"} // Ban is not in, as in the original
MAP_BUTTONS  := [?]string{"<<<<", ">>>>", "Select"}

// Where a button is, in the layout's units.
@(private = "file")
esc_button :: proc(sc: Screen, i: int) -> (x, y, w, h: f32) {
	left, top := (sc.width - ESC_W) / 2, (480 - ESC_H) / 2
	return left + 5, top + BUTTON_H * f32(i + 1), 240, BUTTON_H
}

@(private = "file")
window_button :: proc(menu: Menu, i: int) -> (x, y, w, h: f32) {
	kick := [?][4]f32{{15, 35, 90, 25}, {265, 35, 90, 25}, {105, 55, 90, 25}, {195, 55, 80, 25}}
	maps := [?][4]f32{{15, 35, 90, 25}, {265, 35, 90, 25}, {120, 55, 90, 25}}
	b := menu == .Kick ? kick[i] : maps[i]
	return WINDOW_X + b[0], WINDOW_Y + b[1], b[2], b[3]
}

@(private = "file")
button_count :: proc(menu: Menu) -> int {
	switch menu {
	case .Esc:  return len(ESC_BUTTONS)
	case .Kick: return len(KICK_BUTTONS)
	case .Maps: return len(MAP_BUTTONS)
	case .None: return 0
	}
	return 0
}

@(private = "file")
button_rect :: proc(sc: Screen, menu: Menu, i: int) -> (x, y, w, h: f32) {
	if menu == .Esc do return esc_button(sc, i)
	return window_button(menu, i)
}

menus_open :: proc(h: ^Hud) -> bool {
	return h.menus.esc || h.menus.kick || h.menus.maps
}

menus_covers :: proc(h: ^Hud, sc: Screen, cursor: sim.Vec2) -> bool {
	x, y := cursor.x / sc.scale, cursor.y / sc.scale
	if h.menus.esc {
		left, top := (sc.width - ESC_W) / 2, (480 - ESC_H) / 2
		if x >= left && x <= left + ESC_W && y >= top && y <= top + ESC_H do return true
	}
	if h.menus.kick || h.menus.maps {
		if x >= WINDOW_X && x <= WINDOW_X + WINDOW_W && y >= WINDOW_Y && y <= WINDOW_Y + WINDOW_H do return true
	}
	return false
}

// This frame's keys and mouse for these menus. Returns whether the mouse is theirs.
menus_input :: proc(h: ^Hud, g: ^game.Game, cursor: sim.Vec2) -> (mouse_taken: bool) {
	m := &h.menus
	if rl.IsKeyPressed(.ESCAPE) {
		if m.kick || m.maps do menus_show_esc(h) // back to it from a window
		else do menus_show_esc(h, !m.esc)
	}
	// which button the cursor is over
	sc := screen()
	x, y := cursor.x / sc.scale, cursor.y / sc.scale
	m.hovered = {}
	for menu in ([]Menu{.Esc, .Kick, .Maps}) {
		if menu == .Esc && !m.esc do continue
		if menu == .Kick && !m.kick do continue
		if menu == .Maps && !m.maps do continue
		for i in 0 ..< button_count(menu) {
			bx, by, bw, bh := button_rect(sc, menu, i)
			if x >= bx && x <= bx + bw && y >= by && y <= by + bh do m.hovered = {menu, i}
		}
	}
	if m.esc {
		keys := [?]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR}
		for key, i in keys do if rl.IsKeyPressed(key) do menus_press(h, g, .Esc, i)
	}
	if m.hovered.menu != .None && rl.IsMouseButtonPressed(.LEFT) {
		menus_press(h, g, m.hovered.menu, m.hovered.button)
	}
	return menus_covers(h, sc, cursor)
}

// The escape menu opens over everything else, and closes the windows with it.
menus_show_esc :: proc(h: ^Hud, show := true) {
	m := &h.menus
	m.esc, m.kick, m.maps = show, false, false
	if !show do return
	h.menu.open, h.team.open, h.scores_shown = false, false, false
}

@(private = "file")
menus_press :: proc(h: ^Hud, g: ^game.Game, menu: Menu, button: int) {
	m := &h.menus
	switch menu {
	case .Esc:
		switch button {
		case 0: m.leaving = true // Exit to menu: there is no menu here, so the game closes
		case 1:
			m.maps, m.kick, m.esc = !m.maps, false, false
			if m.maps {
				m.index = 0
				game.ask_map(g, m.index)
			} else {
				m.esc = true
			}
		case 2:
			m.kick, m.maps, m.esc = !m.kick, false, false
			if m.kick do m.slot = kick_next(g, g.me, 1)
			else do m.esc = true
		case 3:
			m.esc = false
			h.team.open = true
		}
	case .Kick:
		switch button {
		case 0: m.slot = kick_next(g, m.slot, -1)
		case 1: m.slot = kick_next(g, m.slot, 1)
		case 2:
			if m.slot != g.me && m.slot < sim.MAX_PLAYERS {
				m.kick, m.esc = false, false
				chat_ask_reason(&h.chat, m.slot) // the vote goes when the reason is typed
			}
		case 3: // Ban: not in, as in the original
		}
	case .Maps:
		switch button {
		case 0:
			if m.index > 0 {
				m.index -= 1
				game.ask_map(g, m.index)
			}
		case 1:
			if m.index < int(g.map_list.count) - 1 {
				m.index += 1
				game.ask_map(g, m.index)
			}
		case 2:
			m.maps, m.esc = false, false
			game.call_map(g, net.text_string(&g.map_list.name))
		}
	case .None:
	}
}

// The next player in the slots, wrapping, for the kick window's arrows.
@(private = "file")
kick_next :: proc(g: ^game.Game, from: u8, step: int) -> u8 {
	at := int(from)
	for _ in 0 ..< sim.MAX_PLAYERS {
		at = (at + step + sim.MAX_PLAYERS) % sim.MAX_PLAYERS
		if g.world.soldiers[at].active do return u8(at)
	}
	return from
}

menus_draw :: proc(h: ^Hud, g: ^game.Game, sc: Screen) {
	m := &h.menus
	if m.esc {
		left, top := (sc.width - ESC_W) / 2, (480 - ESC_H) / 2
		draw_panel(h, sc, left, top, ESC_W, ESC_H)
		text(h, sc, .Small, "ESC - return to game", left + 20, top + ESC_H - 45, {250, 245, 255, 240})
		text(h, sc, .Small, "soldat-odin", left + ESC_W - 2, top + ESC_H - 14, {230, 235, 255, 190}, .Right)
		for caption, i in ESC_BUTTONS {
			draw_button(h, sc, .Esc, i, caption, {255, 255, 255, 250})
		}
	}
	if m.kick {
		draw_panel(h, sc, WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H)
		bx, by, _, _ := window_button(.Kick, 0)
		if m.slot < sim.MAX_PLAYERS && g.world.soldiers[m.slot].active {
			text(h, sc, .Menu, game.name_of(g, m.slot), bx, by - 15, shirt_color(g.world.soldiers[m.slot].team))
		}
		for caption, i in KICK_BUTTONS {
			color := rl.Color{255, 255, 255, 250}
			if i == 3 do color = {255, 255, 255, 90} // Ban is not in
			draw_button(h, sc, .Kick, i, caption, color)
		}
	}
	if m.maps {
		draw_panel(h, sc, WINDOW_X, WINDOW_Y, WINDOW_W, WINDOW_H)
		bx, by, _, _ := window_button(.Maps, 0)
		text(h, sc, .Menu, net.text_string(&g.map_list.name), bx, by - 15, {135, 235, 135, 230})
		for caption, i in MAP_BUTTONS {
			draw_button(h, sc, .Maps, i, caption, {255, 255, 255, 250})
		}
	}
}

// A button's caption, moved a pixel up and to the right while the cursor is on it, as
// the original moves its own.
@(private = "file")
draw_button :: proc(h: ^Hud, sc: Screen, menu: Menu, i: int, caption: string, color: rl.Color) {
	x, y, _, height := button_rect(sc, menu, i)
	over := f32(h.menus.hovered.menu == menu && h.menus.hovered.button == i ? 1 : 0)
	text(h, sc, .Menu, caption, x + 10 + over, y + (height - FONT_UNITS[.Menu]) / 2 - over, color)
}
