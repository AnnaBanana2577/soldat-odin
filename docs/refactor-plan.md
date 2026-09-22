# Refactoring plan

What [refactor.md](refactor.md) is after, arranged the way Odin wants it: one package
per program, with file names and procedure prefixes doing the organising that packages
were being asked to do.

This plan changed shape several times before it settled here. The corrections are kept
at the end, under "What this plan got wrong on the way", because each was found by
counting something in the code rather than by argument.

## The shape

	shared/         one package: the simulation and the wire
	shared/cvar/    standalone: a name, a value, a default, a line of help
	shared/pms/     standalone: the map file codec
	shared/timer/   standalone: a fine sleep on Windows

	client/         one package: game, hud, render, audio, input, connection, editor
	server/         one package

Three things keep their own package because they pass the test literally: no knowledge
of this game, one direction only, usable by anything. Everything else folds into the
program it serves.

## Why one package

Odin forbids circular imports. Fine-grained packages inside one program therefore spend
their time wanting something they cannot have, and the design bends around the
constraint instead of the problem. Four exchanges went into where the HUD should live,
and that question only exists because of packages.

The argument that settles it: **packages prevent cycles, not direction.** Nothing in the
compiler stopped `hud` importing `game`, and nothing would have stopped `render` reading
the game forever. That was found by reading imports, not by a build failing. The
boundaries were never enforcing the layering they appeared to, and one package stops
cycles by construction.

The practical cost is eight names. Of 282 top-level procedures in `client/`, exactly
eight are used twice: `tick`, `init`, `destroy`, `draw`, `send`, `sample`, `receive` and
`minimap_draw`. Every one is a lifecycle name the prefix convention renames anyway.

What it costs that is real: `#+private` in fifteen files, and the compiler noticing an
accidental upward dependency. In a package of forty files nothing stops someone having
`render` read `Game.view` again. That discipline moves from the build to the naming and
to review, which is a trade rather than a free win.

## Conventions

**A top-level struct per program.** `Client` and `Server`, with `client_init` /
`client_run` / `client_destroy` beside them, and a `main.odin` that calls the three and
nothing else. The server is nearly there already. The client's loop is inlined in `main`
on purpose (3e45c33) so that a frame reads top to bottom: `client_run` is that same
frame moved, not split into update and draw.

**Procedures are named for the struct they act on.** `hud_draw`, `render_tick`,
`view_advance`, `game_tick`, `outbox_say`. With one package per program, the exception
that used to apply, where a package name already served, is gone. The rule is plain.

**File names organise.** `hud.odin`, `kill_feed.odin`, `scoreboard.odin`, `predict.odin`
and `view.odin` sit beside each other in `client/`, as `shared/sim`'s thirty-three files
already do. That package is the model: one package, because a bullet cannot be isolated
from the soldier it wounds, and a boundary there would be paid for at every call.

**The editor lives in the client package.** It uses the renderer and `main` dispatches
to it, so anything else is a cycle.

## Done already

- **The baseline** (below), and the harness fix that made it trustworthy.
- **`render` and `audio` stopped reading the game** (12294d4). Still right: handing over
  a `Scene` of what is drawn beats handing over the whole game, whether or not a
  compiler is watching. The justification changes from "breaks a cycle" to "keeps it
  honest".
- **The outbox left `Game`** (b965701). Still right, for its own reason: the queues a
  client fills for the server were never game state.

Neither is wasted by the change of shape. Both would be worth doing inside one package.

## Stage 1: the packages collapse

First, because every stage after it is smaller once the constraint is gone, and because
doing the rest under a rule already decided against means doing it twice.

- `client/*/` and `server/*/` lose their `package` lines and move up; the directories
  go.
- The eight colliding names take their prefix.
- Imports of the folded packages go. Imports of `cvar`, `pms` and `timer` stay.
- `shared/sim` and `shared/net` become one `shared`.

Mechanical, and large in the diff. It touches every file, so it wants a moment when the
editor work is at a commit rather than mid-thought.

## Stage 2: Match beside World

`Round` sits inside `World`, and the rest of what makes a match sits on the server as
`rules`, `map_index` and `map_name`. One `Match` beside `World`, holding the limits and
the rotation. Touches the wire, so `net.VERSION` goes up.

## Stage 3: the content out of the game

Both `Game` structs carry `ctx`, `level`, `anims`, `skeletons`, `base` and `map_name`.
That is loaded content rather than game state, and it is most of why both read as
grab-bags. A `Content` struct owns it, loaded once and borrowed.

No wire change and no behaviour change: the most clarity for the least risk in the plan.

## Stage 4: the networking out of the server's game

The client's half is done. The server's `clients`, `born`, `ends`, `shot_seq` and
`things_sent` are the same thing, and are not game state. After this a server's game
really is the world and the match, which is what refactor.md is after.

Left on purpose from the client's half: `pending`, `seq`, `seen_shot` and `newest`.
`pending` is read by the replay as much as by the send, so it is prediction state as
much as network state and deserves its own gate rather than a ride on a queue move.

## Stage 5: Client and Server

`App` is already the `Client` under another name. It becomes one, holding a
`Client_Game` of the world, the match, the prediction, the camera and the HUD, since the
HUD is the running game's and the server must never learn that it exists.

## Stage 6: the editor as a mode

`-cl_editor` returns from `main` before the loop, so the editor has its own window
handling and can be neither entered nor left while the game runs. A `Client_Mode` enum
of `Game` and `Editor`, with `Menu` and `Console` to come, one window and one renderer
between them, and `client_run` switching on it.

Worth doing for itself rather than for tidiness: it is what lets the editor open a map,
try it in the game, and come back.

## Deferred: stable entity IDs

refactor.md recommends `Entity_ID` over array indices. Not here, and the reason is worth
writing down so that it is not raised again.

The indices are already stable. `soldiers`, `bullets` and `things` are fixed arrays with
an `active` flag, never compacted, and a soldier's index is its slot for as long as it
plays. That is what an entity id buys, and it is bought. Against it, those indices are
on the wire in a dozen places, including the mask the delta compression is built on and
the rewind history.

Revisit if entities ever become dynamic.

## Stage 0: the baseline, taken

Five runs at ce28f5b, sixty seconds each against six bots:

	odin run build.odin -file -- dev -no-build -sv_bots 6 -- -cl_headless -dbg_seconds 60

	run   shots seen/ruled   taken s/r   pred mean   pred worst   up    down
	1        33 / 33          18 / 12      0.01         2.38      3.2   29.2
	2        34 / 34           4 / 4       0.00         0.41      3.3   29.9
	3        49 / 49          20 / 19      0.02         1.17      3.3   29.4
	4        39 / 40          35 / 32      0.03         6.56      3.3   32.0
	5        25 / 25          31 / 26      0.02         0.82      3.2   32.0

The bots seed from the clock, so no two runs fight alike. The useful output of this
stage is therefore not a number but a division.

**Gate on these**, which barely move: shots seen against shots ruled, exact in four runs
of five and off by one in the fifth; mean prediction error, 0.00 to 0.03; uplink, 3.0 to
3.3 KB/s; three ticks of interpolation and two commands waiting, constant throughout.

The uplink band is wider than these five runs showed. They landed 3.2 to 3.3 and the
next four stages read 3.0 to 3.3 without touching anything a client sends, so the table
above is a narrow sample rather than a tight number. Five runs is enough to say what a
metric roughly does and not enough to fix its edges.

**Do not gate on these**, which swing with the bots: hits taken, seen against ruled,
which ran 150, 100, 105, 109 and 119 per cent; worst-case prediction error, 0.41 to
6.56, tracking deaths; downlink, 29.2 to 32.0.

## The gate on every stage

	odin run build.odin -file -- check
	odin run build.odin -file -- test
	odin run build.odin -file -- dev -no-build -sv_bots 6 -- -cl_headless -dbg_seconds 60

A stage that moves a tight number has broken something, however well it reads. A stage
that moves only a loose one has probably moved nothing, and five more runs will say so.

**What the gate does not cover, which matters more.** A headless client opens no menus,
says nothing and votes on nothing, so it exercises none of the outbox, the chat, the
votes or the HUD. Five green runs after the outbox moved proved only that the outbox was
not being used. That path was checked on its own instead, with `-dbg_vote "map Arena"`
against a server whose rotation holds Arena: the map loads, and does not load in the
same run without the vote.

Stages 5 and 6 move HUD and client code, which the gate covers less still. Each wants a
targeted check of its own, or the green runs mean nothing.

## What this plan got wrong on the way

Kept because each was corrected by evidence, and the evidence is the useful part.

- **"The HUD must share a package with the game, or they import each other."** True of
  the cycle, wrong about the fix: the HUD's eight calls into the game are outbox
  appends, and moving the outbox settles them.
- **"Then the HUD can be its own package."** Also wrong. It reads sixteen fields of
  `Game` and thirteen are client state rather than simulation. Fixing the actions left
  the reads.
- **"A package for anything isolable."** Isolable and generic are different tests, and
  `render` is the first but not the second: it names the simulation 133 times against
  102 raylib calls.
- **"Four subsystems."** Two at most, counted by consumers: `gfx` had the editor and the
  game, `sound` had only the game. And then none, once the packages collapse.

The pattern in all four: every question about where a boundary belongs was answered by
counting something in the code. None was answered by reasoning about architecture.
