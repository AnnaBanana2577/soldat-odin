package editor

// A map the editor makes has to satisfy two readers that do not agree about what matters:
// the codec, which keeps everything, and the game's loader, which is strict about the
// counts and the sector grid. Checking both is the point - a blank map that only the
// codec accepts would look fine in the editor and refuse to load in the game.

import "core:testing"

import "../../shared/pms"
import "../../shared/polymap"

@(test)
test_a_new_map_reads_back_as_itself :: proc(t: ^testing.T) {
	m := new_map("test_map")
	defer pms.destroy(&m)

	bytes := pms.write(&m)
	defer delete(bytes)

	again, err := pms.read(bytes)
	defer pms.destroy(&again)

	testing.expect_value(t, err, pms.Error.None)
	testing.expect_value(t, pms.text_of(again.name[:]), "test_map")
	testing.expect_value(t, again.version, i32(pms.VERSION))
	testing.expect_value(t, len(again.polygons), 0)

	// The grid is (2n+1)^2 cells whether or not anything is in them.
	side := 2 * NEW_SECTORS_NUM + 1
	testing.expect_value(t, len(again.sectors), side * side)
	testing.expect_value(t, again.sectors_division, i32(NEW_SECTORS_DIVISION))

	// Nothing left over: only a file written in place over a longer one has that.
	testing.expect_value(t, len(again.trailing), 0)
}

@(test)
test_the_game_will_load_a_new_map :: proc(t: ^testing.T) {
	m := new_map("test_map")
	defer pms.destroy(&m)

	bytes := pms.write(&m)
	defer delete(bytes)

	level, err := polymap.load(bytes)
	defer polymap.destroy(&level)

	testing.expect_value(t, err, polymap.Error.None)
	testing.expect_value(t, len(level.polys), 0)
	testing.expectf(t, level.sectors_division > 0, "the sector grid did not survive")
}

// Writing is byte-for-byte repeatable, so saving twice cannot drift.
@(test)
test_writing_a_new_map_is_stable :: proc(t: ^testing.T) {
	m := new_map("test_map")
	defer pms.destroy(&m)

	once := pms.write(&m)
	defer delete(once)

	again, err := pms.read(once)
	defer pms.destroy(&again)
	testing.expect_value(t, err, pms.Error.None)

	twice := pms.write(&again)
	defer delete(twice)

	testing.expect_value(t, len(twice), len(once))
	for b, i in once {
		if twice[i] != b {
			testing.expectf(t, false, "byte %d differs on the second write", i)
			break
		}
	}
}

// Every layer the toolbar offers maps onto something; the four that belong to the map
// reach the renderer and the three overlays do not.
@(test)
test_layer_parts_only_passes_the_maps_own :: proc(t: ^testing.T) {
	all := Layers{}
	for layer in Layer do all += {layer}

	parts := layer_parts(all)
	testing.expect(t, .Background in parts, "background should reach the renderer")
	testing.expect(t, .Polygons in parts, "polygons should reach the renderer")
	testing.expect(t, .Scenery in parts, "scenery should reach the renderer")
	testing.expect(t, .Wireframe in parts, "wireframe should reach the renderer")

	// The overlays are the editor's own and have no part in the map's drawing.
	testing.expect_value(t, card(layer_parts(Layers{.Spawns, .Colliders, .Waypoints})), 0)
	testing.expect_value(t, card(layer_parts(Layers{})), 0)
	testing.expect_value(t, card(layer_parts(DEFAULT_LAYERS)), 3)
}
