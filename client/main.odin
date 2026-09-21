// The client. Reads as what it is: each subsystem opened, the loop, each closed.
//
//   connection   the link to the server (connection/)
//   game         the world: my soldier, everyone else as the server tells them (game/)
//   input        the keys and mouse, or a script (input/)
//   render       the world's picture: camera, map, soldiers, sparks (render/)
//   hud          what is drawn over it: the bars, the kill feed, the weapons menu (hud/)
//   audio        the sounds (audio/)
//
// Each tick: the game's tick (the server's news in, my soldier and the world stepped,
// my soldier out), then the sparks and sounds of it. Each frame: the camera follows me
// and the world is drawn between the last two ticks. Everything the client is lives in
// App; nothing else is global.
//
//   client -cl_join IP [-cl_port N] [-cl_name NAME] [-cl_window] [-cl_headless]
//          [-net_ping MS] [-net_jitter MS] [-net_loss PERCENT]
//
// Every setting is a cvar (settings.odin): config.cfg first, the command line over it,
// `-cvars` to see them all. The client plays the maps the server names. net_ping,
// net_jitter and net_loss put a simulated bad line between this client and the server,
// for testing. cl_headless runs without a window, its input played by the bots' brain
// (input/script.odin), and reports what it saw with dbg_seconds. The bots are the
// server's (sv_bots there). What is only for looking at the game is in debug.odin.
package client

import "core:fmt"
import "core:os"
import "core:time"
import rl "vendor:raylib"
import "audio"
import "connection"
import "game"
import "hud"
import "input"
import "render"
import "../shared/sim"
import "../shared/timer"

TICK :: sim.TICK
MAX_FRAME :: 0.25 // a stall never turns into a burst of ticks

App :: struct {
	settings:    Settings,
	debug:       Debug,
	conn:        connection.Connection,
	game:        game.Game,
	script:      input.Script, // before `input`: a field named after a package hides it from the fields after
	input:       input.Input,
	camera:      render.Camera,
	render:      render.Render,
	hud:         hud.Hud,
	audio:       audio.Audio,
	accumulator: f64,
	seconds:     f64, // since the start: the wall clock the art animates on
	last_frame:  time.Tick,
	quit:        bool,
}

app: App

main :: proc() {
	app.settings = settings_default()
	settings_read(&app.settings)
	o := &app.settings
	if o.join == "" {
		fmt.eprintln("which server? client -cl_join IP ... (-cvars lists every setting)")
		os.exit(2)
	}
	if o.headless {
		run_headless()
		return
	}

	rl.SetTraceLogLevel(.WARNING)
	open_window(o.windowed)
	open_connection()
	if !game.init(&app.game, o.base, app.conn.slot, o.interp_least, o.clock_target) do fail("could not load the game's data from %s", o.base)
	render.init(&app.render, o.base)
	hud.init(&app.hud, o.base)
	audio.init(&app.audio, o.base, o.volume)
	app.camera.zoom = 1
	debug_init(&app.debug, o, &app.camera)

	for !rl.WindowShouldClose() && !app.conn.lost && !app.quit {
		dt := frame_seconds()
		sample_input()

		ticks := ticks_owed(dt)
		for _ in 0 ..< ticks {
			game.tick(&app.game, &app.conn, &app.input)
			render.tick(&app.render, &app.game)
			hud.tick(&app.hud, &app.game)
			audio.tick(&app.audio, &app.game, app.camera.pos)
			input.clear(&app.input)
		}

		if app.game.missing != "" do fail("the server plays %s, which is not in %s", app.game.missing, o.base)

		alpha := f32(app.accumulator / TICK) // how far into the next tick this frame is
		render.camera_follow(&app.camera, game.drawn_pos(&app.game, int(app.game.me), alpha), cursor(), dt)
		rl.BeginDrawing()
		render.draw(&app.render, &app.game, &app.camera, alpha, app.seconds, app.settings.wireframe)
		hud.draw(&app.hud, &app.game, &app.render, &app.camera, cursor(), alpha)
		rl.EndDrawing()
		debug_frame(&app.debug, dt)
		free_all(context.temp_allocator) // the frame's scratch: its strings
	}

	audio.destroy(&app.audio)
	hud.destroy(&app.hud)
	render.destroy(&app.render)
	game.destroy(&app.game)
	connection.close(&app.conn)
	rl.CloseWindow()
}

// The same client without a window, a picture or sound, its input scripted: a player
// for the netcode's tests. Between ticks it sleeps, having nothing to draw.
run_headless :: proc() {
	o := &app.settings
	open_connection()
	if !game.init(&app.game, o.base, app.conn.slot, o.interp_least, o.clock_target) do fail("could not load the game's data from %s", o.base)
	input.script_init(&app.script, u64(app.conn.slot) + 1, sim.bot_profiles_load(o.base))
	timer.fine_sleep_begin() // this loop sleeps between ticks
	defer timer.fine_sleep_end()
	debug_init(&app.debug, o, &app.camera)

	for !app.conn.lost && !app.quit {
		dt := frame_seconds()
		input.script_sample(&app.script, &app.input, &app.game.ctx, &app.game.world, app.game.me)

		ticks := ticks_owed(dt)
		for _ in 0 ..< ticks {
			game.tick(&app.game, &app.conn, &app.input)
			input.clear(&app.input)
		}

		if app.game.missing != "" do fail("the server plays %s, which is not in %s", app.game.missing, o.base)
		time.sleep(time.Duration((TICK - app.accumulator) * 1e9))
		debug_frame(&app.debug, dt)
	}

	game.destroy(&app.game)
	connection.close(&app.conn)
}

// The server, and the simulated bad line if one was asked for.
open_connection :: proc() {
	o := &app.settings
	if !connection.open(&app.conn, o.join, u16(o.port), o.name) do fail("could not reach %s", o.join)
	connection.simulate_line(&app.conn, f64(o.ping), f64(o.jitter), f64(o.loss))
}

// How many ticks this frame owes: its time goes in at the pace that holds my commands
// waiting on the server (game.time_scale), a whole tick comes out per tick, and the
// rest waits for the next frame. A stall never turns into a burst: at most
// MAX_FRAME is owed.
ticks_owed :: proc(dt: f64) -> int {
	app.seconds += dt
	app.accumulator = min(app.accumulator + dt * app.game.time_scale, MAX_FRAME)
	n := int(app.accumulator / TICK)
	app.accumulator -= f64(n) * TICK
	return n
}

// This frame's keys and mouse, the cursor turned into a place in the world. The HUD has
// them first: a click on a menu is not a shot, and a line typed is not a run.
sample_input :: proc() {
	mouse_taken, keys_taken := hud.input(&app.hud, &app.game, cursor())
	if hud.leaving(&app.hud) do app.quit = true // Exit to menu, off the escape menu
	input.sample(&app.input, render.screen_to_world(&app.camera, cursor()), app.debug.hold, !mouse_taken, !keys_taken)
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

