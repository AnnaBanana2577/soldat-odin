package client

import "core:fmt"
import "core:os"
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
//   dbg_shotlog F      writes a line for every shot I fire and every hit it makes here,
//                      to be joined with the server's sv_shotlog by (slot, shot, cmd)
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
	shot_log:   ^os.File, // dbg_shotlog, or nil
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
	if s.shot_log != "" do d.shot_log = shot_log_open(s.shot_log)
	if d.shot_log != nil do app.game.before_bullets = debug_flights
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
		fmt.printfln("round trip: %d ms measured here, %d ms by the server's last word", app.game.my_ping, app.game.pings[app.game.me])
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

// dbg_shotlog: after each tick, the hits my bullets made here, which are the blood I
// was shown, and the bullets that ended; the shots I fired and what they flew at are
// written before the bullets fly (debug_flights). The server's sv_shotlog has the same shots by
// (slot, shot, cmd) and whether they were ruled to hit; the tick I showed the others at when
// I fired, against the tick the server ran the command in, is the lag the shot should
// have been judged by.
debug_tick :: proc(d: ^Debug) {
	if d.shot_log == nil do return
	g := &app.game
	for e in sim.events_slice(&g.events) {
		#partial switch v in e {
		case sim.Bullet_End:
			if v.owner != g.me do continue
			b := &g.world.bullets[v.id]
			fmt.fprintfln(d.shot_log, "end\t%d\t%d\t%d\t%d\t%d\t%.2f\t%.2f\t%s", g.world.tick, g.view.tick, g.me, v.shot, b.timeout, v.pos.x, v.pos.y, sim.bullet_end_cause(&g.events, v))
		case sim.Hit:
			if v.shooter != g.me || v.target == g.me do continue
			fmt.fprintfln(d.shot_log, "hit\t%d\t%d\t%d\t%d\t%d\t%d\t%v\t%v", g.world.tick, g.view.tick, g.me, v.shot, v.target, v.part, g.view.guessed[v.target], g.world.soldiers[v.target].dead)
		}
	}
}

@(private = "file")
shot_log_open :: proc(path: string) -> ^os.File {
	f, err := os.create(path)
	if err != nil {
		fmt.eprintfln("could not write the shot log %s: %v", path, err)
		return nil
	}
	fmt.fprintln(f, "# fire  tick view slot shot cmd weapon")
	fmt.fprintln(f, "#   tick: my clock, the server's plus my unrun commands; view: the tick I showed")
	fmt.fprintln(f, "#   the others at, which the server should judge the shot at; cmd: the command")
	fmt.fprintln(f, "#   that fired it, which the server's line names too")
	fmt.fprintln(f, "# hit   tick view slot shot target part guessed dead")
	fmt.fprintln(f, "#   part 0 is a blast; guessed: the target was shown guessed on, its newer word")
	fmt.fprintln(f, "#   not having come; dead: it was a corpse already")
	fmt.fprintln(f, "# fly   tick view slot shot timeout x y vx vy")
	fmt.fprintln(f, "#   a bullet about to be met against the soldiers: its path is x,y to x+vx,y+vy")
	fmt.fprintln(f, "# near  tick view slot shot timeout target x y dir stance body frame legs frame protected part1x part1y .. part7x part7y")
	fmt.fprintln(f, "#   a soldier within SHOT_LOG_REACH of that path, as shown here, with the centres of")
	fmt.fprintln(f, "#   its seven hit parts (radius sim.PART_RADIUS)")
	fmt.fprintln(f, "# end   tick view slot shot timeout x y why")
	fmt.fprintln(f, "#   a bullet gone, and what ended it here: soldier, wall, collider, explosion, or")
	fmt.fprintln(f, "#   other (the server's word on where it ended, as a rule)")
	return f
}

SHOT_LOG_REACH :: 60 // a soldier this near a bullet's path is logged with it (the server's too)

// Before the bullets fly: each of mine, and the soldiers near its path as I show them
// (sim.bullet_near), for the shot log. The same lines the server writes of the same
// bullet, at the same timeout, rewound.
@(private = "file")
debug_flights :: proc(g: ^game.Game) {
	f := app.debug.shot_log
	// the shots of this tick's command first, so that every line of a bullet follows its own
	for e in sim.events_slice(&g.events) {
		v, spawned := e.(sim.Bullet_Spawn)
		if !spawned || v.player != g.me do continue
		b := &g.world.bullets[v.id]
		fmt.fprintfln(f, "fire\t%d\t%d\t%d\t%d\t%d\t%v", g.world.tick, g.view.tick, g.me, b.shot_id, b.spawn_cmd, b.weapon)
	}
	near: [sim.MAX_PLAYERS]sim.Bullet_Near
	for &b in g.world.bullets {
		if !b.active || b.owner != g.me do continue
		fmt.fprintfln(f, "fly\t%d\t%d\t%d\t%d\t%d\t%.2f\t%.2f\t%.2f\t%.2f", g.world.tick, g.view.tick, b.owner, b.shot_id, b.timeout, b.pos.x, b.pos.y, b.vel.x, b.vel.y)
		for n in sim.bullet_near(&g.ctx, &g.world, &b, SHOT_LOG_REACH, near[:]) {
			s := n.soldier
			fmt.fprintf(f, "near\t%d\t%d\t%d\t%d\t%d\t%d\t%.2f\t%.2f\t%d\t%v\t%v\t%d\t%v\t%d\t%v", g.world.tick, g.view.tick, b.owner, b.shot_id, b.timeout, n.target,
				s.pos.x, s.pos.y, s.direction, s.stance, s.body.id, s.body.frame, s.legs.id, s.legs.frame, s.cease_fire_counter >= 0)
			for p in n.parts do fmt.fprintf(f, "\t%.2f\t%.2f", p.x, p.y)
			fmt.fprintln(f)
		}
	}
}
