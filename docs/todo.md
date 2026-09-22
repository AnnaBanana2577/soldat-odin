# To do

What is left. The readme says how the netcode works (the model, at the top) and what it
measured; this says what it does not do yet. Checked against the code on 2026-09-21.

x Bots bullets are invisible
x Death ragdolls have weird physics currently
x Weps menu after spawn not working
x Spawn timer remove
x Roll/flip parity with opensoldat — read against Control.pas line for line and traced
  tick for tick against ../soldat-love, which agrees: entry, direction, forces, the two
  machines in lockstep, the graceful end, the free flip, the animation files and their
  speeds, the stance, and the roll's sound and the reload it silences all match. Nothing
  found to fix; shared/sim/movement_test.odin now holds it there.
- Flag throws
- HUD parity
  - Big Messages for everything
  - Parity gaps in things that exist:
  - Crosshair doesn't grow with bink — hit_spray is in the sim
  - Sniper line missing
  - Kill feed and console each draw in one colour; the original colours by kind (join, vote, death, server)
  - Scoreboard: no spectators, no PageUp/PageDown scrolling, shows the map name where a server name belongs
  - Shirt colours are team colours — the roster carries names only, so this needs a wire change
  - Cease-fire counter draws always; the original draws it in survival mode only
  Missing outright:
    7. Weapon stats page (F2)
    8. Radio menu (V)
    9. Key binds in settings, with the original's as defaults
    10. Spectators — team menu, scoreboard section, free camera, server support
    11. Interface read from the interface-gfx archive and its .ini rather than fixed in code
- Chat/commands
- Game modes and match lifecycle
- Polygon types?
- Modifiers
- -----
- Netcode fixes
- Lobby
- Demos
- File transfer
- Map editor
- Editor for po and poa
- -----
- Code refactor
- GitHub workflows for packaging
- Scripting via lua
- rcon for servers

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

- One game mode. Capture the flag is in and plays: flags, captures, scores, a round
  that ends on the score or the clock. It is the only one. Deathmatch, Team Deathmatch,
  Pointmatch, Rambo, Hold the Flag and Infiltration are all missing, and with them
  Charlie and Delta, spectators, a setting to pick a mode, and the maps' own families
  (dm_, htf_, inf_).
- The bots are the original's (AI.pas, in shared/sim/bot*.odin), but what their files
  say about how they look (shirt, trousers, hair, headgear) is read and dropped,
  since the roster carries names only. Their paths for the modes this game does not
  have are left out, nothing sends one to a stationary gun, and their aim at a target
  on a stationary gun is the plain one.
- Lobby and console: no console and no commands (a map vote and a kick vote are in,
  off the escape menu), no muting, no teams beyond Alpha and Bravo, and no spectators.
  A setting can only be given at startup (config.cfg or the command line), not changed
  while playing.
- The weapons menu offers every weapon; a server's list of allowed ones is not in.
- Sounds missing: shell casings, the antics. Shell casings are not drawn either.
- The sim's own gaps, each marked TODO where it belongs: the stationary gun's burst,
  heat and overheat (stat_gun.odin); the antics on the body animation (antics.odin); the
  parachute hung from the head of the pose (parachute.odin); a thrown knife that lands
  becoming a knife to pick up (dropped_gun.odin); the flag carrier check on hurting
  polygons (soldier_collision.odin).

## HUD

What the original draws over the game and this does not. The layout, the menus and the
scoreboard are ported from InterfaceGraphics.pas and GameMenus.pas, and the readme says
what is in; this is the rest of it.

- The weapon stats page (F2): the weapon in hand attribute by attribute against its
  default, as RenderWeaponStatsTexts and GetWeaponAttribs give it.
- Keys are hardwired (client/input/input.odin) and are not the original's, which binds
  them from its own config (configs/controls.cfg): it jets on the middle mouse button,
  throws the flag with Space, opens the radio on V and the command line on /, takes a
  screenshot on F4, and puts the weapon stats on F2 and the minimap on F3. Binds belong
  in the settings, with those as the defaults.
- Spectators: no entry on the team menu, no section on the scoreboard, no free camera,
  and nothing on the server that lets a player sit a round out.
- The radio menu (V): the three keys, the lines they say, and the heads they say them
  over.
- The sniper line, the bonus's name and how long is left of it, and the crosshair
  growing with the bink.
- The scoreboard has no spectators, does not scroll (PageUp and PageDown), and shows
  the map's name where a server's name would go; nobody knows the next map until it
  loads.
- The console and the kill feed each draw in one colour. The original colours a line by
  what it is (a join, a vote, a death, the server speaking) and keeps the server's
  messages apart from the kills.
- The names of the players and their colours: the roster carries names only, so the
  shirts on the scoreboard, the kill feed and the gostek are the team's colours and not
  each player's own.
- The whole interface is fixed in code. The original reads an interface-gfx archive
  with its own .ini: where every bar, icon and number sits, what colour it is and which
  image draws it, so a player can change the look of the lot.
- Exit to menu, off the escape menu, closes the game: there is no main menu here to
  return to, and no server browser to return to it from.
- The cease fire count over one's own head (RenderCeaseFireCounter) is gone, the
  original putting it up in survival mode alone and this game not having that mode. It
  belongs with survival when that lands, over skeleton point 9 less (2, 15), reading
  the counter in whole seconds and one more.
- The weapons menu cannot be locked. The original's weapons key, pressed while the menu
  is up, sets LimboLock and says "Weapons menu disabled": the menu then stops opening
  by itself on death until the key turns it back on.

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
- Holding left and right together is remembered for the tick it happened on, and the
  jet flip reads it there. The original keeps it in a global it never clears
  (PlayerPressedLeftRight, set in the client's own input and read in the flip's
  condition), so once a player has pressed the two together, every later side jump
  flips on the jet whichever way it is going, and only on that player's own screen.
  Deliberate: the flip would be predicted and never ruled.
- A client goes on playing for half a round trip after the server has killed it: it
  keeps firing on its own screen, and counts hits on itself that the server never rules.
  The server runs none of those commands, so nothing of it reaches anyone else.
- A corpse was twice seen hanging under a ceiling on ctf_Ash. Not reproduced.
- A shot at a corpse is judged against the body where the server has it, not where its
  shooter saw it: no history is kept of the corpses, and a client starts its own a few
  ticks after the server does, so the two bodies are the same motion a moment apart.
  It shows for the second or so a body is still moving; once it has settled they agree.
  Both earlier ports make the same approximation. Rewinding a corpse would mean keeping
  24 points a tick for a second, for a target that barely moves.
- A test window takes the keyboard's focus when it opens, so keys typed elsewhere while
  it runs reach the game (a scripted run once picked a weapon from the menu this way).

## What was tried and dropped

None of these is kept. They are written down so that the next person to think of one
knows it has been thought of.

- A server that stepped a player whose commands had not arrived, which is what made
  this model feel wrong the first time.
- A draft with a shadow world, and a fast-forward that never moved the bullet.
- OpenSoldat's netcode copied message for message.
- Soldat's own model: a client owning its own movement and the server refereeing. It
  was carried far enough to feel both on one line, and then dropped.
- Corpses on the clients alone, as decoration. Most of a corpse is decoration, but two
  things are not: a bullet through a body loses a tenth of its speed, and speed is the
  damage it does, so a body between two players is worth a tenth of a shot; and a body
  comes apart by its health, which only the server may lower. Either the server runs
  the corpses or neither of those can happen, and a full server of 32 of them costs
  35 us of a tick's 16666. Nothing about them crosses the wire either way: every
  machine derives the same body from the state a dead soldier's word already carries.
