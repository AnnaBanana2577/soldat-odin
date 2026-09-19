# To do

What is left, on the `netcode` branch. The readme says how the netcode works (five
rules, at the top) and what it measured; this says what it does not do yet.

## Netcode

- End a bullet everywhere when the server rules that it hit. A client's copy of
  another's bullet dies when the client's own world finds the collision, which agrees
  with the server nine times in ten on a bad line; the tenth flies through someone it
  was ruled to hit, or stops on someone it missed. The bullets are numbered already
  (Fired.seq): a line in the Update naming shooter, number and target would do it, and
  put the blood in the right place.
- A shot that arrives in its second or third packet (the first was lost) is spawned a
  tick or two late and flies that far behind its shooter's copy. It could carry its
  age and be flown on, as the others' bullets are on a client.
- Fast weapons send every bullet, and a shotgun six. Fine on the wire (a shot is 21
  bytes); Soldat sends none for the minigun and makes them on every machine from the
  Fire key, which would not survive the rewind.
- The Update sends floats whole. Quantised positions and velocities, and leaving out
  a weapon that has not changed, would halve the 19.5 KB/s down measured with seven
  soldiers in view. Only worth it for full servers.
- Movement is checked for speed only. A client can still fly (the jets are its to say)
  and walk through walls. Checking a reported position against the map, and the jets
  against the keys, are the next two checks if cheating shows up.
- The Correction has not been seen in real play. Check it against jets, blasts and
  respawns on a bad line, so an honest client is never put back.
- The cap on the rewind (300 ms) and the view's constants (when the clock waits, how
  fast a correction blends out) are first guesses. Try them over a real internet line
  and with a full server.
- A third party sees a bullet fast-forwarded by its own lag too, which is right for
  bullets aimed at it and a little early for bullets aimed at others. Cosmetic.

## Game

- HUD, still missing: the scoreboard (F1), the minimap, the name of the player under
  the cursor, the bonus's name and time, the sniper line, the bink showing in the
  crosshair's size (`client/hud/`).
- The weapons menu offers every weapon; the server's list of allowed weapons, and the
  weapon stats shown beside a modded weapon, are not in.
- Lobby: teams and the team menu, chat, the console, map change and the round's end.
  The roster carries names only; the player's colours would go in it. These are all
  news (reliable).
- Console and settings: the binds (`client/input/input.odin`), the sound volume (a
  constant in `client/audio/audio.odin`), the player's name and colours.
- Sounds still missing: the corpse's thud, shell casings, the antics.
- Shell casings and the other sparks that are only for show.
- The stationary gun's burst, heat and overheat (`shared/sim/stat_gun.odin`).
- The antics on the body animation (`shared/sim/antics.odin`).
- The parachute hung from the head of the pose (`shared/sim/parachute.odin`).
- A thrown knife that lands becomes a knife to pick up
  (`shared/sim/dropped_gun.odin`, `dropped_gun_land_knife`).
- Corpses as targets for bullets (`shared/sim/bullet_collision.odin`).
- The flag carrier check in the soldier's collision
  (`shared/sim/soldier_collision.odin`).

## Tests and tools

- The wire format has tests (`shared/net/protocol_test.odin`). The sim has none: the
  same world from the same seed, a bullet flown on alone landing where one flown with
  the rest does, the server's shot checks.
- The headless client's summary against the server's leave line is read by eye. A
  script that runs the three lines (clean, 120 ms, 250 ms) and fails under a
  threshold would make it a regression test.
- The trace comparer from the Love port, to hold the sim against OpenSoldat's.

## Known issues

- A corpse was twice seen hanging under a ceiling on ctf_Ash. Not reproduced.
- A pickup waits for the server, so it takes a round trip. By design, as in Soldat.
- A thrown gun appears a round trip after the throw, for the same reason.
- A gun dropped at death does not carry the body's velocity, where Soldat's does.
  Deliberate: with it the gun flew off whenever a soldier died moving.
- A client keeps shooting for half a round trip after the server has killed it; those
  shots show locally and are refused. It also counts hits on itself in that time
  that the server never rules.

## The other branches

Kept for reference; this branch replaces them.

- `main`: the server runs everything; clients send commands, predict by replaying
  them on the newest snapshot, and show the rest interpolated. Every lag in that chain
  (the command queue, the interpolation buffer) adds to how far behind a victim sees
  the bullet that hits it, and snapshot bullets cannot be flown forward to make up
  for it.
- `soldat-net`: this model's first draft. It kept a shadow world to send soldiers only
  when the clients' guess had drifted, and its fast-forward never moved the bullet.
- `opensoldat-net`: OpenSoldat's netcode, message for message.
- `server-auth`: the first version of `main`.
