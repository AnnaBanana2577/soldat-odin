# Layout and loops

Where everything lives, and how the client and the server each spend a tick.

```
shared/sim/  the simulation, shared, one file per object: level (the map: loading,
             sectors, collision queries), soldier (movement, soldier_anim, combat,
             antics, soldier_collision), bullet (bullet_collision, explosion), damage
             (the one place health changes), thing (flag, kit, dropped_gun, parachute,
             stat_gun), ragdoll, history (the server's rewind), round, event (a tagged
             union), bot (the brain of the server's bots and of the test client), rand
shared/geom/ Vec2 and the arithmetic the sim shares: the vector procedures, the distances,
             the banker's rounding, on one float path so every world computes the same
shared/cvar/ the settings: a name, a value, a default and a line of help, set from
             config.cfg and the command line
shared/net/  the wire: serialize (one Stream that reads or writes), protocol (Hello,
             Welcome, Map, Roster, Input, Act, Chat, Update, Things, Facts), Fake_Link
shared/timer/  a fine sleep on Windows, for the loops that sleep between ticks
client/      main (each subsystem opened, the loop, each closed), settings (every cl_,
             net_, snd_, r_ and dbg_ setting), debug, and a package
             per subsystem:
  connection/  the link to the server, the simulated bad line
  game/        the world: game (the tick: receive / step / send), predict (my own
               soldier: the replay, the error blending out, the clock), view (the
               others: the words kept of each, the tick they are shown at, the drawing
               between two of them)
  input/       input (the keys and mouse), script (the headless client's)
  render/      render (the world's picture, the map's meshes), camera, textures,
               gostek, bullet_art, things_art, sparks, sprite
  hud/         what is drawn over the world: hud (the bars and counts, the messages,
               the crosshair), kill_feed, weapons_menu, team_menu, scoreboard, chat
  audio/       audio
server/      main (init / server_loop / cleanup), settings (every sv_ setting), game
             (the tick), queue (a client's commands and which of them this tick runs),
             connection
```

The client, client/main.odin:

```
open window, connection, game, render, hud, audio
until the window closes:
  sample input                  the weapons menu first, then the keys and the cursor
  for each tick owed:
    game.tick                   (client/game/game.odin)
      view_advance                everyone else one tick on, as guessed
      receive                     the server's word over the guesses; the others' bullets
      step_mine                   my soldier on this tick's keys
      step_world                  the corpses, the things, every bullet
      send                        my soldier, the tick I show the others at, my shots
    render.tick, hud.tick, audio.tick    the sparks, the kill feed, the sounds of it
  render.camera_follow, render.draw, hud.draw
close audio, hud, render, game, connection, window
```

A headless client (cl_headless) runs the same without the window, the picture and the
sound (run_headless), played by the bots' brain: a player for testing the netcode.

The server's tick, server/game.odin, reads the same way:

```
for each tick owed:
  step_soldiers   every soldier one tick on: the bots played, the players guessed
  receive         the clients' word over the guesses; their shots, checked
  step_world      the corpses, the things, every bullet, the round; the hits become wounds
  send            what changed, what was decided, the soldiers and the bullets born
sleep until the next tick
```
