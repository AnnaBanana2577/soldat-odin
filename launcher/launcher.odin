// The launcher a player runs: a server of their own and the client joined to it, both
// from the folder the launcher is in, and the server stopped when the client exits. Or,
// told -cl_join, the client alone on someone else's server.
//
//   launcher                                      a game of your own, as config.cfg says
//   launcher -sv_bots 4 -sv_map ctf_Ash           the same, the server told more
//   launcher -cl_join 79.117.176.36 -cl_port 27073    someone else's game
//
// Every -sv_ setting goes to the server as it was given, and everything else to the
// client. The server writes what it says here, in the launcher's own window.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

DEFAULT_PORT :: 23073 // the game's (net.DEFAULT_PORT); the launcher imports nothing of it

main :: proc() {
	dir, dir_err := os.get_executable_directory(context.allocator)
	if dir_err != nil do fail("could not find the folder the launcher is in: %v", dir_err)

	server_args, client_args: [dynamic]string
	port := DEFAULT_PORT
	joining := false
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		value := i + 1 < len(args) && !strings.has_prefix(args[i + 1], "-") ? args[i + 1] : ""
		if !strings.has_prefix(arg, "-sv_") {
			if arg == "-cl_join" do joining = true
			append(&client_args, arg)
			continue
		}
		if arg == "-sv_port" {
			port = strconv.parse_int(value) or_else port
			i += 1
			continue
		}
		append(&server_args, arg)
		if value != "" {
			append(&server_args, value)
			i += 1
		}
	}

	client := executable(dir, "client")
	if joining {
		// someone else's server: the client alone, its settings as they were given
		exit(run(concat({client, "-cl_base", dir}, client_args[:])))
	}

	server, err := os.process_start({
		command = concat({executable(dir, "server"), "-sv_base", dir, "-sv_port", fmt.tprint(port)}, server_args[:]),
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if err != nil do fail("could not start the server: %v", err)
	// the client's own settings come after these, so a -cl_port of theirs has the last word
	code := run(concat({client, "-cl_base", dir, "-cl_join", "127.0.0.1", "-cl_port", fmt.tprint(port)}, client_args[:]))
	_ = os.process_kill(server)
	_, _ = os.process_wait(server)
	exit(code)
}

// A program here, by name, with this platform's suffix.
executable :: proc(dir, name: string) -> string {
	suffix := ODIN_OS == .Windows ? ".exe" : ""
	path, _ := filepath.join({dir, fmt.tprintf("%s%s", name, suffix)}, context.temp_allocator)
	return path
}

concat :: proc(head: []string, tail: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, ..head)
	append(&out, ..tail)
	return out[:]
}

// Runs a program in this window and waits for it: its exit code, or 1 if it would not
// start.
run :: proc(command: []string) -> int {
	process, err := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("could not start %s: %v", command[0], err)
		return 1
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil do return 1
	return state.exit_code
}

// Out, with the client's exit code. When something went wrong the window stays until
// Enter is pressed, so whoever double-clicked the launcher can read why.
exit :: proc(code: int) -> ! {
	if code != 0 {
		fmt.eprintfln("\nthe game stopped with code %d. Press Enter to close.", code)
		buf: [1]u8
		_, _ = os.read(os.stdin, buf[:])
	}
	os.exit(code)
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	exit(1)
}
