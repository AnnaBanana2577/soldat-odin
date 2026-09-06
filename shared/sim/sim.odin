// Package sim is the game simulation, shared by the client and the server.
//
// Rules:
//   - No I/O, no rendering, no audio, no globals. Everything a step needs is in
//     Context (static data) and World (state).
//   - No allocation per tick: fixed-capacity arrays only.
//   - Randomness comes from World.rng only.
//   - Nothing in here wounds a soldier on its own. Bullets and blasts emit a Hit; the
//     caller applies it through damage_apply (the client for its own shots, the
//     server for bots' and for the claims it settles). Health changes in one place.
//   - Everything else that happened is emitted as an Event too (sounds, sparks,
//     messages, and the pickups, deaths and scores the server relays as commits).
//
// Who runs what (client authority, a relaying and refereeing server):
//   - A client steps its own soldier (soldier_step), flies every bullet it knows of,
//     runs the things on from what the server last sent of each (w.things_relayed:
//     it makes none itself), and dead-reckons the others.
//   - The server steps nobody's soldier (w.humans). It makes and moves the things,
//     runs the round (round_tick) and settles claims (thing_grant, damage_apply).
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
	humans: bit_set[0 ..< MAX_PLAYERS],
	ragdolls: [MAX_PLAYERS]Ragdoll, // the corpses, one per dead soldier
	things_relayed: bool, // this world's things come from the server: thing_create makes none here
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
		if !s.active || i in w.humans do continue
		soldier_step(ctx, w, u8(i), cmds[i], events)
	}
	things_update(ctx, w, events)
	bullets_update(ctx, w, events)
	round_tick(ctx, w, events)
	w.tick += 1
}
