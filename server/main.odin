// The dedicated server. Headless: imports the sim and the net, never raylib.
//
//   init
//   while running:
//     for each tick owed (game.odin):
//       next_round     when the last round's scores have stood long enough
//       step_soldiers  every soldier one tick on: the bots played, the players guessed
//       receive        the clients' word over the guesses, and their shots
//       step_world     the things, the bullets, the round; the hits become wounds
//       send           what changed, what was decided, the soldiers and the bullets born
//     sleep until the next tick
//   cleanup
package server

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../shared/sim"
import "../shared/timer"

TICK :: sim.TICK

Server :: struct {
	options:     Options,
	game:        Game,
	host:        Host,
	accumulator: f64,
	last:        time.Tick,
	quit:        bool,
}

Options :: struct {
	base:     string,
	maps:     []string, // -map a,b,c: played in turn
	time_limit_minutes: f64, // 0: the default
	score_limit: int,        // 0: the default
	port:     u16,
	max_rewind_ms: int, // how far back a shot is judged at most (0: not at all, shooters lead)
	bots:     int,  // played by the server itself, from the start
	dodge:    bool, // the bots change direction and jet at random in a fight, as a person does
}

server: Server

main :: proc() {
	init()
	for !server.quit do server_loop()
	cleanup()
}

init :: proc() {
	server.options = parse_options()
	timer.fine_sleep_begin() // the loop sleeps between ticks
	o := &server.options
	host_open(&server.host, o.port)
	rules := Rules{
		maps        = o.maps,
		time_limit  = i32(o.time_limit_minutes * 60 * sim.TICK_RATE),
		score_limit = i32(o.score_limit),
		max_rewind  = u32(o.max_rewind_ms * sim.TICK_RATE / 1000),
	}
	if !game_init(&server.game, o.base, rules) {
		fmt.eprintfln("could not load %s from %s", o.maps[0], o.base)
		os.exit(1)
	}
	for _ in 0 ..< o.bots do add_bot(&server.game, o.dodge)
	server.last = time.tick_now()
}

server_loop :: proc() {
	now := time.tick_now()
	server.accumulator += time.duration_seconds(time.tick_diff(server.last, now))
	server.last = now
	for server.accumulator >= TICK {
		tick(&server.game, &server.host)
		server.accumulator -= TICK
	}
	time.sleep(time.Millisecond)
}

cleanup :: proc() {
	timer.fine_sleep_end()
	host_close(&server.host)
}

// Where the map and its art are read from: SOLDAT_BASE if it is set, and otherwise
// the opensoldat assets beside this checkout. -base overrides both.
default_base :: proc() -> string {
	if set := os.get_env("SOLDAT_BASE", context.allocator); set != "" do return set
	return "assets"
}

parse_options :: proc() -> (o: Options) {
	o.base = default_base()
	o.maps = {"ctf_Ash"}
	o.port = 23073
	o.max_rewind_ms = 300
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-base": o.base = next; i += 1
		case "-map":  o.maps = strings.split(next, ","); i += 1
		case "-time-limit":  o.time_limit_minutes, _ = strconv.parse_f64(next); i += 1
		case "-score-limit": o.score_limit = strconv.parse_int(next) or_else 0; i += 1
		case "-port": o.port = u16(strconv.parse_int(next) or_else 23073); i += 1
		case "-max-rewind": o.max_rewind_ms = strconv.parse_int(next) or_else 300; i += 1
		case "-bots":  o.bots = strconv.parse_int(next) or_else 0; i += 1
		case "-dodge": o.dodge = true
		}
	}
	return
}
