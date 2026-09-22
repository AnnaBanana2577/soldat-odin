# Refactoring plan

What [refactor.md](refactor.md) settles on, against what the code already is, and the
order to close the gap in. Every stage is a branch off main, small enough to merge
within a day, because the gameplay and HUD work in flight touches the same files.

## What the code already does

Most of the target architecture is here. Worth saying plainly so the refactor stays
small:

- `sim.World` already holds the entities (`soldiers`, `bullets`, `things`, `ragdolls`)
  and is already shared by the client, the server and the headless tests.
- Entities already own their behaviour: `soldier_step`, `bullets_update`,
  `things_update`, `ragdolls_update`, `bot_command`.
- The "small deliberate World API" the conversation asks for largely exists:
  `damage_apply`, `bullet_spawn`, `bullet_end`, `thing_create`, `dropped_gun_*`,
  `kit_give`, `soldier_spawn`.
- The renderer already knows nothing of simulation internals: `render.Map_View` takes a
  level and draws it, and the editor reuses it.
- `shared/net` already serialises pieces of the world rather than the whole thing.

So this is not a rewrite. It is four pieces of coupling and one application-shape
change.

## Stage 0: the baseline, taken

Five runs on the refactor branch at ce28f5b, sixty seconds each against six bots:

	odin run build.odin -file -- dev -no-build -sv_bots 6 -- -cl_headless -dbg_seconds 60

	run   shots seen/ruled   given s/r   taken s/r   pred mean   pred worst   up    down
	1        33 / 33           0 / 1      18 / 12      0.01         2.38      3.2   29.2
	2        34 / 34           5 / 6       4 / 4       0.00         0.41      3.3   29.9
	3        49 / 49           5 / 8      20 / 19      0.02         1.17      3.3   29.4
	4        39 / 40          18 / 15     35 / 32      0.03         6.56      3.3   32.0
	5        25 / 25           7 / 7      31 / 26      0.02         0.82      3.2   32.0

The bots are seeded from the clock, so no two runs fight alike. That is why there are
five, and why the useful output of this stage is not a number but a division: which of
these can gate a refactor, and which are too loose to mean anything.

**Gate on these.** They barely move, so a change in them is a change in the code:

- *Shots seen against shots ruled*, which agreed exactly in four runs of five and by one
  in the fifth. The best signal here by some way.
- *Prediction error, mean*: 0.00 to 0.03 units.
- *Uplink*: 3.2 to 3.3 KB/s.
- *The others shown 3 ticks behind*, and *2 commands waiting*, both constant across all
  five.

**Do not gate on these.** They swing with how much the bots happen to fight:

- *Hits taken, seen against ruled*: 150%, 100%, 105%, 109%, 119%. The client counts more
  hits on itself than the server rules, which is known and written up under Netcode in
  todo.md, but the spread is far too wide to read a regression in.
- *Prediction error, worst*: 0.41 to 6.56, tracking the number of deaths. Run 4 had five
  of them.
- *Downlink*: 29.2 to 32.0 KB/s.

So a stage passes if the shots still agree, the mean prediction error stays at or under
0.03, the uplink stays near 3.2, and the interpolation and queue depth do not move. If
one of the loose numbers looks wrong, run it five more times before believing it.

Two things worth noting from taking it. The harness lost the ruled line entirely at
first, which ce28f5b fixes; and the client over-counting hits taken is visible in every
run, so it is a property of the code and not of a bad afternoon.

## Stage 1: Match beside World, not inside it

`Round` sits inside `World` today; the rest of what makes a match sits on the server's
`Game` as `rules`, `map_index` and `map_name`. The conversation wants one `Match` that
is a sibling of `World`.

- `shared/sim/round.odin` becomes `match.odin`, `Round` becomes `Match`, and it gains
  the map rotation and the limits now held in the server's `Rules`.
- `World` loses `round`. A new `Game_State { world: World, match: Match }` holds both,
  or the two are passed side by side; the name only earns its place if it is used.
- The wire carries the match where it carries the round now, so `net.Update` changes
  shape and `net.VERSION` goes up.

Touches the protocol, so it goes first while the surface is smallest.

## Stage 2: the content out of the game

Both `Game` structs carry `ctx`, `level`, `anims`, `skeletons`, `base` and `map_name`.
That is loaded content, not game state, and it is why both structs read as grab-bags.

- A `Content` struct owns the map, the animations, the skeletons and the weapon table,
  loaded once and borrowed by the simulation.
- `sim` procedures already take `ctx` as their first argument, so most call sites change
  in name only.

No wire change, no behaviour change. The largest clarity win for the least risk.

## Stage 3: the networking out of the game

The stage the rest depends on. It is what frees the HUD, so it comes early.

**What moves.** On the client, `pending`, `seq`, `acts`, `called`, `asked`, `said`,
`seen_shot` and `newest` are an outbox and an inbox, not game state. On the server,
`clients`, `born`, `ends`, `shot_seq` and `things_sent` are the same. What is left on
either `Game` is the world, the match, and the prediction the client needs (`view`,
`error`, the clock). A `Server_Game` then really is `{ world, match }`.

**The shape the outbox lands in.** It becomes a struct in `subsystems/net`, below both
the game and the HUD, with procedures named for it:

	Outbox :: struct {
	    acts:   [dynamic]net.Act,
	    said:   [dynamic]net.Chat,
	    called: [dynamic]net.Vote,
	    asked:  [dynamic]net.Map_Query,
	}

	outbox_join_team :: proc(o: ^Outbox, team: sim.Team)
	outbox_say       :: proc(o: ^Outbox, line: string, team: bool)
	outbox_vote      :: proc(o: ^Outbox, v: net.Vote)
	outbox_ask_map   :: proc(o: ^Outbox, index: int)
	outbox_loadout   :: proc(o: ^Outbox, primary, secondary: sim.Weapon_Id)

The eight procedures the HUD calls on `Game` today move here, and the HUD takes an
`^Outbox` where it takes a `^game.Game` now. The call count does not change and neither
does the directness; what changes is that the arrow points down.

The rule this follows, worth stating once: **a module the HUD calls is fine, as long as
it sits below the HUD.** The trouble was never that the HUD mutates something. It was
that it reached up into the thing that owns it.

**Two that are not plain appends.** `vote_yes` also clears `vote.active`, which is local
interface state and stays with the HUD. `choose_weapons` also arms the soldier when it
has not moved since spawning, so the HUD calls `outbox_loadout` and `sim.soldier_arm`,
both of which are below it.

**Intents, deferred.** The HUD could instead return a `Hud_Intent` union for the client
to drain, which would make it a pure function of state in to picture and intents out,
and testable with no network and no game. Not now: fourteen call sites do not pay for a
drain loop, and the ordering it usually buys is already there, since `hud.input` runs
before the game tick and says what it took. Worth revisiting the day the HUD wants
tests, and the conversion is mechanical once the calls go to one module.

## Stage 4: Client_Game, and App becomes Client

`App` already is the conversation's `Client`, flat: `game`, `camera`, `render`, `hud`,
`audio`, `input`, `conn` side by side.

- `Client_Game { state: Game_State, hud: Hud, camera: Camera }`, per the conversation's
  own revision: the HUD is the running game's, and the server must never know it exists.
- `App` becomes `Client`, holding `game: Client_Game`, the renderer, the audio, the
  input and the connection.

## Stage 5: the editor as a mode

Today `-cl_editor` returns early from `main` before the loop, so the editor has its own
window handling and cannot be entered or left while the game runs.

- `Client_Mode :: enum { Game, Editor }`, with `Menu` and `Console` to come.
- One window, one renderer, one input, and `client_update` and `client_draw` switching
  on the mode.

This one is worth doing for its own sake, not only for tidiness: it is what lets the
editor open on a map, test it in the game and come back.

## Deferred: stable entity IDs

The conversation recommends `Entity_ID` over array indices. Not worth it here, and it is
worth writing down why rather than leaving it to be raised again.

The indices in this codebase are already stable. `soldiers`, `bullets` and `things` are
fixed arrays with an `active` flag, never compacted; a soldier's index is its slot for
as long as it plays. That is what an entity id buys, and it is already bought.

Against that, the indices are on the wire in a dozen places: the slot in every update
entry, `Bullet_End.id`, the thing index, the entity mask the delta compression is built
on, and the rewind history. Adding a stable id means a lookup on every one of those, in
the part of the codebase with the least margin for a mistake.

Revisit it if entities ever become dynamic. Until then it costs the netcode and buys
nothing.

## Order, and why

	6, 3, 1, 2, 4, 5, then the folders

**6** first: self-contained, no protocol change, and every folder move afterwards
assumes the subsystems import only `shared/`.

**3** next, because it is what frees the HUD. Until the outbox leaves `Game` the HUD
must reach through it, and nothing above can be arranged honestly.

**1** and **2** then: the shared core, each making the next smaller. 1 changes the wire,
so it wants a quiet moment; 2 is the safest change in the plan and can go whenever.

**4** and **5** last of the code, since both need 3 to have emptied the `Game` structs.

**The folders move at the end**, when the imports already obey the layering the names
claim. Moving them earlier writes a promise the code has not made yet.

## The gate on every stage

	odin run build.odin -file -- check
	odin run build.odin -file -- test
	odin run build.odin -file -- dev -no-build -sv_bots 6 -- -cl_headless -dbg_seconds 60

The third is the one that matters, read against the Stage 0 table and only on the
numbers that stage found tight enough to read: the shots agreeing, the mean prediction
error at or under 0.03, the uplink near 3.2 KB/s, three ticks of interpolation and two
commands waiting.

A stage that moves one of those has broken something, however well it reads. A stage
that moves only the hits taken, the worst-case error or the downlink has probably moved
nothing: those swing with the bots, and five more runs will usually say so.

## Conventions

**A top-level struct per program.** `Client` and `Server`, each with
`client_init` / `client_run` / `client_destroy` beside it, and a `main.odin` that does
nothing but call the three. The server is already shaped this way. The client is not:
`App` is the `Client` under another name, and its loop is inlined in `main` on purpose
(3e45c33), so that a frame reads top to bottom. Keep that: `client_run` is that same
frame, moved, not broken into update and draw.

**Procedures are `structname_*`,** unless the package exists for that one struct and its
name already serves. `shared/sim` holds many types and prefixes them all
(`soldier_spawn`, `bullet_spawn`); a package that is one type would stutter as
`hud.hud_draw`. Odin's own core draws the line in the same place: `strings.Builder` with
`strings.builder_init`, never `strings.strings_builder_init`.

**The folders show the layering.** Not the whole graph, which is a DAG and will not fit
in a tree, but the layers:

	client/
	  main.odin          three lines
	  client.odin        Client, Client_Mode, init / run / destroy
	  subsystems/        depend on shared/ and on nothing above them
	    render/
	    audio/
	    input/
	    net/
	  game/              the running game: world, match, hud, camera
	  editor/

Everything under `subsystems/` must import only `shared/`. That is the rule the folder
name is making, and it is worth something only if it is true.

## Stage 6: the subsystems stop importing the game

`client/render` and `client/audio` import `client/game` today, which under the layout
above would be a subsystem importing the layer above it. The fix is small: both take
`^game.Game` only as a parameter type, four procedures in render and three in audio.

- They take what they read instead: the world, the view, the events, the level.
- `drawn_pos` is already a one-line wrapper over `view_drawn_pos(view, world, slot,
  alpha)`, so the thing render wants exists at the right level already.

Do this before moving any folders. Moving them first would encode a layering the imports
do not obey.

## What earns its own package

A thing gets its own package when it can be isolated: when it needs nothing above it.
Depending on `subsystems/` does not count against it, since everything depends on those.
Anything else is a file in the package it belongs to.

The rule already describes the best-organised part of this codebase. `shared/sim` is
thirty-three files in one package because a bullet cannot be isolated from the soldier
it wounds or the thing it pushes, and pretending otherwise would buy a boundary and pay
for it at every call.

Applied here:

- `render`, `audio`, `input`, `net`: after Stage 6 each imports only `shared/`, so each
  is isolable and keeps its package, under `subsystems/`.
- `editor`: imports `pms`, `sim` and `render`, all at or below it. Isolable, so it
  keeps its own package.
- **`hud`: not isolable. A file in `game/`.**

The HUD reads sixteen fields of `Game` and thirteen of them are `Client_Game` state
rather than `shared/sim`: `me`, `my_lag`, `lags`, `names`, `bots`, `vote`, `heard`,
`map_list`, `map_name`, `primary`, `secondary`, `events`. Only `world`, `ctx` and
`level` are shared types. To make it a package you would pass thirteen things, or invent
a `Hud_View` that is most of `Client_Game` under another name: a boundary that exists on
paper and is paid for at every call site.

So `client/game/` holds `hud.odin`, `kill_feed.odin`, `scoreboard.odin`, `chat.odin`,
`menus.odin` and the rest beside `world.odin`, `predict.odin` and `view.odin`, with
procedures named for what they act on: `hud_draw`, `view_advance`, `game_tick`.

Stage 3 is still worth doing and still comes early, but for its own sake rather than the
HUD's: it empties `Game` of the outbox so `Server_Game` is `{ world, match }`. What it
does not do is make the HUD isolable, which is what an earlier draft of this plan
claimed. The eight action procedures move to the outbox because that is where they
belong, not because the HUD needs them moved to escape.

## What belongs in subsystems, and what does not

`subsystems/` is for what is generic: what depends only on `shared/` and knows nothing
of a running client. Isolable and generic are not the same test, and the first one alone
would put the whole of `client/render` there, which would be wrong: it draws soldiers.

The editor settles where the line falls, because it renders maps without a game and so
uses exactly the generic half. It names `Map_View`, `Map_Parts`, `map_view_load`,
`map_view_draw`, `map_view_bounds`, `map_view_unload`, `Camera`, `camera_fit`,
`camera_pan`, `camera_zoom_at`, `rl_camera`, `pixels_per_unit` and `color_of`. It names
nothing from `gostek`, `bullet_art`, `things_art` or `sparks`.

So:

	subsystems/gfx/     textures, sprite, camera, map_view, minimap, color_of
	subsystems/input/   keys and mouse
	subsystems/net/     the link, the outbox, the simulated line

	game/render/        gostek, bullet_art, things_art, sparks, the Scene
	game/audio/         whole: the sounds and which event plays them
	game/               world, match, predict, view, hud

`gfx` draws a map, a sprite, a camera: anything with a level can use it, and the editor
does. `game/render` draws *this game*: the gostek from a pose, the bullet art by style,
the sparks from the events. It is isolable, taking the state it draws as arguments, but
it is not generic and has no business under `subsystems/`.

The same split runs through the sound. Loading a wav, placing it by distance and holding
a listener is generic; knowing that a Fire event of a Flamer plays flamer.wav is the
game's.

Stage 6 stands either way. Cutting `render` and `audio` free of `game` is what makes
both halves placeable at all, and it is done. Where the halves go is a folder move, and
the folders move last.

## How many subsystems, and the test for one

raylib does not write these for us. It hands out primitives; the decisions are ours, and
the counts say so: `render` names the simulation 133 times against 102 raylib calls,
`audio` 59 against 23. Where a texture sits in a mod's layout, how a sound is placed by
distance, how keys become a `sim.Command`: raylib has no opinion on any of it.

But the test for a package is not whether raylib already did the work, and it is not
only whether the thing is isolable. It is **how many consumers the boundary has**. One
consumer is a filing decision. Two is an interface.

	                lines   rl.   sim.   consumers
	render           1649   102    133   game, editor
	audio             534    23     59   game
	input              86     4     18   game
	connection        145     0      0   game

So two subsystems, not four:

- **`gfx`** earns it: 607 lines of textures, sprite, camera, map_view, minimap and
  `color_of`, wanted by the editor and the running game alike. Two consumers is what
  made splitting `render` real rather than tidy.
- **`net`** earns it: the link and the simulated line now, the outbox after Stage 3.
  No raylib, no simulation, pure transport.
- **`input`** keeps the package it already has, at 86 lines and one consumer. Not worth
  defending, not worth moving either.
- **`sound` is not made.** `audio` is 534 lines with one consumer, and the generic half
  of it is perhaps a hundred: loading, playing, placing by distance. The editor is what
  justified splitting `render`, because it draws maps. Nothing else in this codebase
  makes a sound. `audio` stays whole under `game/` until something does, and if the
  editor ever previews one, revisit it then.
