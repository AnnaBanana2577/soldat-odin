// The build and run tasks, in Odin so there is one of them and it works the same on
// every platform. A single-file package: it builds on its own.
//
//   odin run build.odin -file -- check          type-check every package
//   odin run build.odin -file -- build          compile the client and the server
//   odin run build.odin -file -- test           run the package tests
//   odin run build.odin -file -- dev            build, then a server with a client joined (-bots N adds bots)
//   odin run build.odin -file -- server         build, then the server alone
//   odin run build.odin -file -- clean
//
// Options: -release, -no-build, -base DIR, -map NAME, -port N, -bots N. Anything after
// the options goes to the client being run, and to the bots (dev -bots 2 -- -ping 120).
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

BUILD_DIR :: "build"

Target :: struct {
	src, out: string,
}

TARGETS := [?]Target{{"client", "client"}, {"server", "server"}}
LIBRARIES := [?]string{"shared/sim", "shared/net"} // checked and tested, never built alone

Options :: struct {
	release:  bool,
	no_build: bool,
	base:     string,
	map_name: string,
	port:     int,
	bots:     int, // headless bot clients dev starts beside the player
	extra:    []string, // forwarded to the program
}

main :: proc() {
	opts := Options{base = "../opensoldat-base/shared", map_name = "ctf_Ash", port = 23073}
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
		case "-base":     opts.base = value; i += 1
		case "-map":      opts.map_name = value; i += 1
		case "-port":     opts.port = strconv.parse_int(value) or_else opts.port; i += 1
		case "-bots":     opts.bots = strconv.parse_int(value) or_else 0; i += 1
		case "--":        opts.extra = args[i + 1:]; i = len(args)
		case:
			fmt.eprintfln("unknown option %s", args[i])
			os.exit(2)
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
	return run(argv({exe("server"), "-base", opts.base, "-map", opts.map_name, "-port", fmt.tprint(opts.port)}, opts.extra))
}

// A server with a client joined to it, and the bots asked for, on the same line as the
// client; everything stops when the client exits.
dev :: proc(opts: Options) -> int {
	if !opts.no_build {
		if code := build_all(opts); code != 0 do return code
	}
	server, err := spawn({exe("server"), "-base", opts.base, "-map", opts.map_name, "-port", fmt.tprint(opts.port)})
	if err != nil {
		fmt.eprintfln("could not start the server: %v", err)
		return 1
	}
	defer stop(server)
	for i in 0 ..< opts.bots {
		bot, bot_err := spawn(argv({exe("client"), "-bot", "-join", "127.0.0.1", "-name", fmt.tprintf("Bot%d", i + 1), "-base", opts.base, "-map", opts.map_name}, opts.extra))
		if bot_err != nil {
			fmt.eprintfln("could not start a bot: %v", bot_err)
			return 1
		}
		defer stop(bot)
	}
	return run(argv({exe("client"), "-join", "127.0.0.1", "-base", opts.base, "-map", opts.map_name}, opts.extra))
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
