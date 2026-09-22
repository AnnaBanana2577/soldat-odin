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

## Stage 0: a baseline to refactor against

Before touching anything, record what the game measures today, on main:

	odin run build.odin -file -- dev -sv_bots 6 -- -cl_headless -dbg_seconds 60

Keep the prediction error, the hits given and taken as agreed, and the bandwidth both
ways. Those numbers are the regression test for every stage below. The netcode is the
part of this codebase most easily broken by moving code, and the only thing that will
say so is a measurement.

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
	odin run build.odin -file -- dev -sv_bots 6 -- -cl_headless -dbg_seconds 60

The third is the one that matters. If the prediction error or the hits agreed move from
the Stage 0 baseline, the stage is wrong, however well it reads.

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

## The HUD lives under game/, and imports nothing from it

The HUD is the running game's, so it sits under `game/` and the server never learns it
exists. It stays its own package, and after Stage 3 it does not import `game` at all.

It looks at first as though it must. `client/hud` names `game` in forty-five places:
`game.Game` as a parameter type twenty-nine times, and eight procedures called fourteen
times between them. But look at what those procedures are:

	choose_team :: proc(g: ^Game, team: sim.Team) { append(&g.acts, net.Act{...}) }
	say         :: proc(g: ^Game, line: string, team: bool) { append(&g.said, chat) }
	call_kick   :: proc(g: ^Game, slot: u8, reason: string) { append(&g.called, v) }
	ask_map     :: proc(g: ^Game, index: int) { append(&g.asked, net.Map_Query{...}) }

Seven of the eight are appends to the outbox and touch no world state whatever. The HUD
is not depending on the game; it is reaching through `Game` to get at the outbox,
because the outbox is a field of `Game` today. Stage 3 takes the outbox out. After that
those calls go to the connection layer and the dependency is simply gone.

What is left is small and goes the right way:

- `name_of(g, slot)` is a roster lookup. The roster is client state, not world state,
  and belongs beside the outbox.
- `drawn_pos(g, slot, alpha)` is one line over `view_drawn_pos(view, world, slot,
  alpha)`, so what the HUD wants already exists at the level it wants it.
- `^game.Game` as a parameter becomes the world, the match and the view: `shared/sim`
  types, which the HUD may import freely.
- Two of the eight do a little more than append. `vote_yes` also clears `vote.active`,
  which is local interface state and belongs to the HUD anyway. `choose_weapons` also
  arms the soldier when it has not moved since spawning, which is the one genuine call
  into the simulation, and `sim.soldier_arm` is already public.

So the HUD ends up importing `shared/sim`, `shared/net` and `render`, and nothing above
it. `Client_Game` can own a `Hud` field with no cycle, which is what refactor.md wanted
and could not see a way to.

This changes the order: **Stage 3 must come before the HUD moves under `game/`.** Moving
it first would mean importing `game` for an outbox that is about to leave.
