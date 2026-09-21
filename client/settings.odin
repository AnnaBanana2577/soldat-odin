package client

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../shared/cvar"
import "../shared/net"
import "../shared/sim"

// What the client can be told, and where each setting lives. They come from config.cfg
// and then from the command line, which has the last word:
//
//   client -cl_join 127.0.0.1 -cl_name Brandon -snd_volume 0.3
//
// `-cvars` prints the lot with what they are set to. A setting's value here is its
// default. The ones under `dbg_` are for looking at the game rather than playing it,
// and nothing outside debug.odin reads them.
Settings :: struct {
	base:      string,
	join:      string, // the server to play on
	port:      int,
	name:      string,
	windowed:  bool, // in a window instead of borderless fullscreen
	headless:  bool, // no window, no picture, no sound: a player for the netcode's tests
	volume:    f32,
	// the simulated bad line, for testing: round trip ms, more ms at random, percent lost
	ping, jitter, loss: f32,
	interp_least: int, // ticks the others are shown behind the newest word of them, at least
	clock_target: f32, // commands to keep waiting on the server
	// looking at the game: see debug.odin
	wireframe:  bool,
	zoom:       f32,
	hold:       string, // buttons held the whole run, by comma
	aim:        string, // "x,y": the cursor held at this offset from our soldier
	seconds:    f32,    // quit after this long with a line of counts
	screenshot: string, // and write the frame to this file
	menu:       string, // a menu opened at the start, to capture it
	vote:       string, // a vote called a second in
	config:     string,
	list_cvars: bool,
}

settings_default :: proc() -> Settings {
	return {
		base         = ".",
		name         = "Major",
		port         = int(net.DEFAULT_PORT),
		volume       = 0.12,
		interp_least = 3,
		clock_target = 2,
		zoom         = 1,
	}
}

settings_declare :: proc(c: ^cvar.Set, s: ^Settings) {
	cvar.add(c, "cl_base", &s.base, "where the maps, the art and config.cfg are read from")
	cvar.add(c, "cl_join", &s.join, "the server to play on")
	cvar.add(c, "cl_port", &s.port, "its port")
	cvar.add(c, "cl_name", &s.name, "the name everyone sees")
	cvar.add(c, "cl_window", &s.windowed, "in a window instead of borderless fullscreen")
	cvar.add(c, "cl_headless", &s.headless, "no window, no picture, no sound: a player for the tests")
	cvar.add(c, "snd_volume", &s.volume, "how loud everything is, 0 to 1")
	cvar.add(c, "net_ping", &s.ping, "a simulated line: the round trip in ms")
	cvar.add(c, "net_jitter", &s.jitter, "and up to this many ms more at random")
	cvar.add(c, "net_loss", &s.loss, "and this percent of the packets lost")
	cvar.add(c, "net_interp", &s.interp_least, "ticks the others are shown behind the newest word of them, at least")
	cvar.add(c, "net_clock_target", &s.clock_target, "commands to keep waiting on the server")
	cvar.add(c, "r_wire", &s.wireframe, "the polygons as lines over the art")
	cvar.add(c, "r_zoom", &s.zoom, "the view scale: 1 the original, smaller closer")
	cvar.add(c, "dbg_hold", &s.hold, "buttons held the whole run, by comma (left,right,fire...)")
	cvar.add(c, "dbg_aim", &s.aim, "x,y: the cursor held at this offset from our soldier")
	cvar.add(c, "dbg_seconds", &s.seconds, "quit after this long with a line of counts")
	cvar.add(c, "dbg_screenshot", &s.screenshot, "and write the frame to this file")
	cvar.add(c, "dbg_menu", &s.menu, "a menu opened at the start: esc, kick, map, team, weapons or scores")
	cvar.add(c, "dbg_vote", &s.vote, "a vote called a second in: kick SLOT REASON, or map NAME")
	cvar.add(c, "cl_config", &s.config, "the settings file read at startup")
	cvar.add(c, "cvars", &s.list_cvars, "print every setting and what it is set to, and stop")
}

// The settings file, then the command line over it. What is not a setting is said,
// since it is a misspelling and not something the client silently ignores.
settings_read :: proc(s: ^Settings) {
	c: cvar.Set
	settings_declare(&c, s)
	for arg, i in os.args[1:] {
		if arg == "-cl_base"   && i + 2 < len(os.args) do s.base = os.args[i + 2]
		if arg == "-cl_config" && i + 2 < len(os.args) do s.config = os.args[i + 2]
	}
	if s.config == "" do s.config = strings.concatenate({s.base, "/config.cfg"})
	cvar.load(&c, s.config, {"sv_"}) // the server's settings may share the file
	for arg in cvar.parse(&c, os.args[1:]) do fmt.eprintfln("%s is no setting of the client", arg)
	if s.list_cvars {
		cvar.list(&c)
		os.exit(0)
	}
	if s.headless && s.name == "Major" do s.name = "Headless"
}


// dbg_hold as the buttons it names.
settings_hold :: proc(s: ^Settings) -> (held: sim.Buttons) {
	for name in strings.split(s.hold, ",", context.temp_allocator) {
		switch strings.trim_space(name) {
		case "left":    held += {.Left}
		case "right":   held += {.Right}
		case "jump":    held += {.Jump}
		case "crouch":  held += {.Crouch}
		case "jet":     held += {.Jet}
		case "fire":    held += {.Fire}
		case "throw":   held += {.Throw}
		case "drop":    held += {.Drop}
		case "reload":  held += {.Reload}
		case "change":  held += {.Change}
		case "prone":   held += {.Prone}
		case "suicide": held += {.Suicide}
		case "":
		case:           fmt.eprintfln("%q is no button", name)
		}
	}
	return
}

// dbg_aim as the offset it names, and whether it named one.
settings_aim :: proc(s: ^Settings) -> (aim: sim.Vec2, held: bool) {
	parts := strings.split(s.aim, ",", context.temp_allocator)
	if len(parts) != 2 do return
	x, x_ok := strconv.parse_f32(strings.trim_space(parts[0]))
	y, y_ok := strconv.parse_f32(strings.trim_space(parts[1]))
	if !x_ok || !y_ok do return
	return {x, y}, true
}
