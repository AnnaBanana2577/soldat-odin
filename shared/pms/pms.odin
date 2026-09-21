// The .pms map format, read and written losslessly.
//
// Ported from OpenSoldat's shared/MapFile.pas and shared/Waypoints.pas. The types here
// mirror the on-disk record field for field, including the padding bytes that the
// original Delphi records carried and that real maps still have junk in. Nothing is
// interpreted: sector indices stay 1-based, normals stay unnormalized, inactive props
// stay in the list, the jet value is the raw one. The editor's document model is a
// separate layer on top of this.
//
// That split is what makes "did we parse this right" answerable by a byte comparison:
// read a map, write it back, expect the same bytes. See pms_test.odin.
package pms

import "core:math"

// The limits the game enforces while loading. A file past any of them is rejected
// rather than truncated, because the game would refuse it too.
MAX_POLYS       :: 5000
MAX_SECTOR      :: 25
MAX_PROPS       :: 500
MAX_SPAWNPOINTS :: 255
MAX_COLLIDERS   :: 128
MAX_WAYPOINTS   :: 5000
MAX_CONNECTIONS :: 20

// Every map in the base pack is version 11. The loader never branches on it, so neither
// do we, but it is kept so it round-trips and so the editor can warn about oddities.
VERSION :: 11

// Field sizes of the Delphi short strings, not counting their length byte.
NAME_SIZE    :: 38
TEXTURE_SIZE :: 24
SCENERY_SIZE :: 50

Color :: [4]u8 // rgba here, bgra on disk
Vec2  :: [2]f32
Vec3  :: [3]f32

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

Waypoint_Action :: enum u8 {
	None          = 0,
	Stop_And_Camp = 1,
	Wait_1s       = 2,
	Wait_5s       = 3,
	Wait_10s      = 4,
	Wait_15s      = 5,
	Wait_20s      = 6,
}

// z and rhw are leftovers of the Direct3D transformed-vertex struct Soldat drew with.
// Nothing reads them, but maps carry values in them, so they are kept.
Vertex :: struct {
	pos:   Vec2,
	z:     f32,
	rhw:   f32,
	color: Color,
	uv:    Vec2,
}

// The three normals are per-edge, not per-vertex: normals[k] is the outward normal of
// the edge from vertex k to k+1. Its length is 1 for a normal polygon and carries the
// bounciness for a Bouncy one, which is why they are stored unnormalized.
Polygon :: struct {
	verts:   [3]Vertex,
	normals: [3]Vec3,
	type:    Poly_Type,
}

// Scenery placed on the map. `style` is a 1-based index into Map.scenery; 0 means none.
Prop :: struct {
	active:   u8,
	_pad0:    u8, // the Word that follows was 2-byte aligned in the Delphi record
	style:    u16,
	width:    i32,
	height:   i32,
	pos:      Vec2,
	rotation: f32,
	scale:    Vec2,
	alpha:    u8,
	_pad1:    [3]u8,
	color:    Color,
	level:    u8, // 0 behind the map, 1 in front of it, 2 in front of the players
	_pad2:    [3]u8,
}

// The image a prop refers to. `date` is the source file's timestamp as the editor that
// wrote the map saw it; the game ignores it.
Scenery :: struct {
	name: [1 + SCENERY_SIZE]u8,
	date: i32,
}

Collider :: struct {
	active: u8,
	_pad0:  [3]u8,
	pos:    Vec2,
	radius: f32,
}

Spawnpoint :: struct {
	active: u8,
	_pad0:  [3]u8,
	x:      i32,
	y:      i32,
	team:   i32, // 0 general, 1-4 alpha/bravo/charlie/delta, then the flag and kit spawns
}

// A node in the bot pathing graph. `connections` is a fixed array of which only the
// first `connections_num` entries mean anything, but the rest are kept as they are.
Waypoint :: struct {
	active:          u8,
	_pad0:           [3]u8,
	id:              i32,
	x:               i32,
	y:               i32,
	left:            u8,
	right:           u8,
	up:              u8,
	down:            u8,
	jetpack:         u8,
	path_num:        u8,
	action:          Waypoint_Action,
	_pad1:           [5]u8,
	connections_num: i32,
	connections:     [MAX_CONNECTIONS]i32,
}

Map :: struct {
	version:   i32,
	// Delphi short strings: a length byte then a fixed buffer. Real maps leave junk in
	// the buffer past the length, so the whole field is kept verbatim and only read
	// through text_of / set_text.
	name:      [1 + NAME_SIZE]u8,
	texture:   [1 + TEXTURE_SIZE]u8,
	bg_top:    Color,
	bg_bottom: Color,
	start_jet: i32, // raw; the game scales this by 119/100 when it loads
	grenades:  u8,
	medikits:  u8,
	weather:   u8,
	steps:     u8,
	random_id: i32,

	polygons:  []Polygon,

	// The broadphase grid the game uses to find candidate polygons. It is stored in the
	// file rather than derived, so the editor has to rebuild it on save: see sectors.odin.
	// Indices are 1-based and may point past the polygon list in maps built by old tools.
	sectors_division: i32,
	sectors_num:      i32,
	sectors:          [][]u16,

	props:       []Prop,
	scenery:     []Scenery,
	colliders:   []Collider,
	spawnpoints: []Spawnpoint,
	waypoints:   []Waypoint,

	// Anything after the waypoints, which the game never reads. In the base pack this is
	// not appended data but the tail of a PREVIOUS, longer save: the old editors rewrote
	// a map in place without truncating the file, so whatever the last save did not cover
	// is still there. It reads as waypoint records with ids that restart partway through,
	// and it runs to 33 KB in Jungle.pms. 97 of the 99 base maps carry some.
	//
	// It is kept so that read -> write is byte-identical, which is what makes the codec
	// testable. An editor saving a map should drop it: set this to nil before write.
	trailing: []u8,
}

// The readable part of a Delphi short string field.
text_of :: proc(field: []u8) -> string {
	if len(field) == 0 {
		return ""
	}
	n := int(field[0])
	if n > len(field) - 1 {
		return ""
	}
	return string(field[1:][:n])
}

// Overwrite a short string field, clearing the buffer so we never leak the junk that
// was there. Text too long for the field is cut.
set_text :: proc(field: []u8, text: string) {
	if len(field) == 0 {
		return
	}
	capacity := len(field) - 1
	n := min(len(text), capacity)
	for i in 0 ..< len(field) {
		field[i] = 0
	}
	field[0] = u8(n)
	copy(field[1:], text[:n])
}

// The side length of the sector grid: sectors is side*side entries.
sector_side :: proc(m: ^Map) -> int {
	return int(2 * m.sectors_num + 1)
}

// On-disk sizes of the fixed-size records, for seeking and for reporting where a byte
// difference landed. They are spelled out rather than taken from size_of, because the
// Odin structs carry the padding as named fields and could drift from the file layout.
POLYGON_BYTES    :: 3 * (4 * 4 + 4 + 2 * 4) + 3 * 12 + 1 // 121
PROP_BYTES       :: 44
SCENERY_BYTES    :: 1 + SCENERY_SIZE + 4 // 55
COLLIDER_BYTES   :: 16
SPAWNPOINT_BYTES :: 16
WAYPOINT_BYTES   :: 32 + 4 * MAX_CONNECTIONS // 112

// What a spawn point spawns, from the team numbers OpenSoldat's Things.pas dispatches
// on. 1-4 are the player teams; the rest are object spawns and are placed once a round.
Spawn_Team :: enum i32 {
	General        = 0,
	Alpha          = 1,
	Bravo          = 2,
	Charlie        = 3,
	Delta          = 4,
	Alpha_Flag     = 5,
	Bravo_Flag     = 6,
	Grenade_Kit    = 7,
	Medical_Kit    = 8,
	Cluster_Kit    = 9,
	Vest_Kit       = 10,
	Flamer_Kit     = 11,
	Berserk_Kit    = 12,
	Predator_Kit   = 13,
	Pointmatch_Flag = 14,
	Rambo_Bow      = 15,
	Stationary_Gun = 16,
}

// Maps in the wild carry team numbers outside the known set, so this names what it can
// and passes the rest through rather than rejecting the map.
spawn_team_name :: proc(team: i32) -> string {
	if team < i32(Spawn_Team.General) || team > i32(Spawn_Team.Stationary_Gun) {
		return "unknown"
	}
	switch Spawn_Team(team) {
	case .General:         return "general"
	case .Alpha:           return "alpha"
	case .Bravo:           return "bravo"
	case .Charlie:         return "charlie"
	case .Delta:           return "delta"
	case .Alpha_Flag:      return "alpha flag"
	case .Bravo_Flag:      return "bravo flag"
	case .Grenade_Kit:     return "grenade kit"
	case .Medical_Kit:     return "medical kit"
	case .Cluster_Kit:     return "cluster kit"
	case .Vest_Kit:        return "vest kit"
	case .Flamer_Kit:      return "flamer kit"
	case .Berserk_Kit:     return "berserk kit"
	case .Predator_Kit:    return "predator kit"
	case .Pointmatch_Flag: return "pointmatch flag"
	case .Rambo_Bow:       return "rambo bow"
	case .Stationary_Gun:  return "stationary gun"
	}
	return "unknown"
}

// Bouncy polygons hide their bounciness in the length of the third edge normal, which
// is why normals are stored unnormalized.
bounciness :: proc(p: ^Polygon) -> f32 {
	n := p.normals[2]
	return math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
}
