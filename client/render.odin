package client

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import "../shared/sim"

// Everything drawn: the art read once (the gostek, the bullets and things), the map's
// part read again whenever the game loads another map (its texture and scenery, its
// polygons as meshes), and the sparks, the one part with a life of its own (tick).
// Draws the game as it stands; changes nothing in it.
// What a frame is drawn from, handed over rather than reached into: everything here
// belongs to the simulation or is worked out by the caller, so render knows nothing of
// a Game and can be used by anything that has a world to show.
Scene :: struct {
	ctx:    ^sim.Context,
	world:  ^sim.World,
	level:  ^sim.Level,
	events: ^sim.Events,
	loads:  int,        // maps the game has loaded: what the map.s part is rebuilt by
	drawn:  []sim.Vec2, // where each soldier is drawn this frame (drawn_pos)
}

Render :: struct {
	base:       string,
	map_view:   Map_View, // the game's map, once it has one (map_view.odin)
	map_loads:  int,      // which of the game's map loads the map's part was built for
	minimap:    Minimap,
	gostek:     Gostek,
	bullet_art: Bullet_Art,
	things_art: Things_Art,
	sparks:     Sparks,
}

// The art every map shares, from `base`. The window must be open.
render_init :: proc(r: ^Render, base: string) {
	r.base = base
	gostek_load(&r.gostek, base)
	bullet_art_load(&r.bullet_art, base)
	things_art_load(&r.things_art, base)
	sparks_load(&r.sparks, base)
}

render_destroy :: proc(r: ^Render) {
	sparks_unload(&r.sparks)
	things_art_unload(&r.things_art)
	bullet_art_unload(&r.bullet_art)
	gostek_unload(&r.gostek)
	map_unload(r)
}

// The map's part of the picture, when the game has loaded a map it was not built for.
// The sparks of the last map go with it.
@(private)
map_sync :: proc(r: ^Render, scene: ^Scene) {
	if r.map_loads == scene.loads do return
	map_unload(r)
	map_view_load(&r.map_view, r.base, scene.level)
	minimap_build(&r.minimap, scene.level, &r.map_view.meshes)
	for &spark in r.sparks.pool do spark = {}
	r.map_loads = scene.loads
}

@(private)
map_unload :: proc(r: ^Render) {
	if r.map_loads == 0 do return
	minimap_unload(&r.minimap)
	map_view_unload(&r.map_view)
	r.map_loads = 0
}

// Once per tick: this tick's bursts, and every spark on.
render_tick :: proc(r: ^Render, scene: ^Scene) {
	map_sync(r, scene)
	if r.map_view.level == nil do return
	for e in sim.events_slice(scene.events) do sparks_event(&r.sparks, e, &scene.world.soldiers)
	sparks_corpses(&r.sparks, scene.world, &scene.ctx.skeletons.gostek)
	sparks_update(&r.sparks, r.map_view.level)
}
// The world's part of the frame, in the original's layer order: the sky, the background
// polys, scenery behind, everything alive, scenery in front of it, the terrain, scenery
// in front of the players, the sparks. The HUD goes over it (hud/). Reads the game,
// changes nothing. Between the caller's BeginDrawing and EndDrawing.
render_draw :: proc(r: ^Render, scene: ^Scene, camera: ^Camera, alpha: f32, seconds: f64, wireframe: bool) {
	map_sync(r, scene)
	v := &r.map_view
	if v.level == nil { // no map yet: the server has not named one
		rl.ClearBackground(rl.BLACK)
		return
	}
	m := &v.meshes
	rl.ClearBackground(color_of(v.level.bg_bottom))
	rl.BeginMode2D(rl_camera(camera))
	rlgl.DisableBackfaceCulling() // the map's triangles wind either way
	draw_background(v.level, camera)
	if m.built do draw_mesh_now(m.background, m.material)
	draw_scenery(v, 0)
	things_draw(&r.things_art, scene.world, alpha, seconds)
	draw_soldiers(r, scene, alpha)
	bullets_draw(&r.bullet_art, &scene.world.bullets, alpha, seconds)
	draw_scenery(v, 1)
	if m.built do draw_mesh_now(m.terrain, m.material)
	draw_scenery(v, 2)
	sparks_draw(&r.sparks)
	if wireframe do draw_wireframe(v.level)
	rl.EndMode2D()
}

// A mesh draws at once while everything else waits in the batch, so the batch is
// flushed first or the mesh ends up underneath what was pushed before it.
@(private)
draw_mesh_now :: proc(mesh: rl.Mesh, material: rl.Material) {
	rlgl.DrawRenderBatchActive()
	rl.DrawMesh(mesh, material, rl.Matrix(1))
}

// The living on their animated pose at this frame's position, the dead on their
// ragdoll's points between the last two ticks.
@(private)
draw_soldiers :: proc(r: ^Render, scene: ^Scene, alpha: f32) {
	for &s, i in scene.world.soldiers {
		if !s.active do continue
		body := &scene.world.ragdolls[i]
		// a dead soldier whose kill has not come yet holds its last pose
		corpse := s.dead && body.active
		pose := corpse ? sim.ragdoll_pose(body, alpha) : sim.soldier_pose(scene.ctx.anims, &s, scene.drawn[i])
		gostek_draw(&r.gostek, &s, &pose, corpse)
	}
}

// A sim colour as raylib wants it.
color_of :: proc(c: sim.Color) -> rl.Color {
	return {c.r, c.g, c.b, c.a}
}
