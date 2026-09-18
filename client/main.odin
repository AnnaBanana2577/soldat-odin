// The client. Reads as the loop it is:
//
//   init
//   while running:
//     sample input
//     tick accumulator:
//       process server messages
//       simulate
//       send to server
//       clear input
//     interpolate
//     draw
//   cleanup
//
// Everything the client is lives in App; nothing else is global.
//
//   client -join IP [-base DIR] [-map NAME] [-name NAME] [-window]
//          [-ping MS] [-jitter MS] [-loss PERCENT] [-bot]
//
// The client always plays on a server: -join names it, and when it cannot be reached
// the client quits. -ping, -jitter and -loss put a simulated bad line between this
// client and the server, for testing. -bot runs without a window, its input from the
// brain in bot.odin, so the server sees a player like any other. The debug options
// are in debug.odin.
package client

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import "../shared/net"
import "../shared/sim"

TICK :: sim.TICK
MAX_FRAME :: 0.25 // a stall never turns into a burst of ticks

App :: struct {
	options:     Options,
	debug:       Debug,
	assets:      Assets,
	meshes:      Map_Meshes,
	conn:        Connection,
	input:       Input,
	bot:         Bot,
	game:        Game,
	sparks:      Sparks,
	audio:       Audio,
	accumulator: f64,
	seconds:     f64, // since the start: the wall clock the art animates on
	last_frame:  time.Tick,
	quit:        bool,
}

Options :: struct {
	port:         u16,
	interp_ticks: int,  // how far behind the newest snapshot the world is shown; 0: by the jitter
	base:     string,
	map_name: string,
	join:     string,
	windowed: bool,
	name:     string,
	bot:      bool,
	dodge:    bool, // a bot that dodges in a fight
	ping, jitter, loss: f64, // the simulated line: round trip ms, extra ms at random, percent lost
}

app: App

main :: proc() {
	init()
	for !should_quit() do game_loop()
	cleanup()
}

init :: proc() {
	app.options, app.debug = parse_options()
	o := &app.options
	if o.join == "" {
		fmt.eprintln("usage: client -join IP [-base DIR] [-map NAME] [-name NAME] [-window] [-ping MS] [-jitter MS] [-loss PERCENT] [-bot]")
		os.exit(2)
	}
	rl.SetTraceLogLevel(.WARNING)
	if !o.bot {
		rl.SetConfigFlags({.VSYNC_HINT})
		rl.InitWindow(1280, 960, "soldat")
		if !o.windowed do rl.ToggleBorderlessWindowed() // borderless fullscreen on the current monitor
		audio_init(&app.audio, o.base)
	}
	if !assets_load(&app.assets, o.base, o.map_name, art = !o.bot) {
		fmt.eprintfln("could not load %s from %s", o.map_name, o.base)
		os.exit(1)
	}
	if !o.bot {
		map_meshes_build(&app.meshes, &app.assets.level, app.assets.map_texture)
		sparks_load(&app.sparks, o.base)
	}

	if !connect(&app.conn, strings.clone_to_cstring(o.join, context.temp_allocator), o.port, o.name) {
		fmt.eprintfln("could not reach %s", o.join)
		os.exit(1)
	}
	net.fake_init(&app.conn.fake, o.ping, o.jitter, o.loss)
	game_init(&app.game, &app.assets.ctx, app.conn.slot, o.interp_ticks)
	if o.bot do bot_init(&app.bot, app.conn.slot, o.dodge)
	debug_init(&app.debug, &app.game)
}

should_quit :: proc() -> bool {
	if app.options.bot do return app.quit || app.conn.lost
	return app.quit || app.conn.lost || rl.WindowShouldClose()
}

game_loop :: proc() {
	dt := frame_seconds()
	if app.options.bot do bot_input(&app.bot, &app.input, app.game.ctx, &app.game.world)
	else do sample_input(&app.input, &app.game.camera, app.debug.hold)
	if app.debug.has_aim do app.input.aim = app.game.camera.pos + app.debug.aim
	app.accumulator = min(app.accumulator + dt * app.game.time_scale, MAX_FRAME)
	for app.accumulator >= TICK {
		process_server_messages(&app.game, &app.conn)
		simulate(&app.game, &app.input)
		if !app.options.bot {
			for e in sim.events_slice(&app.game.events) do sparks_event(&app.sparks, e, &app.game.world.soldiers)
			sparks_update(&app.sparks, &app.assets.level)
			audio_tick(&app.audio, &app.game)
		}
		send_to_server(&app.game, &app.conn)
		clear_input(&app.input)
		app.accumulator -= TICK
	}
	app.seconds += dt
	if app.options.bot {
		time.sleep(time.Duration((TICK - app.accumulator) * 1e9)) // nothing to draw: sleep until the next tick
	} else {
		alpha := f32(app.accumulator / TICK)
		m := rl.GetMousePosition()
		cursor := sim.Vec2{m.x, m.y}
		if app.debug.has_aim do cursor = screen_center() + app.debug.aim * pixels_per_unit(&app.game.camera)
		interpolate(&app.game, alpha, dt, cursor)
		draw(&app.game, &app.assets, &app.meshes, &app.sparks, alpha, app.seconds)
	}
	debug_frame(&app.debug, dt)
}

// The wall clock between frames, from our own timer: the sim runs on it, so it must
// be the real interval, not a smoothed one.
frame_seconds :: proc() -> f64 {
	now := time.tick_now()
	if app.last_frame == {} do app.last_frame = now
	dt := time.duration_seconds(time.tick_diff(app.last_frame, now))
	app.last_frame = now
	return dt
}

cleanup :: proc() {
	disconnect(&app.conn)
	game_destroy(&app.game)
	if !app.options.bot {
		sparks_unload(&app.sparks)
		map_meshes_unload(&app.meshes)
	}
	assets_unload(&app.assets)
	if !app.options.bot {
		audio_destroy(&app.audio)
		rl.CloseWindow()
	}
}

parse_options :: proc() -> (o: Options, d: Debug) {
	o.base = "../opensoldat-base/shared"
	o.map_name = "ctf_Ash"
	o.name = "Major"
	o.port = net.DEFAULT_PORT
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-base":   o.base = next; i += 1
		case "-map":    o.map_name = next; i += 1
		case "-join":   o.join = next; i += 1
		case "-port":   o.port = u16(strconv.parse_int(next) or_else net.DEFAULT_PORT); i += 1
		case "-interp-ticks": o.interp_ticks = strconv.parse_int(next) or_else 0; i += 1
		case "-window": o.windowed = true
		case "-name":   o.name = next; i += 1
		case "-bot":    o.bot = true
		case "-dodge":  o.dodge = true
		case "-ping":   o.ping, _ = strconv.parse_f64(next); i += 1
		case "-jitter": o.jitter, _ = strconv.parse_f64(next); i += 1
		case "-loss":   o.loss, _ = strconv.parse_f64(next); i += 1
		case:
			if debug_option(&d, args[i], next) do i += 1
		}
	}
	if o.bot && o.name == "Major" do o.name = "Bot"
	return
}
