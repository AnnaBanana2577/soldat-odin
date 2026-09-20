# To do

What is left, on the `netcode` branch. The readme says how the netcode works (five
rules, at the top) and what it measured; this says what it does not do yet.

## Netcode

- The server rewinds to whole ticks, but a client shows the others between two of them,
  so what it aimed at can be half a tick from what the server rules against. Carrying
  the fraction in the Input would close it.
- The knockback of a hit arrives with the server's word on my soldier, so it lands half
  a round trip after the bullet is seen to. Soldat holds the local shove to the tick the
  server will rule it on instead; worth trying if it feels late.
- A burst of commands runs in one tick on the server, but the bullets those commands
  fire are stepped once for that tick, where the client stepped each of them as its own
  tick. A shot fired during a burst therefore trails its client's copy slightly.
- The client sends every unrun command in every packet: 10 KB/s up at 120 ms. Sending
  only what changed, or capping the repeat, would cut most of it.
- Another's bullet on my screen still dies where my own world finds the collision. Mine
  end where the server says (net.End); the same could be told for everyone's, which is
  what is left of the disagreement over hits taken.
- Fast weapons send every bullet, and a shotgun six. Fine on the wire (a shot is 21
  bytes); Soldat sends none for the minigun and makes them on every machine from the
  Fire key, which would not survive the rewind.
- The Update sends floats whole, and the receiver's own soldier whole every tick: 30
  KB/s down with six soldiers in view. Quantising positions and velocities, and sending
  only what changed since the last update the client acknowledged, is most of a halving.
- The cap on the rewind (300 ms) and the view's constants (when the clock waits, how
  fast a correction blends out) are first guesses. Try them over a real internet line
  and with a full server.
- A third party sees a bullet fast-forwarded by its own lag too, which is right for
  bullets aimed at it and a little early for bullets aimed at others. Cosmetic.

## Game

- HUD, still missing: the weapon stats page (F2), the minimap, the name of the player under
  the cursor, the bonus's name and time, the sniper line, the bink showing in the
  crosshair's size (`client/hud/`).
- The weapons menu offers every weapon; the server's list of allowed weapons, and the
  weapon stats shown beside a modded weapon, are not in.
- Lobby: spectators, Charlie and Delta (they come with the game modes), the console and
  commands, voting a map, muting, the chat's typing indicator over heads. The next map's
  name is not known until it loads. The scoreboard has no server name (it shows the
  map's) and no spectators.
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

- A test window takes the keyboard's focus when it opens, so keys typed elsewhere while
  it runs reach the game (a scripted run once picked a weapon from the menu this way).
- A corpse was twice seen hanging under a ceiling on ctf_Ash. Not reproduced.
- A pickup waits for the server, so it takes a round trip. By design, as in Soldat.
- A thrown gun appears a round trip after the throw, for the same reason.
- A gun dropped at death does not carry the body's velocity, where Soldat's does.
  Deliberate: with it the gun flew off whenever a soldier died moving.
- A client keeps shooting for half a round trip after the server has killed it; those
  shots show locally and are refused. It also counts hits on itself in that time
  that the server never rules.

## The other branches

`csp` is the line of work: the server runs every soldier and the client predicts its
own. The rest are kept for reference.

- `netcode`: the same game with Soldat's model instead, a client owning its own
  movement. Worth keeping to compare the feel of the two on one line.
- `server-auth`: the first try at this model, and the one that felt wrong. Its server
  stepped a player whose commands had not arrived by repeating the last one, which is
  a correction on every starved tick (server/queue.odin has the rule that replaces it).
- `soldat-net`: the first draft of `netcode`, with a shadow world and a fast-forward
  that never moved the bullet.
- `opensoldat-net`: OpenSoldat's netcode, message for message.
- `main`: the client-authority baseline this all started from.
