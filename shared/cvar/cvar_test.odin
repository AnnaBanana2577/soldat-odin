package cvar

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
set_from_command_and_file :: proc(t: ^testing.T) {
	port := 23073
	name := "Major"
	volume: f32 = 0.12
	windowed := false
	s: Set
	add(&s, "port", &port, "the port")
	add(&s, "name", &name, "who I am")
	add(&s, "volume", &volume, "how loud")
	add(&s, "window", &windowed, "in a window")

	rest := parse(&s, {"-port", "1234", "-name", "Brandon", "-window", "-join", "127.0.0.1"})
	testing.expect(t, port == 1234 && name == "Brandon" && windowed, "the command line sets them")
	testing.expect(t, len(rest) == 2 && rest[0] == "-join", "what it does not know comes back")

	temp := os.get_env("TEMP", context.temp_allocator)
	path, _ := filepath.join({temp, "cvar_test.cfg"}, context.temp_allocator)
	missing, _ := filepath.join({temp, "cvar_test_missing.cfg"}, context.temp_allocator)
	written := os.write_entire_file(path, transmute([]u8)string("# a comment\nvolume 0.5\nname  Someone Else  // trailing\nnonsense 3\n"))
	testing.expect(t, written == nil, "the file is written")
	defer os.remove(path)
	testing.expect(t, load(&s, path), "the file is read")
	testing.expect(t, volume == 0.5, "a number out of the file")
	testing.expect(t, name == "Someone Else", "a name with a space in it, and no comment")
	testing.expect(t, !load(&s, missing), "a missing file is no error, only false")

	testing.expect(t, !set(&s, "port", "birds"), "what is not a number is refused")
	testing.expect(t, port == 1234, "and leaves the setting alone")
	testing.expect(t, !set(&s, "nothing", "1"), "a name nothing knows is refused")
}
