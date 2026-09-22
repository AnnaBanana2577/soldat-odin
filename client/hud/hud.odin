// Package hud is what is drawn over the world, and the menus in it: my soldier's bars
// and counts, the kill feed, the chat, the weapons and team menus, the scoreboard, the
// messages across the middle, the crosshair. Ported from InterfaceGraphics.pas with its default layout.
//
// The original lays its interface out on a screen 640 by 480. So does this: every
// position below is in those units, `scale` pixels each, and the x positions spread
// over the window's width the way the original's do on a wide screen (Screen).
//
// It reads the game and tells it what the player chose: weapons (game.choose_weapons),
// a team (game.choose_team), a line to say (game.say).
package hud

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import "../game"
import "../render"
import "../../shared/sim"

Hud :: struct {
	art:    [Art]rl.Texture2D,
	guns:   [sim.Weapon_Id]rl.Texture2D, // the kill feed's and the menu's icons
	fonts:  [Font]rl.Font,
	feed:   Kill_Feed,
	menu:   Weapons_Menu,
	team:   Team_Menu,
	menus:  Menus, // the escape menu and the vote windows
	chat:   Chat,
	big:    Big_Message,
	was_dead, was_ended: bool,
	team_was: sim.Team, // my soldier's team a tick ago: a change is the server moving me
	scores_shown: bool, // F1
	minimap_shown: bool, // F3; off until it is asked for, as in the original
}

Art :: enum { Health, Health_Bar, Vest_Bar, Ammo, Ammo_Bar, Fire_Bar, Fire_Bar_Back, Jet, Jet_Bar, Nade, Cluster_Nade, Back, Flag, No_Flag, Cursor, Menu_Cursor, Small_Dot }

ART_FILES := [Art]string {
	.Health = "health.png", .Health_Bar = "health-bar.png", .Vest_Bar = "vest-bar.png",
	.Ammo = "ammo.png", .Ammo_Bar = "reload-bar.png", .Fire_Bar = "fire-bar.png", .Fire_Bar_Back = "fire-bar-r.png",
	.Jet = "jet.png", .Jet_Bar = "jet-bar.png", .Nade = "nade.png", .Cluster_Nade = "cluster-nade.png",
	.Back = "back.png", .Flag = "flag.png", .No_Flag = "noflag.png", .Cursor = "cursor.png", .Menu_Cursor = "menucursor.png",
	.Small_Dot = "smalldot.png",
}

GUN_FILES := #partial [sim.Weapon_Id]string {
	.Eagle = "guns/1.png", .MP5 = "guns/2.png", .AK74 = "guns/3.png", .Steyr = "guns/4.png", .Spas = "guns/5.png",
	.Ruger = "guns/6.png", .M79 = "guns/7.png", .Barrett = "guns/8.png", .M249 = "guns/9.png", .Minigun = "guns/0.png", // numbered by their keys in the menu
	.Colt = "guns/10.png", .Knife = "guns/knife.png", .Thrown_Knife = "guns/knife.png", .Chainsaw = "guns/chainsaw.png",
	.LAW = "guns/law.png", .Flamer = "guns/flamer.png", .Bow = "guns/bow.png", .Bow2 = "guns/bow.png", .M2 = "guns/m2.png",
	.None = "guns/fist.png", .Frag = "nade.png", .Cluster_Nade = "cluster-nade.png", .Cluster = "cluster-nade.png",
}

ART_SCALE    :: 4.5  // the art's pixels per unit (mod.ini DefaultScale)
CURSOR_SCALE :: 10.0 // but the crosshair's

// Sizes in units: font.ini's point sizes as pixels on the 480-line screen.
Font :: enum { Tiny, Small, Menu, Big }
FONT_UNITS := [Font]f32{.Tiny = 11, .Small = 12, .Menu = 16, .Big = 37}

// ---- the screen ----

Screen :: struct {
	scale: f32, // pixels per unit
	width: f32, // in units: 640 on a 4:3 window, more on a wider one
}

screen :: proc() -> Screen {
	scale := f32(rl.GetScreenHeight()) / 480
	return {scale, f32(rl.GetScreenWidth()) / scale}
}

// An x of the original's layout on this screen: spread over its width.
spread :: proc(sc: Screen, x: f32) -> f32 {
	return x * sc.width / 640
}

// A position laid out beside an anchor: the anchor spreads, the offset from it does not.
beside :: proc(sc: Screen, x, anchor: f32) -> f32 {
	return spread(sc, anchor) + (x - anchor)
}

// ---- opening and closing ----

// The interface art and the font, from `base`. The window must be open.
init :: proc(h: ^Hud, base: string) {
	for file, id in ART_FILES do h.art[id] = texture_load(base, file)
	for file, id in GUN_FILES do if file != "" do h.guns[id] = texture_load(base, file)
	sc := screen()
	font_path := font_find(base)
	for units, id in FONT_UNITS {
		h.fonts[id] = rl.GetFontDefault()
		if font_path == "" do continue
		if f := rl.LoadFontEx(strings.clone_to_cstring(font_path, context.temp_allocator), i32(units * sc.scale + 0.5), nil, 0); f.texture.id != 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			h.fonts[id] = f
		}
	}
	menu_init(&h.menu)
	rl.SetExitKey(.KEY_NULL) // Escape opens the menu; the game is left from there
	rl.HideCursor() // the crosshair is drawn
}

destroy :: proc(h: ^Hud) {
	for t in h.art do if t.id != 0 do rl.UnloadTexture(t)
	for t in h.guns do if t.id != 0 do rl.UnloadTexture(t)
	default_font := rl.GetFontDefault()
	for f in h.fonts do if f.texture.id != default_font.texture.id do rl.UnloadFont(f)
	rl.ShowCursor()
}

@(private)
texture_load :: proc(base, file: string) -> rl.Texture2D {
	path, _ := filepath.join({base, "interface-gfx", file}, context.temp_allocator)
	if !os.exists(path) do return {}
	t := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
	if t.id != 0 do rl.SetTextureFilter(t, .BILINEAR)
	return t
}

// The original's font ships beside the shared folder, or in it.
@(private)
font_find :: proc(base: string) -> string {
	for dir in ([]string{"..", "."}) {
		path, _ := filepath.join({base, dir, "play-regular.ttf"}, context.temp_allocator)
		if os.exists(path) do return path
	}
	return ""
}

// ---- the frame's input ----

// This frame's keys and mouse for the HUD: the chat first, which has the whole keyboard
// while a line is typed; F1 for the scoreboard; the weapons and team menus. Returns
// what of the keys and the mouse the HUD took this frame, which the game does not hear.
input :: proc(h: ^Hud, g: ^game.Game, cursor: sim.Vec2) -> (mouse_taken, keys_taken: bool) {
	if chat_input(&h.chat, g) do return false, true
	if vote_input(h, g) do return false, false
	mouse_taken = menus_input(h, g, cursor)
	if menus_open(h) do return mouse_taken, false // the soldier still hears its own keys
	if rl.IsKeyPressed(.F1) do h.scores_shown = !h.scores_shown
	if rl.IsKeyPressed(.F3) do h.minimap_shown = !h.minimap_shown
	if rl.IsKeyPressed(.TAB) do h.team.open = false // the weapons menu's key: one menu at a time
	// the weapons menu first: a team picked opens it, and this frame's keys are the team menu's
	mouse_taken = menu_input(&h.menu, g, cursor) || mouse_taken
	mouse_taken = team_menu_input(h, g, cursor) || mouse_taken
	return mouse_taken, false
}

// Whether Exit to menu was pressed on the escape menu: the game closes, there being
// no menu here to go back to.
leaving :: proc(h: ^Hud) -> bool {
	return h.menus.leaving
}

// ---- the tick ----

// Once per tick: the kills into the feed and across the screen, the feed scrolling
// off, the lines heard; the weapons menu opening when I die, when a round begins and
// when the server moves me to the other team, and closing when my soldier first moves
// and when a round ends.
tick :: proc(h: ^Hud, g: ^game.Game) {
	for e in sim.events_slice(&g.events) {
		if kill, is_kill := e.(sim.Kill); is_kill {
			feed_add(&h.feed, g, kill)
			big_kill(&h.big, g, kill)
		}
	}
	feed_tick(&h.feed)
	chat_tick(&h.chat, g)
	if h.big.ticks > 0 do h.big.ticks -= 1

	mine := &g.world.soldiers[g.me]
	dead := !mine.active || mine.dead
	if dead && !h.was_dead && !h.team.open do menu_open(&h.menu, by_hand = false)
	if !dead && !mine.spawn_still do menu_moved(&h.menu)
	h.was_dead = dead
	if mine.active && mine.team != h.team_was {
		if h.team_was != .None do menu_open(&h.menu, by_hand = false)
		h.team_was = mine.team
	}

	ended := g.world.round.state == .Ended
	if ended && !h.was_ended do h.menu.open, h.team.open = false, false
	if !ended && h.was_ended do menu_open(&h.menu, by_hand = false)
	h.was_ended = ended
}

// ---- the frame ----

// Over the world, in the original's order: the bars and counts, the feed, the menu, the
// scoreboard, the messages, the cursor last. `cursor` is the mouse in pixels; the
// camera and `alpha` place a line said over its speaker's head. The scoreboard covers
// the top of the screen, so the feed and my ping make way for it.
draw :: proc(h: ^Hud, g: ^game.Game, r: ^render.Render, camera: ^render.Camera, cursor: sim.Vec2, alpha: f32) {
	sc := screen()
	mine := &g.world.soldiers[g.me]
	alive := mine.active && !mine.dead
	if alive do draw_bars(h, g, sc, mine)
	ended := g.world.round.state == .Ended
	scores := h.scores_shown || ended
	draw_status(h, g, sc, mine)
	minimap_draw(h, g, sc, r, camera)
	if !scores {
		feed_draw(h, g, sc)
		text(h, sc, .Small, fmt.tprintf("%d ms", g.my_lag * 1000 / sim.TICK_RATE), spread(sc, 600), 18, {200, 200, 200, 200})
	}
	chat_draw(h, g, sc, camera, alpha)
	if h.menu.open do menu_draw(h, g, sc)
	if h.team.open do team_menu_draw(h, g, sc)
	menus_draw(h, g, sc)
	vote_draw(h, g, sc)
	vote_reason_draw(h, sc)
	if mine.active && mine.dead do draw_respawn(h, sc, mine)
	names_draw(h, g, sc, camera, alpha)
	if scores do scoreboard_draw(h, g, sc)
	if !ended do big_draw(h, sc)

	over_menu := (h.menu.open && menu_covers(sc, cursor)) || (h.team.open && team_menu_covers(sc, cursor)) ||
		menus_covers(h, sc, cursor)
	if over_menu {
		draw_art(h.art[.Menu_Cursor], sc, cursor.x / sc.scale, cursor.y / sc.scale, ART_SCALE, rl.WHITE)
	} else if alive {
		t := h.art[.Cursor]
		half := f32(t.width) / CURSOR_SCALE / 2
		draw_art(t, sc, cursor.x / sc.scale - half, cursor.y / sc.scale - half, CURSOR_SCALE, {255, 255, 255, 200})
	}
}

// Health, vest, ammo or the reload, the fire interval, the jets, the grenades; the ammo
// count and the weapon's name. Each bar sits beside its icon.
@(private)
draw_bars :: proc(h: ^Hud, g: ^game.Game, sc: Screen, s: ^sim.Soldier) {
	info := &g.ctx.weapons[s.weapon.id]

	draw_art(h.art[.Health], sc, spread(sc, 5), 439, ART_SCALE, rl.WHITE)
	draw_bar(h.art[.Health_Bar], sc, beside(sc, 45, 5), 449, s.health / sim.DEFAULT_HEALTH)
	if s.vest > 0 do draw_bar(h.art[.Vest_Bar], sc, beside(sc, 45, 5), 459, s.vest / sim.DEFAULT_VEST)

	draw_art(h.art[.Ammo], sc, spread(sc, 275), 439, ART_SCALE, rl.WHITE)
	if s.weapon.ammo == 0 && s.weapon.id != .Spas && info.reload_time > 0 {
		draw_bar(h.art[.Ammo_Bar], sc, beside(sc, 352, 275), 449, 1 - f32(s.weapon.reload_count) / f32(info.reload_time))
	} else if s.weapon.ammo > 0 && info.ammo > 0 {
		draw_bar(h.art[.Ammo_Bar], sc, beside(sc, 352, 275), 449, f32(s.weapon.ammo) / f32(info.ammo))
	}
	draw_art(h.art[.Fire_Bar_Back], sc, beside(sc, 402, 275), 464, ART_SCALE, rl.WHITE)
	if info.fire_interval > 0 do draw_bar(h.art[.Fire_Bar], sc, beside(sc, 409, 275), 464, f32(s.weapon.fire_count) / f32(info.fire_interval), from_right = true)

	draw_art(h.art[.Jet], sc, spread(sc, 480), 439, ART_SCALE, rl.WHITE)
	if g.level.start_jet > 0 do draw_bar(h.art[.Jet_Bar], sc, beside(sc, 520, 480), 449, f32(s.jets) / f32(g.level.start_jet))

	nade := h.art[.Nade]
	for j in 1 ..= int(s.grenades) {
		draw_art(nade, sc, beside(sc, 308, 275) + f32(nade.width) / ART_SCALE * f32(j), 462, ART_SCALE, rl.WHITE)
	}

	text(h, sc, .Menu, fmt.tprint(s.weapon.ammo), beside(sc, 348, 275), 451, {242, 244, 40, 255}, .Right)
	text(h, sc, .Tiny, info.name, beside(sc, 285, 275), 454, {255, 245, 177, 255}, .Right)
}

// The corner of the screen that says how the round stands: the flags and the teams'
// scores, and my place among the players and my kills.
@(private)
draw_status :: proc(h: ^Hud, g: ^game.Game, sc: Screen, mine: ^sim.Soldier) {
	w := &g.world
	x := spread(sc, 575)
	has_flags := false
	for &t in w.things do if sim.is_flag(t.style) do has_flags = true
	if has_flags {
		draw_panel(h, sc, x, 330, 57, 88, 143) // Int.Alpha * 0.56 in the original

		// A flag shows only while it is away from its base, and always as noflag.png:
		// the box warns that a flag is out, it is not a pair of indicators. The two sit
		// side by side across the top of it (the CTF branch of the original's team box).
		for &t in w.things {
			if !sim.is_flag(t.style) || t.in_base do continue
			alpha_team := sim.flag_team(t.style) == .Alpha
			tint := alpha_team ? rl.Color{255, 0, 0, 255} : rl.Color{0, 0, 255, 255}
			draw_art(h.art[.No_Flag], sc, x + (alpha_team ? 4 : 35), 335, ART_SCALE, tint)
		}

		// The scores below them, the leading team's on top, each in its own colour: the
		// original sorts SortedTeamScore by score and the colour travels with the team.
		Team_Row :: struct {
			score: i32,
			tint:  rl.Color,
		}
		rows := [2]Team_Row{
			{w.round.scores[.Alpha], {210, 15, 5, 255}},
			{w.round.scores[.Bravo], {5, 15, 210, 255}},
		}
		if rows[1].score > rows[0].score do rows[0], rows[1] = rows[1], rows[0]
		for r, i in rows do text(h, sc, .Menu, fmt.tprint(r.score), x + 2, 355 + f32(i) * 40, r.tint)
	}

	if mine.active {
		place, players, best_other := 1, 0, min(i32)
		for &o, i in w.soldiers {
			if !o.active || o.team == .Spectator do continue
			players += 1
			if u8(i) == g.me do continue
			if o.kills > mine.kills do place += 1
			best_other = max(best_other, o.kills)
		}
		text(h, sc, .Small, fmt.tprintf("%d/%d", place, players), x, 421, {88, 255, 90, 255})

		// Leading, the gap back to the second; otherwise the gap up to the leader, which
		// is negative and carries its own sign. The original signs only a gain.
		lead := fmt.tprint(mine.kills)
		if players > 1 {
			gap := mine.kills - best_other
			lead = fmt.tprintf("%d (%s%d)", mine.kills, gap > 0 ? "+" : "", gap)
		}
		text(h, sc, .Small, lead, x, 431, {255, 55, 50, 255})

		// What it takes to win, under the two of them.
		text(h, sc, .Small, fmt.tprint(w.round.score_limit), x, 441, {114, 120, 255, 255})
	}

	// The bonus in hand and how long is left of it, by the middle of the bars.
	bonus_name := ""
	switch mine.bonus {
	case .None:
	case .Flame_God: bonus_name = "Flame God"
	case .Predator:  bonus_name = "Predator"
	case .Berserker: bonus_name = "Berserker"
	}
	if bonus_name != "" {
		left := f32(max(mine.bonus_time, 0)) / sim.TICK_RATE
		text(h, sc, .Menu, fmt.tprintf("%s - %.1f", bonus_name, left), spread(sc, 190), 435, {245, 40, 50, 255})
	}
}

@(private)
draw_respawn :: proc(h: ^Hud, sc: Screen, mine: ^sim.Soldier) {
	if mine.respawn_counter <= 0 do return
	draw_panel(h, sc, spread(sc, 180), 1, 300, 22)
	line := fmt.tprintf("Respawn in... %.1f", f32(mine.respawn_counter) / sim.TICK_RATE)
	text(h, sc, .Menu, line, spread(sc, 180) + 150, 4, {255, 65, 55, 255}, .Center)
}

// ---- the messages across the middle ----

Big_Message :: struct {
	line:  [64]u8,
	len:   int,
	color: rl.Color,
	ticks: int, // left to show
}

BIG_TICKS :: 4 * sim.TICK_RATE

// A kill of mine, or my death, said large (the original's BigMessage).
@(private)
big_kill :: proc(b: ^Big_Message, g: ^game.Game, kill: sim.Kill) {
	line: string
	switch {
	case kill.killer == g.me && kill.target == g.me: line, b.color = "You killed yourself", {197, 48, 37, 255}
	case kill.killer == g.me: line, b.color = fmt.tprintf("You killed %s", game.name_of(g, kill.target)), {234, 53, 48, 255}
	case kill.target == g.me: line, b.color = fmt.tprintf("Killed by %s", game.name_of(g, kill.killer)), {197, 48, 37, 255}
	case: return
	}
	b.len = copy(b.line[:], line)
	b.ticks = BIG_TICKS
}

@(private)
big_draw :: proc(h: ^Hud, sc: Screen) {
	b := &h.big
	if b.ticks <= 0 do return
	color := b.color
	color.a = u8(min(3 * b.ticks + 25, 255)) // fading out at the end
	text(h, sc, .Big, string(b.line[:b.len]), sc.width / 2, 385, color, .Center)
}

// ---- drawing in units ----

// A piece of art with its top-left at (x, y), `art_scale` of its pixels to the unit.
@(private)
draw_art :: proc(t: rl.Texture2D, sc: Screen, x, y: f32, art_scale: f32, tint: rl.Color, shrink: f32 = 1) {
	if t.id == 0 do return
	w, h := f32(t.width) / art_scale * shrink, f32(t.height) / art_scale * shrink
	rl.DrawTexturePro(t, {0, 0, f32(t.width), f32(t.height)}, {x * sc.scale, y * sc.scale, w * sc.scale, h * sc.scale}, {}, 0, tint)
}

// A bar filled to `part` of its length (RenderBar): the image cropped, from the left or
// from the right.
@(private)
draw_bar :: proc(t: rl.Texture2D, sc: Screen, x, y: f32, part: f32, from_right := false) {
	if t.id == 0 do return
	p := clamp(part, 0, 1)
	w, h := f32(t.width), f32(t.height)
	src := rl.Rectangle{from_right ? w * (1 - p) : 0, 0, w * p, h}
	rl.DrawTexturePro(t, src, {(x + src.x / ART_SCALE) * sc.scale, y * sc.scale, src.width / ART_SCALE * sc.scale, h / ART_SCALE * sc.scale}, {}, 0, rl.WHITE)
}

// The translucent panel behind the menus and boxes: back.png stretched.
@(private)
draw_panel :: proc(h: ^Hud, sc: Screen, x, y, w, height: f32, alpha: u8 = 112) {
	t := h.art[.Back]
	if t.id == 0 do return
	rl.DrawTexturePro(t, {0, 0, f32(t.width), f32(t.height)}, {x * sc.scale, y * sc.scale, w * sc.scale, height * sc.scale}, {}, 0, {255, 255, 255, alpha})
}

Align :: enum { Left, Right, Center }

// A line of text with its top at y, over a shadow.
@(private)
text :: proc(h: ^Hud, sc: Screen, font: Font, line: string, x, y: f32, color: rl.Color, align := Align.Left) {
	if line == "" do return
	f := h.fonts[font]
	size := FONT_UNITS[font] * sc.scale
	c := strings.clone_to_cstring(line, context.temp_allocator)
	px := x * sc.scale
	switch align {
	case .Left:
	case .Right:  px -= rl.MeasureTextEx(f, c, size, 0).x
	case .Center: px -= rl.MeasureTextEx(f, c, size, 0).x / 2
	}
	at := rl.Vector2{f32(int(px)), f32(int(y * sc.scale))}
	shadow := rl.Color{0, 0, 0, color.a}
	rl.DrawTextEx(f, c, at + sc.scale, size, 0, shadow)
	rl.DrawTextEx(f, c, at, size, 0, color)
}

@(private)
text_width :: proc(h: ^Hud, sc: Screen, font: Font, line: string) -> f32 {
	c := strings.clone_to_cstring(line, context.temp_allocator)
	return rl.MeasureTextEx(h.fonts[font], c, FONT_UNITS[font] * sc.scale, 0).x / sc.scale
}

// A menu opened by name, for a capture of it (dbg_menu). Nothing in the game calls it.
open_menu :: proc(h: ^Hud, g: ^game.Game, which: string) {
	switch which {
	case "esc":     menus_show_esc(h)
	case "kick":
		menus_show_esc(h)
		h.menus.esc, h.menus.kick = false, true
		h.menus.slot = g.me
	case "map":
		menus_show_esc(h)
		h.menus.esc, h.menus.maps = false, true
		game.ask_map(g, 0)
	case "team":    h.team.open = true
	case "weapons": menu_open(&h.menu, by_hand = true)
	case "scores":  h.scores_shown = true
	}
}
