// The build and run tasks, in Odin so there is one of them and it works the same on
// every platform. A single-file package: it builds on its own.
//
//   odin run build.odin -file -- check          type-check every package
//   odin run build.odin -file -- build          compile the client and the server
//   odin run build.odin -file -- test           run the package tests
//   odin run build.odin -file -- dev            build, then a server with a client joined (-sv_bots N for bots)
//   odin run build.odin -file -- server         build, then the server alone
//   odin run build.odin -file -- editor         build, then the map editor (-- -cl_map ctf_Ash)
//   odin run build.odin -file -- package        release builds, and the client and server packages in dist/
//   odin run build.odin -file -- shots S C      join a server's sv_shotlog S with its client's dbg_shotlog C
//   odin run build.odin -file -- compare        the shot logs over simulated lines: hits shown against hits ruled
//   odin run build.odin -file -- clean
//
// Options: -release and -no-build are this script's, and compare's -runs N and -seconds N.
// Every other -name value goes to the server as it was given, so its settings work here
// (-sv_map ctf_Ash,Arena -sv_bots 5 -sv_timelimit 3; server -cvars lists them). Anything
// after a -- goes to the client instead (dev -- -net_ping 120 -cl_window).
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// Not build/: on Linux, odin run build.odin leaves this tool itself as ./build.
BUILD_DIR :: "bin"
DIST_DIR :: "dist"
ASSETS_DIR :: "assets"

Target :: struct {
	src, out: string,
}

TARGETS := [?]Target{{"client", "client"}, {"server", "server"}, {"launcher", "launcher"}}
LIBRARIES := [?]string{"shared/sim", "shared/net", "shared/timer", "shared/cvar", "shared/pms", "client/input", "client/editor"} // checked and tested, never built alone

Options :: struct {
	release:  bool,
	no_build: bool,
	port:     int,
	runs:     int, // compare: runs of each line, at once
	seconds:  int, // compare: how long each runs
	server:   [dynamic]string, // settings passed to the server as they were given
	extra:    []string,        // and these to the client, after a --
}

main :: proc() {
	opts := Options{port = 23073, runs = 3, seconds = 90}
	args := os.args[1:]
	command := "check"
	if len(args) > 0 && !strings.has_prefix(args[0], "-") {
		command = args[0]
		args = args[1:]
	}
	if command == "shots" do os.exit(shots(args)) // two files, not settings
	for i := 0; i < len(args); i += 1 {
		value := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-release":  opts.release = true
		case "-no-build": opts.no_build = true
		case "-sv_port":  opts.port = strconv.parse_int(value) or_else opts.port; i += 1
		case "-runs":     opts.runs = max(strconv.parse_int(value) or_else opts.runs, 1); i += 1
		case "-seconds":  opts.seconds = max(strconv.parse_int(value) or_else opts.seconds, 5); i += 1
		case "--":        opts.extra = args[i + 1:]; i = len(args)
		case:
			// every other setting is the server's, and goes to it as it was given
			if !strings.has_prefix(args[i], "-") {
				fmt.eprintfln("unknown command %s", args[i])
				os.exit(2)
			}
			append(&opts.server, args[i])
			if value != "" && !strings.has_prefix(value, "-") {
				append(&opts.server, value)
				i += 1
			}
		}
	}

	switch command {
	case "check":  os.exit(check_all(opts))
	case "build":  os.exit(build_all(opts))
	case "test":   os.exit(run_tests(opts))
	case "dev":    os.exit(dev(opts))
	case "server": os.exit(run_server(opts))
	case "editor": os.exit(editor(opts))
	case "package": os.exit(package_all(opts))
	case "clean":  os.exit(clean())
	case "compare": os.exit(compare(opts))
	case:
		fmt.eprintfln("unknown command %s", command)
		os.exit(2)
	}
}

check_all :: proc(opts: Options) -> int {
	for lib in LIBRARIES {
		fmt.printfln("checking %s", lib)
		if code := run(argv({"odin", "check", lib, "-no-entry-point"}, flags(opts))); code != 0 do return code
	}
	for t in TARGETS {
		fmt.printfln("checking %s", t.src)
		if code := run(argv({"odin", "check", t.src}, flags(opts))); code != 0 do return code
	}
	return 0
}

build_all :: proc(opts: Options) -> int {
	if !ensure_build_dir() do return 1
	for t in TARGETS {
		fmt.printfln("building %s", t.src)
		if code := run(argv({"odin", "build", t.src, fmt.tprintf("-out:%s", exe(t.out))}, flags(opts))); code != 0 do return code
	}
	return 0
}


run_tests :: proc(opts: Options) -> int {
	if !ensure_build_dir() do return 1 // where the test binaries go: not there in a fresh checkout
	for lib in LIBRARIES {
		fmt.printfln("testing %s", lib)
		if code := run(argv({"odin", "test", lib, fmt.tprintf("-out:%s", exe("test"))}, flags(opts))); code != 0 do return code
	}
	return 0
}

run_server :: proc(opts: Options) -> int {
	if !opts.no_build {
		if code := build_all(opts); code != 0 do return code
	}
	return run(argv({exe("server"), "-sv_base", assets(), "-sv_port", fmt.tprint(opts.port)}, opts.server[:], opts.extra))
}

// A server, with the bots asked for, and a client joined to it; everything stops when
// the client exits.
dev :: proc(opts: Options) -> int {
	if !opts.no_build {
		if code := build_all(opts); code != 0 do return code
	}
	server, err := spawn(argv({exe("server"), "-sv_base", assets(), "-sv_port", fmt.tprint(opts.port)}, opts.server[:]))
	if err != nil {
		fmt.eprintfln("could not start the server: %v", err)
		return 1
	}
	defer stop(server)
	return run(argv({exe("client"), "-cl_base", assets(), "-cl_join", "127.0.0.1", "-cl_port", fmt.tprint(opts.port)}, opts.extra))
}

// The map editor: the client, pointed at the assets, with no server and no soldier.
editor :: proc(opts: Options) -> int {
	if !opts.no_build {
		if code := build_all(opts); code != 0 do return code
	}
	return run(argv({exe("client"), "-cl_base", assets(), "-cl_editor"}, opts.extra))
}

clean :: proc() -> int {
	if err := os.remove_all(BUILD_DIR); err != nil {
		fmt.eprintfln("could not remove %s: %v", BUILD_DIR, err)
		return 1
	}
	return 0
}

// Release builds, and the two packages a player downloads, in dist/ and archived there
// (a .zip on Windows, a .tar.gz elsewhere):
//
//   soldat-client-<os>   the client, the server, the launcher and the assets: a game of
//                        one's own with a double-click, or anyone's with -cl_join
//   soldat-server-<os>   the server and the assets
//
// The assets are unpacked flat beside the executables, which is where they look for
// config.cfg and the art. Each package carries what it needs and a machine cannot be
// counted on to have: on Windows the Visual C++ runtime the client's raylib is built
// against, and on Linux ENet, in lib/, where a release build looks first.
package_all :: proc(opts: Options) -> int {
	release := opts
	release.release = true
	if code := build_all(release); code != 0 do return code
	platform := ODIN_OS == .Windows ? "windows" : ODIN_OS == .Linux ? "linux" : "macos"
	if os.exists(dist_path("")) {
		if err := os.remove_all(dist_path("")); err != nil do return failed("could not clear %s: %v", DIST_DIR, err)
	}
	Package :: struct {
		name:     string,
		programs: []string,
	}
	packages := [?]Package{
		{fmt.tprintf("soldat-client-%s", platform), []string{"client", "server", "launcher"}},
		{fmt.tprintf("soldat-server-%s", platform), []string{"server"}},
	}
	for p in packages {
		dir := dist_path(p.name)
		fmt.printfln("packaging %s", p.name)
		if err := os.copy_directory_all(dir, assets()); err != nil do return failed("could not copy the assets into %s: %v", dir, err)
		for program in p.programs {
			name := fmt.tprintf("%s%s", program, ODIN_OS == .Windows ? ".exe" : "")
			if err := os.copy_file(join(dir, name), exe(program)); err != nil do return failed("could not copy %s: %v", name, err)
		}
		if err := os.copy_file(join(dir, "license.md"), join(repo_root, "license.md")); err != nil do return failed("could not copy the licence: %v", err)
		if !bundle_runtime(dir, p.programs) do return 1
		if code := archive(p.name); code != 0 do return code
	}
	return 0
}

// What the programs need that a machine cannot be counted on to have, beside them.
bundle_runtime :: proc(dir: string, programs: []string) -> bool {
	when ODIN_OS == .Windows {
		// raylib's library is built against the Visual C++ runtime, which Windows does not
		// ship; Microsoft allows it beside the program. The server does not use it.
		needs := false
		for p in programs do if p == "client" do needs = true
		if !needs do return true
		dll := join(windows_dir(), "System32", "vcruntime140.dll")
		if err := os.copy_file(join(dir, "vcruntime140.dll"), dll); err != nil {
			fmt.eprintfln("could not copy %s: %v", dll, err)
			return false
		}
	} else when ODIN_OS == .Linux {
		// ENet is the system's, linked by name: the one this build found goes in lib/
		state, out, _, err := os.process_exec({command = {"ldd", exe("server")}}, context.temp_allocator)
		if err != nil || state.exit_code != 0 {
			fmt.eprintfln("could not ask ldd what the server links: %v", err)
			return false
		}
		for line in strings.split_lines(string(out), context.temp_allocator) {
			// "	libenet.so.7 => /usr/lib/x86_64-linux-gnu/libenet.so.7 (0x...)"
			if !strings.contains(line, "libenet") do continue
			arrow := strings.index(line, " => ")
			paren := strings.last_index(line, " (")
			if arrow < 0 || paren < arrow do continue
			name := strings.trim_space(line[:arrow])
			from := line[arrow + 4:paren]
			if dir_err := os.make_directory_all(join(dir, "lib")); dir_err != nil && dir_err != .Exist {
				fmt.eprintfln("could not make %s/lib: %v", dir, dir_err)
				return false
			}
			if copy_err := os.copy_file(join(dir, "lib", name), from); copy_err != nil {
				fmt.eprintfln("could not copy %s: %v", from, copy_err)
				return false
			}
			return true
		}
		fmt.eprintln("ldd does not say where the server's ENet is")
		return false
	}
	return true
}

// dist/NAME as one archive beside it.
archive :: proc(name: string) -> int {
	when ODIN_OS == .Windows {
		// Windows' own tar, which writes a zip; the one a Git bash puts first on the PATH
		// does not
		tar := join(windows_dir(), "System32", "tar.exe")
		return run({tar, "-a", "-c", "-f", dist_path(fmt.tprintf("%s.zip", name)), "-C", dist_path(""), name})
	} else {
		return run({"tar", "-c", "-z", "-f", dist_path(fmt.tprintf("%s.tar.gz", name)), "-C", dist_path(""), name})
	}
}

dist_path :: proc(name: string) -> string {
	return join(repo_root, DIST_DIR, name)
}

windows_dir :: proc() -> string {
	dir := os.get_env("SystemRoot", context.temp_allocator)
	return dir != "" ? dir : `C:\Windows`
}

join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	return path
}

failed :: proc(format: string, args: ..any) -> int {
	fmt.eprintfln(format, ..args)
	return 1
}

// ---- helpers ----

DEBUG_FLAGS   := [?]string{"-debug", "-vet-unused", "-vet-shadowing"}
when ODIN_OS == .Linux {
	// A release build looks for its libraries in lib/ beside it before the system's: that is
	// where a package carries ENet (package_all). Odin hands it to the linker as it is, with no
	// shell between to read $ORIGIN as a variable.
	RELEASE_FLAGS := [?]string{"-o:speed", "-vet-unused", "-vet-shadowing", `-extra-linker-flags:-Wl,-rpath,$ORIGIN/lib`}
} else {
	RELEASE_FLAGS := [?]string{"-o:speed", "-vet-unused", "-vet-shadowing"}
}

flags :: proc(opts: Options) -> []string {
	return opts.release ? RELEASE_FLAGS[:] : DEBUG_FLAGS[:]
}

argv :: proc(groups: ..[]string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for g in groups do append(&out, ..g)
	return out[:]
}

// Absolute, with the platform's separators: a relative path does not reliably spawn
// on Windows.
exe :: proc(name: string) -> string {
	suffix := ODIN_OS == .Windows ? ".exe" : ""
	path, err := filepath.join({repo_root, BUILD_DIR, fmt.tprintf("%s%s", name, suffix)}, context.temp_allocator)
	return err == nil ? path : fmt.tprintf("%s/%s%s", BUILD_DIR, name, suffix)
}

// The assets in the checkout, so a run from here finds the art and config.cfg whatever
// the working directory is. A distribution unpacks them beside the executable instead.
assets :: proc() -> string {
	path, err := filepath.join({repo_root, ASSETS_DIR}, context.temp_allocator)
	return err == nil ? path : ASSETS_DIR
}

ensure_build_dir :: proc() -> bool {
	if os.exists(BUILD_DIR) do return true
	if err := os.make_directory(BUILD_DIR); err != nil {
		fmt.eprintfln("could not create %s: %v", BUILD_DIR, err)
		return false
	}
	return true
}

run :: proc(command: []string) -> int {
	process, err := spawn(command)
	if err != nil {
		fmt.eprintfln("could not run %v: %v", command, err)
		return 1
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("could not wait on %v: %v", command, wait_err)
		return 1
	}
	return state.exit_code
}

spawn :: proc(command: []string) -> (os.Process, os.Error) {
	return os.process_start({command = command, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
}

stop :: proc(process: os.Process) {
	_ = os.process_kill(process)
	_, _ = os.process_wait(process)
}

// The repo root, from this file's location, so the tool works from any directory.
repo_root :: #directory

// ---- shots: the two halves of the shot log, joined ----

// A server's sv_shotlog and its client's dbg_shotlog, joined by (slot, shot, cmd): each
// shot that hit on either side, the rewind it needed (the tick the server ran its command
// in, less the tick the client showed the others at when it fired) against the one it was
// judged with, and the counts. A hit is joined to the newest shot of its slot and number
// in its own file, since a hit line carries no command; a hit on a corpse counts on
// neither side.
//
//   odin run build.odin -file -- shots server.log client.log [-all]
//
// -all lists every shot, not only the ones that hit somewhere.
//
// A hit seen and not ruled is put down to one cause. The rewind: judged at its cap, or by
// a tick other than the one it needed. The target: dead on the server already (its copy
// hit the corpse, or the death came after the tick the client showed and before the step),
// or a corpse in front taking the server's copy first. Otherwise the geometry of the step the client saw it hit in, from the
// fly and near lines both sides wrote of it: the bullet gone on the server by then (its
// end line says on what); the target not near the server's path at all; the server's
// path crossing the target as the client had it (the target: moved, or posed otherwise
// at the same place); the client's path crossing the target as the server had it (the
// path); both; the server's path crossing its own target, but something stopping it short
// (a wall in front, spawn protection); or none of these. A melee swing is met from the
// hand, not along its path, so only the causes before the geometry hold for it.
Shot_Key :: struct {
	slot: int,
	shot: int,
	cmd:  int,
}

Shot :: struct {
	key:                                Shot_Key,
	on_server, on_client:               bool,
	server_tick, lag, behind, ran, cap: int, // the server's line
	view:                               int, // the client's
	ruled, seen, guessed:               bool,
	hit_timeout, hit_target:            int, // the step the client saw it hit in, and whom
	corpse_hit:                         [dynamic][2]int, // whom the server's copy hit dead already, and at which step
	server_end:                         string, // what ended the server's copy, and at which step
	server_end_timeout:                 int,
	first_timeout:                      int, // the server's copy's first step: the tick of a step is counted from it
}

// A bullet about to be met against the soldiers, on one side, and the soldiers near its
// path there.
Flight_Key :: struct {
	key:     Shot_Key,
	timeout: int,
	server:  bool,
}

Flight :: struct {
	pos, vel: [2]f64,
	near:     [dynamic]Near_Soldier,
}

Near_Soldier :: struct {
	target:    int,
	pos:       [2]f64,
	pose:      string, // direction, stance and the two animations and their frames
	protected: bool,
	parts:     [7][2]f64,
}

Shot_Log :: struct {
	list:    [dynamic]Shot,
	flights: map[Flight_Key]Flight,
	deaths:  map[int][dynamic]int, // each soldier's deaths on the server, by tick
}

Cause :: enum {
	None, Capped, Wrong_Tick, Corpse, Gone, Target_Far, Target_Moved, Target_Posed, Path, Both, Corpse_In_Front, Met, Other, Unlogged,
}

CAUSE_NAMES := [Cause]string{
	.None = "", .Capped = "at the cap", .Wrong_Tick = "wrong tick", .Corpse = "target already dead on the server", .Gone = "bullet gone on the server",
	.Target_Far = "target far on the server", .Target_Moved = "target moved", .Target_Posed = "target posed otherwise",
	.Path = "bullet path", .Both = "target and path", .Corpse_In_Front = "a corpse in front on the server", .Met = "met on the server, stopped short", .Other = "none of these",
	.Unlogged = "not logged",
}

PART_RADIUS :: 7 // sim.PART_RADIUS

// What a run's shots come to. Of the hits seen and not ruled: judged at the rewind's
// cap, judged by a tick other than the one it needed below the cap, aimed at a soldier
// shown guessed on, fired in a burst; and how many ticks too recent they were judged.
Shot_Counts :: struct {
	fired, seen, ruled:                     int,
	agree, seen_only, ruled_only, unrun:    int,
	capped, wrong, guessed, burst, short:   int,
	need_sum, need_count, need_most:        int, // the rewind every shot on both sides needed
	causes:                                 [Cause]int, // of the hits seen and not ruled
}

shots :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.eprintln("shots SERVER_LOG CLIENT_LOG [-all]")
		return 2
	}
	all := len(args) > 2 && args[2] == "-all"
	log, ok := shots_join(args[0], args[1])
	if !ok do return 1
	list := log.list
	fmt.printfln("%-5s %-5s %-6s %-6s %-6s %-5s %-5s %-5s %-4s %-8s %s", "slot", "shot", "cmd", "client", "server", "need", "used", "raw", "ran", "guessed", "")
	for s in list {
		verdict := shot_verdict(s)
		if verdict == "" && !all do continue
		yes := proc(b: bool, word: string) -> string { return b ? word : "-" }
		if s.on_server && s.on_client {
			fmt.printfln("%-5d %-5d %-6d %-6s %-6s %-5d %-5d %-5d %-4d %-8s %s", s.key.slot, s.key.shot, s.key.cmd, yes(s.seen, "hit"), yes(s.ruled, "hit"),
				s.server_tick - s.view, s.lag, s.behind, s.ran, s.guessed ? "yes" : "", verdict)
			if s.seen && !s.ruled do fmt.printfln("      %s", shot_story(&log, s))
		} else {
			fmt.printfln("%-5d %-5d %-6d %-6s %-6s %-5s %-5s %-5s %-4s %-8s %s", s.key.slot, s.key.shot, s.key.cmd, yes(s.seen, "hit"), yes(s.ruled, "hit"), "", "", "", "", s.guessed ? "yes" : "", verdict)
		}
	}
	c := shots_count(&log)
	fmt.println()
	fmt.printfln("%d shots fired on the server; %d hits seen on the client, %d ruled on the server", c.fired, c.seen, c.ruled)
	fmt.printfln("  %d agree, %d seen and not ruled, %d ruled and not seen, %d seen from a shot the server never fired", c.agree, c.seen_only, c.ruled_only, c.unrun)
	fmt.printfln("  of the %d seen and not ruled: %d judged at the rewind's cap, %d judged by the wrong tick below it, %d aimed at a guessed soldier, %d fired in a burst; judged %.1f ticks too recent on average",
		c.seen_only, c.capped, c.wrong, c.guessed, c.burst, f64(c.short) / f64(max(c.seen_only, 1)))
	fmt.printfln("  the rewind a shot needed: %.1f ticks on average, %d at most", f64(c.need_sum) / f64(max(c.need_count, 1)), c.need_most)
	fmt.print("  seen and not ruled, by cause:")
	for n, cause in c.causes do if n > 0 do fmt.printf(" %s %d;", CAUSE_NAMES[cause], n)
	fmt.println()
	return 0
}

shots_join :: proc(server_path, client_path: string) -> (log: Shot_Log, ok: bool) {
	list := &log.list
	index: map[Shot_Key]int
	find := proc(list: ^[dynamic]Shot, index: ^map[Shot_Key]int, key: Shot_Key) -> ^Shot {
		if i, found := index[key]; found do return &list[i]
		index[key] = len(list)
		append(list, Shot{key = key})
		return &list[len(list) - 1]
	}
	for path, side in ([2]string{server_path, client_path}) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("could not read %s: %v", path, err)
			return
		}
		newest: map[[2]int]Shot_Key // (slot, shot): the newest fire of it, which its hits join
		flying: map[Shot_Key]int    // the timeout of its newest fly line: the step a hit is in
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if line == "" || line[0] == '#' do continue
			f := strings.split(line, "\t", context.temp_allocator)
			n := proc(f: []string, i: int) -> int { return i < len(f) ? strconv.parse_int(f[i]) or_else 0 : 0 }
			server := side == 0
			o := server ? 0 : 1 // a client's lines have its view tick second
			x := proc(f: []string, i: int) -> f64 { return i < len(f) ? strconv.parse_f64(f[i]) or_else 0 : 0 }
			switch {
			case f[0] == "fly":
				key, found := newest[{n(f, 2 + o), n(f, 3 + o)}]
				if !found do continue
				t := n(f, 4 + o)
				if server && key not_in flying do list[index[key]].first_timeout = t
				flying[key] = t
				log.flights[{key, t, server}] = {pos = {x(f, 5 + o), x(f, 6 + o)}, vel = {x(f, 7 + o), x(f, 8 + o)}}
			case f[0] == "near":
				key, found := newest[{n(f, 2 + o), n(f, 3 + o)}]
				if !found do continue
				fl, flown := &log.flights[{key, n(f, 4 + o), server}]
				if !flown || len(f) < 28 + o do continue
				ns := Near_Soldier{target = n(f, 5 + o), pos = {x(f, 6 + o), x(f, 7 + o)}, protected = f[14 + o] == "true",
					pose = strings.join(f[8 + o:14 + o], " ", context.temp_allocator)}
				for k in 0 ..< 7 do ns.parts[k] = {x(f, 15 + o + 2 * k), x(f, 16 + o + 2 * k)}
				append(&fl.near, ns)
			case f[0] == "end" && server:
				key, found := newest[{n(f, 2), n(f, 3)}]
				if !found do continue
				s := &list[index[key]]
				s.server_end, s.server_end_timeout = strings.clone(f[7]), n(f, 4)
			case f[0] == "end":
			case f[0] == "death":
				target := n(f, 2)
				if target not_in log.deaths do log.deaths[target] = {}
				append(&log.deaths[target], n(f, 1))
			case f[0] == "fire" && server:
				key := Shot_Key{n(f, 2), n(f, 3), n(f, 4)}
				s := find(list, &index, key)
				s.on_server, s.server_tick, s.lag, s.behind, s.ran, s.cap = true, n(f, 1), n(f, 5), n(f, 6), n(f, 7), n(f, 10)
				newest[{key.slot, key.shot}] = key
			case f[0] == "fire":
				key := Shot_Key{n(f, 3), n(f, 4), n(f, 5)}
				s := find(list, &index, key)
				s.on_client, s.view = true, n(f, 2)
				newest[{key.slot, key.shot}] = key
			case f[0] == "hit" && server:
				key, found := newest[{n(f, 2), n(f, 3)}]
				if !found || len(f) < 8 do continue
				if f[7] == "false" do list[index[key]].ruled = true
				else do append(&list[index[key]].corpse_hit, [2]int{n(f, 4), flying[key] or_else -1})
			case f[0] == "hit":
				key, found := newest[{n(f, 3), n(f, 4)}]
				if !found || len(f) < 9 || f[8] != "false" do continue
				s := &list[index[key]]
				if !s.seen do s.hit_timeout, s.hit_target = flying[key] or_else -1, n(f, 5)
				s.seen = true
				if f[7] == "true" do s.guessed = true
			}
		}
	}
	return log, true
}

shot_verdict :: proc(s: Shot) -> string {
	switch {
	case !s.seen && !s.ruled:   return ""
	case s.seen && !s.on_server: return "seen, never fired on the server"
	case s.seen && s.ruled:     return "agree"
	case s.seen:                return "SEEN, NOT RULED"
	}
	return "ruled, not seen"
}

shots_count :: proc(log: ^Shot_Log) -> (c: Shot_Counts) {
	for s in log.list {
		if s.on_server do c.fired += 1
		if s.seen do c.seen += 1
		if s.ruled do c.ruled += 1
		need := s.server_tick - s.view
		if s.on_server && s.on_client {
			c.need_sum += need
			c.need_count += 1
			c.need_most = max(c.need_most, need)
		}
		switch shot_verdict(s) {
		case "seen, never fired on the server": c.unrun += 1
		case "agree":                           c.agree += 1
		case "ruled, not seen":                 c.ruled_only += 1
		case "SEEN, NOT RULED":
			c.seen_only += 1
			if s.guessed do c.guessed += 1
			if s.ran > 1 do c.burst += 1
			cause, _ := shot_cause(log, s)
			c.causes[cause] += 1
			if cause == .Capped do c.capped += 1
			if cause == .Wrong_Tick do c.wrong += 1
			if s.on_client do c.short += max(need - s.lag, 0)
		}
	}
	return
}

// What the two sides had at the step the client saw a hit seen and not ruled.
Shot_Scene :: struct {
	client, server:           ^Flight,
	seen_at, served:          ^Near_Soldier, // the target, as the client showed it and as the server met it
	server_own, server_seen:  f64, // how near the server's path passes the parts: of its own target, and of the client's
	client_server:            f64, // and the client's path the server's target's
}

shot_cause :: proc(log: ^Shot_Log, s: Shot) -> (cause: Cause, scene: Shot_Scene) {
	need := s.server_tick - s.view
	if s.on_client && need > s.lag && s.lag >= s.cap do return .Capped, scene
	if s.on_client && need != s.lag do return .Wrong_Tick, scene
	for c in s.corpse_hit do if c[0] == s.hit_target do return .Corpse, scene
	// dead on the server after the tick the client showed it at, and by the step it was hit
	// in there: the client shows it alive until word of the death comes
	step_tick := s.server_tick + (s.first_timeout - s.hit_timeout)
	for d in log.deaths[s.hit_target] do if d > s.view && d <= step_tick do return .Corpse, scene
	// a corpse took the server's copy first at that step
	for c in s.corpse_hit do if c[1] == s.hit_timeout do return .Corpse_In_Front, scene
	ok: bool
	if scene.client, ok = &log.flights[{s.key, s.hit_timeout, false}]; !ok do return .Unlogged, scene
	for &n in scene.client.near do if n.target == s.hit_target do scene.seen_at = &n
	if scene.seen_at == nil do return .Unlogged, scene
	if scene.server, ok = &log.flights[{s.key, s.hit_timeout, true}]; !ok do return .Gone, scene
	for &n in scene.server.near do if n.target == s.hit_target do scene.served = &n
	if scene.served == nil do return .Target_Far, scene

	scene.server_own = path_to_parts(scene.server, scene.served)
	scene.server_seen = path_to_parts(scene.server, scene.seen_at)
	scene.client_server = path_to_parts(scene.client, scene.served)
	if scene.server_own <= PART_RADIUS do return .Met, scene
	target, path := scene.server_seen <= PART_RADIUS, scene.client_server <= PART_RADIUS
	switch {
	case target && path: return .Both, scene
	case path:           return .Path, scene
	case target:
		moved := distance(scene.seen_at.pos, scene.served.pos) >= 0.5
		return moved ? .Target_Moved : .Target_Posed, scene
	}
	return .Other, scene
}

// A line on a hit seen and not ruled: its cause, and what the two sides had.
shot_story :: proc(log: ^Shot_Log, s: Shot) -> string {
	cause, sc := shot_cause(log, s)
	if cause == .Gone do return fmt.tprintf("-> %s: the server's ended at step %d (the client's hit is at %d) on: %s", CAUSE_NAMES[cause], s.server_end_timeout, s.hit_timeout, s.server_end)
	if sc.served == nil || sc.seen_at == nil do return fmt.tprintf("-> %s", CAUSE_NAMES[cause])
	pose := sc.seen_at.pose == sc.served.pose ? "same pose" : fmt.tprintf("pose %q here, %q there", sc.seen_at.pose, sc.served.pose)
	return fmt.tprintf("-> %s: target %.1f off (%s), bullet %.1f off; the server's path misses its target's parts by %.1f and the client's by %.1f; the client's path misses the server's by %.1f",
		CAUSE_NAMES[cause], distance(sc.seen_at.pos, sc.served.pos), pose, distance(sc.client.pos, sc.server.pos),
		sc.server_own - PART_RADIUS, sc.server_seen - PART_RADIUS, sc.client_server - PART_RADIUS)
}

// How near a bullet's path this step (a segment) passes the nearest of a soldier's parts.
path_to_parts :: proc(f: ^Flight, n: ^Near_Soldier) -> f64 {
	start, d := f.pos, f.vel
	best := max(f64)
	for p in n.parts {
		dd := d.x * d.x + d.y * d.y
		t := dd > 0 ? clamp(((p.x - start.x) * d.x + (p.y - start.y) * d.y) / dd, 0, 1) : 0
		best = min(best, distance(start + d * t, p))
	}
	return best
}

distance :: proc(a, b: [2]f64) -> f64 {
	d := a - b
	return math.sqrt(d.x * d.x + d.y * d.y)
}

// ---- compare: the shot logs over simulated lines ----

// Every line of COMPARE_LINES, with a few runs of each at once: a server with five bots
// on Arena and a headless client joined to it over the simulated line, both writing their
// shot logs (and what they print) to bin/compare/, then each pair joined as shots does.
// A row a line: the hits the client showed against the ones the server ruled, and why
// the rest were not. Server settings given here go to every server, so one rule can be
// held against another (compare -sv_maxrewind 300).
//
//   odin run build.odin -file -- compare [-runs 3] [-seconds 90]
Line :: struct {
	ping, jitter, loss: int, // ms, ms, percent (net_ping, net_jitter, net_loss)
}

COMPARE_LINES := [?]Line{{0, 0, 0}, {120, 0, 0}, {120, 0, 10}, {120, 60, 0}, {300, 60, 5}}

Compare_Run :: struct {
	server, client:             os.Process,
	server_out, client_out:     ^os.File,
	server_log, client_log:     string,
	started:                    bool,
}

compare :: proc(opts: Options) -> int {
	if !opts.no_build {
		if code := build_all(opts); code != 0 do return code
	}
	dir := join(repo_root, BUILD_DIR, "compare")
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil do return failed("could not create %s: %v", dir, err)
	}
	fmt.printfln("%d runs of %d s a line, Arena, five bots; logs in %s", opts.runs, opts.seconds, dir)
	fmt.printfln("%-12s %-6s %-6s %-6s %-16s %-7s %-6s %-9s %-12s %s", "line", "fired", "seen", "ruled", "seen, not ruled", "at cap", "wrong", "not seen", "never fired", "need (most)")
	port := opts.port + 100
	causes: [len(COMPARE_LINES)][Cause]int
	for line, li in COMPARE_LINES {
		name := fmt.tprintf("%d/%d/%d%%", line.ping, line.jitter, line.loss)
		runs := make([]Compare_Run, opts.runs, context.temp_allocator)
		for &r, i in runs {
			port += 1
			base := join(dir, fmt.tprintf("p%d_j%d_l%d_%d", line.ping, line.jitter, line.loss, i + 1))
			r.server_log = fmt.tprintf("%s.server.log", base)
			r.client_log = fmt.tprintf("%s.client.log", base)
			r.server_out, _ = os.create(fmt.tprintf("%s.server.out", base))
			r.client_out, _ = os.create(fmt.tprintf("%s.client.out", base))
			_ = os.remove(r.server_log)
			_ = os.remove(r.client_log)
			p := fmt.tprint(port)
			err: os.Error
			r.server, err = os.process_start({command = argv({exe("server"), "-sv_base", assets(), "-sv_port", p, "-sv_bots", "5", "-sv_map", "Arena", "-sv_shotlog", r.server_log}, opts.server[:]), stdout = r.server_out, stderr = r.server_out})
			if err != nil {
				fmt.eprintfln("could not start a server: %v", err)
				continue
			}
			r.client, err = os.process_start({command = argv({exe("client"), "-cl_base", assets(), "-cl_join", "127.0.0.1", "-cl_port", p, "-cl_headless",
				"-dbg_seconds", fmt.tprint(opts.seconds), "-net_ping", fmt.tprint(line.ping), "-net_jitter", fmt.tprint(line.jitter), "-net_loss", fmt.tprint(line.loss),
				"-dbg_shotlog", r.client_log}, opts.extra), stdout = r.client_out, stderr = r.client_out})
			if err != nil {
				fmt.eprintfln("could not start a client: %v", err)
				stop(r.server)
				continue
			}
			r.started = true
		}
		total: Shot_Counts
		for &r in runs {
			if !r.started do continue
			state, _ := os.process_wait(r.client, time.Duration(opts.seconds + 60) * time.Second)
			if !state.exited do stop(r.client)
			stop(r.server)
			os.close(r.server_out)
			os.close(r.client_out)
			log, ok := shots_join(r.server_log, r.client_log)
			if !ok do continue
			c := shots_count(&log)
			total.fired += c.fired; total.seen += c.seen; total.ruled += c.ruled
			total.agree += c.agree; total.seen_only += c.seen_only; total.ruled_only += c.ruled_only; total.unrun += c.unrun
			total.capped += c.capped; total.wrong += c.wrong; total.guessed += c.guessed; total.burst += c.burst; total.short += c.short
			total.need_sum += c.need_sum; total.need_count += c.need_count; total.need_most = max(total.need_most, c.need_most)
			for n, cause in c.causes do total.causes[cause] += n
		}
		t := &total
		fmt.printfln("%-12s %-6d %-6d %-6d %-16s %-7d %-6d %-9d %-12d %.1f (%d)", name, t.fired, t.seen, t.ruled, fmt.tprintf("%d (%.0f%%)", t.seen_only, 100 * f64(t.seen_only) / f64(max(t.seen, 1))),
			t.capped, t.wrong, t.ruled_only, t.unrun, f64(t.need_sum) / f64(max(t.need_count, 1)), t.need_most)
		causes[li] = t.causes
	}

	// why the hits seen were not ruled, a line to a row, a cause to a column
	fmt.println()
	fmt.printf("%-12s", "seen, not ruled:")
	for cause in Cause.Capped ..= Cause.Unlogged do fmt.printf(" | %s", CAUSE_NAMES[cause])
	fmt.println()
	for line, li in COMPARE_LINES {
		fmt.printf("%-16s", fmt.tprintf("%d/%d/%d%%", line.ping, line.jitter, line.loss))
		for cause in Cause.Capped ..= Cause.Unlogged do fmt.printf(" | %-*d", len(CAUSE_NAMES[cause]), causes[li][cause])
		fmt.println()
	}
	return 0
}
