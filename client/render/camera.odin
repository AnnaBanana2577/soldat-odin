package render

import "core:math"
import rl "vendor:raylib"
import "../../shared/sim"

// The view: where it looks, how far it is zoomed, and the conversions between the
// screen and the world. The app owns one; input, render and audio read it.
//
// The game's camera fills the window and chases a soldier. The editor's fills one pane
// and is dragged about by hand, so a camera carries the rectangle it draws into and
// every conversion below is in terms of that rather than the window.

GAME_HEIGHT :: 480.0 // the original's view: 480 units tall, the width follows the window

Camera :: struct {
	pos:      sim.Vec2,
	zoom:     f32,
	// Where on screen this camera draws. Left zero it is the whole window, which is what
	// the game wants; the editor sets it to its viewport pane.
	viewport: rl.Rectangle,
}

// The rectangle this camera draws into, in screen pixels.
viewport_of :: proc(c: ^Camera) -> rl.Rectangle {
	if c.viewport.width > 0 && c.viewport.height > 0 do return c.viewport
	return {0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
}

// What the camera shows, in world units.
view_size :: proc(c: ^Camera) -> sim.Vec2 {
	vp := viewport_of(c)
	h := GAME_HEIGHT * c.zoom
	return {h * vp.width / vp.height, h}
}

CAMERA_SPEED    :: 0.14 // the share of the distance to the target closed per tick
CAMERA_AIM_DIST :: 7.0  // the cursor's lead: the view slides toward where you aim

// The camera chases the soldier and leads toward the cursor, as the original does,
// per frame at the frame's dt so it feels the same at any frame rate.
camera_follow :: proc(c: ^Camera, target: sim.Vec2, cursor: sim.Vec2, dt: f64) {
	vp := viewport_of(c)
	w, h := vp.width, vp.height
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
	vp := viewport_of(c)
	view := view_size(c)
	return {
		c.pos.x - view.x / 2 + (p.x - vp.x) * view.x / vp.width,
		c.pos.y - view.y / 2 + (p.y - vp.y) * view.y / vp.height,
	}
}

// A place in the world, in pixels on the screen: screen_to_world the other way.
world_to_screen :: proc(c: ^Camera, p: sim.Vec2) -> sim.Vec2 {
	vp := viewport_of(c)
	view := view_size(c)
	return {
		vp.x + (p.x - c.pos.x + view.x / 2) * vp.width / view.x,
		vp.y + (p.y - c.pos.y + view.y / 2) * vp.height / view.y,
	}
}

screen_center :: proc() -> sim.Vec2 {
	return {f32(rl.GetScreenWidth()) / 2, f32(rl.GetScreenHeight()) / 2}
}

pixels_per_unit :: proc(c: ^Camera) -> f32 {
	return viewport_of(c).height / (GAME_HEIGHT * c.zoom)
}

// The raylib camera this one describes, for BeginMode2D.
rl_camera :: proc(c: ^Camera) -> rl.Camera2D {
	vp := viewport_of(c)
	return {
		offset = {vp.x + vp.width / 2, vp.y + vp.height / 2},
		target = {c.pos.x, c.pos.y},
		zoom   = vp.height / (GAME_HEIGHT * c.zoom),
	}
}

// Half of what the screen shows, in world units: the minimap's box.
view_half :: proc(c: ^Camera) -> sim.Vec2 {
	return view_size(c) / 2
}

// ---- free look: the editor drags the view about, the game's follows a soldier ----

MIN_ZOOM :: 0.05
MAX_ZOOM :: 40.0

// Drag the view by a distance in screen pixels.
camera_pan :: proc(c: ^Camera, screen_delta: sim.Vec2) {
	c.pos -= screen_delta / pixels_per_unit(c)
}

// Zoom about a point on screen, so whatever is under the cursor stays under it. A
// smaller zoom shows less of the world, so the factor is inverted against the wheel.
camera_zoom_at :: proc(c: ^Camera, factor: f32, screen: sim.Vec2) {
	before := screen_to_world(c, screen)
	c.zoom = clamp(c.zoom / factor, MIN_ZOOM, MAX_ZOOM)
	after := screen_to_world(c, screen)
	c.pos += before - after
}

// Frame a box with a little room around it.
camera_fit :: proc(c: ^Camera, low, high: sim.Vec2, padding: f32 = 0.06) {
	vp := viewport_of(c)
	extent := sim.Vec2{max(1, high.x - low.x), max(1, high.y - low.y)} * (1 + padding)
	c.pos = (low + high) / 2
	// Zoom is the view's height in GAME_HEIGHT units, so take whichever axis needs more.
	c.zoom = clamp(max(extent.y, extent.x * vp.height / vp.width) / GAME_HEIGHT, MIN_ZOOM, MAX_ZOOM)
}
