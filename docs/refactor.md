# Refactor: the code as a tree of structs

The whole program is one struct, and every part of it is a struct inside that one. A
file is a struct and the procedures that act on it. A directory is a struct big enough
to be called by name from outside. The directory tree is the struct tree: what the
client owns is under client/, what the game owns is under game/, what the world owns is
under game/world/. Nothing is global but the root of each executable.

The shape, in the sim's terms:

```
Game {                              game.tick
  World {                           world.step
    map, soldiers[], bullets[], things[] (flags, kits, dropped guns), ragdolls[], events
    each entity stepped on a View of the world, never the World itself
  }
  Match {                           match.run
    settings, time_remaining, score, mode
  }
}
```

The client is mostly arranged this way already (App owns the connection, the game, the
render, the HUD, the audio, each a package with init, tick, draw and destroy). This plan
finishes the job: the sim, whose forty files stand in one package with the round and
the rules mixed into the world; the server, whose one Game struct holds both the world
and the wire; and the client's own game struct, which carries the netcode as well.

## How Odin lets us say it

Odin has no methods. `x.verb()` exists in exactly one place: a package boundary, where
`world.step(&w)` is the package `world` and its procedure `step`. Inside a package there
is only a prefix, `soldier_step(&w.soldiers[i])`. So the rule has two scales, and both
are the same rule:

- **A struct that wants to be called by name gets a directory.** Its package is named
  for it, in lower case; the struct itself is named again inside, `world.World`,
  `match.Match`, `render.Render`, as the client does now. Its procedures carry no
  prefix: `render.init`, `render.tick`, `render.draw`, `render.destroy`.
- **A struct that only its parent uses gets a file** in the parent's package, and its
  procedures carry its name: `Soldier` in world/soldier.odin, `soldier_spawn`,
  `soldier_step`; `Sparks` in render/sparks.odin, `sparks_draw`. The file is named after
  the struct.
- **The parent imports the child, never the reverse.** A child that needs something
  from above takes it as an argument: the world's Context, a setting's value rather than
  the Settings struct, the game to draw. That is already the shape of every call in
  client/main.odin, and it is what keeps the tree a tree.
- **Structs that refer to each other by type share a package.** Odin refuses an import
  cycle, and a subdirectory is always another package. The entities are one such knot
  (a bullet meets the soldiers, a flag reads who touches it, a shot spawns a bullet),
  so they share the package world/entities/, prefixed inside it.
- **A child that would need its parent gets a view of it instead.** The entities'
  steps read the World back, and entities cannot import world. So entities defines a
  View: pointers to the pools, the map, the rng and the history, and the tick, the
  gravity, the authority and the flag homes by value. The world builds one of itself
  at the top of each step and passes it down. What an entity may reach is then written
  in one place, and a pointer to an array indexes and ranges the same as the array, so
  `v.soldiers[i]` reads as `w.soldiers[i]` did.
- **The verbs are the ones in use now.** `init`/`destroy` for what is set up once,
  `load`/`unload` for art and files, `tick` for one tick of a whole, `step` for one
  tick of the world, `run` for the match, `draw` for one frame, `receive`/`send` for the
  wire. A new struct uses these before inventing one.
- **A field named after a package hides that package from the fields declared after
  it** (an Odin quirk; see the comment on App.script). So in a struct that owns
  `game: game.Game`, every other field typed from package `game` is declared before it.

One consequence to accept: splitting a package makes public what was `@(private)` and
crossed the split. Prefer `@(private = "file")` where a helper really is one file's.

## The tree

The target, with what each package is. A file is the struct it is named for and its
procedures; where a struct has parts, they follow in parentheses.

```
shared/                 the layer both executables import, a DAG of packages, listed
                        bottom up: nothing imports anything above itself
  geom/     Vec2, the vector arithmetic, point_line_distance, line_circle_collision,
            round_half_even: what knows no type but Vec2 (from sim/math and sim/level)
  level/    Level: the map as the game reads it. level (the types, load, destroy),
            file (the byte reader), query (sectors, ray casts, the polygon tests)
  anim/     the .poa animations and the .po particle objects: Anims, Anim (one
            running), Pose, Particle_Object, their parsers and loaders (anim, pose, file)
  weapons/  Weapon_Id, Bullet_Style, Weapon_Info, the table and its defaults, named
  game/     Game: game.odin (Game: ctx, world, match; init, tick, destroy; Context,
            the static data the world reads: anims, weapons, skeletons)
    world/  World: world.odin (World: the map, the pools, tick, rng, authority, the
            flag homes; init, step: a View built, every soldier stepped on its command,
            then the ragdolls, the things, the bullets), spawn (where a team is placed,
            which polygons a team passes: the rules over the map that were the
            level's)
      entities/  the knot: view (View: what an entity may reach), soldier (movement,
              soldier_anim, combat, antics, soldier_collision, soldier_pose), bullet
              (bullet_collision, explosion), damage, thing (the pool and its physics:
              flag, kit, dropped_gun, parachute, stat_gun), ragdoll, event, history,
              command (Command, Buttons, Team), rand
    match/  Match: match.odin (Match: settings, time_remaining, score, mode, state;
            run: the clock, the end, who respawns when), score (Match_Score),
            settings (Match_Settings: time and score limits, respawn time, grenades,
            friendly fire, kits collide)
      rules/  the modes: rules.odin (Mode, what an event scores, when a match is
              over), ctf, dm
  bot/      Bot: the brain, played by the server and by the headless client
            (bot, fight, path, file)
  net/      Stream (stream), Message and the protocol (protocol), Fake_Link (fake_link)
  pms/      Map, Reader, Writer: the codec that keeps every field         unchanged
  cvar/     Cvar, Set                                                     unchanged
  timer/    the fine sleep                                                unchanged

server/
  server.odin   Server: settings, game, rotation, bots, net, vote; main and the loop
  settings.odin Settings, and Match_Settings and the net's settings built from it
  rotation.odin Rotation: the maps played in turn, next_round, map_load
  bots.odin     Bots: the slots the server plays itself and their profiles
  net/          Net: the wire. Host (host: ENet, the peers by slot), Client (client:
                connected, name, queue, lag, the tallies), Queue (queue), and net.odin:
                receive and its parts, send and its parts, tell_born, in_view,
                could_reach, born / ends / shot_seq / things_sent, the scratch messages,
                and its own settings: max_rewind, update_others
  vote/         Vote: what is being voted on and its clock. It decides; the net carries
                it; the server applies a passed kick or map

client/
  client.odin   Client: settings, debug, game, me, predict, view, net, engine, hud;
                main, the loop, run_headless
  settings.odin Settings
  debug.odin    Debug
  predict/      Predict: my soldier over the server's word. pending and seq (the
                commands the server has not run), the error blending out and its
                measures, my_prev; reconcile, predict_tick, drawn_pos
  view/         View: the others between two of the server's words; the view tick
  net/          Net: Connection (connection: ENet, the fake line) and net.odin: receive
                and its parts, send, the clock (depth, time_scale, clock_target),
                newest, seen_shot, my_lag, the roster (names, lags, the bot slots),
                and what is told once (acts, called, asked, said: choose_weapons,
                choose_team, say, call_kick, call_map, vote_yes, vote_no, ask_map)
  engine/       Engine: the raylib side. engine.odin (the window, the frame clock,
                ticks_owed), then
    input/      Input, Script
    render/     Render, Camera (camera), Map_View, Minimap, Gostek, Bullet_Art,
                Things_Art, Sparks, Sprite, the texture loaders    as now
    audio/      Audio                                             as now
  hud/          Hud and its parts                                 as now
  editor/       Editor: the other program in the binary            as now
```

Who imports whom. In shared: world imports entities; match imports rules and world;
rules imports entities (the events); game imports world and match; bot and net import
game, and entities for the soldiers, the bullets and the things they read. The world never hears of the match:
what it does that the match must know (a capture, a kill, a death) it emits as an event,
as it does now, and the match reads the events and scores them; what the match decides
(a respawn, the end) it does through world's procedures. On the server, net imports
game and vote, vote imports game, server imports all three. On the client, predict and
view import game; net imports game, predict and view; engine's render and audio import
game and view; hud imports game and engine/render; client imports all of them. No line
runs upward.

**The pools.** The world keeps one `things` pool for the flags, the kits, the dropped
guns, the parachutes and the stationary guns, as it has now, with a file per kind. They
share one Verlet body and one physics, and the wire names them by pool index. Typed
pools (`flags[2]`, `kits[]`, `dropped_guns[]`) would read better and are a fair later
step, but they change the protocol and every place that walks the pool, so they are not
part of this refactor.

**The names.** The words are the code's current ones (bullet, thing, kit) so that each
commit is a move and not a rename. A rename (bullet to projectile, kit to pickup) is a
find-and-replace to do at the end, once, if wanted.

## What moves, in order

Three stages, each a branch (`refactor/shared`, `refactor/server`, `refactor/client`)
merged with its history, each commit a `refactor(scope)` that changes no behaviour.
Before each commit lands: `check`, `test`, and a `dev -sv_bots 2` that plays. Each
commit rewrites its callers in the client and the server in the same commit (a
`sim.Vec2` becomes a `world.Vec2`); nothing is aliased to be cleaned up later. The wire
does not change at any point, so a client from before a stage talks to a server from
after it.

### Stage 1: shared

The sim gives up what only points downward, then becomes the game. Each step is one
commit, in this order, because each depends on the one before.

1. **geom.** sim/math.odin's Vec2, vector procs, point_line_distance and
   round_half_even, and level.odin's line_circle_collision, become shared/geom. The
   tests against a Polygon (point_in_poly, line_in_poly, closest_perpendicular) stay
   with the level. The rng stays in the sim (rand.odin): it is the sim's determinism,
   not arithmetic. `Vec2 :: geom.Vec2` in the sim keeps `sim.Vec2` for everyone
   above; this one alias stays, because everything above the world speaks in its terms.
2. **level.** sim/level.odin and level_file.odin become shared/level, and the one file
   becomes three: level (the types, load, destroy), file (the byte reader), query
   (sectors, ray casts, the collision tests). Two things move up into the sim instead
   of across: `level_spawn_point` (it takes a Team and rolls the rng) and
   `team_collides` / `bullet_team_collides` (which polygons a team passes is a rule of
   the game, not a fact of the map). The Level keeps its spawnpoints; the sim picks.
3. **weapons.** sim/weapons.odin becomes shared/weapons: the ids, the styles, the
   table, its defaults and `named`. The Weapon a soldier holds (ammo, the reload
   clocks) is state and stays with the soldier, in combat.odin.
4. **anim.** The data half of soldier_anim.odin (Anim_Id, Anim_Info, Anim_Data, Anims,
   Anim, advance, set, parse), pose.odin's Pose and Particle_Object with their parsers,
   and anim_file.odin's loaders become shared/anim. `soldier_pose` stays in the sim, in
   its own file; so do Skeletons and their loader, which are the things'.
5. **entities, and world over them.** shared/sim becomes shared/game/world/entities:
   the package renamed, Command, Buttons and Team into command.odin, math.odin's rng
   into rand.odin. World, world_init and step leave for shared/game/world/world.odin,
   with level_spawn_point and the team collision tests beside them in spawn.odin.
   entities/view.odin is the View, and every entity procedure that took `w: ^World`
   takes `v: ^View`: the pools index the same through the pointer, `&w.rng` becomes
   `v.rng`, and `w.round` goes (next step). round.odin and Match_State come out with it;
   `step` no longer ticks the round. Every `sim.` above becomes `entities.` or
   `world.`, and the sim.odin header is rewritten as world.odin's and entities'.
6. **match, and game over it.** shared/game/match holds Match (settings,
   time_remaining, score, mode, state) and `run`: the clock, the end of the round when
   the score or the time is reached, the scores standing, and who is placed again and
   when (soldier_served_tick's respawn counting moves here, reading the world's dead
   and calling `world.soldier_respawn`). match/rules holds what the mode makes of an
   event: ctf.odin scores a Flag_Score for a team, and says the match is over at the
   score limit; dm.odin scores a Kill for a player, the same shape, so that the mode
   the to-do list wants has its place before it exists. shared/game/game.odin is Game
   (ctx, world, match) with `init`, `tick` (world.step, then match.run over its events)
   and `destroy`; the tests' whole-world tick calls it. The server's Rules struct is
   split: time_limit, score_limit, respawn_time, max_grenades, friendly_fire and
   kits_collide become match.Match_Settings; max_rewind and update_others are the
   net's; bots_difficulty and bots_chat the bots'; vote_percent the vote's.
7. **bot.** bot.odin, bot_fight, bot_path and bot_file become shared/bot, files named
   bot, fight, path, file, importing game.

Each commit updates build.odin's LIBRARIES and moves the tests that belong to the new
package (movement_test and ragdoll_test step a whole world, so they go with world).

Optional polish in the same stage, one commit: net's files named for their structs
(serialize.odin to stream.odin, fakelink.odin to fake_link.odin).

### Stage 2: server

1. **The wire out of the game.** server/game.odin's Client, Queue, born, ends,
   shot_seq, things_sent, the scratch messages and every receive_* and send_* move to
   server/net with Host. `step_soldiers` takes the tick's commands as an argument, the
   way `world.step` does; the net's queues give them.
2. **What is left of the server's game** is the shared Game plus the map rotation
   (rotation.odin: the maps in turn, next_round, map_load, round_start) and the bots
   it plays (bots.odin: the slots, the brains, the profiles, add_bot, bot_chat). Both
   are files of the server's root package, owned by Server.
3. **Vote as a package.** vote.odin becomes server/vote, importing game only. Its
   `receive` is called by the net and its state is sent by the net; a passed vote comes
   back as a result the server applies (a kick through the net, a map through the
   rotation).
4. **Server.** main.odin becomes server.odin; Server is settings, game, rotation,
   bots, net, vote; `init` builds Match_Settings and the net's settings from Settings.

### Stage 3: client

1. **The wire out of the game.** client/game/game.odin's receive and its parts, send,
   the clock, newest, seen_shot, my_lag, server_depth, the roster and the told-once
   queues move to client/net with Connection. What the HUD tells the game (weapons, a
   team, a line) it tells through the net.
2. **Predict and view as packages.** predict.odin becomes client/predict, owning
   pending, seq, the error and its measures, my_prev, `reconcile`, `predict_tick` and
   `drawn_pos`; view.odin becomes client/view. What is left of client/game is the
   shared Game, and the package goes: Client owns `game: game.Game` directly, with
   `me` beside it.
3. **Engine.** client/engine holds the window, the frame clock and ticks_owed from
   main.odin, and input/, render/ and audio/ move under it; Camera moves into render.
   hud's and editor's imports follow.
4. **Client.** main.odin becomes client.odin, App becomes Client with game, me,
   predict, view, net, engine and hud.

### Afterwards

docs/architecture.md's layout block and the tick listings are rewritten to the tree
above; docs/conventions.md's scopes become `geom`, `level`, `anim`, `weapons`, `game`,
`world`, `match`, `bot`, `net`, `client`, `server`, and the rules under "How Odin lets
us say it" move there as the way new code is placed. The readme's mentions of
shared/sim and client/game/predict.odin follow.

## What does not change

- **The entities' knot.** Soldier, Bullet, Thing, Ragdoll, History, Events and damage
  stay one package. Its files are already a struct each with a prefix, which is the
  in-package half of the rule.
- **The things pool, and the words.** See above: typed pools and renames are later
  steps, taken on purpose, not by the way.
- **pms, cvar, timer, the editor, hud, render's internals.** Already a struct per file,
  or a package that is one struct.
- **Behaviour, and the wire.** Every commit is a refactor. If a test wants changing,
  the change is wrong.
