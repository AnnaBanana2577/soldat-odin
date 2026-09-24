// Package polymap is the map as the game reads it: polygons in sectors, colliders,
// spawn points, waypoints, and the props and scenery names the client draws. Ported
// from OpenSoldat MapFile.pas / PolyMap.pas by way of the old Odin port.
//
//   polymap  the types, destroy, and the teams as the map knows them
//   file     the bytes: a .pms read from disk, and the fields taken out of it
//   query    sectors, ray casts, the polygon tests, which polygons a team passes
package polymap

import "../geom"

// The teams as the map knows them: whose a team polygon is, whose a spawn point. The
// game's soldiers wear this same enum (sim.Team is this one).
Team :: enum u8 { None, Alpha, Bravo, Charlie, Delta, Spectator }

MAX_POLYS       :: 5000
MAX_SECTOR      :: 25
MIN_SECTORZ     :: -35
MAX_SECTORZ     :: 35
MAX_PROPS       :: 500
MAX_SPAWNPOINTS :: 255
MAX_COLLIDERS   :: 128

Poly_Type :: enum u8 {
	Normal                = 0,
	Only_Bullets          = 1,
	Only_Player           = 2,
	Doesnt                = 3,
	Ice                   = 4,
	Deadly                = 5,
	Bloody_Deadly         = 6,
	Hurts                 = 7,
	Regenerates           = 8,
	Lava                  = 9,
	Red_Bullets           = 10,
	Red_Player            = 11,
	Blue_Bullets          = 12,
	Blue_Player           = 13,
	Yellow_Bullets        = 14,
	Yellow_Player         = 15,
	Green_Bullets         = 16,
	Green_Player          = 17,
	Bouncy                = 18,
	Explodes              = 19,
	Hurts_Flaggers        = 20,
	Only_Flaggers         = 21,
	Not_Flaggers          = 22,
	Non_Flagger_Collides  = 23,
	Background            = 24,
	Background_Transition = 25,
}

Color :: [4]u8 // rgba

Polygon :: struct {
	verts:      [3]geom.Vec2,
	colors:     [3]Color,
	uvs:        [3]geom.Vec2,
	perp:       [3]geom.Vec2, // normalized edge normals; perp[k] belongs to edge k -> k+1
	bounciness: f32,
	type:       Poly_Type,
}

Spawnpoint :: struct {
	active: bool,
	pos:    geom.Vec2,
	team:   i32, // 0 general, 1 alpha, 2 bravo, 3 charlie, 4 delta, then the flag and kit spawns
}

Collider :: struct {
	active: bool,
	pos:    geom.Vec2,
	radius: f32,
}

// A piece of scenery placed by the map author. Purely decorative: nothing collides.
Prop :: struct {
	style:         u16, // 1-based index into Polymap.scenery, 0 = none
	width, height: i32,
	pos:           geom.Vec2,
	rotation:      f32,
	scale:         geom.Vec2,
	alpha:         u8,
	color:         Color,
	level:         u8, // 0 behind the map, 1 in front of it, 2 in front of the players
}

MAX_WAYPOINTS   :: 5000
MAX_CONNECTIONS :: 20

// One point of the path net the map author laid for the bots: where it is, which keys
// to hold on the way there, whose path it belongs to, whether to wait on it, and the
// waypoints it leads on to. The numbering is the file's own, 1-based with 0 for none,
// because that is what the connections hold; waypoints[0] is a blank one.
Waypoint :: struct {
	active:      bool,
	pos:         geom.Vec2,
	left, right, up, down, jet: bool,
	path:        u8, // the team whose bots follow it, 0 any
	action:      u8, // 0 none, 1 stop and camp, 2-6 wait 1, 5, 10, 15 or 20 seconds
	connections: [MAX_CONNECTIONS]i32,
	count:       int, // of them
}

Polymap :: struct {
	name:             string,
	texture:          string,
	bg_top:           Color,
	bg_bottom:        Color,
	start_jet:        i32,
	grenade_packs:    u8,
	medikits:         u8,
	weather:          u8,
	steps:            u8,
	polys:            []Polygon,
	back_polys:       []u16, // indices of Background / Background_Transition polys
	sectors_division: i32,
	sectors_num:      i32,
	sectors:          [][]u16, // (2n+1)^2 grid of poly indices, see sector_at
	spawnpoints:      []Spawnpoint,
	waypoints:        []Waypoint, // the bots' paths; 1-based, [0] a blank
	colliders:        []Collider,
	props:            []Prop,
	scenery:          []string, // image names props refer to by 1-based style
}

Error :: enum {
	None, Too_Many_Polys, Bad_Sectors, Too_Many_Props, Too_Many_Colliders, Too_Many_Spawnpoints, Too_Many_Waypoints,
}

destroy :: proc(m: ^Polymap, allocator := context.allocator) {
	context.allocator = allocator
	delete(m.name)
	delete(m.texture)
	delete(m.polys)
	delete(m.back_polys)
	delete(m.props)
	for s in m.scenery do delete(s)
	delete(m.scenery)
	for s in m.sectors do delete(s)
	delete(m.sectors)
	delete(m.spawnpoints)
	delete(m.waypoints)
	delete(m.colliders)
	m^ = {}
}
