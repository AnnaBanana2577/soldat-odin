package client

import "core:math"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import "../shared/sim"

// The things as drawn, from TThing.Render and TThing.PolygonsRender: the flag's
// cloth is a quad stretched over its skeleton points so it flutters with the physics,
// with a handle along the pole and a pulsing glow in base; a kit is a quad over its
// box; a dropped gun hangs from its grip end along the grip-to-muzzle line.

// The loose art of dropped guns: the held art, except the pistols and the bow, which
// have a version without the hand.
GUN_ART := #partial [sim.Weapon_Id]string{
	.Eagle = "n-deserteagle", .MP5 = "mp5", .AK74 = "ak74", .Steyr = "steyraug", .Spas = "spas12", .Ruger = "ruger77",
	.M79 = "m79", .Barrett = "barretm82", .M249 = "m249", .Minigun = "minigun", .Colt = "n-colt1911", .Knife = "knife",
	.Chainsaw = "chainsaw", .LAW = "law", .Bow = "n-bow", .Bow2 = "n-bow", .Flamer = "flamer",
}

KIT_ART := #partial [sim.Thing_Style]string{
	.Medical_Kit = "medikit", .Grenade_Kit = "grenadekit", .Flamer_Kit = "flamerkit", .Predator_Kit = "predatorkit",
	.Vest_Kit = "vestkit", .Berserk_Kit = "berserkerkit", .Cluster_Kit = "clusterkit",
}

Things_Art :: struct {
	cloth:   Sprite, // textures/objects/flag.bmp, grey, tinted per team
	kits:    [sim.Thing_Style]Sprite,
	handle:  Sprite, // objects-gfx/flag.png, along the pole
	glow:    Sprite, // objects-gfx/ilum.png, the in-base pulse
	guns:    [sim.Weapon_Id][2]Sprite, // [flipped]
	para:    [2]Sprite, // gostek-gfx/para.png, para2.png
	rope:    Sprite,
	m2_base: Sprite,
	m2:      [2]Sprite, // [flipped]
	loaded:  bool,
}

// The cloth tints: base, top, low, so it reads as lit from one side.
ALPHA_TINT := [3]rl.Color{{173, 20, 20, 255}, {181, 20, 20, 255}, {148, 20, 20, 255}}
BRAVO_TINT := [3]rl.Color{{5, 15, 173, 255}, {5, 15, 181, 255}, {5, 15, 148, 255}}

things_art_load :: proc(a: ^Things_Art, base: string) {
	load :: proc(base: string, parts: ..string) -> Sprite {
		all := make([]string, len(parts) + 1, context.temp_allocator)
		all[0] = base
		copy(all[1:], parts)
		path, _ := filepath.join(all, context.temp_allocator)
		s, _ := sprite_load(path, COLOR_KEY_GREEN)
		return s
	}
	a.cloth = load(base, "textures", "objects", "flag.bmp")
	for stem, style in KIT_ART {
		if stem != "" do a.kits[style] = load(base, "textures", "objects", strings.concatenate({stem, ".png"}, context.temp_allocator))
	}
	a.handle = load(base, "objects-gfx", "flag.png")
	a.glow = load(base, "objects-gfx", "ilum.png")
	for stem, id in GUN_ART {
		if stem == "" do continue
		a.guns[id][0] = load(base, "weapons-gfx", strings.concatenate({stem, ".png"}, context.temp_allocator))
		a.guns[id][1] = load(base, "weapons-gfx", strings.concatenate({stem, "-2.png"}, context.temp_allocator))
	}
	a.para[0] = load(base, "gostek-gfx", "para.png")
	a.para[1] = load(base, "gostek-gfx", "para2.png")
	a.rope = load(base, "gostek-gfx", "para-rope.png")
	a.m2_base = load(base, "weapons-gfx", "m2-stat.png")
	a.m2[0] = load(base, "weapons-gfx", "m2.png")
	a.m2[1] = load(base, "weapons-gfx", "m2-2.png")
	a.loaded = true
}

things_art_unload :: proc(a: ^Things_Art) {
	sprite_unload(&a.cloth)
	for &s in a.kits do sprite_unload(&s)
	sprite_unload(&a.handle)
	sprite_unload(&a.glow)
	for &g in a.guns do for &s in g do sprite_unload(&s)
	for &s in a.para do sprite_unload(&s)
	sprite_unload(&a.rope)
	sprite_unload(&a.m2_base)
	for &s in a.m2 do sprite_unload(&s)
	a^ = {}
}

// Every thing, its points blended between the last two ticks; a thing about to go
// blinks. `seconds` drives the in-base glow.
things_draw :: proc(a: ^Things_Art, w: ^sim.World, alpha: f32, seconds: f64) {
	if !a.loaded do return
	for &t in w.things {
		if t.style == .None do continue
		if t.timeout < 300 && t.timeout % 6 < 3 && t.style != .Alpha_Flag && t.style != .Bravo_Flag do continue
		p: [4]sim.Vec2
		for k in 0 ..< 4 do p[k] = t.old_pos[k] + (t.pos[k] - t.old_pos[k]) * alpha
		#partial switch t.style {
		case .Alpha_Flag, .Bravo_Flag:
			draw_flag(a, &t, p, seconds)
		case .Weapon:
			art := a.guns[t.weapon][t.flip ? 1 : 0]
			if art.tex.id == 0 do art = a.guns[t.weapon][0]
			angle := math.atan2(p[1].y - p[0].y, p[1].x - p[0].x)
			draw_sprite(art, p[0] - {0, 1}, {0, 2}, {1, 1}, angle, rl.WHITE)
		case .Parachute:
			draw_parachute(a, &t, p, w)
		case .Stat_Gun:
			draw_sprite(a.m2_base, p[2] - {0, 20}, {0, 0}, {1, 1}, math.atan2(p[1].y - p[2].y, p[1].x - p[2].x), rl.WHITE)
			heat := f32(t.interest)
			tint := rl.Color{255, alpha8(255 - 10 * heat), alpha8(255 - 13 * heat), 255}
			gun := a.m2[p[3].x >= p[0].x ? 1 : 0]
			draw_sprite(gun, p[0] - {0, 13}, {5, 4}, {1, 1}, -math.atan2(p[0].y - p[3].y, p[0].x - p[3].x), tint)
		case:
			// kit.po numbers its corners bottom first, so the box is drawn upright from the top pair
			draw_quad(a.kits[t.style].tex, {p[2], p[3], p[0], p[1]}, {{0, 0}, {1, 0}, {1, 1}, {0, 1}}, {rl.WHITE, rl.WHITE, rl.WHITE, rl.WHITE})
		}
	}
}

@(private = "file")
draw_flag :: proc(a: ^Things_Art, t: ^sim.Thing, p: [4]sim.Vec2, seconds: f64) {
	// the handle along the pole, from the base toward the tip
	draw_sprite(a.handle, p[0], {0, 0}, {1, 1}, math.atan2(p[1].y - p[0].y, p[1].x - p[0].x), rl.WHITE)
	// the cloth hangs from the upper half of the pole: p2 the tip, half the lifted
	// handle corner, p4 and p3 the free edge, with the original's UV assignment
	half := p[0] + (p[1] - p[0]) * 0.5
	tint := t.style == .Alpha_Flag ? ALPHA_TINT : BRAVO_TINT
	draw_quad(a.cloth.tex, {p[1], half, p[3], p[2]}, {{0, 0}, {0, 1}, {1, 1}, {1, 0}}, {tint[0], tint[1], tint[0], tint[2]})
	if t.in_base {
		glow := abs(5 + 20 * math.sin(5.1 * seconds)) / 255
		draw_sprite(a.glow, half - {12.5, 12.5}, {0, 0}, {1, 1}, 0, tinted(rl.WHITE, f32(glow) * 255))
	}
}

// Three ropes from the harness to the canopy corners, then the canopy in the owner's
// shirt colour.
@(private = "file")
draw_parachute :: proc(a: ^Things_Art, t: ^sim.Thing, p: [4]sim.Vec2, w: ^sim.World) {
	for target, i in ([3]sim.Vec2{p[1], p[2], p[0]}) {
		angle := math.atan2(target.y - p[3].y, target.x - p[3].x)
		if i == 1 do angle -= 5 * math.PI / 180
		draw_sprite(a.rope, p[3] - {0, 0.55}, {0, a.rope.height / 2}, {1, 1}, angle, rl.WHITE)
	}
	span := sim.vec2_length(p[1] - p[2]) / 45.83
	if span > 2 do return
	color := rl.WHITE
	if t.owner > 0 do color = gostek_color(.Main, &w.soldiers[t.owner - 1])
	draw_sprite(a.para[1], p[2], {0, 0}, {span, span}, math.atan2(p[0].y - p[2].y, p[0].x - p[2].x), color)
	draw_sprite(a.para[0], p[0], {0, 0}, {span, span}, math.atan2(p[1].y - p[0].y, p[1].x - p[0].x), color)
}
