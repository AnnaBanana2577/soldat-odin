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
//   client -cl_editor [-cl_map NAME]        the map editor instead of the game (editor/)
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
import "../shared/sim"
import "../shared/timer"

TICK :: sim.TICK
MAX_FRAME :: 0.25 // a stall never turns into a burst of ticks

Client :: struct {
	settings:    Settings,
	debug:       Debug,
	conn:        Connection,
	game:        Game,
	script:      Script, // before `input`: a field named after a package hides it from the fields after
	input:       Input,
	render:      Render,
	audio:       Audio,
	drawn:       [sim.MAX_PLAYERS]sim.Vec2, // where each soldier is drawn this frame
	accumulator: f64,
	seconds:     f64, // since the start: the wall clock the art animates on
	last_frame:  time.Tick,
	quit:        bool,
}

client: Client

// What the renderer is given: the game as it stands, so that it need not know what a
// Game is. The drawn positions are filled only for a frame that draws.
scene_of :: proc() -> Scene {
	return {
		ctx    = &client.game.content.ctx,
		world  = &client.game.world,
		level  = &client.game.content.level,
		events = &client.game.events,
		loads  = client.game.content.loads,
	}
}

drawn_positions :: proc(alpha: f32) -> []sim.Vec2 {
	for i in 0 ..< len(client.drawn) do client.drawn[i] = drawn_pos(&client.game, i, alpha)
	return client.drawn[:]
}

// ---- the game: opened, run and closed ----

client_init :: proc(o: ^Settings) {

	rl.SetTraceLogLevel(.WARNING)
	open_window(o.windowed)
	open_connection()
	if !game_init(&client.game, o.base, client.conn.slot, o.interp_least, o.clock_target) do fail("could not load the game's data from %s", o.base)
	render_init(&client.render, o.base)
	hud_init(&client.game.hud, o.base)
	audio_init(&client.audio, o.base, o.volume)
	client.game.camera.zoom = 1
	debug_init(&client.debug, o, &client.game.camera)
}

client_run :: proc(o: ^Settings) {
	for !rl.WindowShouldClose() && !client.conn.lost && !client.quit {
		dt := frame_seconds()
		sample_input()

		ticks := ticks_owed(dt)
		for _ in 0 ..< ticks {
			game_tick(&client.game, &client.conn, &client.input)
			tick_scene := scene_of()
			render_tick(&client.render, &tick_scene)
			hud_tick(&client.game.hud, &client.game)
			audio_tick(&client.audio, &client.game.content.ctx, &client.game.world, &client.game.events, client.game.me, client.game.camera.pos)
			input_clear(&client.input)
		}

		if client.game.missing != "" do fail("the server plays %s, which is not in %s", client.game.missing, o.base)

		alpha := f32(client.accumulator / TICK) // how far into the next tick this frame is
		camera_follow(&client.game.camera, drawn_pos(&client.game, int(client.game.me), alpha), cursor(), dt)
		rl.BeginDrawing()
		frame := scene_of()
		frame.drawn = drawn_positions(alpha)
		render_draw(&client.render, &frame, &client.game.camera, alpha, client.seconds, client.settings.wireframe)
		hud_draw(&client.game.hud, &client.game, &client.render, &client.game.camera, cursor(), alpha)
		rl.EndDrawing()
		debug_frame(&client.debug, dt)
		free_all(context.temp_allocator) // the frame's scratch: its strings
	}
}

client_destroy :: proc() {
	audio_destroy(&client.audio)
	hud_destroy(&client.game.hud)
	render_destroy(&client.render)
	game_destroy(&client.game)
	connection_close(&client.conn)
	rl.CloseWindow()
}

// The same client without a window, a picture or sound, its input scripted: a player
// for the netcode's tests. Between ticks it sleeps, having nothing to draw.
run_headless :: proc() {
	o := &client.settings
	open_connection()
	if !game_init(&client.game, o.base, client.conn.slot, o.interp_least, o.clock_target) do fail("could not load the game's data from %s", o.base)
	script_init(&client.script, u64(client.conn.slot) + 1, sim.bot_profiles_load(o.base))
	timer.fine_sleep_begin() // this loop sleeps between ticks
	defer timer.fine_sleep_end()
	debug_init(&client.debug, o, &client.game.camera)

	for !client.conn.lost && !client.quit {
		dt := frame_seconds()
		script_sample(&client.script, &client.input, &client.game.content.ctx, &client.game.world, client.game.me)

		ticks := ticks_owed(dt)
		for _ in 0 ..< ticks {
			game_tick(&client.game, &client.conn, &client.input)
			input_clear(&client.input)
		}

		if client.game.missing != "" do fail("the server plays %s, which is not in %s", client.game.missing, o.base)
		time.sleep(time.Duration((TICK - client.accumulator) * 1e9))
		debug_frame(&client.debug, dt)
	}

	game_destroy(&client.game)
	connection_close(&client.conn)
}

// The server, and the simulated bad line if one was asked for.
open_connection :: proc() {
	o := &client.settings
	if !connection_open(&client.conn, o.join, u16(o.port), o.name) do fail("could not reach %s", o.join)
	connection_simulate_line(&client.conn, f64(o.ping), f64(o.jitter), f64(o.loss))
}

// How many ticks this frame owes: its time goes in at the pace that holds my commands
// waiting on the server (time_scale), a whole tick comes out per tick, and the
// rest waits for the next frame. A stall never turns into a burst: at most
// MAX_FRAME is owed.
ticks_owed :: proc(dt: f64) -> int {
	client.seconds += dt
	client.accumulator = min(client.accumulator + dt * client.game.time_scale, MAX_FRAME)
	n := int(client.accumulator / TICK)
	client.accumulator -= f64(n) * TICK
	return n
}

// This frame's keys and mouse, the cursor turned into a place in the world. The HUD has
// them first: a click on a menu is not a shot, and a line typed is not a run.
sample_input :: proc() {
	mouse_taken, keys_taken := hud_input(&client.game.hud, &client.game, cursor())
	if hud_leaving(&client.game.hud) do client.quit = true // Exit to menu, off the escape menu
	input_sample(&client.input, screen_to_world(&client.game.camera, cursor()), client.debug.hold, !mouse_taken, !keys_taken)
	if client.debug.has_aim do client.input.aim = client.game.camera.pos + client.debug.aim
}

// The mouse on the screen, or where a debug option holds it.
cursor :: proc() -> sim.Vec2 {
	if client.debug.has_aim do return screen_center() + client.debug.aim * pixels_per_unit(&client.game.camera)
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
	if client.last_frame == {} do client.last_frame = now
	dt := time.duration_seconds(time.tick_diff(client.last_frame, now))
	client.last_frame = now
	return dt
}

