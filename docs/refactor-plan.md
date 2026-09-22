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

- Client: `pending`, `seq`, `acts`, `called`, `asked`, `said`, `seen_shot` and `newest`
  are an outbox and an inbox, not game state. They move to the connection layer.
- Server: `clients`, `born`, `ends`, `shot_seq` and `things_sent` move the same way.
- What is left on either `Game` is the world, the match, and the prediction the client
  needs (`view`, `error`, the clock).

After this a `Server_Game` really is `{ world, match }`, which is what the conversation
is after.

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

1, 2 and 3 are the shared core and go first: they are what the client and the server
both sit on, and each one makes the next smaller. 4 and 5 are the client's shape and
depend on 3 having emptied the `Game` structs.

## The gate on every stage

	odin run build.odin -file -- check
	odin run build.odin -file -- test
	odin run build.odin -file -- dev -sv_bots 6 -- -cl_headless -dbg_seconds 60

The third is the one that matters. If the prediction error or the hits agreed move from
the Stage 0 baseline, the stage is wrong, however well it reads.
