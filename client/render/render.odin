package render

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../game"
import "../../shared/sim"

// Everything drawn: the art read once (the map's texture and scenery, the gostek,
// the bullets and things), the map's polygons as meshes, and the sparks, the one part
// with a life of its own (tick). Draws the game as it stands; changes nothing in it.
Render :: struct {
	level:       ^sim.Level, // the game's
	map_texture: rl.Texture2D,   // id 0 draws the polygons untextured
	scenery:     []rl.Texture2D, // one per entry in Level.scenery, id 0 where it failed to load
	meshes:      Map_Meshes,
	gostek:      Gostek,
	bullet_art:  Bullet_Art,
	things_art:  Things_Art,
	sparks:      Sparks,
}

// The art for the game's map, from `base`. The window must be open.
init :: proc(r: ^Render, base: string, level: ^sim.Level) {
	r.level = level
	r.map_texture = map_texture_load(base, level.texture)
	r.scenery = scenery_load(base, level.scenery)
	map_meshes_build(&r.meshes, level, r.map_texture)
	gostek_load(&r.gostek, base)
	bullet_art_load(&r.bullet_art, base)
	things_art_load(&r.things_art, base)
	sparks_load(&r.sparks, base)
}

destroy :: proc(r: ^Render) {
	sparks_unload(&r.sparks)
	things_art_unload(&r.things_art)
	bullet_art_unload(&r.bullet_art)
	gostek_unload(&r.gostek)
	map_meshes_unload(&r.meshes)
	for t in r.scenery do if t.id != 0 do rl.UnloadTexture(t)
	delete(r.scenery)
	if r.map_texture.id != 0 do rl.UnloadTexture(r.map_texture)
}

// Once per tick: this tick's bursts, and every spark on.
tick :: proc(r: ^Render, g: ^game.Game) {
	for e in sim.events_slice(&g.events) do sparks_event(&r.sparks, e, &g.world.soldiers)
	sparks_update(&r.sparks, r.level)
}

// The map's polygons as two static meshes built once: the background polys, drawn
// first, and the solid terrain, drawn after the players so it occludes them (the
// original's order). Both carry the map texture with per-vertex colour.
@(private)
Map_Meshes :: struct {
	background: rl.Mesh,
	terrain:    rl.Mesh,
	material:   rl.Material,
	built:      bool,
}

@(private)
map_meshes_build :: proc(m: ^Map_Meshes, level: ^sim.Level, texture: rl.Texture2D) {
	m.background = build_poly_mesh(level, background = true)
	m.terrain = build_poly_mesh(level, background = false)
	m.material = rl.LoadMaterialDefault()
	if texture.id != 0 do rl.SetMaterialTexture(&m.material, .ALBEDO, texture)
	m.built = true
}

@(private)
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
draw :: proc(r: ^Render, g: ^game.Game, camera: ^Camera, alpha: f32, seconds: f64, wireframe: bool) {
	m := &r.meshes
	rl.BeginDrawing()
	rl.ClearBackground(color_of(r.level.bg_bottom))
	rl.BeginMode2D(rl_camera(camera))
	rlgl.DisableBackfaceCulling() // the map's triangles wind either way
	draw_background(r.level, camera)
	if m.built do draw_mesh_now(m.background, m.material)
	draw_scenery(r, 0)
	things_draw(&r.things_art, &g.world, alpha, seconds)
	draw_soldiers(r, g, alpha)
	bullets_draw(&r.bullet_art, &g.world.bullets, alpha, seconds)
	draw_scenery(r, 1)
	if m.built do draw_mesh_now(m.terrain, m.material)
	draw_scenery(r, 2)
	sparks_draw(&r.sparks)
	if wireframe do draw_wireframe(r.level)
	rl.EndMode2D()
	draw_hud(g)
	rl.EndDrawing()
}

// A mesh draws at once while everything else waits in the batch, so the batch is
// flushed first or the mesh ends up underneath what was pushed before it.
@(private)
draw_mesh_now :: proc(mesh: rl.Mesh, material: rl.Material) {
	rlgl.DrawRenderBatchActive()
	rl.DrawMesh(mesh, material, rl.Matrix(1))
}

// The sky gradient. The original anchors it in world space vertically, spanning +/-d
// about the origin, and stretches it across the screen, so it scrolls with the camera.
@(private)
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
@(private)
draw_scenery :: proc(r: ^Render, layer: u8) {
	for &prop in r.level.props {
		if prop.level != layer || prop.style == 0 do continue
		tex := r.scenery[prop.style - 1]
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

@(private)
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

@(private)
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
@(private)
draw_soldiers :: proc(r: ^Render, g: ^game.Game, alpha: f32) {
	for &s, i in g.world.soldiers {
		if !s.active do continue
		body := &g.world.ragdolls[i]
		// a dead soldier whose kill has not come yet holds its last pose
		corpse := s.dead && body.active
		pose := corpse ? sim.ragdoll_pose(body, alpha) : sim.soldier_pose(g.ctx.anims, &s, game.drawn_pos(g, i, alpha))
		gostek_draw(&r.gostek, &s, &pose, corpse)
	}
}

@(private)
draw_hud :: proc(g: ^game.Game) {
	// TODO the bars, the kill feed, the weapon and ammo
}

@(private)
color_of :: proc(c: sim.Color) -> rl.Color {
	return {c.r, c.g, c.b, c.a}
}
