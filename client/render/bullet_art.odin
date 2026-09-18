#+private
package render

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import "../../shared/sim"

// The projectiles as drawn, from TBullet.Render in Bullets.pas. Most styles are the
// bullet's own image at pos + vel, stretched along its length by the speed and turned
// to face the way it goes, with a fainter stretched streak behind it as a trail.
// Grenades and rockets spin on their timeout instead.

BULLET_TRAIL :: 13
BULLET_ALPHA :: 110
FLAME_FRAMES :: 16

// Plain rounds of weapons not listed use the USSOCOM's image, as the original does.
BULLET_ART := #partial [sim.Weapon_Id]string{
	.Eagle   = "eagles-bullet",
	.MP5     = "mp5-bullet",
	.AK74    = "ak74-bullet",
	.Steyr   = "steyraug-bullet",
	.Spas    = "spas12-bullet",
	.Ruger   = "ruger77-bullet",
	.M79     = "m79-bullet",
	.Barrett = "barretm82-bullet",
	.M249    = "m249-bullet",
	.Minigun = "minigun-bullet",
	.Colt    = "colt-bullet",
	.LAW     = "missile",
	.Bow     = "arrow",
	.Bow2    = "arrow",
}

Bullet_Shared :: enum u8 { Streak, Missile, Frag_Grenade, Cluster_Grenade, Cluster, Arrow, Knife, Knife_Left, Smudge }

BULLET_SHARED_ART := [Bullet_Shared]string{
	.Streak = "bullet", .Missile = "missile", .Frag_Grenade = "frag-grenade", .Cluster_Grenade = "cluster-grenade",
	.Cluster = "cluster", .Arrow = "arrow", .Knife = "knife", .Knife_Left = "knife2", .Smudge = "smudge",
}

Bullet_Art :: struct {
	weapons: [sim.Weapon_Id]Sprite,
	shared:  [Bullet_Shared]Sprite,
	flames:  [FLAME_FRAMES]Sprite, // sparks-gfx/flames/explode1..16: a flamer shot burning out
	loaded:  bool,
}

bullet_art_load :: proc(b: ^Bullet_Art, base: string) {
	dir, _ := filepath.join({base, "weapons-gfx"}, context.temp_allocator)
	load :: proc(dir, stem: string) -> Sprite {
		if stem == "" do return {}
		path, found := find_image(dir, strings.concatenate({stem, ".png"}, context.temp_allocator))
		if !found do return {}
		s, _ := sprite_load(path)
		return s
	}
	missing := 0
	for stem, id in BULLET_ART {
		b.weapons[id] = load(dir, stem)
		if stem != "" && b.weapons[id].tex.id == 0 do missing += 1
	}
	for stem, kind in BULLET_SHARED_ART {
		b.shared[kind] = load(dir, stem)
		if b.shared[kind].tex.id == 0 do missing += 1
	}
	for &frame, i in b.flames {
		path, _ := filepath.join({base, "sparks-gfx", "flames", fmt.tprintf("explode%d.png", i + 1)}, context.temp_allocator)
		ok: bool
		if frame, ok = sprite_load(path, COLOR_KEY_GREEN); !ok do missing += 1
	}
	if missing > 0 do fmt.eprintfln("%d bullet sprites not found under %s", missing, base)
	b.loaded = true
}

bullet_art_unload :: proc(b: ^Bullet_Art) {
	for &s in b.weapons do sprite_unload(&s)
	for &s in b.shared do sprite_unload(&s)
	for &s in b.flames do sprite_unload(&s)
	b^ = {}
}

// Every live bullet, between its last two ticks by alpha so it does not step.
bullets_draw :: proc(b: ^Bullet_Art, bullets: ^[sim.MAX_BULLETS]sim.Bullet, alpha: f32, seconds: f64) {
	if !b.loaded do return
	for &bullet in bullets do if bullet.active do bullet_draw(b, &bullet, alpha, seconds)
}

@(private = "file")
bullet_draw :: proc(b: ^Bullet_Art, bullet: ^sim.Bullet, alpha: f32, seconds: f64) {
	pos := bullet.old_pos + (bullet.pos - bullet.old_pos) * alpha
	timeout := f32(bullet.timeout) + 1 - alpha // TimeOutReal
	vel := bullet.vel
	speed := sim.vec2_length(vel)
	heading := math.atan2(vel.y, vel.x)
	spin := timeout * -6 * math.PI / 180 // the timeout counts down, so it stands in for age
	sinus := f32(math.sin(f64(timeout) + 5.1 * seconds)) // the M2's wobbling smudge

	streak := b.shared[.Streak]
	own := b.weapons[bullet.weapon]
	if own.tex.id == 0 do own = b.weapons[.Colt]
	if own.tex.id == 0 do own = streak
	half := u8(BULLET_ALPHA / 2)

	#partial switch bullet.style {
	case .Frag_Grenade:
		if timeout < sim.GRENADE_TIMEOUT - 3 {
			off := sim.Vec2{vel.y > 0 ? -1 : 1, vel.x > 0 ? 1 : -1}
			draw_streak(streak, pos + off - {0, 3}, {speed / 3, 1}, heading, {100, 255, 100, 82})
		}
		draw_one(b.shared[.Frag_Grenade], pos - {1, 4}, {1, 1}, 0, rl.WHITE)
	case .Cluster_Nade:
		turn := timeout * -5 * math.PI / 180 * (vel.x < 0 ? -1 : 1)
		draw_one(b.shared[.Cluster_Grenade], pos - {0, 3}, {1, 1}, turn, rl.WHITE)
	case .Cluster:
		draw_one(b.shared[.Cluster], pos - {0, 2}, {1, 1}, 0, rl.WHITE)
	case .M79:
		if timeout >= sim.BULLET_TIMEOUT - 2 do break
		draw_one(own, pos + {0, 1}, {1, 1}, spin, {255, 255, 255, 252}) // only the M79 round tumbles
		if timeout < sim.BULLET_TIMEOUT - 4 {
			off := sim.Vec2{vel.y > 0 ? -1 : 1, vel.x > 0 ? 1 : -1}
			draw_streak(streak, pos + off, {speed / 4, 1.3}, heading, {255, 255, 85, BULLET_ALPHA})
		}
	case .LAW:
		if timeout >= sim.BULLET_TIMEOUT - 2 do break
		draw_streak(b.shared[.Missile], pos + vel, {1, 1}, heading, rl.WHITE)
		if timeout < sim.BULLET_TIMEOUT - 7 do draw_streak(streak, pos, {speed / 3, 1}, heading, {255, 255, 255, BULLET_ALPHA / 5})
	case .Arrow, .Flame_Arrow:
		if timeout >= sim.BULLET_TIMEOUT - 2 do break
		draw_streak(b.shared[.Arrow], pos + vel, {1, 1}, heading, rl.WHITE)
		if bullet.style == .Arrow && timeout > sim.ARROW_RESIST do draw_streak(streak, pos, {speed / 3, 1}, heading, {255, 255, 255, BULLET_ALPHA / 7})
	case .Shotgun:
		if timeout >= sim.BULLET_TIMEOUT - 2 do break
		draw_streak(own, pos + vel, {1, 1}, heading, {255, 255, 255, 150})
		if timeout < sim.BULLET_TIMEOUT - 3 do draw_streak(streak, pos, {speed / 9, 1}, heading, {255, 255, 255, BULLET_ALPHA / 5})
	case .M2:
		if timeout >= sim.M2BULLET_TIMEOUT - 2 do break
		draw_streak(streak, pos + vel, {speed / BULLET_TRAIL, 1.2}, heading, {255, 191, 120, BULLET_ALPHA * 2})
		if timeout < sim.M2BULLET_TIMEOUT - 13 {
			draw_streak(streak, pos, {speed / 3, 1}, heading, {255, 255, 255, BULLET_ALPHA / 5})
			draw_streak(b.shared[.Smudge], pos, {speed / (sinus + 2.5), sinus}, heading, {255, 255, 255, BULLET_ALPHA / 6})
		}
	case .Flame:
		if timeout <= 0 || timeout > sim.FLAMER_TIMEOUT do break
		frame := clamp(FLAME_FRAMES - 1 - int(timeout / 2), 0, FLAME_FRAMES - 1)
		draw_one(b.flames[frame], pos - {8, 17}, {1, 1}, 0, rl.WHITE)
	case .Thrown_Knife:
		turn := timeout / math.PI
		if vel.x >= 0 do draw_sprite(b.shared[.Knife], pos + vel + {4, 1}, {4, 1}, {1, 1}, -turn, rl.WHITE)
		else do draw_sprite(b.shared[.Knife_Left], pos + vel + {4, 1}, {4, 1}, {1, 1}, turn, rl.WHITE)
	case .Punch, .Knife:
		// melee has no projectile art
	case:
		if timeout >= sim.BULLET_TIMEOUT - 2 do break
		stretch := speed / BULLET_TRAIL
		a := clamp(bullet.hit_multiply * stretch * stretch / 4.63 * 255, 50, 230)
		draw_streak(own, pos + vel, {stretch, 1}, heading, {255, 255, 255, u8(a)})
		// the trail is the weapon's own art at half alpha; a round that hit someone trails pink
		if timeout < sim.BULLET_TIMEOUT - 7 {
			if bullet.hit_body >= 0 do draw_streak(own, pos, {speed / 4, 1}, heading, {255, 222, 222, half})
			else do draw_streak(own, pos, {speed / 3.5, 1}, heading, {255, 255, 255, half})
		}
	}
}

// A streak: `at` is its leading point and the art extends back along the heading, so
// it trails the bullet. The image's left edge sits at the head, turned to face back.
@(private = "file")
draw_streak :: proc(sprite: Sprite, at, scale: sim.Vec2, angle: f32, color: rl.Color) {
	draw_sprite(sprite, at, {0, 0}, scale, angle + math.PI, color)
}

// A discrete object (a grenade, a cluster), anchored at its own origin.
@(private = "file")
draw_one :: proc(sprite: Sprite, at, scale: sim.Vec2, angle: f32, color: rl.Color) {
	draw_sprite(sprite, at, {0, 0}, scale, angle, color)
}
