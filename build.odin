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
//   odin run build.odin -file -- clean
//
// Options: -release and -no-build are this script's. Every other -name value goes to the
// server as it was given, so its settings work here (-sv_map ctf_Ash,Arena -sv_bots 5
// -sv_timelimit 3; server -cvars lists them). Anything after a -- goes to the client
// instead (dev -- -net_ping 120 -cl_window).
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

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
	server:   [dynamic]string, // settings passed to the server as they were given
	extra:    []string,        // and these to the client, after a --
}

main :: proc() {
	opts := Options{port = 23073}
	args := os.args[1:]
	command := "check"
	if len(args) > 0 && !strings.has_prefix(args[0], "-") {
		command = args[0]
		args = args[1:]
	}
	for i := 0; i < len(args); i += 1 {
		value := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-release":  opts.release = true
		case "-no-build": opts.no_build = true
		case "-sv_port":  opts.port = strconv.parse_int(value) or_else opts.port; i += 1
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
