package client

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import "../shared/sim"

// Everything that exists for checking the game rather than playing it, in one place
// so it never leaks into game code:
//
//   -wire             the polygons as lines over the art
//   -zoom F           the view scale, 1 the original, smaller closer
//   -hold a,b,c       buttons held the whole run (left right jump crouch jet fire throw drop reload change prone suicide)
//   -aim X,Y          the cursor held at this offset from our soldier
//   -seconds N        quits after N seconds with a line of counts
//   -screenshot FILE  writes the frame then too; alone it implies -seconds 2
Debug :: struct {
	wireframe:  bool,
	zoom:       f32,
	hold:       sim.Buttons,
	aim:        sim.Vec2,
	has_aim:    bool,
	screenshot: string,
	seconds:    f64,
	elapsed:    f64, // seconds since the start, from our own clock
	frames:     int,
	frame_time: f64,
	done:       bool,
}

// Consumes a debug option; returns whether it took `value` as well.
debug_option :: proc(d: ^Debug, name, value: string) -> (took_value: bool) {
	switch name {
	case "-wire":
		d.wireframe = true
	case "-zoom":
		d.zoom, _ = strconv.parse_f32(value)
		return true
	case "-hold":
		for button in strings.split(value, ",", context.temp_allocator) {
			switch button {
			case "left":   d.hold += {.Left}
			case "right":  d.hold += {.Right}
			case "jump":   d.hold += {.Jump}
			case "crouch": d.hold += {.Crouch}
			case "jet":    d.hold += {.Jet}
			case "fire":   d.hold += {.Fire}
			case "throw":  d.hold += {.Throw}
			case "drop":   d.hold += {.Drop}
			case "reload": d.hold += {.Reload}
			case "change": d.hold += {.Change}
			case "prone":  d.hold += {.Prone}
			case "suicide": d.hold += {.Suicide}
			}
		}
		return true
	case "-aim":
		parts := strings.split(value, ",", context.temp_allocator)
		if len(parts) == 2 {
			d.aim.x, _ = strconv.parse_f32(parts[0])
			d.aim.y, _ = strconv.parse_f32(parts[1])
			d.has_aim = true
		}
		return true
	case "-screenshot":
		d.screenshot = value
		return true
	case "-seconds":
		d.seconds, _ = strconv.parse_f64(value)
		return true
	}
	return false
}

debug_init :: proc(d: ^Debug, g: ^Game) {
	if d.zoom > 0 do g.camera.zoom = d.zoom
	if d.screenshot != "" do d.has_aim = true // a capture never follows the real mouse
	if d.screenshot != "" && d.seconds == 0 do d.seconds = 2
	fmt.printfln("map %s: %d polys, %d props", g.ctx.level.name, len(g.ctx.level.polys), len(g.ctx.level.props))
}

// After each frame: the counts and the capture when the run is up, with the mean frame
// time of the second before. Our own clock throughout: raylib's runs fast on some
// machines.
debug_frame :: proc(d: ^Debug, dt: f64) {
	d.elapsed += dt
	if d.elapsed > 1 {
		d.frames += 1
		d.frame_time += dt
	}
	if d.seconds > 0 && d.elapsed > d.seconds && !d.done {
		d.done = true
		things := 0
		for t in app.game.world.things do if t.style != .None do things += 1
		me := &app.game.world.soldiers[app.game.me]
		fmt.printfln("frame time over the second before: %.1f ms; tick %d, %d shots fired, %d hits seen, %d hits ruled, %d things, %d kills, %d deaths, at %.0f,%.0f", d.frame_time / f64(max(d.frames, 1)) * 1000, app.game.world.tick, app.game.shots_fired, app.game.hits_predicted, app.game.hits_confirmed, things, me.kills, me.deaths, me.pos.x, me.pos.y)
		if d.screenshot != "" do rl.TakeScreenshot(strings.clone_to_cstring(d.screenshot, context.temp_allocator))
		app.quit = true
	}
}
