// The client. Reads as what it is: each subsystem opened, the loop, each closed.
//
//   connection   the link to the server (connection/)
//   game         the world: snapshots, my prediction, everyone else shown late (game/)
//   input        the keys and mouse, or the bot's brain (input/)
//   render       the window's picture: camera, map, soldiers, sparks (render/)
//   audio        the sounds (audio/)
//
// Each tick: the server's news in, the world simulated, the sparks and sounds of it,
// my commands out. Each frame: the camera follows me and the world is drawn between
// the last two ticks. Everything the client is lives in App; nothing else is global.
//
//   client -join IP [-port N] [-base DIR] [-name NAME] [-window] [-interp-ticks N]
//          [-ping MS] [-jitter MS] [-loss PERCENT] [-bot [-dodge]]
//
// The client plays the map the server names. -ping, -jitter and -loss put a simulated
// bad line between this client and the server, for testing. -bot runs without a
// window, its input from the brain in input/bot.odin, so the server sees a player
// like any other; -dodge makes it change direction and jet at random in a fight.
// -interp-ticks fixes how far behind the newest snapshot the world is shown (by
// default it follows the jitter). The debug options are in debug.odin.
package client

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import rl "vendor:raylib"
import "audio"
import "connection"
import "game"
import "input"
import "render"
import "../shared/net"
import "../shared/sim"

TICK :: sim.TICK
MAX_FRAME :: 0.25 // a stall never turns into a burst of ticks

App :: struct {
	options:     Options,
	debug:       Debug,
	conn:        connection.Connection,
	game:        game.Game,
	bot:         input.Bot, // before `input`: a field named after a package hides it from the fields after
	input:       input.Input,
	camera:      render.Camera,
	render:      render.Render,
	audio:       audio.Audio,
	accumulator: f64,
	seconds:     f64, // since the start: the wall clock the art animates on
	last_frame:  time.Tick,
	quit:        bool,
}

Options :: struct {
	base:         string,
	join:         string,
	port:         u16,
	name:         string,
	windowed:     bool,
	bot:          bool,
	dodge:        bool, // a bot that dodges in a fight
	interp_ticks: int,  // how far behind the newest snapshot the world is shown; 0: by the jitter
	ping, jitter, loss: f64, // the simulated line: round trip ms, extra ms at random, percent lost
}

app: App

main :: proc() {
	app.options, app.debug = parse_options()
	o := &app.options
	if o.join == "" {
		fmt.eprintln("usage: client -join IP [-port N] [-base DIR] [-name NAME] [-window] [-interp-ticks N] [-ping MS] [-jitter MS] [-loss PERCENT] [-bot [-dodge]]")
		os.exit(2)
	}
	if o.bot {
		run_bot()
		return
	}

	rl.SetTraceLogLevel(.WARNING)
	open_window(o.windowed)
	open_connection()
	if !game.init(&app.game, o.base, app.conn.map_name, app.conn.slot, o.interp_ticks) do fail("could not load %s from %s", app.conn.map_name, o.base)
	render.init(&app.render, o.base, &app.game.level)
	audio.init(&app.audio, o.base)
	app.camera.zoom = 1
	debug_init(&app.debug, &app.game, &app.camera)

	for !rl.WindowShouldClose() && !app.conn.lost && !app.quit {
		dt := frame_seconds()
		sample_input()

		ticks := ticks_owed(dt)
		for _ in 0 ..< ticks {
			game.receive(&app.game, &app.conn)
			game.simulate(&app.game, &app.input)
			render.tick(&app.render, &app.game)
			audio.tick(&app.audio, &app.game, app.camera.pos)
			game.send(&app.game, &app.conn)
			input.clear(&app.input)
		}

		alpha := f32(app.accumulator / TICK) // how far into the next tick this frame is
		render.camera_follow(&app.camera, game.drawn_pos(&app.game, int(app.game.me), alpha), cursor(), dt)
		render.draw(&app.render, &app.game, &app.camera, alpha, app.seconds, app.debug.wireframe)
		debug_frame(&app.debug, dt)
	}

	audio.destroy(&app.audio)
	render.destroy(&app.render)
	game.destroy(&app.game)
	connection.close(&app.conn)
	rl.CloseWindow()
}

// A bot: the same client without a window, a picture or sound. Its brain plays, and
// between ticks it sleeps, having nothing to draw.
run_bot :: proc() {
	o := &app.options
	open_connection()
	if !game.init(&app.game, o.base, app.conn.map_name, app.conn.slot, o.interp_ticks) do fail("could not load %s from %s", app.conn.map_name, o.base)
	input.bot_init(&app.bot, app.conn.slot, o.dodge)
	debug_init(&app.debug, &app.game, &app.camera)

	for !app.conn.lost && !app.quit {
		dt := frame_seconds()
		input.bot_sample(&app.bot, &app.input, &app.game.ctx, &app.game.world)

		ticks := ticks_owed(dt)
		for _ in 0 ..< ticks {
			game.receive(&app.game, &app.conn)
			game.simulate(&app.game, &app.input)
			game.send(&app.game, &app.conn)
			input.clear(&app.input)
		}

		time.sleep(time.Duration((TICK - app.accumulator) * 1e9))
		debug_frame(&app.debug, dt)
	}

	game.destroy(&app.game)
	connection.close(&app.conn)
}

// The server, and the simulated bad line if one was asked for.
open_connection :: proc() {
	o := &app.options
	if !connection.open(&app.conn, o.join, o.port, o.name) do fail("could not reach %s", o.join)
	connection.simulate_line(&app.conn, o.ping, o.jitter, o.loss)
}

// How many ticks this frame owes: its time goes in at the pace the server steers my
// clock to (game.time_scale), a whole tick comes out per tick, and the rest waits for
// the next frame. A stall never turns into a burst: at most MAX_FRAME is owed.
ticks_owed :: proc(dt: f64) -> int {
	app.seconds += dt
	app.accumulator = min(app.accumulator + dt * app.game.time_scale, MAX_FRAME)
	n := int(app.accumulator / TICK)
	app.accumulator -= f64(n) * TICK
	return n
}

// This frame's keys and mouse, the cursor turned into a place in the world.
sample_input :: proc() {
	input.sample(&app.input, render.screen_to_world(&app.camera, cursor()), app.debug.hold)
	if app.debug.has_aim do app.input.aim = app.camera.pos + app.debug.aim
}

// The mouse on the screen, or where a debug option holds it.
cursor :: proc() -> sim.Vec2 {
	if app.debug.has_aim do return render.screen_center() + app.debug.aim * render.pixels_per_unit(&app.camera)
	m := rl.GetMousePosition()
	return {m.x, m.y}
}

open_window :: proc(windowed: bool) {
	rl.SetConfigFlags({.VSYNC_HINT})
	rl.InitWindow(1280, 960, "soldat")
	if !windowed do rl.ToggleBorderlessWindowed() // borderless fullscreen on the current monitor
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
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

parse_options :: proc() -> (o: Options, d: Debug) {
	o.base = "../opensoldat-base/shared"
	o.name = "Major"
	o.port = net.DEFAULT_PORT
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-base":   o.base = next; i += 1
		case "-join":   o.join = next; i += 1
		case "-port":   o.port = u16(strconv.parse_int(next) or_else net.DEFAULT_PORT); i += 1
		case "-name":   o.name = next; i += 1
		case "-window": o.windowed = true
		case "-bot":    o.bot = true
		case "-dodge":  o.dodge = true
		case "-interp-ticks": o.interp_ticks = strconv.parse_int(next) or_else 0; i += 1
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
