package pms

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// Where the base map pack lives. Override with PMS_MAPS when it is somewhere else.
@(private = "file")
maps_dir :: proc() -> string {
	if dir, found := os.lookup_env("PMS_MAPS", context.temp_allocator); found {
		return dir
	}
	return "assets/maps"
}

@(private = "file")
map_paths :: proc(t: ^testing.T) -> []string {
	dir := maps_dir()
	handle, open_err := os.open(dir)
	if open_err != nil {
		testing.fail_now(t, fmt.tprintf("cannot open map directory %q: %v", dir, open_err))
	}
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil {
		testing.fail_now(t, fmt.tprintf("cannot list %q: %v", dir, read_err))
	}

	paths := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for entry in entries {
		if strings.equal_fold(filepath.ext(entry.name), ".pms") {
			append(&paths, entry.fullpath)
		}
	}
	slice.sort(paths[:])
	return paths[:]
}

// The guardrail: every map in the pack must survive read -> write unchanged. If this
// passes for all of them, the codec understands the format, including the padding junk
// and the fields the game itself ignores.
@(test)
test_round_trip_is_byte_exact :: proc(t: ^testing.T) {
	paths := map_paths(t)
	testing.expectf(t, len(paths) > 0, "no .pms files in %q", maps_dir())

	checked := 0
	for path in paths {
		name := filepath.base(path)
		original, read_err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, read_err == nil, "%s: cannot read: %v", name, read_err) {
			continue
		}

		m, err := read(original)
		if !testing.expectf(t, err == .None, "%s: read failed: %v", name, err) {
			continue
		}
		defer destroy(&m)

		rewritten := write(&m)
		defer delete(rewritten)

		if !testing.expectf(
			t,
			len(rewritten) == len(original),
			"%s: wrote %d bytes, original is %d",
			name,
			len(rewritten),
			len(original),
		) {
			continue
		}
		at, differs := first_difference(original, rewritten)
		if differs {
			testing.expectf(
				t,
				false,
				"%s: byte %d differs: original %02x, rewritten %02x (%s)",
				name,
				at,
				original[at],
				rewritten[at],
				describe_offset(&m, at),
			)
			continue
		}
		checked += 1
	}
	fmt.printfln("round-tripped %d/%d maps byte-exact", checked, len(paths))
}

// Reading a map back through its own written bytes must produce the same bytes again,
// which catches a writer that is self-consistently wrong.
@(test)
test_second_generation_is_stable :: proc(t: ^testing.T) {
	for path in map_paths(t) {
		name := filepath.base(path)
		original, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		first, err := read(original)
		if err != .None {
			continue
		}
		defer destroy(&first)

		once := write(&first)
		defer delete(once)

		second, second_err := read(once)
		if !testing.expectf(t, second_err == .None, "%s: reread failed: %v", name, second_err) {
			continue
		}
		defer destroy(&second)

		twice := write(&second)
		defer delete(twice)

		testing.expectf(t, slice.equal(once, twice), "%s: not stable across a second pass", name)
	}
}

// A file cut short must be reported, not quietly zero-filled into a valid-looking map.
@(test)
test_truncated_file_is_rejected :: proc(t: ^testing.T) {
	paths := map_paths(t)
	if len(paths) == 0 {
		return
	}
	original, read_err := os.read_entire_file(paths[0], context.temp_allocator)
	if !testing.expectf(t, read_err == nil, "cannot read %s: %v", paths[0], read_err) {
		return
	}

	m, err := read(original[:len(original) / 2])
	defer destroy(&m)
	testing.expectf(t, err == .Truncated, "expected .Truncated, got %v", err)
}

// Short string fields keep their junk on read and lose it on write.
@(test)
test_short_string_fields :: proc(t: ^testing.T) {
	field: [1 + NAME_SIZE]u8
	for i in 0 ..< len(field) {
		field[i] = 0xAB // junk, as a real map has
	}

	set_text(field[:], "ctf_Example")
	testing.expect_value(t, text_of(field[:]), "ctf_Example")
	testing.expect_value(t, field[0], u8(11))
	testing.expect_value(t, field[len(field) - 1], u8(0))

	long := strings.repeat("x", NAME_SIZE + 10, context.temp_allocator)
	set_text(field[:], long)
	testing.expect_value(t, len(text_of(field[:])), NAME_SIZE)

	// A length byte larger than the field is nonsense and must not read out of bounds.
	field[0] = 0xFF
	testing.expect_value(t, text_of(field[:]), "")
}

@(private = "file")
first_difference :: proc(a, b: []u8) -> (at: int, differs: bool) {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i, true
		}
	}
	if len(a) != len(b) {
		return n, true
	}
	return 0, false
}

// Turn a byte offset into the section it falls in, so a failure says what broke rather
// than just which byte.
@(private = "file")
describe_offset :: proc(m: ^Map, at: int) -> string {
	Section :: struct {
		name: string,
		size: int,
	}

	sector_bytes := 0
	for sector in m.sectors {
		sector_bytes += 2 + 2 * len(sector)
	}

	sections := [?]Section {
		{"header", 4 + len(m.name) + len(m.texture) + 4 + 4 + 4 + 4 + 4},
		{"polygon count", 4},
		{"polygons", POLYGON_BYTES * len(m.polygons)},
		{"sector header", 8},
		{"sectors", sector_bytes},
		{"prop count", 4},
		{"props", PROP_BYTES * len(m.props)},
		{"scenery count", 4},
		{"scenery", SCENERY_BYTES * len(m.scenery)},
		{"collider count", 4},
		{"colliders", COLLIDER_BYTES * len(m.colliders)},
		{"spawnpoint count", 4},
		{"spawnpoints", SPAWNPOINT_BYTES * len(m.spawnpoints)},
		{"waypoint count", 4},
		{"waypoints", WAYPOINT_BYTES * len(m.waypoints)},
		{"trailing", len(m.trailing)},
	}

	start := 0
	for section in sections {
		if at < start + section.size {
			return fmt.tprintf("%s +%d", section.name, at - start)
		}
		start += section.size
	}
	return "past the end"
}

// The leftover bytes past the waypoints are the tail of an older, longer save that the
// editor which wrote the map never truncated. Nothing reads them, but they are two
// thirds of the pack, so the codec has to carry them for a save to be a no-op.
@(test)
test_leftovers_are_carried :: proc(t: ^testing.T) {
	with_leftovers, total := 0, 0
	for path in map_paths(t) {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			continue
		}
		m, err := read(data)
		if err != .None {
			continue
		}
		defer destroy(&m)
		total += 1
		if len(m.trailing) == 0 {
			continue
		}
		with_leftovers += 1
		leftover_bytes := len(m.trailing)

		// Dropping them is what saving from the editor will do, and it must produce a
		// shorter file that still reads back the same way.
		m.trailing = m.trailing[:0]
		cleaned := write(&m)
		defer delete(cleaned)
		testing.expectf(
			t,
			len(cleaned) == len(data) - leftover_bytes,
			"%s: dropping %d leftover bytes gave %d bytes, expected %d",
			filepath.base(path),
			leftover_bytes,
			len(cleaned),
			len(data) - leftover_bytes,
		)

		reread, reread_err := read(cleaned)
		defer destroy(&reread)
		testing.expectf(t, reread_err == .None, "%s: cleaned map does not load: %v", filepath.base(path), reread_err)
		testing.expectf(
			t,
			len(reread.polygons) == len(m.polygons) && len(reread.waypoints) == len(m.waypoints),
			"%s: cleaned map lost content",
			filepath.base(path),
		)
	}
	fmt.printfln("%d/%d maps carry leftovers from an older save", with_leftovers, total)
}
