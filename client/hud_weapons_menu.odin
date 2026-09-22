#+private
package client

import "core:fmt"
import rl "vendor:raylib"
import "../shared/sim"

// The weapons menu (the original's limbo menu): ten primaries and four secondaries down
// the left of the screen. It opens when I die and when I join, and Tab opens and
// closes it. A click or a number key picks a primary and closes it; a click picks a
// secondary. What is picked is for my next spawn, and for this one too while my
// soldier has not moved since it spawned, which is also when a menu that opened by
// itself goes away.
Weapons_Menu :: struct {
	open:    bool,
	by_hand: bool, // opened with Tab: it stays until it is closed the same way, or something is picked
	hovered: int,  // the row under the cursor, or -1
}

MENU_PRIMARIES   :: [?]sim.Weapon_Id{.Eagle, .MP5, .AK74, .Steyr, .Spas, .Ruger, .M79, .Barrett, .M249, .Minigun}
MENU_SECONDARIES :: [?]sim.Weapon_Id{.Colt, .Knife, .Chainsaw, .LAW}
MENU_ROWS        :: len(MENU_PRIMARIES) + len(MENU_SECONDARIES)

// The original's layout: rows 18 apart from y 154, a row's gap before the secondaries,
// each row's icon and caption centred a little below its top.
MENU_X, MENU_Y, MENU_W, MENU_H :: 35.0, 140.0, 262.0, 290.0
ROW_X, ROW_Y, ROW_W, ROW_STEP :: 35.0, 157.0, 235.0, 18.0

menu_init :: proc(m: ^Weapons_Menu) {
	m^ = {open = true, hovered = -1}
}

menu_open :: proc(m: ^Weapons_Menu, by_hand: bool) {
	m.open, m.by_hand = true, by_hand
}

// My soldier moved: what is picked now is for the next spawn, so a menu that opened by
// itself has nothing more to offer.
menu_moved :: proc(m: ^Weapons_Menu) {
	if !m.by_hand do m.open = false
}

menu_weapon :: proc(row: int) -> sim.Weapon_Id {
	primaries, secondaries := MENU_PRIMARIES, MENU_SECONDARIES
	return row < len(primaries) ? primaries[row] : secondaries[row - len(primaries)]
}

@(private = "file")
row_top :: proc(row: int) -> f32 {
	return ROW_Y + ROW_STEP * f32(row + (row >= len(MENU_PRIMARIES) ? 1 : 0))
}

// Whether the cursor (in pixels) is over the menu: a click there is not a shot.
menu_covers :: proc(sc: Screen, cursor: sim.Vec2) -> bool {
	x, y := cursor.x / sc.scale, cursor.y / sc.scale
	return x >= MENU_X && x <= MENU_X + MENU_W && y >= MENU_Y && y <= MENU_Y + MENU_H
}

// This frame's keys and mouse for the menu. Returns whether the mouse is the menu's
// this frame, and so not the trigger.
menu_input :: proc(m: ^Weapons_Menu, g: ^Game, cursor: sim.Vec2) -> (mouse_taken: bool) {
	if rl.IsKeyPressed(.TAB) {
		if m.open do m.open = false
		else do menu_open(m, by_hand = true)
	}
	m.hovered = -1
	if !m.open do return false

	number_keys := [?]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE, .ZERO}
	for key, row in number_keys do if rl.IsKeyPressed(key) do menu_pick(m, g, row)

	sc := screen()
	x, y := cursor.x / sc.scale, cursor.y / sc.scale
	for row in 0 ..< MENU_ROWS {
		top := row_top(row)
		if x >= ROW_X && x <= ROW_X + ROW_W && y >= top && y < top + ROW_STEP do m.hovered = row
	}
	if m.hovered >= 0 && rl.IsMouseButtonPressed(.LEFT) do menu_pick(m, g, m.hovered)
	return menu_covers(sc, cursor)
}

// A primary closes the menu; a secondary leaves it open for the primary.
@(private = "file")
menu_pick :: proc(m: ^Weapons_Menu, g: ^Game, row: int) {
	weapon := menu_weapon(row)
	if row < len(MENU_PRIMARIES) {
		choose_weapons(g, weapon, g.secondary)
		m.open = false
	} else {
		choose_weapons(g, g.primary, weapon)
	}
}

menu_draw :: proc(h: ^Hud, g: ^Game, sc: Screen) {
	m := &h.menu
	draw_panel(h, sc, 45, 140, 252, 210)
	draw_panel(h, sc, 45, 350, 252, 80)
	text(h, sc, .Small, "Primary Weapon:", 65, 142, {234, 234, 234, 255})
	text(h, sc, .Small, "Secondary Weapon:", 65, 339, {214, 214, 214, 255})

	for row in 0 ..< MENU_ROWS {
		weapon := menu_weapon(row)
		top := row_top(row)
		chosen := weapon == g.primary || weapon == g.secondary
		hovered := row == m.hovered

		icon := h.guns[weapon]
		if icon.id != 0 {
			icon_height := f32(icon.height) / ART_SCALE
			tint: rl.Color = row < len(MENU_PRIMARIES) || chosen ? {255, 255, 255, 230} : {255, 255, 255, 115}
			draw_art(icon, sc, 55, top + max(0, ROW_STEP - icon_height) / 2, ART_SCALE, tint)
		}

		name := g.content.ctx.weapons[weapon].name
		caption := row < len(MENU_PRIMARIES) ? fmt.tprintf("%d %s", (row + 1) % 10, name) : name
		color := rl.Color{255, 255, 255, 230}
		x, y := f32(ROW_X + 85), top + (ROW_STEP - FONT_UNITS[.Small]) / 2
		switch {
		case chosen && hovered: color = {85, 105, 55, 230}
		case chosen:            color = {55, 165, 55, 230}
		case hovered:           x, y = x + 1, y - 1
		}
		text(h, sc, .Small, caption, x, y, color)
	}
}
