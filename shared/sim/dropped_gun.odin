package sim

// Guns on the ground: thrown from a hand, dropped by a death, a thrown knife landing.
// A two-point thing (karabin.po at the gun's length) carrying the weapon and its
// ammo; it resists pickup for half a second, settles without bouncing and goes
// after a while if nobody takes it. Ported from dropWeapon / setupGun / weaponPickup
// in things.lua and rules.lua.

GUN_RESIST_TIME  :: 60 * 20 // a dropped gun lies around this long...
GUN_RESIST_TICKS :: 30      // ...and can't be taken for its first half second
GUN_RADIUS       :: 10.0    // the pickup radius (a knife's is half again as big)

dropped_gun_update :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, events: ^Events) {
	if !t.static do thing_physics(ctx, w, t, events)
	t.timeout -= 1
	if t.timeout <= 0 do thing_clear(t)
}

// The gun leaves the hand: the grip barely moved, the muzzle flung along the aim
// (a throw) or given the killing impact (a death). The event goes out even where the
// thing is not made (a client's world): a thrown gun is claimed by it.
dropped_gun_create :: proc(ctx: ^Context, w: ^World, weapon: Weapon_Id, owner: u8, pos: Vec2, dead: bool, impact: Vec2, ammo: i32, events: ^Events) {
	if GUN_OBJECTS[weapon].scale == 0 do return // the flamer and the hands are never dropped
	emit(events, Weapon_Drop{player = owner, weapon = weapon, ammo = ammo, thrown = !dead})
	index, ok := thing_create(ctx, w, .Weapon, pos, weapon)
	if !ok do return
	t := &w.things[index]
	t.owner = owner + 1
	t.timeout = GUN_RESIST_TIME
	s := &w.soldiers[owner]
	t.flip = s.direction < 0
	t.ammo = ammo
	pose := soldier_pose(ctx.anims, s, s.pos)
	aim := vec2_normalize(s.aim - pose[14])
	// a thrown gun carries the thrower's speed; one let go of by a death does not, so it
	// drops where the soldier fell (the original gives it the body's velocity too, which
	// sends a jetting soldier's gun sailing away)
	carry := dead ? Vec2{} : s.vel
	grip, muzzle: f32 = 0.01, 3
	if dead do grip, muzzle = 0.02, 0.64
	t.pos[0] += carry + aim * grip
	t.pos[1] += carry + aim * muzzle
	if dead do t.forces[1] = impact
}

// The throw: from the muzzle end of the gun in hand. The weapon is named rather than
// read from the hand, so the server can throw it for a client that already let go.
dropped_gun_throw :: proc(ctx: ^Context, w: ^World, index: u8, s: ^Soldier, weapon: Weapon_Id, ammo: i32, events: ^Events) {
	pose := soldier_pose(ctx.anims, s, s.pos)
	dropped_gun_create(ctx, w, weapon, index, pose[15], false, {}, ammo, events)
}

dropped_gun_from_death :: proc(ctx: ^Context, w: ^World, index: u8, s: ^Soldier, impact: Vec2, events: ^Events) {
	pose := soldier_pose(ctx.anims, s, s.pos)
	dropped_gun_create(ctx, w, s.weapon.id, index, pose[15], true, impact, s.weapon.ammo, events)
}

// A thrown knife that stopped lands as a knife to pick up, a step back from where.
dropped_gun_land_knife :: proc(w: ^World, b: ^Bullet) {
	// TODO needs the context for the skeleton: thing_create(ctx, w, .Weapon, b.pos - b.vel, .Knife)
}

// May this soldier take it: with empty hands, near, once the gun has lain long enough.
dropped_gun_can_pickup :: proc(t: ^Thing, s: ^Soldier) -> bool {
	if t.timeout >= GUN_RESIST_TIME - GUN_RESIST_TICKS do return false
	if s.weapon.id != .None do return false
	// the secondaries are not taken mid weapon change
	secondary := t.weapon == .Knife || t.weapon == .Chainsaw || t.weapon == .LAW
	if secondary && s.body.id == .Change do return false
	radius := t.weapon == .Knife ? f32(GUN_RADIUS) * 1.5 : f32(GUN_RADIUS)
	return vec2_length(thing_center(t) - s.pos) <= radius
}

// The pickup: the gun and its ammo into the hand, the thing gone.
dropped_gun_pickup :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, soldier: u8, events: ^Events) {
	s := &w.soldiers[soldier]
	s.weapon = weapon_state(ctx, t.weapon)
	s.weapon.ammo = t.ammo
	emit(events, Weapon_Pickup{player = soldier, thing = index, weapon = t.weapon, pos = t.pos[0]})
	thing_clear(t)
}
