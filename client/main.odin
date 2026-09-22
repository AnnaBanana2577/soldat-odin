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
import rl "vendor:raylib"

// The settings say which mode to run, and then it is opened, run and closed. The
// headless client is not a mode: it has no window, and a mode is a thing with a frame.
main :: proc() {
	client.settings = settings_default()
	settings_read(&client.settings)
	o := &client.settings
	if o.editor do client.mode = .Editor

	if o.headless {
		if o.join == "" do no_server()
		run_headless()
		return
	}
	if client.mode == .Game && o.join == "" do no_server()

	if !client_init(o) {
		rl.CloseWindow()
		return
	}
	client_run(o)
	client_destroy()
}

@(private = "file")
no_server :: proc() -> ! {
	fmt.eprintln("which server? client -cl_join IP ... (-cvars lists every setting)")
	os.exit(2)
}
