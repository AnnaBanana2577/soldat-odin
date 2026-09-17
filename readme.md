# soldat-odin skeleton

The shape of an Odin port on raylib and ENet. The server is authoritative: clients
send their commands, the server runs the one true world and sends it whole every
tick; a client predicts itself by replaying its unacknowledged commands on the latest
snapshot and shows everyone else interpolated between two older ones; the server
judges shots against the soldiers as their shooter saw them.

```
shared/sim/  the simulation, shared, one file per object: level (the map: loading,
             sectors, collision queries), soldier (movement, soldier_anim, combat,
             antics, soldier_collision), bullet (bullet_collision, explosion), damage
             (the one place health changes), thing (flag, kit, dropped_gun, parachute,
             stat_gun), ragdoll, history (the server's rewind), round, event (a tagged
             union), math
shared/net/  the wire: Writer/Reader, Msg, Hello/Welcome, Input, Snapshot, Fake_Link
client/      main (init / game_loop / cleanup), input, bot, game (reset / place others /
             replay / effects), interp (the snapshot ring and the render clock), render,
             audio, assets, connection, debug
server/      main (init / server_loop / cleanup), game (tick / send_snapshots),
             connection
```

The client loop, client/main.odin:

```
sample_input
tick accumulator:
  process_server_messages
  simulate
  send_to_server
  clear_input
interpolate
draw
```

The server loop, server/main.odin:

```
receive_client_messages
tick accumulator:
  tick            one command per client, the world stepped, the hits applied
  send_snapshots
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
assets, expected at ../opensoldat-base/shared (-base DIR to point elsewhere, -map NAME
for another map). Anything after a second -- goes to the program:

```
odin run build.odin -file -- dev -- -window          in a window instead of borderless fullscreen
odin run build.odin -file -- dev -- -wire -zoom 0.3  the polygons as lines, the view closer
odin run build.odin -file -- dev -- -hold right,fire -aim 200,0 -screenshot out.png
odin run build.odin -file -- dev -bots 2 -- -ping 120 -jitter 30 -loss 5
```

The last is a scripted run for checks without a person at the screen: it holds the
buttons, aims at an offset from the soldier, writes the frame after two seconds and
quits with a line of counts (-seconds N for a longer run). The debug options live in
client/debug.odin and nowhere else. The last puts a simulated bad line between every
client and the server: a round trip of 120 ms, up to 30 ms more at random, one packet
in twenty lost (shared/net/fakelink.odin; reliable packets are never lost, only late).
A bot is the client with -bot: no window, its input from client/bot.odin, so the
server sees a player like any other.

Keys: A and D run, W jumps, S crouches, X goes prone, Space jets, Q changes weapon,
R reloads, F throws the gun, K is suicide, the mouse aims and fires.

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
  have it takes it, in the things' own update.
- Online, server authority. The client says hello with its name, the server answers
  with a slot and the map and spawns the soldier on the emptier team. From then on
  the client sends only its commands, numbered by itself, the last few in every
  packet so a lost one costs nothing. The server keeps a short queue per client,
  applies one command per tick (the last one again, without its one-shot buttons,
  when none has arrived), steps the whole world, applies the hits, and every second
  tick sends every client a snapshot: every soldier, thing and bullet, the round, the
  events since the last one, and for the receiver its last applied command and how
  many were waiting. A snapshot goes as a delta against the newest one the client
  says it holds: only the entities that changed, and of those only the 4-byte words
  that changed under a mask, so a quiet tick costs a hundred bytes; a client holding
  nothing useful gets it whole.
  The client rebuilds its world from the newest snapshot every tick and replays its
  pending commands on it, which predicts everything they touch: its movement, its
  shots and their flight, its pickups, the things it holds. Everyone else and their
  bullets are placed from two older snapshots, interpolated at a render tick that
  runs a few ticks behind the newest, and the tick's events are applied as the render
  tick passes them. The client runs its clock a little faster or slower to hold the
  server's queue at a small target, and the render tick likewise to hold its
  distance, so the two never need to agree on a clock. A correction, the server
  putting the soldier elsewhere than predicted for the same command, is drawn as an
  offset that blends out. Each command says which tick the client shows the others
  at, and the server keeps the last second of soldiers so a shot meets them as its
  shooter saw them, for as long as it flies (the server'"'"'s -no-rewind switches that off,
  to show what it does; the run summary'"'"'s "hits seen" against "hits ruled" is the
  measure). The state crosses the wire as the sim'"'"'s structs byte for byte, so the
  same build must run on both ends; the hello carries the layout and a mismatch is
  refused. A dead soldier'"'"'s state says how it died, so a corpse starts from any
  snapshot and a lost one loses nothing.
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
- Bots, for testing: the client with -bot has no window and takes its input from a
  small brain (run at the nearest enemy, jet when it is above, jump when stuck, fire
  with line of sight in range). A simulated bad line (-ping, -jitter, -loss) sits on
  any client, bots included.
- The HUD is still a stub.
