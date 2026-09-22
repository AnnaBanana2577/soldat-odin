// The dedicated server. Headless: imports the sim and the net, never raylib.
//
//   init (config.cfg and the command line: settings.odin)
//   while running:
//     for each tick owed (game.odin):
//       next_round     when the last round's scores have stood long enough
//       step_soldiers  every soldier one tick on: the bots played, the players guessed
//       receive        the clients' word over the guesses, and their shots
//       step_world     the things, the bullets, the round; the hits become wounds
//       send           what changed, what was decided, the soldiers and the bullets born
//     sleep until the next tick
//   cleanup
package server

main :: proc() {
	server_init()
	server_run()
	server_destroy()
}
