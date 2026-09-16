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
//
// The client always plays on a server: -join names it, and when it cannot be reached
// the client quits. The debug options are in debug.odin.
package client

import "core:fmt"
import "core:os"
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
	game:        Game,
	sparks:      Sparks,
	audio:       Audio,
	accumulator: f64,
	seconds:     f64, // since the start: the wall clock the art animates on
	last_frame:  time.Tick,
	quit:        bool,
}

Options :: struct {
	base:     string,
	map_name: string,
	join:     string,
	windowed: bool,
	name:     string,
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
		fmt.eprintln("usage: client -join IP [-base DIR] [-map NAME] [-name NAME] [-window]")
		os.exit(2)
	}
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.VSYNC_HINT})
	rl.InitWindow(1280, 960, "soldat")
	if !o.windowed do rl.ToggleBorderlessWindowed() // borderless fullscreen on the current monitor
	audio_init(&app.audio, o.base)
	if !assets_load(&app.assets, o.base, o.map_name) {
		fmt.eprintfln("could not load %s from %s", o.map_name, o.base)
		os.exit(1)
	}
	map_meshes_build(&app.meshes, &app.assets.level, app.assets.map_texture)
	sparks_load(&app.sparks, o.base)

	if !connect(&app.conn, strings.clone_to_cstring(o.join, context.temp_allocator), net.DEFAULT_PORT, o.name) {
		fmt.eprintfln("could not reach %s", o.join)
		os.exit(1)
	}
	game_init(&app.game, &app.assets.ctx, app.conn.slot)
	app.game.world.things_relayed = true
	debug_init(&app.debug, &app.game)
}

should_quit :: proc() -> bool {
	return app.quit || app.conn.lost || rl.WindowShouldClose()
}

game_loop :: proc() {
	dt := frame_seconds()
	sample_input(&app.input, &app.game.camera, app.debug.hold)
	if app.debug.has_aim do app.input.aim = app.game.camera.pos + app.debug.aim
	app.accumulator = min(app.accumulator + dt, MAX_FRAME)
	for app.accumulator >= TICK {
		sim.events_clear(&app.game.events)
		process_server_messages(&app.game, &app.conn)
		simulate(&app.game, &app.input)
		for e in sim.events_slice(&app.game.events) do sparks_event(&app.sparks, e, &app.game.world.soldiers)
		sparks_update(&app.sparks, &app.assets.level)
		audio_tick(&app.audio, &app.game)
		send_to_server(&app.game, &app.conn)
		clear_input(&app.input)
		app.accumulator -= TICK
	}
	app.seconds += dt
	alpha := f32(app.accumulator / TICK)
	m := rl.GetMousePosition()
	cursor := sim.Vec2{m.x, m.y}
	if app.debug.has_aim do cursor = screen_center() + app.debug.aim * pixels_per_unit(&app.game.camera)
	interpolate(&app.game, alpha, dt, cursor)
	draw(&app.game, &app.assets, &app.meshes, &app.sparks, alpha, app.seconds)
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
	sparks_unload(&app.sparks)
	map_meshes_unload(&app.meshes)
	assets_unload(&app.assets)
	audio_destroy(&app.audio)
	rl.CloseWindow()
}

parse_options :: proc() -> (o: Options, d: Debug) {
	o.base = "../opensoldat-base/shared"
	o.map_name = "ctf_Ash"
	o.name = "Major"
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-base":   o.base = next; i += 1
		case "-map":    o.map_name = next; i += 1
		case "-join":   o.join = next; i += 1
		case "-window": o.windowed = true
		case "-name":   o.name = next; i += 1
		case:
			if debug_option(&d, args[i], next) do i += 1
		}
	}
	return
}
