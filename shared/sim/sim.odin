// Package sim is the game simulation, shared by the client and the server.
//
// Rules:
//   - No I/O, no rendering, no audio, no globals. Everything a step needs is in
//     Context (static data) and World (state).
//   - No allocation per tick: fixed-capacity arrays only.
//   - Randomness comes from World.rng, from a soldier's own rng for what its player
//     rolls (the spread of a shot), and from a bullet's own numbers for what happens
//     to it in flight, so a bullet flies the same on every machine.
//   - Nothing in here wounds a soldier on its own. Bullets and blasts emit a Hit; the
//     server applies it through damage_apply. Health changes in one place.
//   - Everything else that happened is emitted as an Event too (sounds, sparks,
//     messages, the pickups, deaths and scores).
//
// Who runs what. Every machine runs this same simulation on its own world, and one
// flag on the world, authority, marks the server's: the one that decides.
//   - The server steps every soldier (soldier_step), on the commands its client sent or
//     on its bot's brain. A client steps its own the same way, on the same commands, to
//     predict it; the others it draws from the server's word and never steps.
//   - Every machine flies every bullet and moves every thing, so the blood, the sparks
//     and the sounds are local everywhere.
//   - Only with authority do hits become wounds (damage_apply), are things made, taken,
//     returned and scored, do the dead respawn, and does the map's own harm count
//     (soldier_served_tick, match_tick). A bullet there meets the soldiers as its
//     shooter saw them (history).
//   - Tools and tests run step() on a whole world with authority, which does all of it
//     at once.
//
// Files, one per object:
//   soldier, movement, soldier_anim, combat, antics, soldier_collision
//   bullet, bullet_collision, explosion, damage
//   thing (the pool and its physics), flag, kit, dropped_gun, parachute, stat_gun
//   ragdoll (the corpses)
//   round (the clock), event
package sim

TICK_RATE :: 60
TICK      :: 1.0 / f64(TICK_RATE)

MAX_PLAYERS :: 32
MAX_BULLETS :: 512
MAX_THINGS  :: 64

Vec2 :: [2]f32

Button :: enum u8 {
	Left, Right, Jump, Crouch, Prone, Jet, Fire, Throw, Reload, Change, Suicide, Drop, Flag_Throw,
}
Buttons :: bit_set[Button; u16]

// Buttons that count once when pressed, however long they are held.
ONE_SHOT :: Buttons{.Throw, .Change, .Prone, .Drop, .Suicide, .Flag_Throw, .Reload}

// One tick of input for one soldier, numbered by the client that made it: the server
// runs them in order and says which it has run, and the client replays the rest over
// what the server sent (client/game/predict.odin).
Command :: struct {
	seq:     u32,
	buttons: Buttons,
	aim:     Vec2, // world-space cursor
}

Team :: enum u8 { None, Alpha, Bravo, Charlie, Delta, Spectator }

// Static data a step reads and never writes.
Context :: struct {
	level:     ^Level,
	anims:     ^Anims,
	weapons:   Weapons,
	skeletons: ^Skeletons, // the things' particle objects
}


World :: struct {
	tick:     u32,
	gravity:  f32,
	rng:      u64,
	soldiers: [MAX_PLAYERS]Soldier,
	bullets:  [MAX_BULLETS]Bullet,
	things:   [MAX_THINGS]Thing,
	match:    ^Match,  // borrowed: the game owns the match, as it owns the world
	flag_home: [2]Vec2, // where the alpha and bravo flags spawn and return to

	ragdolls: [MAX_PLAYERS]Ragdoll, // the corpses, one per dead soldier
	history:  ^History, // the server's rewind for judging shots; nil elsewhere

	// This world decides: things are made, taken, returned and scored here, and the dead
	// respawn. Elsewhere (a client's world) things only move, and what was decided
	// arrives as facts.
	authority: bool,
}

world_init :: proc(w: ^World, seed: u64) {
	w^ = {}
	w.gravity = DEFAULT_GRAVITY
	w.rng = seed
}

DEFAULT_GRAVITY :: 0.06

// Everything at once, in the order the server and the clients run it: the tools' and
// tests' whole-world tick.
step :: proc(ctx: ^Context, w: ^World, cmds: []Command, events: ^Events) {
	events_clear(events)
	for &s, i in w.soldiers {
		if !s.active do continue
		soldier_step(ctx, w, u8(i), cmds[i], events)
	}
	ragdolls_update(ctx, w, events)
	things_update(ctx, w, events)
	bullets_update(ctx, w, events)
	match_tick(ctx, w, events)
	w.tick += 1
}
