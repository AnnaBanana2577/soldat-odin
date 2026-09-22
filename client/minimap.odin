package client

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../shared/sim"

// The minimap: the map drawn once into a small texture when it loads, which the HUD
// puts in a corner of the screen with the players on it (MapGraphics.pas). Its size is
// the original's: the polygons' bounds scaled so that its width and height together
// come to 260 of the interface's units.
Minimap :: struct {
	texture: rl.RenderTexture2D,
	min:     sim.Vec2, // the polygons' bounds
	max:     sim.Vec2,
	scale:   f32,      // interface units per world unit
	width:   f32,      // and its size in those units
	height:  f32,
	built:   bool,
}

MINIMAP_UNITS :: 260.0 // the width and the height together
MINIMAP_SUPER :: 4.0   // pixels the texture holds per interface unit

// Where a point of the world is on the minimap, in units from its corner.
minimap_place :: proc(m: ^Minimap, pos: sim.Vec2) -> sim.Vec2 {
	return (pos - m.min) * m.scale
}

@(private)
minimap_build :: proc(m: ^Minimap, level: ^sim.Level, meshes: ^Map_Meshes) {
	minimap_unload(m)
	if len(level.polys) == 0 do return
	m.min, m.max = level.polys[0].verts[0], level.polys[0].verts[0]
	for &poly in level.polys {
		for v in poly.verts {
			m.min = {min(m.min.x, v.x), min(m.min.y, v.y)}
			m.max = {max(m.max.x, v.x), max(m.max.y, v.y)}
		}
	}
	size := m.max - m.min
	if size.x + size.y < 1 do return
	m.scale = MINIMAP_UNITS / (size.x + size.y)
	m.width, m.height = size.x * m.scale, size.y * m.scale

	m.texture = rl.LoadRenderTexture(i32(m.width * MINIMAP_SUPER), i32(m.height * MINIMAP_SUPER))
	if m.texture.id == 0 do return
	rl.BeginTextureMode(m.texture)
	rl.ClearBackground({0, 0, 0, 0})
	// Nothing behind the map: the original clears the texture and draws the polygons
	// alone, so the shape of the map floats over the 
	camera := rl.Camera2D{target = m.min, zoom = m.scale * MINIMAP_SUPER}
	rl.BeginMode2D(camera)
	rlgl.DisableBackfaceCulling()
	if meshes.built {
		draw_mesh_now(meshes.background, meshes.material)
		draw_mesh_now(meshes.terrain, meshes.material)
	}
	rl.EndMode2D()
	rl.EndTextureMode()
	m.built = true
}

@(private)
minimap_unload :: proc(m: ^Minimap) {
	if m.texture.id != 0 do rl.UnloadRenderTexture(m.texture)
	m^ = {}
}

// The minimap of the map being played, or nil until there is one.
minimap :: proc(r: ^Render) -> ^Minimap {
	return r.minimap.built ? &r.minimap : nil
}

// The picture itself, drawn by the HUD at `x`, `y` in interface units.
minimap_draw :: proc(m: ^Minimap, x, y, scale: f32, alpha: u8) {
	t := m.texture.texture
	src := rl.Rectangle{0, 0, f32(t.width), -f32(t.height)} // a render texture comes out upside down
	dst := rl.Rectangle{x * scale, y * scale, m.width * scale, m.height * scale}
	rl.DrawTexturePro(t, src, dst, {}, 0, {255, 255, 255, alpha})
}
