# soldat-odin skeleton

The shape of an Odin port on raylib and ENet, and its netcode, which is five rules:

1. **The server runs every soldier; my client predicts mine.** I send the keys I
   pressed, numbered; the server runs them in order; I run the same step on the same
   command the moment I make it, and replay the ones the server has not run over its
   word (client/game/predict.odin). What I press shows at once and what counts is the
   server's, so there is nothing to cheat with and nothing to wait for.
2. **What matters to anyone else is the server's.** Whether a bullet hit, health,
   deaths, respawns, things, pickups, flags, scores. Every machine runs the same
   simulation and one flag on the world, authority, marks the one whose word counts.
3. **A bullet crosses the wire once, at birth,** and flies on every machine from
   there, so the blood, the sparks and the sounds are local and at once.
4. **Everyone sees the others a little in the past, drawn between two of the server's
   words rather than guessed, and the bullets are moved to match.** The server judges a
   bullet against the soldiers as its shooter saw them (it rewinds to the tick that
   client says it is showing), so what you aim at is what you hit. The other clients fly
   that bullet forward by the shooter's lag plus their own, so the bullet you see coming
   is the one that will be ruled on, and you can dodge it.
5. **State is sent over and over, unreliably; news is sent once, reliably.** My
   commands and where the soldiers are go in every packet and the next one replaces
   them. A death, a respawn,
   a pickup, a score, a thing that changed goes once and is never lost.

How that comes to be built is under "What works", Online.

```
shared/sim/  the simulation, shared, one file per object: level (the map: loading,
             sectors, collision queries), soldier (movement, soldier_anim, combat,
             antics, soldier_collision), bullet (bullet_collision, explosion), damage
             (the one place health changes), thing (flag, kit, dropped_gun, parachute,
             stat_gun), ragdoll, history (the server's rewind), round, event (a tagged
             union), bot (the brain of the server's bots and of the test client), math
shared/net/  the wire: serialize (one Stream that reads or writes), protocol (Hello,
             Welcome, Map, Roster, Input, Act, Chat, Update, Things, Facts, Correction), Fake_Link
shared/timer/  a fine sleep on Windows, for the loops that sleep between ticks
client/      main (each subsystem opened, the loop, each closed), debug, and a package
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
server/      main (init / server_loop / cleanup), game (the tick), queue (a client's
             commands and which of them this tick runs), connection
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

A headless client (-headless) runs the same without the window, the picture and the
sound (run_headless), played by the bots' brain: a player for testing the netcode.

The server's tick, server/game.odin, reads the same way:

```
for each tick owed:
  step_soldiers   every soldier one tick on: the bots played, the players guessed
  receive         the clients' word over the guesses; their shots, checked
  step_world      the things, every bullet, the round; the hits become wounds
  send            what changed, what was decided, the soldiers and the bullets born
sleep until the next tick
```

## Building and running

One entry point, build.odin, in Odin so it works the same everywhere:

```
odin run build.odin -file -- check          type-check every package (with the vet flags)
odin run build.odin -file -- build          compile the client and the server into build/
odin run build.odin -file -- test           run the package tests
odin run build.odin -file -- dev            build, then a server with a client joined
odin run build.odin -file -- dev -bots 2    the same with two bots in it
odin run build.odin -file -- server         build, then the server alone
```

The server links no raylib. The map and its art come from the opensoldat/base
assets, expected at ../opensoldat-base/shared, or wherever SOLDAT_BASE says (-base DIR
overrides both, -map NAME
for another map; the clients play the map the server names). Anything after a
second -- goes to the program:

```
odin run build.odin -file -- dev -- -window          in a window instead of borderless fullscreen
odin run build.odin -file -- dev -- -wire -zoom 0.3  the polygons as lines, the view closer
odin run build.odin -file -- dev -- -hold right,fire -aim 200,0 -screenshot out.png
odin run build.odin -file -- dev -bots 2 -- -ping 120 -jitter 30 -loss 5
odin run build.odin -file -- dev -bots 4 -map ctf_Ash,Arena -time-limit 2 -score-limit 3
```

The third is a scripted run for checks without a person at the screen: it holds the
buttons, aims at an offset from the soldier, writes the frame after two seconds and
quits with a line of counts (-seconds N for a longer run). The debug options live in
client/debug.odin and nowhere else. The last puts a simulated bad line between that
client and the server: a round trip of 120 ms, up to 30 ms more at random, one packet
in twenty lost (shared/net/fakelink.odin; a lost reliable packet is resent a round
trip and a half later, and those behind it wait). The next plays ctf_Ash and Arena in
turn, a round each, a round ending after two minutes or three captures (the defaults
are fifteen and ten). trip and a half later, and those behind it wait). The bots are the server's own
(-bots N; with -dodge they change direction and jet at random in a fight, as a person
does). -port N picks another port on the server and the client alike.

The assets are not in this checkout: set SOLDAT_BASE to the opensoldat base folder
(`setx SOLDAT_BASE C:\dev\opensoldat-base\shared` once), or pass -base.

Keys: A and D run, W jumps, S crouches, X goes prone, Space jets, Q changes weapon,
R reloads, F throws the gun, K is suicide, the mouse aims and fires. F1 shows the
scoreboard. Tab opens and closes the weapons menu; in it a click or 1 to 0 picks a
primary, a click a secondary. M opens the team menu. T says something to everyone and
Y to your team; Enter sends it, Esc lets it go.

## What works

- The map loads (polygons, sectors, colliders, spawn points, props, scenery names),
  collides (the soldier against the polygons in the original's order, with the
  special poly types as events) and draws (two static meshes for the background and
  terrain polys, the sky gradient anchored in world space, the scenery in its three
  layers with the colour key).
- The soldier moves as the original does: the legs and body animation state machines
  from Sprites.pas and Control.pas, jets, rolls, backflips, prone, crouch-slides,
  the slope friction by stance, jet fuel regeneration.
- The gostek draws from the animation pose: every body part pinned between its two
  skeleton points, mirrored or flipped for facing left, team colours, the held and
  slung weapons, the jet feet, the muzzle flash.
- Weapons: Soldat 1.7.1's stats built in, firing with the spread, bink and movement
  inaccuracy, the recoil animation by weapon, the shotgun's pellets, the Eagles' pair,
  the minigun's and LAW's wind-up, semi-automatics, reloads (clip out and in, shell
  by shell), changing, throwing the gun, the punch and the rifle butt, the grenade
  wind-up and throw. Bullets ricochet, bounce, stick, split and explode against the
  map and the colliders, hit soldiers by their pose (a Hit event, never a wound in
  the sim), pierce, lose damage with distance, and knock things.
- Bullet art and sparks: every projectile as TBullet.Render draws it (the round
  stretched along its speed with its trail, tumbling M79 rounds, spinning cluster
  grenades, arrows, the flamer's burn-out frames, the thrown knife), and the particle
  bursts from Sparks.pas for wall hits, ricochets, blood, explosions, cluster splits,
  spawns and the special polygons.
- The camera chases the soldier and leads toward the cursor as the original does,
  per frame at the frame's dt. Soldiers and bullets are drawn between their last two
  ticks from a render-only previous position, so nothing steps at 60 Hz.
- Things: the flags and kits spawn from the map's spawn points as Verlet skeletons
  (flag.po, kit.po, karabin.po at each gun's length) with the original's per-thing
  damping and gravity, collide with the map (a flag's pole stops dead and its cloth
  bounces, kits and guns slide to rest), settle, and are drawn as cloth and boxes
  stretched over their points, with the flag's handle and in-base glow. Guns thrown
  or dropped by a death lie where they land with their ammo, resist pickup for half a
  second, and are gone after twenty. A gun let go of by a death drops where the
  soldier fell rather than carrying the body's speed as the original has it, which
  sent a jetting soldier's gun sailing away. Whoever stands by a free thing and may
  have it takes it, in the things' own update, where the world has authority.
- Online. The five rules at the top, as built:
  - A client sends the commands the server has not run, all of them in every packet so
    a lost one costs nothing, with the server tick it is showing the others at (Input).
    What it chooses outside its keys goes once, reliably (Act): its weapons, its team.
    The server tells everyone who plays in which slot, by name, whenever someone joins
    (Roster).
  - The server runs each soldier on the commands its queue gives for that tick
    (server/queue.odin), and three rules there are what make the prediction hold:
    - **A starved queue steps nobody.** While a living soldier's commands are in
      flight it is not stepped at all, so it ends up exactly where its client
      predicted, however late they come. Stepping it with anything else (the last
      command again, a neutral one) moves it here where the client did not, and every
      such tick is a correction the client swallows when the commands land: that is
      the pull-back a player feels under packet loss.
    - **A burst runs in one tick.** Commands held up and landing together run down to
      the depth the client's clock aims for, so a stall costs nothing lasting.
    - **A quiet client's keys are let go** after half a second, so a soldier whose
      player has gone away falls and stops instead of hanging in the air.
  - The client runs its clock a shade faster or slower to keep about two commands
    waiting on the server: enough to ride out jitter, not enough to be felt. Every
    update carries the last command the server ran and how many were waiting.
  - My own bullets stay on my own timeline: I fired them from the same command the
    server did, so they are usually where its are anyway. When the server says where one
    ended, mine ends there too, which is where it was ruled to hit or miss.
  - Prediction is only as good as what the server's word covers, so an update carries
    the receiver's own soldier whole, every tick, and a test holds the wire's three
    parts (served, owned, rest) to the whole soldier, so no field can quietly drift
    (shared/net/soldier_halves_test.odin). Where the server disagrees the difference
    is drawn as an offset that blends out in about a tenth of a second.
  - Rounds. A round ends at its score or time limit; the scores stand for five seconds
    and a third, counted down in the round, and the next round begins on the next map
    of the server's rotation (-map a,b,c), or the same one. The server loads it and
    tells everyone which it is and where its flags stand (Map), then, in that order on
    the same channel, the things and everyone's placing with a nil tally. Joining is
    hearing of the first Map, so a newcomer and a round's start are one path: a client
    has no map until the server names one, the picture is rebuilt whenever the game
    loads another, and an update from before the Map is of the last round and dropped.
    Every placing of a soldier (a spawn, a respawn, a new round) is told as a fact and
    every client places that soldier on it, so nobody lingers where they were.
  - The server steps every soldier every tick: its bots on their brain's command, and
    the players as a guess from their last keys (soldier_reckon), the same guess every
    client makes of them. Then each client's word replaces the guess. Because its
    world has authority, what those steps cause counts: a wound from lava, a fall off
    the map. It checks each shot before it flies (a weapon the soldier holds, a token
    bucket on the fire rate, the muzzle near the soldier, no faster than the weapon
    shoots, not under cease fire) and refuses a soldier that moved further than one
    can, putting it back (Correction).
  - Every other tick each client gets an Update: which slots are in play, the soldiers
    in its view (its own with only the server's half: health, death, the flag, the
    tally), the ones out of view twice a second, and the bullets born lately whose line
    of flight passes near it, each in three updates running and numbered so it flies
    once. A thing goes out whole when it appears or goes, changes hands, or starts or
    stops moving (Things); in between every machine runs the same physics on it. What
    only the server could decide goes out as a fact (Facts), and sounds and shows like
    anything else that happened; what a pickup gives of the things a client owns (a
    gun, grenades) the client gives itself on hearing of it.
  - Time. A client shows the others at a view tick a few ticks behind the newest word
    of them, drawn between the two words around it, so nothing about them is guessed and
    nothing taken back; how far behind follows the line, three ticks on a good one
    (client/game/view.odin). Every Input names that tick, and the
    difference from the tick it arrives in is the client's lag, measured per packet. A
    bullet keeps the lag of the packet it came in and meets the soldiers as they were
    that long ago (sim/history.odin), for as long as it flies, up to a cap (-max-rewind
    MS, 300 by default; past it a shooter leads). The others fly that bullet on by the
    ticks since its birth, its shooter's lag and their own: the server will rule it
    against me as I was my own lag ago, so the bullet that will be ruled to hit me is
    that far ahead of the one the server spawned. Soldat's rule: my ping plus the
    shooter's. The shove of a hit on me comes with the server's word on my soldier,
    as the wound does: shoving myself where I see the bullet land would be a guess at a
    tick the server has not reached.
  - Lives. The server places a soldier (a spawn, a respawn, a correction) and each
    placing begins a new life, numbered. A client says which life its word is of and
    takes the server's word of its own soldier only for the life it is living, so word
    from before a placing is never taken for word from after it, whichever way the
    packets cross.
  - Every message is state or news, and RELIABLE in shared/net/protocol.odin says
    which; no call site chooses. Each has one serialize procedure, used for reading
    and writing both, bounds-checked, that refuses floats that are not numbers, enums
    out of range, counts too large and bytes left over (shared/net/protocol_test.odin).
  - ENet only sends what it was given when it is next pumped, a tick later; both ends
    flush at the end of their tick, which took two ticks off everyone's lag.
  - Measured with the headless client against five dodging bots on Arena, ninety
    seconds a run. Prediction: in a fight on a clean line the client's own soldier sits
    0.00 units from the server's on average (0.34 at worst) over 5000 updates, and 0.10
    on a 120 ms line with 5% loss. Under 30% packet loss at 200 ms it is 0.03, and under
    50% loss at 300 ms 0.06: the starved-queue rule doing its work. Hits: on the clean
    line 21 of the 21 it saw itself give were ruled, and 10 of the 11 it took; on the
    120 ms line 14 of 15 given and 22 of 24 taken. The others sit three ticks behind the
    newest word of them. 3 KB/s up on a clean line (8 when the unrun commands pile up)
    and 30 KB/s down with six soldiers in view.
- Corpses: a dead soldier's skeleton runs on as a ragdoll from its pose at the moment
  of death, falls with the original's damping and gravity, collides with the map and
  comes to rest; a death far below zero health tears the body apart, a head or leg
  shot past the chop threshold takes that part off; blasts shove corpses. Corpses
  touch nothing but the map, so every client runs its own from the kill and nothing
  about them crosses the wire. A suicide (K) shows one.
- Sounds: Sound.pas on raylib's audio. Every play is placed by distance and direction
  from our soldier; gunfire and blasts past half the range play their distant
  samples; a blast beside us rings the ears. Shots, hits, ricochets, blasts, deaths
  by how bad they were, pickups, the flags and kits landing come from the events;
  jets, the chainsaw, wind-ups, reloads, weapon changes, melee, the grenade pin,
  footsteps, jumps, rolls, crouching and landings from each soldier's state against
  the tick before; bullets whistle and whiz past us. Four reserved voices per soldier
  keep the loops alive and let a wind-up be cut. Corpse thuds, shell casings and the
  antics are not in yet.
- Bots: the server plays them itself, with no client and no connection: each tick a
  small brain (shared/sim/bot.odin) reads the server's world and gives the bot's
  command (run at the nearest enemy, jet when it is above, jump when stuck, fire with
  line of sight in range). The server's -bots N adds them, -dodge makes them dodge.
- Tests without a person: the client's -headless has no window and is played by the
  bots' brain, through a real connection, and with -seconds N it quits with a summary:
  the hits it saw itself give and take, how far behind it showed the world, and what
  went over the wire. The server's leave line says how many of those hits it ruled,
  and how far back that client's shots were judged: the two agreeing is the measure
  of the netcode. A simulated bad line (-ping, -jitter, -loss) sits on any client.
  The test command runs the wire format's tests.
- The scoreboard (the original's frags menu), toggled with F1 and shown at every round's
  end with who won and the countdown to the next: the map and the time left, and each
  team's players under its caption and total, the best first, with kills, flags,
  deaths and ping (the server's measure of each player's lag, a byte each in every
  Update; none for the bots, which the Roster marks). The weapons menu closes for a
  round's end and opens again when the next round begins.
- The HUD (client/hud, from InterfaceGraphics.pas with its default layout, on the
  original's 640 by 480 screen scaled to the window): the health, vest, ammo or
  reload, fire interval and jet bars with their icons, the grenades, the ammo count
  and the weapon's name; the kill feed down the right, the killer with its tally and
  the weapon's icon over the victim, in their teams' colours, scrolling off after
  four seconds; "You killed", "Killed by" and the respawn countdown; the flags and
  the teams' scores, my place and kills, my lag; the crosshair. The wounds on a
  soldier (gostek-gfx/ranny) show below 90 health, stronger the lower it goes.
- Teams: the team menu (the original's, on M, since there is no Esc menu yet) asks the
  server for the other team, which it grants when the teams stay even (Soldat's balance)
  and refuses otherwise, telling you so. A move lets go of the flag, places the soldier
  on the new team's spawn and tells everyone; the weapons menu opens for the new life.
- Chat: T to everyone, Y to your team. The server relays team chat to the team alone,
  keeps a client to a line every half second, and says who joins, leaves and changes
  team. Lines show in the top left for five seconds (the original's console), and a
  short one over its speaker's head for as long as it takes to read.
- The weapons menu (the original's limbo menu): it opens when I die and when I join,
  and goes away when my soldier first moves; Tab opens it by hand. Names come from
  the server's roster; the bots have names.
