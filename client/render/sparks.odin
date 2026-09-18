#+private
package render

import "core:fmt"
import "core:math"
import "core:path/filepath"
import rl "vendor:raylib"
import "../../shared/sim"

// The particle effects: chips off walls, blood, smoke, explosions. From Sparks.pas
// and the bursts in Bullets.pas HitSpray; only the styles our events produce. Purely
// cosmetic, so they use their own rng, not the sim's.

MAX_SPARKS        :: 558
SPARK_GRAVITY     :: sim.DEFAULT_GRAVITY / 1.4
SPARK_DAMPING     :: 0.998
SPARK_SURFACECOEF :: 0.7
EXPLOSION_FRAMES  :: 16
SMOKE_FRAMES      :: 10

Spark_Style :: enum u8 {
	None, Smoke, Chip, Lil_Blood, Blood, Explode_M79, Explode_Frag, Spawn_Spark, Chip_Fire,
	Explode_Cluster, Split_Smoke, Explode_Smoke, Mini_Smoke, Big_Smoke,
}

SPARK_MOVES    :: bit_set[Spark_Style]{.Smoke, .Chip, .Lil_Blood, .Blood, .Chip_Fire, .Mini_Smoke}
SPARK_COLLIDES :: bit_set[Spark_Style]{.Lil_Blood, .Blood}

Spark :: struct {
	style:    Spark_Style, // None is a free slot
	life:     f32,
	pos, vel: sim.Vec2,
	color:    rl.Color, // the spawn spark carries the team colour
}

Spark_Art :: enum u8 { Smoke, Lil_Smoke, Mini_Smoke, Big_Smoke, Chip, Lil_Blood, Blood, Spawn_Spark }

SPARK_ART_FILES := [Spark_Art]string{
	.Smoke = "smoke.png", .Lil_Smoke = "lilsmoke.png", .Mini_Smoke = "minismoke.png", .Big_Smoke = "bigsmoke.png",
	.Chip = "odprysk.png", .Lil_Blood = "lilblood.png", .Blood = "blood.png", .Spawn_Spark = "spawnspark.png",
}

Sparks :: struct {
	pool:    [MAX_SPARKS]Spark,
	art:     [Spark_Art]Sprite,
	explode: [EXPLOSION_FRAMES]Sprite, // explosion/explode1..16
	smoke:   [SMOKE_FRAMES]Sprite,     // explosion/smoke1..10
	rng:     u64,
	loaded:  bool,
}

sparks_load :: proc(s: ^Sparks, base: string) {
	dir, _ := filepath.join({base, "sparks-gfx"}, context.temp_allocator)
	for file, kind in SPARK_ART_FILES {
		path, _ := filepath.join({dir, file}, context.temp_allocator)
		s.art[kind], _ = sprite_load(path, COLOR_KEY_GREEN)
	}
	for &frame, i in s.explode {
		path, _ := filepath.join({dir, "explosion", fmt.tprintf("explode%d.png", i + 1)}, context.temp_allocator)
		frame, _ = sprite_load(path, COLOR_KEY_GREEN)
	}
	for &frame, i in s.smoke {
		path, _ := filepath.join({dir, "explosion", fmt.tprintf("smoke%d.png", i + 1)}, context.temp_allocator)
		frame, _ = sprite_load(path, COLOR_KEY_GREEN)
	}
	s.rng = 0x853C49E6748FEA9B
	s.loaded = true
}

sparks_unload :: proc(s: ^Sparks) {
	for &sprite in s.art do sprite_unload(&sprite)
	for &sprite in s.explode do sprite_unload(&sprite)
	for &sprite in s.smoke do sprite_unload(&sprite)
	s^ = {}
}

spark_add :: proc(s: ^Sparks, pos, vel: sim.Vec2, style: Spark_Style, life: f32, color := rl.WHITE) {
	for &spark in s.pool {
		if spark.style != .None do continue
		spark = {style = style, life = life, pos = pos, vel = vel, color = color}
		return
	}
}

// One tick for every live spark, at the game's 60 Hz.
sparks_update :: proc(s: ^Sparks, level: ^sim.Level) {
	for &spark in s.pool {
		if spark.style == .None do continue
		if spark.style in SPARK_MOVES {
			spark.vel.y += SPARK_GRAVITY
			spark.pos += spark.vel
			spark.vel *= SPARK_DAMPING
		}
		if spark.style in SPARK_COLLIDES do spark_collide(level, &spark)
		spark.life -= 1
		if spark.life <= 0 do spark.style = .None
	}
}

// Point collision as TSpark.CheckMapCollision does it, with its probe offset of (-8, -1).
@(private = "file")
spark_collide :: proc(level: ^sim.Level, spark: ^Spark) {
	probe := spark.pos + {-8, -1}
	for index in sim.sector_polys(level, probe) {
		poly := &level.polys[index]
		#partial switch poly.type {
		case .Only_Bullets, .Only_Player, .Doesnt, .Background, .Background_Transition:
			continue
		}
		if !sim.point_in_poly_edges(probe, poly) do continue
		normal, dist, _ := sim.closest_perpendicular(poly, probe)
		spark.vel -= sim.vec2_normalize(normal) * dist
		spark.vel *= SPARK_SURFACECOEF
		return
	}
}

// ---- the bursts each event makes ----

sparks_event :: proc(s: ^Sparks, e: sim.Event, soldiers: ^[sim.MAX_PLAYERS]sim.Soldier) {
	if !s.loaded do return
	#partial switch v in e {
	case sim.Wall_Hit:      sparks_wall_hit(s, v.pos, v.vel)
	case sim.Ricochet:      sparks_wall_hit(s, v.pos, v.vel)
	case sim.Collider_Hit:  sparks_wall_hit(s, v.pos, v.vel)
	case sim.Thing_Hit:     spark_add(s, v.pos, v.vel * (-0.02 * (0.4 + rand01(s) * 0.4)), .Smoke, 70)
	case sim.Blood:         sparks_blood(s, v.pos, v.vel)
	case sim.Explosion:     sparks_explosion(s, v.pos, v.weapon, v.radius)
	case sim.Cluster_Split: spark_add(s, v.pos, {}, .Split_Smoke, 55)
	case sim.Respawn:       spark_add(s, v.pos, {}, .Spawn_Spark, 33, gostek_color(.Main, &soldiers[v.target]))
	case sim.Poly_Effect:
		#partial switch v.type {
		case .Lava, .Explodes:
			for _ in 0 ..< 3 do spark_add(s, v.pos, {rand_spread(s, 0.8), -0.5 - rand01(s)}, .Chip_Fire, 35)
		case .Regenerates:
			spark_add(s, v.pos, {0, -0.4}, .Smoke, 50)
		case:
			spark_add(s, v.pos, {0, -0.2}, .Lil_Blood, 45)
		}
	}
}

@(private = "file")
sparks_wall_hit :: proc(s: ^Sparks, at, vel: sim.Vec2) {
	b := vel * -0.06
	b.y -= 1.0
	b.x *= 0.6 + rand01(s) * 0.8
	b.y *= 0.8 + rand01(s) * 0.4
	spark_add(s, at, b, .Chip, 60)
	b.x *= 0.8 + rand01(s) * 0.4
	b.y *= 0.6 + rand01(s) * 0.8
	spark_add(s, at, b, .Chip, 65)
	spark_add(s, at, b * (0.4 + rand01(s) * 0.4), .Smoke, 60)
	b.x *= 0.5 + rand01(s) * 0.4
	b.y *= 0.7 + rand01(s) * 0.8
	spark_add(s, at, b, .Chip, 50)
	spark_add(s, at, {}, .Mini_Smoke, 22)
}

@(private = "file")
sparks_blood :: proc(s: ^Sparks, pos, vel: sim.Vec2) {
	b := vel * 0.025
	b.x *= 1.2
	b.y *= 0.85
	spark_add(s, pos, b, .Lil_Blood, 70)
	b.x *= 0.745
	b.y *= 1.1
	spark_add(s, pos, b, .Lil_Blood, 75)
	b.x *= 0.9
	b.y *= 0.85
	if rand_int(s, 2) == 0 do spark_add(s, pos, b, .Lil_Blood, 75)
	b.x *= 1.2
	b.y *= 0.85
	spark_add(s, pos, b, .Blood, 80)
	spark_add(s, pos, b, .Blood, 85)
	b.x *= 0.5
	b.y *= 1.05
	if rand_int(s, 2) == 0 do spark_add(s, pos, b, .Blood, 75)
	for _ in 0 ..< 7 {
		if rand_int(s, 6) == 0 {
			spray := sim.Vec2{math.sin(rand01(s) * 100) * 1.6, math.cos(rand01(s) * 100) * 1.6}
			spark_add(s, pos, spray, .Lil_Blood, 55)
		}
	}
}

@(private = "file")
sparks_explosion :: proc(s: ^Sparks, pos: sim.Vec2, weapon: sim.Weapon_Id, radius: f32) {
	if radius <= sim.CLUSTER_EXPLOSION_RADIUS {
		spark_add(s, pos, {}, .Explode_Cluster, EXPLOSION_FRAMES * 3)
		return
	}
	is_m79 := weapon == .M79
	spark_add(s, pos, {}, .Big_Smoke, is_m79 ? 255 : 190)
	spark_add(s, pos, {}, .Explode_Smoke, SMOKE_FRAMES * 4 + 10)
	spark_add(s, pos, {}, is_m79 ? Spark_Style.Explode_M79 : .Explode_Frag, EXPLOSION_FRAMES * 3)
}

// ---- drawing ----

sparks_draw :: proc(s: ^Sparks) {
	if !s.loaded do return
	for &spark in s.pool {
		if spark.style == .None do continue
		l := spark.life
		p := spark.pos
		switch spark.style {
		case .None:
		case .Smoke:       draw_spark(s.art[.Smoke], p, 1, 0, l + 10)
		case .Chip:        draw_spark(s.art[.Chip], p, 1, 0, l * 3 + 10)
		case .Chip_Fire:   draw_spark(s.art[.Chip], p, 1, 0, l * 3 + 154, {255, 254, 53, 255})
		case .Lil_Blood:   draw_spark(s.art[.Lil_Blood], p, 0.75, l * 10 * math.RAD_PER_DEG, l * 2 + 65)
		case .Blood:       draw_spark(s.art[.Blood], p, l > 10 ? 0.33 + 10 / l : 1, l * 2 * math.RAD_PER_DEG, l * 2 + 85)
		case .Mini_Smoke:  draw_spark(s.art[.Mini_Smoke], p - {3, 3}, 1, 0, l * 2.5)
		case .Spawn_Spark: draw_spark(s.art[.Spawn_Spark], p - {20, 20}, 1, l * math.RAD_PER_DEG, l * 6, spark.color)
		case .Explode_M79:
			frame := explosion_frame(l, 4)
			if frame > 0 do draw_spark(s.explode[frame - 1], p - {19, 38}, 0.75, 0, 100, {173, 173, 173, 255})
			draw_spark(s.explode[frame], p - {19, 38}, 0.75, 0, 255 - EXPLOSION_FRAMES * 5 + l)
		case .Explode_Frag:
			frame := explosion_frame(l, 4)
			if frame > 0 do draw_spark(s.explode[frame - 1], p - {25, 50}, 1, 0, 100, {171, 171, 171, 255})
			draw_spark(s.explode[frame], p - {25, 50}, 1, 0, 255 - EXPLOSION_FRAMES * 5 + l)
		case .Explode_Cluster:
			draw_spark(s.explode[explosion_frame(l, 3)], p - {15, 37}, 0.5, 0, 255 - 2 * l)
		case .Explode_Smoke:
			if l <= SMOKE_FRAMES * 4 {
				frame := clamp(SMOKE_FRAMES - 1 - int(math.round(l / 4)), 0, SMOKE_FRAMES - 1)
				if frame > 0 do draw_spark(s.smoke[frame - 1], p - {26, 48}, 1, 0, l * 2 + 10, {204, 204, 204, 255})
				draw_spark(s.smoke[frame], p - {26, 48}, 1, 0, l * 3 + 10, {222, 222, 222, 255})
			}
		case .Big_Smoke:
			sc := 0.5 + 16 / (l + 50)
			draw_spark(s.art[.Big_Smoke], p - {14 * sc, 30}, sc, 0, l / 3.3)
		case .Split_Smoke:
			sc := 0.5 * (0.6 + (75 / l) / 96)
			draw_spark(s.art[.Big_Smoke], p - {22 * sc, 48 - l / 1.5}, sc, 0, l * 2.5)
		}
	}
}

// The frame for a countdown life: the animation runs forward as the life falls.
@(private = "file")
explosion_frame :: proc(l: f32, step: f32) -> int {
	return clamp(EXPLOSION_FRAMES - 1 - int(math.round(l / step)), 0, EXPLOSION_FRAMES - 1)
}

@(private = "file")
draw_spark :: proc(sprite: Sprite, at: sim.Vec2, scale, angle, alpha: f32, tint := rl.WHITE) {
	if alpha <= 0 do return
	draw_sprite(sprite, at, {0, 0}, {scale, scale}, angle, tinted(tint, alpha))
}

@(private = "file")
rand01 :: proc(s: ^Sparks) -> f32 {
	return sim.rand_f32(&s.rng)
}

@(private = "file")
rand_int :: proc(s: ^Sparks, n: int) -> int {
	return sim.rand_int(&s.rng, n)
}

@(private = "file")
rand_spread :: proc(s: ^Sparks, amount: f32) -> f32 {
	return (rand01(s) * 2 - 1) * amount
}
