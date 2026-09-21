package client

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import "hud"
import "game"
import "render"
import "../shared/sim"

// Everything that exists for checking the game rather than playing it, in one place so
// it never leaks into game code. What it is told comes from the settings under r_ and
// dbg_ (settings.odin):
//
//   r_wire             the polygons as lines over the art
//   r_zoom F           the view scale, 1 the original, smaller closer
//   dbg_hold a,b,c     buttons held the whole run (left right jump crouch jet fire...)
//   dbg_aim X,Y        the cursor held at this offset from our soldier
//   dbg_seconds N      quits after N seconds with a line of counts
//   dbg_screenshot F   writes the frame then too; alone it implies dbg_seconds 2
//   dbg_menu NAME      opens a menu at the start, to capture it: esc, kick, map,
//                      team, weapons or scores
//   dbg_vote V         calls a vote a second in: "kick SLOT REASON" or "map NAME"
Debug :: struct {
	hold:       sim.Buttons,
	aim:        sim.Vec2,
	has_aim:    bool,
	screenshot: string,
	seconds:    f64,
	menu:       string, // dbg_menu: opened half a second in
	vote:       string, // dbg_vote: called a second in
	menu_done, vote_done: bool,
	elapsed:    f64, // seconds since the start, from our own clock
	frames:     int,
	frame_time: f64,
	done:       bool,
}

// What the settings say of it, once they have been read.
debug_init :: proc(d: ^Debug, s: ^Settings, camera: ^render.Camera) {
	d.hold = settings_hold(s)
	d.aim, d.has_aim = settings_aim(s)
	d.screenshot, d.seconds = s.screenshot, f64(s.seconds)
	d.menu, d.vote = s.menu, s.vote
	if s.zoom > 0 do camera.zoom = s.zoom
	if d.screenshot != "" do d.has_aim = true // a capture never follows the real mouse
	if d.screenshot != "" && d.seconds == 0 do d.seconds = 2
}

// After each frame: the counts and the capture when the run is up, with the mean frame
// time of the second before. Our own clock throughout: raylib's runs fast on some
// machines.
debug_frame :: proc(d: ^Debug, dt: f64) {
	d.elapsed += dt
	if d.menu != "" && !d.menu_done && d.elapsed > 0.5 {
		d.menu_done = true
		hud.open_menu(&app.hud, &app.game, d.menu)
	}
	if d.vote != "" && !d.vote_done && d.elapsed > 1 {
		d.vote_done = true
		debug_vote(d.vote)
	}
	if d.elapsed > 1 {
		d.frames += 1
		d.frame_time += dt
	}
	if d.seconds > 0 && d.elapsed > d.seconds && !d.done {
		d.done = true
		things := 0
		for t in app.game.world.things do if t.style != .None do things += 1
		me := &app.game.world.soldiers[app.game.me]
		fmt.printfln("frame time over the second before: %.1f ms; tick %d, %d shots fired, %d hits given and %d taken as seen here, %d things, %d kills, %d deaths, health %.0f, at %.0f,%.0f", d.frame_time / f64(max(d.frames, 1)) * 1000, app.game.world.tick, app.game.shots_fired, app.game.hits_given, app.game.hits_taken, things, me.kills, me.deaths, me.health, me.pos.x, me.pos.y)
		fmt.printfln("the others shown %d ticks behind the server, by its measure", app.game.my_lag)
		g := &app.game
		fmt.printfln("the others shown %d ticks behind the newest word of them", app.game.view.behind)
		fmt.printfln("prediction: %.2f units off the server on average, %.2f at worst, over %d updates; %.0f commands waiting there",
			g.error_count > 0 ? g.error_sum / f64(g.error_count) : 0, g.error_worst, g.error_count, g.depth)
		host := app.conn.host
		fmt.printfln("on the wire: %.1f KB/s up, %.1f KB/s down", f64(host.totalSentData) / 1024 / d.elapsed, f64(host.totalReceivedData) / 1024 / d.elapsed)
		if d.screenshot != "" do rl.TakeScreenshot(strings.clone_to_cstring(d.screenshot, context.temp_allocator))
		app.quit = true
	}
}

// dbg_vote as the vote it names: "kick SLOT REASON" or "map NAME". For checking the
// vote without a second person at a keyboard.
@(private = "file")
debug_vote :: proc(line: string) {
	rest := strings.trim_space(line)
	word, _ := strings.split_iterator(&rest, " ")
	switch word {
	case "kick":
		slot, _ := strings.split_iterator(&rest, " ")
		at := 0
		for c in slot do at = at * 10 + int(c - '0')
		game.call_kick(&app.game, u8(at), strings.trim_space(rest))
	case "map":
		game.call_map(&app.game, strings.trim_space(rest))
	case:
		fmt.eprintfln("%q is no vote: kick SLOT REASON, or map NAME", line)
	}
}
