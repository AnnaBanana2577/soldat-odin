package client

import "core:math"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../shared/sim"

// The gostek: layered sprites pinned to the skeleton pose, from GostekGraphics.pas.
//
// Each part is a quad pinned between two skeleton points: it sits at p1, rotates to
// face p2, and is offset so the sprite's normalized point (cx, cy) lands on p1. Some
// parts stretch along their length (flex), most have a mirrored image for facing
// left, most have a team-2 variant. Table order is draw order. Weapons, accessories,
// the wounded overlays and the corpse variants are more entries of the same shape.

Gostek_Color :: enum u8 { None, Main, Pants, Skin, Hair }

Gostek_Part :: struct {
	file:   string, // base name under gostek-gfx
	p1, p2: int,    // skeleton points, the original's 1-based numbering
	cx, cy: f32,    // anchor within the sprite, 0..1
	flex:   f32,    // if > 0, stretch along the part's length
	flip:   bool,   // has a mirrored "<file>2" image for facing left
	team:   bool,   // has a team2/<file> variant
	color:  Gostek_Color,
	jets:   bool,   // drawn only while jetting (replaces the matching foot)
	foot:   bool,   // hidden while jetting
}

GOSTEK_PARTS := [?]Gostek_Part{
	{file = "udo",       p1 = 6,  p2 = 3,  cx = 0.2,  cy = 0.5,  flex = 5, flip = true, team = true, color = .Pants},
	{file = "stopa",     p1 = 2,  p2 = 18, cx = 0.35, cy = 0.35, flip = true, team = true, foot = true},
	{file = "lecistopa", p1 = 2,  p2 = 18, cx = 0.35, cy = 0.35, flip = true, team = true, jets = true},
	{file = "noga",      p1 = 3,  p2 = 2,  cx = 0.15, cy = 0.55, flip = true, team = true, color = .Pants},
	{file = "ramie",     p1 = 11, p2 = 14, cx = 0,    cy = 0.5,  flip = true, team = true, color = .Main},
	{file = "reka",      p1 = 14, p2 = 15, cx = 0,    cy = 0.5,  flex = 5, team = true, color = .Main},
	{file = "dlon",      p1 = 15, p2 = 19, cx = 0,    cy = 0.4,  flip = true, team = true, color = .Skin},
	{file = "udo",       p1 = 5,  p2 = 4,  cx = 0.2,  cy = 0.65, flex = 5, flip = true, team = true, color = .Pants},
	{file = "stopa",     p1 = 1,  p2 = 17, cx = 0.35, cy = 0.35, flip = true, team = true, foot = true},
	{file = "lecistopa", p1 = 1,  p2 = 17, cx = 0.35, cy = 0.35, flip = true, team = true, jets = true},
	{file = "noga",      p1 = 4,  p2 = 1,  cx = 0.15, cy = 0.55, flip = true, team = true, color = .Pants},
	{file = "klata",     p1 = 10, p2 = 11, cx = 0.1,  cy = 0.3,  flip = true, team = true, color = .Main},
	{file = "biodro",    p1 = 5,  p2 = 6,  cx = 0.25, cy = 0.6,  flip = true, team = true, color = .Main},
	{file = "morda",     p1 = 9,  p2 = 12, cx = 0,    cy = 0.5,  flip = true, team = true, color = .Skin},
	{file = "ramie",     p1 = 10, p2 = 13, cx = 0,    cy = 0.6,  flip = true, team = true, color = .Main},
	{file = "reka",      p1 = 13, p2 = 16, cx = 0,    cy = 0.6,  flex = 5, team = true, color = .Main},
	{file = "dlon",      p1 = 16, p2 = 20, cx = 0,    cy = 0.5,  flip = true, team = true, color = .Skin},
}

// The right upper arm: the held weapon goes just before it so the arm wraps the grip.
RIGHT_ARM_PART :: len(GOSTEK_PARTS) - 3

// Held weapons: the primary in the hands (skeleton 16 -> 15), the secondary slung
// across the back (5 -> 10). Mirrored images are "<stem>-2.png" under weapons-gfx.
Weapon_Art :: struct {
	stem:   string,
	cx, cy: f32, // in the hands
	bx, by: f32, // on the back
	fire:   string, // the muzzle flash, drawn the tick a shot goes off
	fx, fy: f32,    // its anchor, past the muzzle so fx is negative
}

WEAPON_ART := #partial [sim.Weapon_Id]Weapon_Art{
	.Eagle    = {"deserteagle", 0.1,  0.8,  0.3, 0.5,  "eagles-fire",   -0.5,  1},
	.MP5      = {"mp5",         0.15, 0.6,  0.3, 0.3,  "mp5-fire",      -0.65, 0.85},
	.AK74     = {"ak74",        0.15, 0.5,  0.3, 0.25, "ak74-fire",     -0.37, 0.8},
	.Steyr    = {"steyraug",    0.2,  0.6,  0.3, 0.5,  "steyraug-fire", -0.24, 0.75},
	.Spas     = {"spas12",      0.1,  0.6,  0.3, 0.3,  "spas12-fire",   -0.2,  0.9},
	.Ruger    = {"ruger77",     0.1,  0.7,  0.3, 0.3,  "ruger77-fire",  -0.35, 0.85},
	.M79      = {"m79",         0.1,  0.7,  0.3, 0.35, "m79-fire",      -0.4,  0.8},
	.Barrett  = {"barretm82",   0.15, 0.7,  0.3, 0.35, "barret-fire",   -0.15, 0.8},
	.M249     = {"m249",        0.15, 0.6,  0.3, 0.35, "m249-fire",     -0.2,  0.9},
	.Minigun  = {"minigun",     0.05, 0.5,  0.2, 0.5,  "minigun-fire",  -0.2,  0.45},
	.Colt     = {"colt1911",    0.2,  0.55, 0.3, 0.5,  "colt1911-fire", -0.24, 0.85},
	.Chainsaw = {"chainsaw",    0.25, 0.5,  0.25, 0.5, "chainsaw-fire", -0.2,  0.5},
	.LAW      = {"law",         0.1,  0.6,  0.3, 0.45, "law-fire",      -0.2,  0.8},
	.Flamer   = {"flamer",      0.3,  0.6,  0.3, 0.3,  "flamer-fire",   -0.2,  0.5},
	.Bow      = {"bow",         0.2,  0.5,  0.3, 0.5,  "bow-fire",      -0.2,  0.5},
	.Bow2     = {"bow",         0.2,  0.5,  0.3, 0.5,  "bow-fire",      -0.2,  0.5},
	.Knife    = {"knife",       0.2,  0.5,  0.3, 0.5,  "",               0,    0},
}

// One sprite per (part, team2, mirrored), plus the weapons and their flashes.
Gostek :: struct {
	parts:   [len(GOSTEK_PARTS)][2][2]Sprite,
	weapons: [sim.Weapon_Id][2]Sprite, // [mirrored]
	flashes: [sim.Weapon_Id]Sprite,
	loaded:  bool,
}

gostek_load :: proc(g: ^Gostek, base: string) {
	for art, id in WEAPON_ART {
		if art.stem == "" do continue
		for mirrored in 0 ..< 2 {
			name := strings.concatenate({art.stem, mirrored == 1 ? "-2.png" : ".png"}, context.temp_allocator)
			path, _ := filepath.join({base, "weapons-gfx", name}, context.temp_allocator)
			if s, ok := sprite_load(path); ok do g.weapons[id][mirrored] = s
		}
		if art.fire != "" {
			name := strings.concatenate({art.fire, ".png"}, context.temp_allocator)
			path, _ := filepath.join({base, "weapons-gfx", name}, context.temp_allocator)
			if s, ok := sprite_load(path); ok do g.flashes[id] = s
		}
	}
	for part, i in GOSTEK_PARTS {
		for team in 0 ..< 2 {
			for mirrored in 0 ..< 2 {
				name := part.file
				if mirrored == 1 {
					if !part.flip do continue // no mirrored image: the quad flips instead
					name = strings.concatenate({part.file, "2"}, context.temp_allocator)
				}
				dir := team == 1 && part.team ? "gostek-gfx/team2" : "gostek-gfx"
				file := strings.concatenate({name, ".png"}, context.temp_allocator)
				path, _ := filepath.join({base, dir, file}, context.temp_allocator)
				if s, ok := sprite_load(path); ok do g.parts[i][team][mirrored] = s
			}
		}
	}
	g.loaded = true
}

gostek_unload :: proc(g: ^Gostek) {
	for &part in g.parts do for &team in part do for &s in team do sprite_unload(&s)
	for &weapon in g.weapons do for &s in weapon do sprite_unload(&s)
	for &s in g.flashes do sprite_unload(&s)
	g^ = {}
}

// Draws one living soldier at pos.
// The soldier's sprites on a pose: the animated one alive, the ragdoll's as a corpse.
// A corpse's face hangs from the head point rather than the neck, so a cut head rolls
// off with it.
gostek_draw :: proc(g: ^Gostek, s: ^sim.Soldier, pose: ^sim.Pose, corpse: bool) {
	if !g.loaded do return
	pose := pose^
	jetting := .Jet in s.controls && s.jets > 0 && !corpse
	team := s.team == .Bravo || s.team == .Delta ? 1 : 0
	facing_left := s.direction != 1

	// slung across the back, so before the body
	if art := WEAPON_ART[s.secondary.id]; art.stem != "" {
		draw_weapon(g, &pose, s.secondary.id, 5, 10, art.bx, art.by, facing_left)
	}

	for part, i in GOSTEK_PARTS {
		if i == RIGHT_ARM_PART do draw_held_weapon(g, &pose, s, facing_left)
		if part.jets && !jetting do continue
		if part.foot && jetting do continue

		mirrored := facing_left && part.flip
		sprite := g.parts[i][part.team ? team : 0][mirrored ? 1 : 0]
		if sprite.tex.id == 0 do continue

		p1 := pose[part.p1 - 1]
		p2 := pose[part.p2 - 1]
		along := p2 - p1
		angle := math.atan2(along.y, along.x)

		cx, cy := part.cx, part.cy
		if corpse && part.p2 == 12 do p1, cx = p2, 1
		sx, sy: f32 = 1, 1
		if facing_left {
			if part.flip do cy = 1 - part.cy
			else do sy = -1
		}
		if part.flex > 0 do sx = min(1.5, sim.vec2_length(along) / part.flex)
		draw_sprite(sprite, p1 + {0, 1}, {cx * sprite.width, cy * sprite.height}, {sx, sy}, angle, gostek_color(part.color, s))
	}
	rlgl.SetTexture(0)
}

@(private = "file")
draw_held_weapon :: proc(g: ^Gostek, pose: ^sim.Pose, s: ^sim.Soldier, facing_left: bool) {
	art := WEAPON_ART[s.weapon.id]
	if art.stem == "" do return
	draw_weapon(g, pose, s.weapon.id, 16, 15, art.cx, art.cy, facing_left)
	if !s.fired do return
	flash := g.flashes[s.weapon.id]
	if flash.tex.id == 0 do return
	p1, p2 := pose[16 - 1], pose[15 - 1]
	along := p2 - p1
	draw_sprite(flash, p1 + {0, 1}, {art.fx * flash.width, art.fy * flash.height}, {1, facing_left ? -1 : 1}, math.atan2(along.y, along.x), rl.WHITE)
}

// A weapon pinned between two skeleton points, the same way a limb is.
@(private = "file")
draw_weapon :: proc(g: ^Gostek, pose: ^sim.Pose, id: sim.Weapon_Id, p1_index, p2_index: int, cx, cy: f32, facing_left: bool) {
	mirrored := facing_left
	sprite := g.weapons[id][mirrored ? 1 : 0]
	if sprite.tex.id == 0 {
		sprite = g.weapons[id][0]
		if sprite.tex.id == 0 do return
		mirrored = false
	}
	p1 := pose[p1_index - 1]
	p2 := pose[p2_index - 1]
	along := p2 - p1
	angle := math.atan2(along.y, along.x)
	anchor_y := cy
	sy: f32 = 1
	if facing_left {
		if mirrored do anchor_y = 1 - cy
		else do sy = -1
	}
	draw_sprite(sprite, p1 + {0, 1}, {cx * sprite.width, anchor_y * sprite.height}, {1, sy}, angle, rl.WHITE)
}

// Shirt, pants and skin. The original takes these from each player's profile; fixed
// per team until the roster carries them.
gostek_color :: proc(c: Gostek_Color, s: ^sim.Soldier) -> rl.Color {
	alpha: u8 = s.cease_fire_counter >= 0 ? 153 : 255
	switch c {
	case .None:  return {255, 255, 255, alpha}
	case .Skin:  return {222, 181, 140, alpha}
	case .Hair:  return {64, 46, 31, alpha}
	case .Pants: return {56, 61, 71, alpha}
	case .Main:
		#partial switch s.team {
		case .Alpha:   return {199, 56, 51, alpha}
		case .Bravo:   return {64, 107, 204, alpha}
		case .Charlie: return {230, 199, 64, alpha}
		case .Delta:   return {77, 179, 89, alpha}
		}
		return {140, 140, 148, alpha}
	}
	return {255, 255, 255, alpha}
}

