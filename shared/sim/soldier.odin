package sim

// A soldier: the struct, spawning, and the tick in order. The parts live in their
// own files: movement (the control state machines), soldier_anim, combat, antics,
// soldier_collision. Ported from OpenSoldat Sprites.pas by way of the old Odin port.

DEFAULT_HEALTH     :: 150.0
DEFAULT_CEASE_FIRE :: 90
SOLDIER_DAMPING    :: 0.99

Stance :: enum u8 { Stand, Crouch, Prone }

Bonus :: enum u8 { None, Flame_God, Predator, Berserker }

// A soldier is run in one place at a time: the server runs them all, on the commands
// their clients sent, and a client runs its own as well to predict it. Everyone else
// draws them from the server's word alone (client/game/view.odin). What a soldier's
// player decides and what the server decides are kept apart all the same, because the
// server sends the parts separately: net.ser_owned (and ser_rest) against ser_served.
Soldier :: struct {
	// the server's
	active: bool,
	team:   Team,
	health: f32,
	dead:   bool,
	// Counts the times the server has placed this soldier: a spawn, a respawn, a
	// correction. Its client says which life it speaks of, and the server which one it
	// means, so word from before a placing is never taken for word from after it.
	life:     u8,
	view_lag: u8, // ticks behind the present its client shows the others; its shots inherit it
	// How it died, so that any client can start the corpse from this state alone. The
	// position is here and not taken from `pos` because an update carries a dead
	// soldier's server half only: its player's half, `pos` among it, stops at the
	// death and would arrive as nothing.
	death_pos:  Vec2,
	death_vel:  Vec2,
	death_part: u8,
	rng:      u64, // its own randomness (the spread of its shots), rolled where it is played
	cmd_seq:  u32, // the command it last ran: what its bullets are stamped with
	shot_count: u32, // bullets it has fired: each is stamped with its number, on every machine alike

	// owned by the client that plays it
	pos, old_pos:  Vec2,
	vel, forces:   Vec2, // forces apply on the next integration step
	next_push:     Vec2, // knockback applied at the start of the next step
	controls:      Buttons, // this tick's resolved input
	aim:           Vec2,
	direction:     i8, // 1 facing right, -1 left
	old_direction: i8,
	// Left+Right held together keeps the previous direction: memory of the last tick.
	was_running_left: bool,
	was_jumping:      bool,
	stance:        Stance,
	legs, body:    Anim,
	on_ground:     bool,
	on_ground_last, on_ground_permanent, on_ground_for_law: bool,
	jets:          i32,
	bg:            Background_State,
	fired:         bool, // a shot went off this tick: the muzzle flash
	weapon:        Weapon,
	secondary:     Weapon,
	grenades:      i32,
	burst_count:   i32,
	grenade_can_throw:         bool,
	can_auto_reload_spas:      bool,
	auto_reload_when_can_fire: bool,
	// Distance from the muzzle to cover (a map collider, or a crouched teammate),
	// refreshed every 10 ticks; 255 = not near any. Crouching by cover raises the gun.
	collider_distance: u8,
	hit_spray:     u16, // bink: aim disturbance from being hit, decaying one per tick
	spawn_still:   bool, // not moved since spawning: the weapons menu still applies
	para, stat:    u8, // the parachute or stationary gun in use (thing index + 1)
	idle:          Idle,
	holding_flag:  bool,

	// the server's
	respawn_counter:    i32,
	cease_fire_counter: i32, // spawn protection: no shooting, no wounds while >= 0
	vest:               f32,
	bonus:              Bonus,
	bonus_time:         i32,
	primary_choice:     Weapon_Id, // the loadout for the next spawn
	secondary_choice:   Weapon_Id,
	kills, deaths, flags: i32,
}

// A fresh soldier at a spot; the tally and the count of its lives survive a respawn.
soldier_spawn :: proc(ctx: ^Context, s: ^Soldier, pos: Vec2, team: Team, primary, secondary: Weapon_Id) {
	kills, deaths, flags, life := s.kills, s.deaths, s.flags, s.life
	rng := s.rng != 0 ? s.rng : (u64(transmute(u32)pos.x) << 32 | u64(transmute(u32)pos.y)) | 1 // seeded once, from where it first stood
	s^ = {
		rng                = rng,
		life               = life,
		kills              = kills,
		deaths             = deaths,
		flags              = flags,
		active             = true,
		team               = team,
		health             = DEFAULT_HEALTH,
		pos                = pos,
		old_pos            = pos,
		direction          = 1,
		old_direction      = 1,
		stance             = .Stand,
		jets               = ctx.level.start_jet,
		bg                 = {status = BACKGROUND_TRANSITION, poly = BACKGROUND_POLY_UNKNOWN},
		cease_fire_counter = DEFAULT_CEASE_FIRE,
		grenades           = 1,
		primary_choice     = primary,
		secondary_choice   = secondary,
		weapon             = weapon_state(ctx, primary),
		secondary          = weapon_state(ctx, secondary),
		grenade_can_throw  = true,
		collider_distance  = 255,
		spawn_still        = true,
		bonus_time         = -1,
	}
	anim_set(ctx.anims, &s.legs, .Stand)
	anim_set(ctx.anims, &s.body, .Stand)
}

// The server places a soldier on one of its team's spawn points: a new life.
soldier_respawn :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	pos := spawn_point(ctx.level, s.team, &w.rng)
	soldier_spawn(ctx, s, pos, s.team, s.primary_choice, s.secondary_choice)
	s.life += 1
	emit(events, Respawn{target = index, life = s.life, team = s.team, primary = s.primary_choice, secondary = s.secondary_choice, pos = pos})
}

// The weapons a soldier chose, put in its hands: at a spawn, or from the weapons menu
// while it has not moved since.
soldier_arm :: proc(ctx: ^Context, s: ^Soldier, primary, secondary: Weapon_Id) {
	s.weapon = weapon_state(ctx, primary)
	s.secondary = weapon_state(ctx, secondary)
}

// Euler integration of the body particle, before the control step.
soldier_integrate :: proc(s: ^Soldier, gravity: f32) {
	s.forces.y += gravity
	prev := s.pos
	s.vel += s.forces
	s.pos += s.vel
	s.vel *= SOLDIER_DAMPING
	s.old_pos = prev
	s.forces = {}
}

// One tick of one soldier, in the original's order: integrate, take the knockback,
// the controls through the state machines, animate, collide with the map, the
// weapon timers, the jet fuel. Everything here is its player's half; the server's
// half ticks in soldier_served_tick. `armed` is false where a soldier is moved without
// its player behind it, which leaves its weapon alone.
soldier_step :: proc(ctx: ^Context, w: ^World, index: u8, cmd: Command, events: ^Events, armed := true) {
	s := &w.soldiers[index]
	if !s.active || s.dead do return
	soldier_integrate(s, w.gravity)
	s.vel += s.next_push
	s.next_push = {}
	if s.hit_spray > 0 do s.hit_spray -= 1

	// Between rounds nobody moves.
	s.cmd_seq = cmd.seq
	s.controls = w.round.state == .Ended ? {} : cmd.buttons
	if s.controls != {} do s.spawn_still = false
	s.aim = cmd.aim
	// suicide is a hit on oneself, applied like any other, and a brutal one
	if .Suicide in s.controls do emit(events, suicide_hit(w, index))
	soldier_control(ctx, w, index, events, armed)
	s.direction = s.aim.x >= s.pos.x ? 1 : -1
	anim_advance(ctx.anims, &s.body)
	anim_advance(ctx.anims, &s.legs)

	if soldier_out_of_bounds(ctx, s.pos) do return // off the map: it waits for the server to place it
	level := ctx.level

	soldier_collide(ctx, w, index, events)
	weapon_timers(ctx, s)
	antics_apply(ctx, w, s)

	// Jet fuel regenerates when not jetting: every tick on the ground, every other in the air.
	if s.jets < level.start_jet && .Jet not_in s.controls {
		if s.on_ground || w.tick % 2 == 0 do s.jets += 1
	}
}

soldier_out_of_bounds :: proc(ctx: ^Context, pos: Vec2) -> bool {
	bound := f32(ctx.level.sectors_num * ctx.level.sectors_division - 50)
	return abs(pos.x) > bound || abs(pos.y) > bound
}

// Suicide is a hit on oneself, applied like any other, and a brutal one.
suicide_hit :: proc(w: ^World, index: u8) -> Hit {
	return {shooter = index, target = index, amount = 4 * DEFAULT_HEALTH, pos = w.soldiers[index].pos}
}

// The server's half of a soldier's tick, whoever moves it: the way back from death and
// from off the map, the spawn protection, the bonus. Only the world that decides runs
// this (round_tick); everyone else hears the result.
soldier_served_tick :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	if !s.active do return
	if s.dead {
		s.respawn_counter -= 1
		// CheckSkeletonOutOfBounds: a corpse that slid off the map is placed again at once
		if s.respawn_counter < 1 || soldier_out_of_bounds(ctx, s.pos) {
			soldier_respawn(ctx, w, index, events)
		}
		return
	}
	if soldier_out_of_bounds(ctx, s.pos) {
		soldier_respawn(ctx, w, index, events)
		return
	}
	if s.cease_fire_counter > -1 do s.cease_fire_counter -= 1
	if s.bonus_time > -1 {
		s.bonus_time -= 1
		if s.bonus_time < 1 do s.bonus = .None
	} else {
		s.bonus = .None
	}
}

// What a soldier's own client decides, from a received state. In step with
// net.ser_owned: a field copied here is a field on the wire.
soldier_copy_owned :: proc(anims: ^Anims, dst, src: ^Soldier) {
	dst.pos, dst.vel, dst.next_push = src.pos, src.vel, src.next_push
	dst.controls, dst.aim = src.controls, src.aim
	dst.direction, dst.stance = src.direction, src.stance
	dst.on_ground, dst.jets = src.on_ground, src.jets
	anim_copy(anims, &dst.legs, src.legs)
	anim_copy(anims, &dst.body, src.body)
	dst.weapon, dst.secondary, dst.grenades = src.weapon, src.secondary, src.grenades
	dst.spawn_still, dst.para, dst.stat = src.spawn_still, src.para, src.stat
}

// What the server decides about a soldier. In step with net.ser_served.
soldier_copy_served :: proc(dst, src: ^Soldier) {
	dst.active, dst.dead, dst.team, dst.life = src.active, src.dead, src.team, src.life
	dst.health, dst.vest = src.health, src.vest
	dst.respawn_counter, dst.cease_fire_counter = src.respawn_counter, src.cease_fire_counter
	dst.bonus, dst.bonus_time = src.bonus, src.bonus_time
	dst.holding_flag = src.holding_flag
	dst.kills, dst.deaths, dst.flags = src.kills, src.deaths, src.flags
	dst.death_pos, dst.death_vel, dst.death_part = src.death_pos, src.death_vel, src.death_part
	dst.rng, dst.cmd_seq, dst.view_lag = src.rng, src.cmd_seq, src.view_lag
	dst.shot_count = src.shot_count
	dst.primary_choice, dst.secondary_choice = src.primary_choice, src.secondary_choice
}

// The rest of a soldier: what only the machine playing it needs, so that the two halves
// and this are the whole soldier and nothing of it is left to drift. In step with
// net.ser_rest.
soldier_copy_rest :: proc(dst, src: ^Soldier) {
	dst.old_pos, dst.forces = src.old_pos, src.forces
	dst.old_direction = src.old_direction
	dst.was_running_left, dst.was_jumping = src.was_running_left, src.was_jumping
	dst.on_ground_last = src.on_ground_last
	dst.on_ground_permanent, dst.on_ground_for_law = src.on_ground_permanent, src.on_ground_for_law
	dst.bg, dst.fired = src.bg, src.fired
	dst.burst_count, dst.grenade_can_throw = src.burst_count, src.grenade_can_throw
	dst.can_auto_reload_spas = src.can_auto_reload_spas
	dst.auto_reload_when_can_fire = src.auto_reload_when_can_fire
	dst.collider_distance, dst.hit_spray = src.collider_distance, src.hit_spray
	dst.idle = src.idle
	dst.legs.count, dst.body.count = src.legs.count, src.body.count
}

// An animation arrives as its id and frame; its pace is looked up here.
@(private = "file")
anim_copy :: proc(anims: ^Anims, dst: ^Anim, src: Anim) {
	if dst.id != src.id || dst.speed == 0 do anim_set(anims, dst, src.id, src.frame)
	else do dst.frame = src.frame
}
