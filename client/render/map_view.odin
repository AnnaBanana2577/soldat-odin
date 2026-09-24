package render

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../../shared/polymap"
import "../../shared/sim"

// One map, ready to draw: its polygons as meshes, the texture they wear, and the images
// its props name. Nothing here knows about a game, which is the point - the client keeps
// one of these inside Render and slots soldiers and bullets between the layers, and the
// editor owns one and draws it whole.

Map_View :: struct {
	level:   ^polymap.Polymap,      // borrowed; the owner outlives the view
	texture: rl.Texture2D,    // id 0 draws the polygons untextured
	scenery: []rl.Texture2D,  // one per entry in Level.scenery, id 0 where it failed to load
	meshes:  Map_Meshes,
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

// Read a map's art and build its meshes. The window must be open.
map_view_load :: proc(v: ^Map_View, base: string, level: ^polymap.Polymap) {
	map_view_unload(v)
	v.level = level
	v.texture = map_texture_load(base, level.texture)
	v.scenery = scenery_load(base, level.scenery)
	map_meshes_build(&v.meshes, level, v.texture)
}

map_view_unload :: proc(v: ^Map_View) {
	if v.level == nil do return
	map_meshes_unload(&v.meshes)
	for t in v.scenery do if t.id != 0 do rl.UnloadTexture(t)
	delete(v.scenery)
	if v.texture.id != 0 do rl.UnloadTexture(v.texture)
	v^ = {}
}

// The pieces of a map, so a caller can leave some out. The game always draws the lot;
// the editor turns them off to see what is underneath.
Map_Part :: enum {
	Background, // the sky gradient
	Polygons,   // the terrain meshes
	Scenery,    // the props
	Wireframe,  // the polygon edges, over everything
}
Map_Parts :: bit_set[Map_Part]

ALL_PARTS :: Map_Parts{.Background, .Polygons, .Scenery}

// The map and nothing else, in the original's layer order. The game draws the same
// pieces but slots the living things between them; see render.draw.
// Between the caller's BeginMode2D and EndMode2D.
map_view_draw :: proc(v: ^Map_View, camera: ^Camera, parts := ALL_PARTS) {
	if v.level == nil do return
	// A map's triangles wind either way, and raylib culls back faces by default, so the
	// polygon meshes come out empty without this. The game's draw does the same thing
	// for the same reason.
	rlgl.DisableBackfaceCulling()

	if .Background in parts do draw_background(v.level, camera)
	if .Polygons in parts && v.meshes.built do draw_mesh_now(v.meshes.background, v.meshes.material)
	if .Scenery in parts {
		draw_scenery(v, 0)
		draw_scenery(v, 1)
	}
	if .Polygons in parts && v.meshes.built do draw_mesh_now(v.meshes.terrain, v.meshes.material)
	if .Scenery in parts do draw_scenery(v, 2)
	if .Wireframe in parts do draw_wireframe(v.level)
}

// The box the map's polygons fill, which is what a view frames when a map opens.
map_view_bounds :: proc(level: ^polymap.Polymap) -> (low, high: sim.Vec2) {
	if level == nil || len(level.polys) == 0 do return {-640, -480}, {640, 480}
	low, high = {max(f32), max(f32)}, {min(f32), min(f32)}
	for &poly in level.polys {
		for v in poly.verts {
			low = {min(low.x, v.x), min(low.y, v.y)}
			high = {max(high.x, v.x), max(high.y, v.y)}
		}
	}
	return
}

@(private)
map_meshes_build :: proc(m: ^Map_Meshes, level: ^polymap.Polymap, texture: rl.Texture2D) {
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
build_poly_mesh :: proc(level: ^polymap.Polymap, background: bool) -> (mesh: rl.Mesh) {
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

// The sky gradient. The original anchors it in world space vertically, spanning +/-d
// about the origin, and stretches it across the view, so it scrolls with the camera.
@(private)
draw_background :: proc(level: ^polymap.Polymap, camera: ^Camera) {
	d := f32(polymap.MAX_SECTOR) * max(f32(level.sectors_division), math.ceil(0.5 * GAME_HEIGHT / f32(polymap.MAX_SECTOR)))
	half_width := view_size(camera).x / 2
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
draw_scenery :: proc(v: ^Map_View, layer: u8) {
	for &prop in v.level.props {
		if prop.level != layer || prop.style == 0 do continue
		tex := v.scenery[prop.style - 1]
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
prop_corners :: proc(prop: ^polymap.Prop) -> (p0, p1, p2, p3: sim.Vec2) {
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
draw_wireframe :: proc(level: ^polymap.Polymap) {
	for &poly in level.polys {
		for k in 0 ..< 3 {
			a, b := poly.verts[k], poly.verts[(k + 1) % 3]
			rl.DrawLineV({a.x, a.y}, {b.x, b.y}, rl.WHITE)
		}
	}
}

