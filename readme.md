# soldat-odin skeleton

The shape of an Odin port on raylib and ENet, with the netcode from the Lua
deadreck branch: clients simulate themselves and report their shots, throws, hits and
pickups; the server relays states and things and referees claims; everyone else is
dead-reckoned.

```
shared/sim/  the simulation, shared, one file per object: level (the map: loading,
             sectors, collision queries), soldier (movement, soldier_anim, combat,
             antics, soldier_collision), bullet (bullet_collision, explosion), damage
             (the one place health changes), thing (flag, kit, dropped_gun, parachute,
             stat_gun), round, event (a tagged union), math
shared/net/  the wire: Writer/Reader, Msg, Update, Throw, State, Shot, Claim, Commit,
             Things, Clock, Fake_Link
client/      main (init / game_loop / cleanup), input, game, view, render, audio
             (events, soldier state, bullets passing), assets, connection, debug
server/      main (init / server_loop / cleanup), game (referee / step_things / relay),
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
  referee
  step_things
  relay
sleep until the next tick
```

## Building and running

One entry point, build.odin, in Odin so it works the same everywhere:

```
odin run build.odin -file -- check          type-check every package (with the vet flags)
odin run build.odin -file -- build          compile the client and the server into build/
odin run build.odin -file -- test           run the package tests
odin run build.odin -file -- dev            build, then a server with a client joined
odin run build.odin -file -- server         build, then the server alone
```

The server links no raylib. The map and its art come from the opensoldat/base
assets, expected at ../opensoldat-base/shared (-base DIR to point elsewhere, -map NAME
for another map). Anything after a second -- goes to the program:

```
odin run build.odin -file -- dev -- -window          in a window instead of borderless fullscreen
odin run build.odin -file -- dev -- -wire -zoom 0.3  the polygons as lines, the view closer
odin run build.odin -file -- dev -- -hold right,fire -aim 200,0 -screenshot out.png
```

The last is a scripted run for checks without a person at the screen: it holds the
buttons, aims at an offset from the soldier, writes the frame after two seconds and
quits with a line of counts (-seconds N for a longer run). The debug options live in
client/debug.odin and nowhere else.

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
  sent a jetting soldier's gun sailing away. Pickups go through one claim path per kind
  (flag, kit, gun) that the client predicts and the server referees.
- Online: the client says hello with its name, the server answers with a slot and
  the map and spawns the soldier on the emptier team. Each tick every client sends
  its owned soldier state and its recent shots; the server copies the owned fields,
  sends every soldier back to everyone with the packet's age (the server's fields,
  cease fire and the counters, ride along), relays the shots to the others, and
  sends the round's clock. The things are event driven: the server sends a thing
  whole when it appears or goes, changes hands, or starts or stops moving (and all
  of them once to a newcomer); from those numbers every client runs the same
  physics until the next change, so nothing about things crosses the wire in
  between. Remote soldiers are moved on by the age plus half the round trip
  and dead-reckoned on their last controls, with a rate-limited drawn offset where a
  state lands them elsewhere. Only what another player could contest is a claim: a
  hit and a pickup, settled in arrival order, answered with a commit everyone applies
  the same way or a reject; a predicted pickup holds until its answer. A thrown gun
  is an event, like a shot: the server throws it from the thrower's relayed pose and
  sends the thing. A client's world makes no things of its own.
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
- The HUD is still a stub.
