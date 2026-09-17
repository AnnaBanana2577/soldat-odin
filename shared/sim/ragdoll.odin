package sim

// Corpses: a dead soldier's gostek skeleton run as a Verlet particle system, from
// the dead-soldier branches of Sprites.pas (Update, Die, CheckSkeletonMapCollision)
// and Parts.pas, by way of the old Odin port. A ragdoll starts from the pose at the
// moment of death and falls, collides with the map and comes to rest; a bad death
// cuts constraints so the body comes apart. Corpses touch nothing but the map, so
// every client runs its own and nothing about them crosses the wire; the server
// never steps one.

RAGDOLL_POINTS        :: 24 // gostek.po
RAGDOLL_HEAD          :: 11 // skeleton point 12: the corpse's position
GOSTEK_SKELETON_SCALE :: 3  // gostek.po at the animations' scale, so the rest lengths match the pose

RAGDOLL_DAMPING :: 0.9945 // VDamping set for sprites
RAGDOLL_GRAVITY :: 1.06   // GravityMultiplier
EXPLOSION_DEADIMPACT_MULTIPLY :: 4.5

// Constraint numbers (1-based, gostek.po order) the deaths cut: the neck, the legs at
// the hip, the upper arms.
CONSTRAINT_NECK      :: 20
CONSTRAINT_LEFT_LEG  :: 2
CONSTRAINT_RIGHT_LEG :: 4
CONSTRAINT_LEFT_ARM  :: 21
CONSTRAINT_RIGHT_ARM :: 23

// Points that never collide with the map: the arms and the hand extras, as in the
// original's loop.
RAGDOLL_NO_COLLIDE :: bit_set[0 ..< RAGDOLL_POINTS]{6, 7, 16, 17, 18, 19}

Torn :: bit_set[0 ..< 32] // constraints that no longer hold, 0-based

Ragdoll :: struct {
	active:       bool,
	pos, old_pos: [RAGDOLL_POINTS]Vec2,
	forces:       [RAGDOLL_POINTS]Vec2,
	torn:         Torn,
}

// The ragdoll of a dead soldier, from its last pose: where it is, and the velocity it
// died with back, so the body keeps the motion. Its state says how it died, so any
// client can start the corpse from a snapshot alone.
ragdoll_start :: proc(ctx: ^Context, w: ^World, index: u8) {
	s := &w.soldiers[index]
	r := &w.ragdolls[index]
	r^ = {active = true}
	now := soldier_pose(ctx.anims, s, s.pos)
	before := soldier_pose(ctx.anims, s, s.pos - s.death_vel)
	for i in 0 ..< POSE_POINTS do r.pos[i], r.old_pos[i] = now[i], before[i]
	// the four extra points the original parks on the neck and head; constrained only
	// to each other, they ride along unseen
	r.pos[20], r.pos[21] = now[8], now[8]
	r.pos[22], r.pos[23] = now[11], now[11]
	for i in POSE_POINTS ..< RAGDOLL_POINTS do r.old_pos[i] = r.pos[i]
}

// Die's cuts: by how far below zero the health went, and where the body was hit.
ragdoll_tear :: proc(w: ^World, index: u8, health: f32, part: u8) {
	r := &w.ragdolls[index]
	cut :: proc(r: ^Ragdoll, constraint: int) { r.torn += {constraint - 1} }
	switch {
	case health <= BRUTAL_DEATH_HEALTH:
		cut(r, CONSTRAINT_LEFT_LEG); cut(r, CONSTRAINT_RIGHT_LEG); cut(r, CONSTRAINT_NECK)
		cut(r, CONSTRAINT_LEFT_ARM); cut(r, CONSTRAINT_RIGHT_ARM)
	case health <= HEADCHOP_DEATH_HEALTH:
		// the 1-based skeleton point hit: the head comes off, or a leg at the hip
		switch part {
		case 12: cut(r, CONSTRAINT_NECK)
		case 3:  cut(r, CONSTRAINT_LEFT_LEG)
		case 4:  cut(r, CONSTRAINT_RIGHT_LEG)
		}
	}
}

// One tick of every corpse. A dead soldier without one gets one from its state; a
// living soldier has none.
ragdolls_update :: proc(ctx: ^Context, w: ^World) {
	for &s, i in w.soldiers {
		r := &w.ragdolls[i]
		if !s.active || !s.dead {
			r.active = false
			continue
		}
		if !r.active {
			ragdoll_start(ctx, w, u8(i))
			ragdoll_tear(w, u8(i), s.health, s.death_part)
		}
		ragdoll_step(ctx, w, u8(i))
	}
}

// The original's order: every point against the map from last tick's positions, then
// the integration with damping and gravity, then one pass over the constraints that
// still hold, both ends moving. The soldier's position follows the head.
ragdoll_step :: proc(ctx: ^Context, w: ^World, index: u8) {
	s := &w.soldiers[index]
	r := &w.ragdolls[index]

	s.bg.test_result = false
	for i in 0 ..< POSE_POINTS {
		if i not_in RAGDOLL_NO_COLLIDE do ragdoll_collide(ctx, w, index, i)
	}
	if !s.bg.test_result {
		s.bg.status = BACKGROUND_NORMAL
		s.bg.poly = BACKGROUND_POLY_NONE
	}

	for i in 0 ..< RAGDOLL_POINTS {
		r.forces[i].y += RAGDOLL_GRAVITY * w.gravity
		prev := r.pos[i]
		r.pos[i] = r.pos[i] * (1 + RAGDOLL_DAMPING) - r.old_pos[i] * RAGDOLL_DAMPING + r.forces[i]
		r.old_pos[i] = prev
		r.forces[i] = {}
	}
	skeleton := &ctx.skeletons.gostek
	for c, ci in skeleton.constraints {
		if ci in r.torn do continue
		a, b := c[0], c[1]
		rest := vec2_length(skeleton.points[b] - skeleton.points[a])
		delta := r.pos[b] - r.pos[a]
		length := vec2_length(delta)
		if length == 0 do continue
		diff := (length - rest) / length
		r.pos[a] += delta * (0.5 * diff)
		r.pos[b] -= delta * (0.5 * diff)
	}

	s.old_pos = s.pos
	s.pos = r.pos[RAGDOLL_HEAD]
}

// CheckSkeletonMapCollision: a point inside a poly goes back to its old position minus
// the push-out. A first pass honours the team and flagger polys; where it hit, a
// second pass just below ignores them.
@(private = "file")
ragdoll_collide :: proc(ctx: ^Context, w: ^World, index: u8, i: int) {
	level := ctx.level
	s := &w.soldiers[index]
	r := &w.ragdolls[index]
	hit := false

	probe := r.pos[i] + {-1, 4}
	bg_test_big_poly_center(level, &s.bg, probe)
	for idx in sector_polys(level, probe) {
		poly := &level.polys[idx]
		if !soldier_collides_with(s, poly.type) || !point_in_poly_edges(probe, poly) do continue
		if bg_test(level, &s.bg, idx) do continue
		normal, dist, _ := closest_perpendicular(poly, probe)
		r.pos[i] = r.old_pos[i] - vec2_normalize(normal) * dist
		hit = true
	}
	if !hit do return

	probe = r.pos[i] + {0, 1}
	bg_test_big_poly_center(level, &s.bg, probe)
	for idx in sector_polys(level, probe) {
		poly := &level.polys[idx]
		if poly.type == .Doesnt || poly.type == .Only_Bullets || !point_in_poly_edges(probe, poly) do continue
		if bg_test(level, &s.bg, idx) do continue
		normal, dist, _ := closest_perpendicular(poly, probe)
		r.pos[i] = r.old_pos[i] - vec2_normalize(normal) * dist
	}
}

// A blast shoves a corpse (ExplosionHit's DeadMeat branch): every body point in range
// has its old position pulled toward the blast, which Verlet turns into a kick away.
ragdoll_explosion :: proc(w: ^World, index: u8, at: Vec2, radius: f32) {
	r := &w.ragdolls[index]
	if !r.active do return
	for i in 0 ..< 16 {
		a := at - r.pos[i]
		dist2 := vec2_dot(a, a)
		if dist2 >= radius * radius do continue
		r.old_pos[i] += a * ((1 / (sqrt_f32(dist2) + 1)) * EXPLOSION_DEADIMPACT_MULTIPLY)
	}
}

// The body points blended between the last two ticks, as a pose to draw.
ragdoll_pose :: proc(r: ^Ragdoll, alpha: f32) -> (p: Pose) {
	for i in 0 ..< POSE_POINTS do p[i] = r.old_pos[i] + (r.pos[i] - r.old_pos[i]) * alpha
	return
}
