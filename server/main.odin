// The dedicated server. Headless: imports the sim and the net, never raylib.
//
//   init (config.cfg and the command line: settings.odin)
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
import "core:time"
import "../shared/sim"
import "../shared/timer"

TICK :: sim.TICK

Server :: struct {
	settings:    Settings,
	game:        Game,
	host:        Host,
	accumulator: f64,
	last:        time.Tick,
	quit:        bool,
}

server: Server

main :: proc() {
	init()
	for !server.quit do server_loop()
	cleanup()
}

init :: proc() {
	server.settings = settings_default()
	s := &server.settings
	settings_read(s)
	timer.fine_sleep_begin() // the loop sleeps between ticks
	host_open(&server.host, u16(s.port))
	maps := settings_maps(s)
	rules := Rules{
		maps          = maps,
		time_limit    = i32(s.time_limit * 60 * sim.TICK_RATE),
		score_limit   = i32(s.score_limit),
		respawn_time  = i32(s.respawn * sim.TICK_RATE),
		max_grenades  = i32(s.grenades),
		friendly_fire = s.friendly_fire,
		kits_collide  = s.kits_collide,
		max_rewind    = u32(s.max_rewind * sim.TICK_RATE / 1000),
		update_others = u32(max(s.update_others, 1)),
		bots_difficulty = s.bots_difficulty,
		bots_chat     = s.bots_chat,
		vote_percent  = s.vote_percent,
	}
	if !game_init(&server.game, s.base, rules) {
		fmt.eprintfln("could not load %s from %s", maps[0], s.base)
		os.exit(1)
	}
	for _ in 0 ..< s.bots do add_bot(&server.game)
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
	sim.content_destroy(&server.game.content)
	wire_destroy(&server.game.wire)
}

