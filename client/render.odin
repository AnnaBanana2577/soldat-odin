package client

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../shared/sim"

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

rl_camera :: proc(c: ^Camera) -> rl.Camera2D {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	return {offset = {w / 2, h / 2}, target = {c.pos.x, c.pos.y}, zoom = h / (GAME_HEIGHT * c.zoom)}
}

// The map's polygons as two static meshes built once: the background polys, drawn
// first, and the solid terrain, drawn after the players so it occludes them (the
// original's order). Both carry the map texture with per-vertex colour.
Map_Meshes :: struct {
	background: rl.Mesh,
	terrain:    rl.Mesh,
	material:   rl.Material,
	built:      bool,
}

map_meshes_build :: proc(m: ^Map_Meshes, level: ^sim.Level, texture: rl.Texture2D) {
	m.background = build_poly_mesh(level, background = true)
	m.terrain = build_poly_mesh(level, background = false)
	m.material = rl.LoadMaterialDefault()
	if texture.id != 0 do rl.SetMaterialTexture(&m.material, .ALBEDO, texture)
	m.built = true
}

map_meshes_unload :: proc(m: ^Map_Meshes) {
	if !m.built do return
	rl.UnloadMesh(m.background)
	rl.UnloadMesh(m.terrain)
	m.built = false
}

@(private = "file")
build_poly_mesh :: proc(level: ^sim.Level, background: bool) -> (mesh: rl.Mesh) {
	count := 0
	for &poly in level.polys {
		is_bg := poly.type == .Background || poly.type == .Background_Transition
		if is_bg == background do count += 1
	}
	if count == 0 do return
	// raylib frees these with its own allocator on UnloadMesh
	mesh.vertexCount = i32(count * 3)
	mesh.triangleCount = i32(count)
	mesh.vertices = ([^]f32)(rl.MemAlloc(u32(count * 3 * 3 * size_of(f32))))
	mesh.texcoords = ([^]f32)(rl.MemAlloc(u32(count * 3 * 2 * size_of(f32))))
	mesh.colors = ([^]u8)(rl.MemAlloc(u32(count * 3 * 4)))
	v := 0
	for &poly in level.polys {
		is_bg := poly.type == .Background || poly.type == .Background_Transition
		if is_bg != background do continue
		for k in 0 ..< 3 {
			mesh.vertices[v * 3 + 0] = poly.verts[k].x
			mesh.vertices[v * 3 + 1] = poly.verts[k].y
			mesh.vertices[v * 3 + 2] = 0
			mesh.texcoords[v * 2 + 0] = poly.uvs[k].x
			mesh.texcoords[v * 2 + 1] = poly.uvs[k].y
			for c in 0 ..< 4 do mesh.colors[v * 4 + c] = poly.colors[k][c]
			v += 1
		}
	}
	rl.UploadMesh(&mesh, false)
	return
}

// The frame, in the original's layer order: the sky, the background polys, scenery
// behind, everything alive, scenery in front of it, the terrain, scenery in front of
// the players, the sparks, then the HUD. Reads the game, changes nothing.
draw :: proc(g: ^Game, assets: ^Assets, meshes: ^Map_Meshes, sparks: ^Sparks, alpha: f32, seconds: f64) {
	rl.BeginDrawing()
	rl.ClearBackground(color_of(assets.level.bg_bottom))
	rl.BeginMode2D(rl_camera(&g.camera))
	rlgl.DisableBackfaceCulling() // the map's triangles wind either way
	draw_background(&assets.level, &g.camera)
	if meshes.built do draw_mesh_now(meshes.background, meshes.material)
	draw_scenery(assets, 0)
	things_draw(&assets.things_art, &g.world, alpha, seconds)
	draw_soldiers(g, assets, alpha)
	bullets_draw(&assets.bullet_art, &g.world.bullets, alpha, seconds)
	draw_scenery(assets, 1)
	if meshes.built do draw_mesh_now(meshes.terrain, meshes.material)
	draw_scenery(assets, 2)
	sparks_draw(sparks)
	if app.debug.wireframe do draw_wireframe(&assets.level)
	rl.EndMode2D()
	draw_hud(g)
	rl.EndDrawing()
}

// A mesh draws at once while everything else waits in the batch, so the batch is
// flushed first or the mesh ends up underneath what was pushed before it.
draw_mesh_now :: proc(mesh: rl.Mesh, material: rl.Material) {
	rlgl.DrawRenderBatchActive()
	rl.DrawMesh(mesh, material, rl.Matrix(1))
}

// The sky gradient. The original anchors it in world space vertically, spanning +/-d
// about the origin, and stretches it across the screen, so it scrolls with the camera.
draw_background :: proc(level: ^sim.Level, camera: ^Camera) {
	d := f32(sim.MAX_SECTOR) * max(f32(level.sectors_division), math.ceil(0.5 * GAME_HEIGHT / f32(sim.MAX_SECTOR)))
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	half_width := GAME_HEIGHT * camera.zoom * w / h / 2
	x0, x1 := camera.pos.x - half_width, camera.pos.x + half_width
	top, bottom := level.bg_top, level.bg_bottom
	rlgl.SetTexture(0)
	rlgl.Begin(rlgl.QUADS)
	rlgl.Color4ub(top.r, top.g, top.b, top.a)
	rlgl.Vertex2f(x0, -d)
	rlgl.Color4ub(bottom.r, bottom.g, bottom.b, bottom.a)
	rlgl.Vertex2f(x0, d)
	rlgl.Vertex2f(x1, d)
	rlgl.Color4ub(top.r, top.g, top.b, top.a)
	rlgl.Vertex2f(x1, -d)
	rlgl.End()
}

// One layer of props. The quad reproduces the original's GfxMat3Transform: the map's
// position is the prop's top-left, its size is the map's width and height times the
// scale (not the image's own size), rotated about a pivot one unit below the anchor.
draw_scenery :: proc(assets: ^Assets, layer: u8) {
	for &prop in assets.level.props {
		if prop.level != layer || prop.style == 0 do continue
		tex := assets.scenery[prop.style - 1]
		if tex.id == 0 do continue
		p0, p1, p2, p3 := prop_corners(&prop)
		c := prop.color
		c.a = u8(f32(c.a) * f32(prop.alpha) / 255)
		rlgl.SetTexture(tex.id)
		rlgl.Begin(rlgl.QUADS)
		rlgl.Color4ub(c.r, c.g, c.b, c.a)
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
	rlgl.SetTexture(0)
}

prop_corners :: proc(prop: ^sim.Prop) -> (p0, p1, p2, p3: sim.Vec2) {
	angle := -prop.rotation
	c, s := math.cos(angle), math.sin(angle)
	cx, cy: f32 = 0, 1
	sx, sy := prop.scale.x, prop.scale.y
	m0, m3 := c * sx, -s * sy
	m1, m4 := s * sx, c * sy
	m6 := prop.pos.x + cy * s - c * cx + cx
	m7 := prop.pos.y - cx * s - c * cy + cy
	w, h := f32(prop.width), f32(prop.height)
	corner :: proc(m0, m3, m6, m1, m4, m7, x, y: f32) -> sim.Vec2 {
		return {m0 * x + m3 * y + m6, m1 * x + m4 * y + m7}
	}
	return corner(m0, m3, m6, m1, m4, m7, 0, 0),
		corner(m0, m3, m6, m1, m4, m7, w, 0),
		corner(m0, m3, m6, m1, m4, m7, w, h),
		corner(m0, m3, m6, m1, m4, m7, 0, h)
}

draw_wireframe :: proc(level: ^sim.Level) {
	for &poly in level.polys {
		for k in 0 ..< 3 {
			a, b := poly.verts[k], poly.verts[(k + 1) % 3]
			rl.DrawLineV({a.x, a.y}, {b.x, b.y}, rl.WHITE)
		}
	}
}

// The living on their animated pose at this frame's position, the dead on their
// ragdoll's points between the last two ticks.
draw_soldiers :: proc(g: ^Game, assets: ^Assets, alpha: f32) {
	for &s, i in g.world.soldiers {
		if !s.active do continue
		r := &g.world.ragdolls[i]
		// a dead soldier whose kill has not come yet holds its last pose
		corpse := s.dead && r.active
		pose := corpse ? sim.ragdoll_pose(r, alpha) : sim.soldier_pose(g.ctx.anims, &s, drawn_pos(g, i, alpha))
		gostek_draw(&assets.gostek, &s, &pose, corpse)
	}
}

draw_hud :: proc(g: ^Game) {
	// TODO the bars, the kill feed, the weapon and ammo
}

color_of :: proc(c: sim.Color) -> rl.Color {
	return {c.r, c.g, c.b, c.a}
}
