package sim

import "core:fmt"
import "core:testing"

// The corpses: a body falls, lands and stays on top of the map, and bullets meet it
// where it lies — blood, a body slowing the shot down, and a corpse shot enough coming
// apart. Read against shared/sim/ragdoll.lua in ../soldat-love, which these numbers
// were compared with.

@(private = "file")
Fixture :: struct {
	level:  Level,
	anims:  ^Anims,
	skels:  ^Skeletons,
	ctx:    Context,
	world:  ^World,
	events: Events,
	seen:   Events, // every event of the run, since a tick clears its own
	cmds:   [MAX_PLAYERS]Command,
}

// A soldier of each team, landed and out of its spawn protection, on `map_name`.
@(private = "file")
fixture :: proc(map_name: string) -> (f: ^Fixture, ok: bool) {
	f = new(Fixture)
	f.level = level_load_file("assets", map_name) or_return
	f.anims = anims_load_files("assets") or_return
	f.skels = skeletons_load_files("assets") or_return
	f.ctx = {level = &f.level, anims = f.anims, skeletons = f.skels}
	weapons_default(&f.ctx.weapons)
	f.world = new(World)
	world_init(f.world, 4213)
	f.world.authority = true
	teams := []Team{.Alpha, .Bravo}
	for team, i in teams {
		pos := level_spawn_point(&f.level, team, &f.world.rng)
		soldier_spawn(&f.ctx, &f.world.soldiers[i], pos, team, .AK74, .Colt)
		f.world.soldiers[i].cease_fire_counter = -1
		f.cmds[i].aim = pos
	}
	for _ in 0 ..< 180 do step(&f.ctx, f.world, f.cmds[:], &f.events)
	return f, true
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	free(f.world)
	free(f.anims)
	free(f.skels)
	level_destroy(&f.level)
	free(f)
}

// A tick of everything, corpses included, with the respawn held off so the body stays.
@(private = "file")
tick :: proc(f: ^Fixture) {
	for &s in f.world.soldiers do if s.dead do s.respawn_counter = 100000
	step(&f.ctx, f.world, f.cmds[:], &f.events)
	apply_hits(f)
	for e in events_slice(&f.events) do emit(&f.seen, e)
}

// The server's half: the hits the tick reported become wounds.
@(private = "file")
apply_hits :: proc(f: ^Fixture) {
	reported := f.events.count
	for i in 0 ..< reported {
		if hit, is_hit := f.events.items[i].(Hit); is_hit do damage_apply(&f.ctx, f.world, hit, &f.events)
	}
}

@(private = "file")
kill :: proc(f: ^Fixture, index: u8, part: u8 = 12, amount: f32 = 10) {
	s := &f.world.soldiers[index]
	damage_apply(&f.ctx, f.world, Hit{shooter = index, target = index, amount = s.health + amount, part = part, pos = s.pos}, &f.events)
}

@(private = "file")
saw :: proc(f: ^Fixture, $T: typeid) -> bool {
	for e in events_slice(&f.seen) do if _, is := e.(T); is do return true
	return false
}

// How far into a polygon a corpse's points have sunk.
@(private = "file")
buried :: proc(f: ^Fixture, index: u8) -> f32 {
	s, r := &f.world.soldiers[index], &f.world.ragdolls[index]
	deepest: f32
	for i in 0 ..< POSE_POINTS {
		if i in RAGDOLL_NO_COLLIDE do continue
		for idx in sector_polys(&f.level, r.pos[i]) {
			poly := &f.level.polys[idx]
			if !soldier_collides_with(s, poly.type) || !point_in_poly(r.pos[i], poly) do continue
			if _, d, _ := closest_perpendicular(poly, r.pos[i]); d > deepest do deepest = d
		}
	}
	return deepest
}

@(test)
test_corpse_lands_on_the_map :: proc(t: ^testing.T) {
	f, ok := fixture("Arena")
	if !ok {
		fmt.eprintln("no assets/maps/Arena.pms; skipping")
		return
	}
	defer fixture_destroy(f)
	kill(f, 0)
	testing.expect(t, f.world.soldiers[0].dead, "the soldier didn't die")
	tick(f)
	r := &f.world.ragdolls[0]
	testing.expect(t, r.active, "no corpse for a dead soldier")
	testing.expect(t, r.torn == {}, "a normal death tore the body")
	head := r.pos[RAGDOLL_HEAD]

	// It slumps from standing and comes to rest on top of the ground, not in it.
	for _ in 0 ..< 240 do tick(f)
	testing.expect(t, r.pos[RAGDOLL_HEAD].y > head.y, "the body never dropped")
	testing.expect(t, vec2_length(r.pos[RAGDOLL_HEAD] - r.old_pos[RAGDOLL_HEAD]) < 0.5, "the body never came to rest")
	testing.expectf(t, buried(f, 0) < 5, "the body sank %.1f px into the map", buried(f, 0))
	testing.expect_value(t, f.world.soldiers[0].pos, r.pos[RAGDOLL_HEAD])
}

// The corpse is built from the state an update carries for a dead soldier, and nothing
// else: a client that was told only the server's half must still put the body where it
// fell rather than at the map's origin.
@(test)
test_a_corpse_starts_from_the_state_alone :: proc(t: ^testing.T) {
	f, ok := fixture("Arena")
	if !ok do return
	defer fixture_destroy(f)
	kill(f, 0)
	died_at := f.world.soldiers[0].death_pos
	testing.expect(t, died_at != {}, "no death position was kept")

	// Everything the wire leaves out of a dead soldier's word, gone.
	s := &f.world.soldiers[0]
	s.pos, s.old_pos, s.vel, s.forces = {}, {}, {}, {}
	tick(f)
	head := f.world.ragdolls[0].pos[RAGDOLL_HEAD]
	testing.expectf(t, vec2_length(head - died_at) < 30, "the corpse started at %v, not where it died (%v)", head, died_at)
}

// A body landing is heard, and the count quiets it as it settles, so a corpse rolling
// to a stop does not rattle on. How hard the landing was rides along on the event, for
// the client to put a bone crack on top of the thud.
@(test)
test_a_falling_corpse_is_heard :: proc(t: ^testing.T) {
	f, ok := fixture("Arena")
	if !ok do return
	defer fixture_destroy(f)
	kill(f, 0)
	tick(f)
	r := &f.world.ragdolls[0]
	for i in 0 ..< RAGDOLL_POINTS do r.old_pos[i].y += 9 // thrown up, so it comes down hard
	thuds := 0
	for _ in 0 ..< 300 {
		tick(f)
		for e in events_slice(&f.events) {
			v, is := e.(Corpse_Hit)
			if !is do continue
			testing.expect_value(t, v.target, u8(0))
			testing.expect(t, v.fall > CORPSE_THUD_FALL, "a landing too soft to hear was reported")
			testing.expect(t, v.count < CORPSE_THUD_HITS, "a body past its count was still heard")
			thuds += 1
		}
	}
	testing.expect(t, thuds > 0, "the body landed without a sound")
	testing.expectf(t, thuds <= CORPSE_THUD_HITS, "the body thudded %d times; the count should quiet it", thuds)
	testing.expect(t, r.dead_time >= 300, "the body's age was not counted")
}

@(test)
test_a_brutal_death_tears_the_body :: proc(t: ^testing.T) {
	f, ok := fixture("Arena")
	if !ok do return
	defer fixture_destroy(f)
	kill(f, 0, 12, 4 * DEFAULT_HEALTH)
	tick(f)
	want := Torn{CONSTRAINT_NECK - 1, CONSTRAINT_LEFT_LEG - 1, CONSTRAINT_RIGHT_LEG - 1,
	             CONSTRAINT_LEFT_ARM - 1, CONSTRAINT_RIGHT_ARM - 1}
	testing.expect_value(t, f.world.ragdolls[0].torn, want)
}

@(test)
test_bullets_meet_a_corpse :: proc(t: ^testing.T) {
	f, ok := fixture("Arena")
	if !ok do return
	defer fixture_destroy(f)
	kill(f, 0)
	for _ in 0 ..< 120 do tick(f) // let it settle
	r := &f.world.ragdolls[0]
	health := f.world.soldiers[0].health

	// A shot straight down into the corpse's chest, from clear of the ground.
	at := r.pos[8]
	speed := f.ctx.weapons[.AK74].speed
	events_clear(&f.seen)
	index, made := bullet_spawn(&f.ctx, f.world, at - {0, 40}, {0, speed}, .AK74, 1, f.ctx.weapons[.AK74].damage, &f.events)
	testing.expect(t, made, "no bullet")
	b := &f.world.bullets[index]
	for _ in 0 ..< 6 {
		tick(f)
		if !b.active || saw(f, Blood) do break
	}
	testing.expect(t, saw(f, Blood), "the shot drew no blood from the corpse")
	testing.expect(t, f.world.soldiers[0].health < health, "the corpse took no wound")
	testing.expect(t, !saw(f, Kill), "the corpse died a second time")
	testing.expect(t, !saw(f, Damage), "a corpse hit was counted as damage dealt")
	// Through a corpse, barely slowed, rather than stopped by it.
	testing.expect(t, b.active, "the bullet stopped in the corpse")
	testing.expect(t, vec2_length(b.vel) < speed, "the corpse didn't slow the bullet")
}

@(test)
test_a_corpse_shot_enough_comes_apart :: proc(t: ^testing.T) {
	f, ok := fixture("Arena")
	if !ok do return
	defer fixture_destroy(f)
	kill(f, 0)
	for _ in 0 ..< 120 do tick(f)
	testing.expect(t, f.world.ragdolls[0].torn == {}, "a normal death tore the body")

	// A hit on the head hard enough to take it off, as Die does on a corpse.
	damage_apply(&f.ctx, f.world, Hit{shooter = 1, target = 0, amount = 200, part = 12, pos = f.world.soldiers[0].pos}, &f.events)
	tick(f)
	testing.expect(t, CONSTRAINT_NECK - 1 in f.world.ragdolls[0].torn, "the head stayed on")

	// And enough more to take it all apart, wherever the last hit landed.
	damage_apply(&f.ctx, f.world, Hit{shooter = 1, target = 0, amount = 4 * DEFAULT_HEALTH, part = 7, pos = f.world.soldiers[0].pos}, &f.events)
	tick(f)
	testing.expect(t, CONSTRAINT_LEFT_ARM - 1 in f.world.ragdolls[0].torn, "an arm stayed on a gibbed corpse")
}
