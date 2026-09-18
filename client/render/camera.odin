package render

import "core:math"
import rl "vendor:raylib"
import "../../shared/sim"

// The view: where it looks, how far it is zoomed, and the conversions between the
// screen and the world. The app owns one; input, render and audio read it.

GAME_HEIGHT :: 480.0 // the original's view: 480 units tall, the width follows the window

Camera :: struct {
	pos:  sim.Vec2,
	zoom: f32,
}

CAMERA_SPEED    :: 0.14 // the share of the distance to the target closed per tick
CAMERA_AIM_DIST :: 7.0  // the cursor's lead: the view slides toward where you aim

// The camera chases the soldier and leads toward the cursor, as the original does,
// per frame at the frame's dt so it feels the same at any frame rate.
camera_follow :: proc(c: ^Camera, target: sim.Vec2, cursor: sim.Vec2, dt: f64) {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	game_w, game_h := f32(GAME_HEIGHT) * w / h, f32(GAME_HEIGHT)
	off := sim.Vec2{
		clamp((cursor.x - w / 2) * game_w / w, -game_w / 2, game_w / 2),
		clamp((cursor.y - h / 2) * game_h / h, -game_h / 2, game_h / 2),
	}
	factor := 2 * 640 / game_w - 1 // the original's wide-screen term
	ticks := f32(dt) * sim.TICK_RATE
	k := 1 - math.pow(1 - CAMERA_SPEED, ticks)
	c.pos.x += (target.x - c.pos.x) * k + c.zoom * off.x / CAMERA_AIM_DIST * factor * ticks
	c.pos.y += (target.y - c.pos.y) * k + c.zoom * off.y / CAMERA_AIM_DIST * ticks
}

screen_to_world :: proc(c: ^Camera, p: sim.Vec2) -> sim.Vec2 {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	view_h := GAME_HEIGHT * c.zoom
	view_w := view_h * w / h
	return {c.pos.x - view_w / 2 + p.x * view_w / w, c.pos.y - view_h / 2 + p.y * view_h / h}
}

screen_center :: proc() -> sim.Vec2 {
	return {f32(rl.GetScreenWidth()) / 2, f32(rl.GetScreenHeight()) / 2}
}

pixels_per_unit :: proc(c: ^Camera) -> f32 {
	return f32(rl.GetScreenHeight()) / (GAME_HEIGHT * c.zoom)
}

@(private)
rl_camera :: proc(c: ^Camera) -> rl.Camera2D {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	return {offset = {w / 2, h / 2}, target = {c.pos.x, c.pos.y}, zoom = h / (GAME_HEIGHT * c.zoom)}
}
