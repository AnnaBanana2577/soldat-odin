// The build and run tasks, in Odin so there is one of them and it works the same on
// every platform. A single-file package: it builds on its own.
//
//   odin run build.odin -file -- check          type-check every package
//   odin run build.odin -file -- build          compile the client and the server
//   odin run build.odin -file -- test           run the package tests
//   odin run build.odin -file -- dev            build, then a server with a client joined (-sv_bots N for bots)
//   odin run build.odin -file -- server         build, then the server alone
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

BUILD_DIR :: "build"
ASSETS_DIR :: "assets"

Target :: struct {
	src, out: string,
}

TARGETS := [?]Target{{"client", "client"}, {"server", "server"}}
LIBRARIES := [?]string{"shared/sim", "shared/net", "shared/timer", "shared/cvar", "shared/pms", "client/editor"} // checked and tested, never built alone

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

clean :: proc() -> int {
	if err := os.remove_all(BUILD_DIR); err != nil {
		fmt.eprintfln("could not remove %s: %v", BUILD_DIR, err)
		return 1
	}
	return 0
}

// ---- helpers ----

DEBUG_FLAGS   := [?]string{"-debug", "-vet-unused", "-vet-shadowing"}
RELEASE_FLAGS := [?]string{"-o:speed", "-vet-unused", "-vet-shadowing"}

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
