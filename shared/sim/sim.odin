// Package sim is the game simulation, shared by the client and the server.
//
// Rules:
//   - No I/O, no rendering, no audio, no globals. Everything a step needs is in
//     Context (static data) and World (state).
//   - No allocation per tick: fixed-capacity arrays only.
//   - Randomness comes from World.rng only.
//   - Nothing in here wounds a soldier on its own. Bullets and blasts emit a Hit; the
//     server applies it through damage_apply. Health changes in one place.
//   - Everything else that happened is emitted as an Event too (sounds, sparks,
//     messages, the pickups, deaths and scores).
//
// Who runs what (server authority):
//   - The server runs the one true world with step() on everyone's commands and
//     applies the hits (damage_apply). What it sends is the world whole.
//   - A client rebuilds its world from the newest snapshot every tick and replays its
//     own pending commands on it (soldier_step, thing_claim, things_update,
//     bullets_update), which predicts everything they touch. It applies no wounds.
//   - Tools and tests run step() on a whole world, which does all of it at once.
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

// Buttons that count once when pressed. A command reused for one that never arrived
// drops them, so a press is never repeated.
ONE_SHOT :: Buttons{.Throw, .Change, .Prone, .Drop, .Suicide, .Flag_Throw, .Reload}

// One tick of input for one soldier. Numbered by the client that made it.
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
	round:    Round,
	flag_home: [2]Vec2, // where the alpha and bravo flags spawn and return to

	// Soldiers another process simulates (the clients' own, on the server): this world
	// never steps them, and their bullets never touch soldiers here (their client
	// reports the hits).
	ragdolls: [MAX_PLAYERS]Ragdoll, // the corpses, one per dead soldier
	history:  ^History, // the server's rewind for judging shots; nil elsewhere
}

world_init :: proc(w: ^World, seed: u64) {
	w^ = {}
	w.gravity = DEFAULT_GRAVITY
	w.rng = seed
}

DEFAULT_GRAVITY :: 0.06

// Everything at once: the tools' and tests' whole-world tick.
step :: proc(ctx: ^Context, w: ^World, cmds: []Command, events: ^Events) {
	events_clear(events)
	for &s, i in w.soldiers {
		if !s.active do continue
		soldier_step(ctx, w, u8(i), cmds[i], events)
	}
	things_update(ctx, w, events)
	bullets_update(ctx, w, events)
	round_tick(ctx, w, events)
	w.tick += 1
}
