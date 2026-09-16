package client

import "core:math"
import "core:os"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../shared/sim"

// A sprite is a texture with its size in world units, drawn as a rotated, scaled
// quad. The gostek, the bullets and the sparks all draw through draw_sprite.

GOSTEK_SCALE :: 1.0 / 4.5 // sprite pixels per world unit, from mod.ini DefaultScale

// Scenery and sparks are keyed on pure green rather than carrying an alpha channel,
// as in the original's ApplyColorKey: a fully opaque (0, 255, 0) pixel is transparent.
COLOR_KEY_GREEN :: [4]u8{0, 255, 0, 255}

Sprite :: struct {
	tex:           rl.Texture2D,
	width, height: f32, // world units, already scaled
}

sprite_load :: proc(path: string, color_key: [4]u8 = {}) -> (s: Sprite, ok: bool) {
	if !os.exists(path) do return s, false
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	tex: rl.Texture2D
	if color_key == {} {
		tex = rl.LoadTexture(cpath)
	} else {
		img := rl.LoadImage(cpath)
		if img.data == nil do return s, false
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
		for &p in ([^][4]u8)(img.data)[:img.width * img.height] do if p == color_key do p = {}
		tex = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
	}
	if tex.id == 0 do return s, false
	rl.SetTextureFilter(tex, .BILINEAR)
	return {tex, f32(tex.width) * GOSTEK_SCALE, f32(tex.height) * GOSTEK_SCALE}, true
}

sprite_unload :: proc(s: ^Sprite) {
	if s.tex.id != 0 do rl.UnloadTexture(s.tex)
	s^ = {}
}

// A rotated, scaled quad whose `center` (world units from the sprite's top-left) lands
// on `at`: the original's DrawGostekSprite matrix, used for everything.
draw_sprite :: proc(sprite: Sprite, at, center, scale: sim.Vec2, angle: f32, color: rl.Color) {
	if sprite.tex.id == 0 do return
	c, s := math.cos(angle), math.sin(angle)
	ax, ay := c * scale.x, s * scale.x
	bx, by := -s * scale.y, c * scale.y
	origin := sim.Vec2{at.x - center.y * bx - center.x * ax, at.y - center.y * by - center.x * ay}
	w, h := sprite.width, sprite.height
	corner :: proc(origin: sim.Vec2, ax, ay, bx, by, x, y: f32) -> sim.Vec2 {
		return {origin.x + x * ax + y * bx, origin.y + x * ay + y * by}
	}
	p0 := corner(origin, ax, ay, bx, by, 0, 0)
	p1 := corner(origin, ax, ay, bx, by, w, 0)
	p2 := corner(origin, ax, ay, bx, by, w, h)
	p3 := corner(origin, ax, ay, bx, by, 0, h)
	rlgl.SetTexture(sprite.tex.id)
	rlgl.Begin(rlgl.QUADS)
	rlgl.Color4ub(color.r, color.g, color.b, color.a)
	rlgl.TexCoord2f(0, 0)
	rlgl.Vertex2f(p0.x, p0.y)
	rlgl.TexCoord2f(0, 1)
	rlgl.Vertex2f(p3.x, p3.y)
	rlgl.TexCoord2f(1, 1)
	rlgl.Vertex2f(p2.x, p2.y)
	rlgl.TexCoord2f(1, 0)
	rlgl.Vertex2f(p1.x, p1.y)
	rlgl.End()
}

// An alpha in the original's 0..255 terms, clamped.
alpha8 :: proc(v: f32) -> u8 {
	return u8(clamp(v, 0, 255))
}

tinted :: proc(tint: rl.Color, alpha: f32) -> rl.Color {
	return {tint.r, tint.g, tint.b, alpha8(f32(tint.a) * alpha / 255)}
}

// A textured quad over four arbitrary points with a colour per corner: the flags'
// cloth and the kits, stretched over their skeleton points.
draw_quad :: proc(tex: rl.Texture2D, p: [4]sim.Vec2, uv: [4]sim.Vec2, colors: [4]rl.Color) {
	if tex.id == 0 do return
	rlgl.SetTexture(tex.id)
	rlgl.Begin(rlgl.QUADS)
	for i in 0 ..< 4 {
		c := colors[i]
		rlgl.Color4ub(c.r, c.g, c.b, c.a)
		rlgl.TexCoord2f(uv[i].x, uv[i].y)
		rlgl.Vertex2f(p[i].x, p[i].y)
	}
	rlgl.End()
}
