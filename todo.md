# To do

What is left. The readme says how the netcode works (five rules, at the top) and what it
measured; this says what it does not do yet. Checked against the code on 2026-09-20.

## Netcode

- Another's bullet on my screen dies where my own world finds the collision, not where
  the server ruled it. My own end where the server says (net.End); telling everyone's
  the same way is what is left of the disagreement over hits taken (22 of 24 on a 120 ms
  line with 5% loss).
- The server rewinds to whole ticks, but a client shows the others between two of them,
  so what it aimed at can be half a tick from what the server rules against. Carrying
  the fraction in the Input would close it.
- The knockback of a hit arrives with the server's word on my soldier, so it lands half
  a round trip after the bullet is seen to. Soldat holds the local shove to the tick the
  server will rule it on instead; worth trying if it feels late.
- A burst of commands runs in one tick on the server, but the bullets those commands
  fire are stepped once for that tick, where the client stepped each of them as its own
  tick. A shot fired during a burst therefore trails its client's copy slightly.
- The Update sends floats whole, and the receiver's own soldier whole every tick: 30
  KB/s down with six soldiers in view. Quantising positions and velocities, and sending
  only what changed since the last update the client acknowledged, is most of a halving.
  Upward it is 3 KB/s on a clean line and 8 at 120 ms, where every unrun command repeats
  in every packet.
- The server relays every bullet of a fast weapon (and six of a shotgun) to the others.
  Soldat sends none for the minigun and makes them on every machine from the Fire key,
  which would not survive the rewind; a seed per pull of the trigger would cover the
  shotgun.
- A third party sees a bullet fast-forwarded by its own lag too, which is right for
  bullets aimed at it and a little early for bullets aimed at others. Cosmetic.
- sv_maxrewind (300 ms) and net_interp (3 ticks) are settings now, but their defaults,
  and the view clock's hysteresis, are still guesses from a simulated line. Try them
  over a real internet line and with a full server.
- The client predicts its own soldier but not the things: a pickup and a thrown gun
  still wait a round trip (see Known issues). With the sim already running here, both
  could be predicted and taken back on the server's word.

## Game

- Game modes. There are none: a round scores captures and ends at the score or time
  limit. Deathmatch, Team Deathmatch, Pointmatch, Rambo, Hold the Flag and Infiltration
  are all missing, and with them Charlie and Delta, spectators, and the maps' own
  families (dm_, ctf_, inf_, htf_).
- Bots cannot navigate: the brain (shared/sim/bot.odin) runs at the nearest enemy, jets
  when it is above and jumps when stuck. The maps' waypoints are parsed and thrown away
  (shared/sim/level.odin); the original's waypoint AI would use them, and then bots
  could carry a flag.
- Lobby and console: no console, no commands, no map voting, no muting, no teams beyond
  Alpha and Bravo. A setting can only be given at startup (config.cfg or the command
  line), not changed while playing.
- Keys are hardwired (client/input/input.odin), and so are the player's colours; the
  roster carries names only. Both belong in the settings and the roster.
- HUD gaps: the weapon stats page (F2), the minimap, the name of the player under the
  cursor, the bonus's name and time, the sniper line, and the crosshair growing with the
  bink. The scoreboard shows the map's name where a server's would go, and the next
  map's name is not known until it loads.
- The weapons menu offers every weapon; a server's list of allowed ones is not in.
- Sounds missing: the corpse's thud, shell casings, the antics. Shell casings are not
  drawn either.
- The sim's own gaps, each marked TODO where it belongs: the stationary gun's burst,
  heat and overheat (stat_gun.odin); the antics on the body animation (antics.odin); the
  parachute hung from the head of the pose (parachute.odin); a thrown knife that lands
  becoming a knife to pick up (dropped_gun.odin); corpses as targets for bullets
  (bullet_collision.odin); the flag carrier check on hurting polygons
  (soldier_collision.odin).

## Tests and tools

- The wire and the settings have tests (shared/net, shared/cvar). The sim has none: the
  same world from the same seed, a bullet flown on alone landing where one flown with
  the rest does, a soldier stepped on the same commands on two worlds ending in the same
  place.
- The headless client's summary against the server's leave line is read by eye. A script
  that runs the three lines (clean, 120 ms, 250 ms) and fails under a threshold would
  make it a regression test, prediction error included.
- The trace comparer from the Love port, to hold the sim against OpenSoldat's.

## Shipping

- Release builds and packaging: the client, the server and assets/ (124 MB) as something
  a player can download and run.
- It has only ever run on this Windows machine. Nothing is known about Linux or macOS,
  and the things' physics relies on both ends computing the same floats, so mixing
  platforms is untested.
- A dedicated server wants a config it can be given at a path, a log, and something that
  keeps it running.

## Known issues

- A pickup waits for the server, so it takes a round trip. By design, as in Soldat.
- A thrown gun appears a round trip after the throw, for the same reason.
- A gun dropped at death does not carry the body's velocity, where Soldat's does.
  Deliberate: with it the gun flew off whenever a soldier died moving.
- A client goes on playing for half a round trip after the server has killed it: it
  keeps firing on its own screen, and counts hits on itself that the server never rules.
  The server runs none of those commands, so nothing of it reaches anyone else.
- A corpse was twice seen hanging under a ceiling on ctf_Ash. Not reproduced.
- A test window takes the keyboard's focus when it opens, so keys typed elsewhere while
  it runs reach the game (a scripted run once picked a weapon from the menu this way).

## The branches

- `main`: the line of work. The server runs every soldier and the client predicts its
  own (client-side prediction, interpolation, lag compensation).
- `netcode`: the same game with Soldat's model instead, a client owning its own
  movement and the server refereeing. Kept to compare the feel of the two on one line.

The tries before those are gone: a server that stepped a player whose commands had not
arrived (which is what made this model feel wrong the first time), a draft with a shadow
world and a fast-forward that never moved the bullet, and OpenSoldat's netcode copied
message for message. GitHub still holds them, and every branch there is stale.
