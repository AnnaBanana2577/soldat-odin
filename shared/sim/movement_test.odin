package sim

import "core:fmt"
import "core:testing"
import "../polymap"

// The rolls and the backflip, against OpenSoldat Control.pas: which way a crouch while
// running throws the body, what the two animation machines do while it turns, what the
// roll costs and leaves behind, and the jet flip out of a side jump. Traced tick for
// tick against the same moves in ../soldat-love, which agrees with this.

@(private = "file")
Fixture :: struct {
	level:  polymap.Polymap,
	anims:  ^Anims,
	skels:  ^Skeletons,
	ctx:    Context,
	world:  ^World,
	events: Events,
	cmds:   [MAX_PLAYERS]Command,
	aim:    Vec2, // where the cursor is held, which is what `direction` follows
}

// One soldier, landed and out of its spawn protection, facing `aim_x` from its feet.
@(private = "file")
fixture :: proc(aim_x: f32) -> (f: ^Fixture, ok: bool) {
	f = new(Fixture)
	f.level = polymap.load_file("assets", "Arena") or_return
	f.anims = anims_load_files("assets") or_return
	f.skels = skeletons_load_files("assets") or_return
	f.ctx = {level = &f.level, anims = f.anims, skeletons = f.skels}
	weapons_default(&f.ctx.weapons)
	f.world = new(World)
	world_init(f.world, 99)
	f.world.authority = true
	round_init(&f.world.round)
	s := &f.world.soldiers[0]
	soldier_spawn(&f.ctx, s, spawn_point(&f.level, .Alpha, &f.world.rng), .Alpha, .AK74, .Colt)
	s.cease_fire_counter = -1
	f.aim = {aim_x, 0}
	hold(f, {}, 120) // land and come to rest
	return f, true
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	free(f.world)
	free(f.anims)
	free(f.skels)
	polymap.destroy(&f.level)
	free(f)
}

// `n` ticks with these buttons held, the cursor kept where the fixture put it.
@(private = "file")
hold :: proc(f: ^Fixture, buttons: Buttons, n: int) {
	s := &f.world.soldiers[0]
	for _ in 0 ..< n {
		f.cmds[0] = {seq = f.cmds[0].seq + 1, buttons = buttons, aim = s.pos + f.aim}
		step(&f.ctx, f.world, f.cmds[:], &f.events)
	}
}

// Runs until the soldier is on the ground with the legs running, so that the crouch
// that follows is the one the roll is entered from. False if it never settles.
@(private = "file")
run_until_grounded :: proc(f: ^Fixture, buttons: Buttons) -> bool {
	s := &f.world.soldiers[0]
	for _ in 0 ..< 60 {
		hold(f, buttons, 1)
		if s.on_ground && (s.legs.id == .Run || s.legs.id == .Run_Back) do return true
	}
	return false
}

// Running one way while facing the other is a backward roll, and the sides are mirrored:
// the original picks by Direction inside the down-right and down-left branches.
@(test)
test_a_crouch_while_running_rolls_the_way_it_faces :: proc(t: ^testing.T) {
	Case :: struct {
		aim_x:   f32,     // the cursor, which sets the facing
		move:    Button,  // the way it runs
		want:    Anim_Id,
	}
	cases := []Case{
		{200, .Right, .Roll},       // facing right, running right
		{-200, .Right, .Roll_Back}, // facing left, running right
		{-200, .Left, .Roll},       // facing left, running left
		{200, .Left, .Roll_Back},   // facing right, running left
	}
	for c in cases {
		f, ok := fixture(c.aim_x)
		if !ok {
			fmt.eprintln("no assets/maps/Arena.pms; skipping")
			return
		}
		defer fixture_destroy(f)
		s := &f.world.soldiers[0]
		if !run_until_grounded(f, {c.move}) {
			testing.expectf(t, false, "never got running on the ground facing %.0f", c.aim_x)
			continue
		}
		hold(f, {c.move, .Crouch}, 1)
		testing.expectf(t, s.legs.id == c.want, "facing %.0f, running %v: rolled %v, wanted %v", c.aim_x, c.move, s.legs.id, c.want)
		testing.expectf(t, s.body.id == c.want, "the body took %v where the legs took %v", s.body.id, s.legs.id)
	}
}

// The two machines turn together and end together: the original syncs their frames
// every tick (the comment there calls it the crouch bug), and the body goes back to
// standing on the last frame while the legs are left to the next tick's locomotion.
@(test)
test_a_roll_runs_both_machines_in_lockstep :: proc(t: ^testing.T) {
	f, ok := fixture(200)
	if !ok do return
	defer fixture_destroy(f)
	s := &f.world.soldiers[0]
	if !run_until_grounded(f, {.Right}) do return
	hold(f, {.Right, .Crouch}, 1)
	testing.expect(t, s.legs.id == .Roll, "no roll")

	frames := 0
	for _ in 0 ..< 120 {
		if s.body.id != .Roll do break
		testing.expect_value(t, s.legs.frame, s.body.frame)
		testing.expect_value(t, s.stance, Stance.Stand) // a roll is not a crouch
		hold(f, {.Right, .Crouch}, 1)
		frames += 1
	}
	testing.expect_value(t, s.body.id, Anim_Id.Stand)
	testing.expectf(t, i32(frames) == f.anims[Anim_Id.Roll].num_frames - 1, "the roll ran %d frames of %d", frames, f.anims[Anim_Id.Roll].num_frames)
}

// A roll outruns the run it came out of: the original gives it 2 * CROUCHRUNSPEED on
// the tick it starts and then ROLLSPEED, against RUNSPEED for the running.
@(test)
test_a_roll_outruns_the_run_it_came_from :: proc(t: ^testing.T) {
	TICKS :: 20
	f, ok := fixture(200)
	if !ok do return
	defer fixture_destroy(f)
	s := &f.world.soldiers[0]
	if !run_until_grounded(f, {.Right}) do return

	running := s.pos.x
	hold(f, {.Right}, TICKS)
	running = s.pos.x - running

	speed := s.vel.x
	rolling := s.pos.x
	hold(f, {.Right, .Crouch}, TICKS)
	rolling = s.pos.x - rolling

	testing.expect(t, s.vel.x > speed, "the roll did not pick the body up")
	testing.expectf(t, rolling > running, "%d ticks rolling went %.0f, running went %.0f", TICKS, rolling, running)
}

// The jet flip: jetting against the way a side jump is going turns it into a backward
// roll, and that first tick spends no fuel, the original's flip being the branch before
// the one that burns it.
@(test)
test_a_side_jump_flips_on_the_jet :: proc(t: ^testing.T) {
	f, ok := fixture(200) // facing right
	if !ok do return
	defer fixture_destroy(f)
	s := &f.world.soldiers[0]
	if !run_until_grounded(f, {.Right}) do return
	for _ in 0 ..< 30 {
		hold(f, {.Right, .Jump}, 1)
		if s.legs.id == .Jump_Side do break
	}
	testing.expect(t, s.legs.id == .Jump_Side, "never jumped to the side")

	fuel := s.jets
	hold(f, {.Left, .Jet}, 1) // jetting against it, facing right still
	testing.expect_value(t, s.legs.id, Anim_Id.Roll_Back)
	testing.expect_value(t, s.body.id, Anim_Id.Roll_Back)
	testing.expectf(t, s.jets == fuel, "the flip spent %d of fuel; it costs none", fuel - s.jets)
}

// Holding the jet and the jump through a flip stays in the flip and stays free: a
// backward roll with Up held meets the flip's own condition again, so the branch that
// burns fuel is never reached. The turn carries on from where it is rather than
// starting over, the original's LegsApplyAnimation only setting a frame when the
// animation it is given is a different one.
@(test)
test_a_flip_held_with_the_jump_stays_free :: proc(t: ^testing.T) {
	f, ok := fixture(200)
	if !ok do return
	defer fixture_destroy(f)
	s := &f.world.soldiers[0]
	if !run_until_grounded(f, {.Right}) do return
	for _ in 0 ..< 30 {
		hold(f, {.Right, .Jump}, 1)
		if s.legs.id == .Jump_Side do break
	}
	hold(f, {.Left, .Jet}, 1)
	testing.expect_value(t, s.legs.id, Anim_Id.Roll_Back)

	fuel, frame := s.jets, s.legs.frame
	hold(f, {.Jet, .Jump}, 8)
	testing.expect_value(t, s.legs.id, Anim_Id.Roll_Back)
	testing.expectf(t, s.legs.frame > frame, "the flip restarted, frame %d then %d", frame, s.legs.frame)
	testing.expectf(t, s.jets == fuel, "a held flip spent %d of fuel", fuel - s.jets)
}
