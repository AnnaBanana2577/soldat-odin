package sim

import "core:math"

// The weapon in hand: firing with the spread and bink, the reloads, changing,
// throwing grenades and the gun, the punch and the rifle butt. Ported from
// OpenSoldat Sprites.pas / Control.pas by way of the old Odin port.

MAX_INACCURACY :: 0.5
MELEE_DIST     :: 12

// The gun in hand and what it is doing.
Weapon :: struct {
	id:            Weapon_Id,
	ammo:          i32,
	fire_count:    i32, // ticks until it may fire again
	reload_count:  i32, // ticks of reload left
	startup_count: i32, // the minigun's and LAW's wind-up
}

weapon_state :: proc(ctx: ^Context, id: Weapon_Id) -> Weapon {
	info := &ctx.weapons[id]
	return {
		id            = id,
		ammo          = id == .M79 ? 0 : info.ammo, // the M79 spawns empty and reloads
		fire_count    = info.fire_interval,
		reload_count  = info.reload_time,
		startup_count = info.startup,
	}
}

// This tick's buttons on the weapon, in the control order.
combat_control :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	anims := ctx.anims
	body := &s.body
	weapon := &s.weapon
	info := &ctx.weapons[weapon.id]
	fire := .Fire in s.controls

	if weapon.ammo > info.ammo || weapon.fire_count > info.fire_interval || weapon.reload_count > info.reload_time {
		weapon^ = weapon_state(ctx, weapon.id)
		weapon.ammo = 0
	}

	// The rifle butt when standing next to someone.
	if s.stance == .Stand && fire && s.cease_fire_counter < 0 && weapon.id != .None && weapon.id != .Knife && weapon.id != .Chainsaw {
		for &other, i in w.soldiers {
			if u8(i) == index || !other.active || other.dead || other.stance != .Stand do continue
			if vec2_length(s.pos - other.pos) < MELEE_DIST do anim_apply(anims, body, .Melee)
		}
	}

	// fire
	if weapon.id == .Chainsaw || (body.id != .Roll && body.id != .Roll_Back && body.id != .Melee && body.id != .Change) {
		if (body.id == .Hands_Up_Aim && body.frame == 11) || body.id != .Hands_Up_Aim {
			if fire && s.cease_fire_counter < 0 {
				if weapon.id == .None || weapon.id == .Knife {
					anim_apply(anims, body, .Punch)
				} else if weapon.fire_count == 0 && weapon.ammo > 0 {
					if info.startup > 0 && weapon.startup_count > 0 {
						if weapon.id != .LAW || (s.on_ground || s.on_ground_permanent) && law_stance(s) do weapon.startup_count -= 1
					} else {
						fire_weapon(ctx, w, index, events)
					}
				}
			} else {
				weapon.startup_count = info.startup
			}
		}
	} else {
		weapon.startup_count = info.startup
		s.burst_count = 0
	}
	if !fire do s.burst_count = 0

	// a semi-automatic needs the trigger released between shots
	if info.semi_auto && fire && (s.burst_count > 0 || .Reload in s.controls) && weapon.fire_count < 2 do weapon.fire_count += 1

	throw_grenade(ctx, w, index, events)

	if body.id != .Roll && body.id != .Roll_Back && .Change in s.controls do anim_apply(anims, body, .Change)

	if body.id != .Roll && body.id != .Roll_Back && body.id != .Change && body.id != .Throw_Weapon && .Drop in s.controls && weapon.id != .None {
		anim_apply(anims, body, .Throw_Weapon)
	}

	// manual reload
	if weapon.id == .Chainsaw || (body.id != .Roll && body.id != .Roll_Back && body.id != .Change) {
		if .Reload in s.controls && weapon.ammo != info.ammo {
			if weapon.id == .Spas {
				if weapon.ammo < info.ammo {
					if weapon.fire_count == 0 do anim_apply(anims, body, .Reload)
					else do s.auto_reload_when_can_fire = true
				}
			} else {
				weapon.ammo = 0
				weapon.fire_count = info.fire_interval
			}
			s.burst_count = 0
		}
	}

	// the shotgun reloads shell by shell
	if body.id == .Reload && body.frame == 7 do body.frame += 1
	if (!fire || weapon.ammo == 0) && body.id == .Reload && body.frame == 14 {
		weapon.ammo += 1
		if weapon.ammo < info.ammo do body.frame = 1
	}

	// the change swaps the guns at frame 25
	if body.id == .Change && body.frame == 2 do body.frame += 1
	if body.id == .Change && body.frame == 25 {
		s.weapon, s.secondary = s.secondary, s.weapon
		s.weapon.startup_count = ctx.weapons[s.weapon.id].startup
		s.burst_count = 0
		weapon = &s.weapon
		info = &ctx.weapons[weapon.id]
	}
	if body.id == .Change && body.frame == anims[.Change].num_frames && weapon.ammo == 0 do anim_apply(anims, body, .Stand)

	// the gun leaves the hand at frame 19 of the throw
	if body.id == .Throw_Weapon && body.frame == 19 && weapon.id != .None {
		dropped_gun_throw(ctx, w, index, s, weapon.id, weapon.ammo, events)
		s.weapon = weapon_state(ctx, .None)
		weapon = &s.weapon
		info = &ctx.weapons[.None]
	}

	// the punch or stab
	if body.id == .Punch && body.frame == 11 && weapon.id != .LAW && weapon.id != .M79 {
		pose := soldier_pose(anims, s, s.pos)
		dir := f32(s.direction)
		bullet_spawn(ctx, w, pose[15] + {2 * dir, 3}, {dir * 0.1, 0}, weapon.id, index, info.damage, events)
		body.frame += 1
	}

	// the rifle butt
	if body.id == .Melee && body.frame == 12 {
		pose := soldier_pose(anims, s, s.pos)
		dir := f32(s.direction)
		bullet_spawn(ctx, w, pose[15] + {2 * dir, 3}, {dir * 0.1, 0}, .None, index, ctx.weapons[.None].damage, events)
	}
	if body.id == .Melee && body.frame > 20 do anim_apply(anims, body, .Stand)

	// the M79's spent casing timing quirk
	if weapon.id == .M79 && weapon.reload_count == info.clip_out_time && weapon.reload_count > 0 do weapon.reload_count -= 1

	if weapon.id == .Barrett && weapon.fire_count > 0 && (body.id == .Stand || body.id == .Crouch || body.id == .Prone) {
		anim_apply(anims, body, .Barret)
	}

	// the reload animation follows the reload timer
	if weapon.reload_count == info.clip_out_time && body.id != .Reload && body.id != .Reload_Bow && body.id != .Roll && body.id != .Roll_Back {
		anim_apply(anims, body, .Clip_In)
	}
	if weapon.reload_count == info.clip_in_time do anim_apply(anims, body, .Slide_Back)
}

@(private = "file")
law_stance :: proc(s: ^Soldier) -> bool {
	#partial switch s.legs.id {
	case .Crouch:                       return s.legs.frame > 13
	case .Crouch_Run, .Crouch_Run_Back: return true
	case .Prone:                        return s.legs.frame > 23
	}
	return false
}

// The fire and reload timers, after the step.
weapon_timers :: proc(ctx: ^Context, s: ^Soldier) {
	anims := ctx.anims
	weapon := &s.weapon
	info := &ctx.weapons[weapon.id]
	body := &s.body

	if s.auto_reload_when_can_fire && (weapon.id != .Spas || weapon.fire_count == 0) {
		s.auto_reload_when_can_fire = false
		if weapon.id == .Spas && body.id != .Roll && body.id != .Roll_Back && body.id != .Change && weapon.ammo != info.ammo {
			anim_apply(anims, body, .Reload)
		}
	}
	if weapon.fire_count > 0 && (weapon.ammo > 0 || weapon.id == .Spas) do weapon.fire_count -= 1
	if .Fire not_in s.controls do s.can_auto_reload_spas = true

	busy := body.id == .Roll || body.id == .Roll_Back || body.id == .Melee || body.id == .Change || body.id == .Throw || body.id == .Throw_Weapon
	if weapon.ammo == 0 && (weapon.id == .Chainsaw || !busy) {
		if body.id != .Get_Up {
			switch {
			case weapon.id == .Spas:
				if weapon.fire_count == 0 && s.can_auto_reload_spas do anim_apply(anims, body, .Reload)
			case weapon.id == .Bow || weapon.id == .Bow2:
				anim_apply(anims, body, .Reload_Bow)
			case body.id != .Clip_In && body.id != .Slide_Back && (weapon.id != .Chainsaw || !busy):
				anim_apply(anims, body, .Clip_Out)
			}
			s.burst_count = 0
		}
		if weapon.id != .Spas {
			if weapon.reload_count > 0 do weapon.reload_count -= 1
			weapon.fire_count = info.fire_interval
			if weapon.reload_count < 1 {
				weapon.reload_count = info.reload_time
				weapon.fire_count = info.fire_interval
				weapon.startup_count = info.startup
				weapon.ammo = info.ammo
			}
		}
	}
}

// One shot: the bullets, the recoil, the self-push, the bink.
@(private = "file")
fire_weapon :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	anims := ctx.anims
	weapon := &s.weapon
	info := &ctx.weapons[weapon.id]
	pose := soldier_pose(anims, s, s.pos)

	aim_dir := info.style == .Knife ? hands_aim_direction(&pose) : vec2_normalize(s.aim - pose[14])
	origin := pose[14] - aim_dir * 4 - {0, 2}

	inaccuracy := f32(s.hit_spray) * 0.01 + movement_inaccuracy(ctx, s)
	if weapon.id != .Eagle && weapon.id != .Spas && info.style != .Shotgun && info.spread > 0 {
		switch {
		case s.legs.id == .Prone_Move || (s.legs.id == .Prone && s.legs.frame > 23):
			inaccuracy += info.spread / 1.625
		case s.legs.id == .Crouch_Run || s.legs.id == .Crouch_Run_Back || (s.legs.id == .Crouch && s.legs.frame > 13):
			inaccuracy += info.spread / 1.3
		case:
			inaccuracy += info.spread
		}
	}
	inaccuracy = min(inaccuracy * 0.25, MAX_INACCURACY)
	max_dev := MAX_INACCURACY * math.sin(inaccuracy / MAX_INACCURACY * math.PI / 2)
	dev := Vec2{(rand_f32(&s.rng) * 2 - 1) * max_dev, (rand_f32(&s.rng) * 2 - 1) * max_dev}
	vel := vec2_normalize(aim_dir + dev) * info.speed + s.vel * info.inherit

	// a muzzle inside a wall (the head in a ceiling) is lowered a bit
	if _, hit := collision_test(ctx.level, origin); hit do origin.y += 2.5

	spread :: proc(s: ^Soldier, v: Vec2, amount: f32) -> Vec2 {
		return v + {(rand_f32(&s.rng) * 2 - 1) * amount, (rand_f32(&s.rng) * 2 - 1) * amount}
	}

	#partial switch weapon.id {
	case .Eagle:
		bullet_spawn(ctx, w, origin, spread(s, vel, info.spread), weapon.id, index, info.damage, events)
		second := spread(s, vel, info.spread)
		n := vec2_normalize(vel)
		origin2 := origin + {-math.sign(vel.x) * abs(n.y) * 3, math.sign(vel.y) * abs(n.x) * 3}
		bullet_spawn(ctx, w, origin2, second, weapon.id, index, info.damage, events)
	case .Flamer:
		bullet_spawn(ctx, w, origin + vel * 3, vel, weapon.id, index, info.damage, events)
	case .Chainsaw:
		bullet_spawn(ctx, w, origin + vel * 2, vel, weapon.id, index, info.damage, events)
	case .LAW:
		if !((s.on_ground || s.on_ground_permanent || s.on_ground_for_law) && law_stance(s)) do return
		bullet_spawn(ctx, w, origin, vel, weapon.id, index, info.damage, events)
	case .None, .Knife:
	case:
		if info.style == .Shotgun {
			for _ in 0 ..< 6 do bullet_spawn(ctx, w, origin, spread(s, vel, info.spread), weapon.id, index, info.damage, events)
			s.vel -= vel * {0.0412, 0.041}
		} else {
			bullet_spawn(ctx, w, origin, vel, weapon.id, index, info.damage, events)
		}
	}

	if weapon.id == .Minigun {
		push := (.Jet in s.controls && s.jets > 0) ? vel * {0.0012, 0.0009} : vel * {0.0082, 0.0078}
		if s.holding_flag do push *= {0.5, 0.7}
		push.x *= 0.6
		s.vel -= push
	}

	if weapon.ammo > 0 do weapon.ammo -= 1
	if weapon.id == .Spas do s.can_auto_reload_spas = false
	weapon.fire_count = info.fire_interval
	if s.burst_count < 255 do s.burst_count += 1

	// self-bink for the next shot; halved when crouched or prone
	if info.bink < 0 {
		steady := s.legs.id == .Crouch || s.legs.id == .Crouch_Run || s.legs.id == .Crouch_Run_Back || s.legs.id == .Prone || s.legs.id == .Prone_Move
		s.hit_spray = calculate_bink(s.hit_spray, steady ? round_half_even(f32(-info.bink) / 2) : int(-info.bink))
	}

	s.fired = true
	emit(events, Fire{player = index, weapon = weapon.id, pos = origin, vel = vel})
	recoil_animation(anims, s)
}

@(private = "file")
recoil_animation :: proc(anims: ^Anims, s: ^Soldier) {
	body := &s.body
	normal_pose := body.id != .Throw && body.id != .Get_Up && body.id != .Melee
	crouch_recoil :: proc(anims: ^Anims, s: ^Soldier) {
		if s.stance != .Crouch do return
		anim_apply(anims, &s.body, s.body.id == .Hands_Up_Aim ? .Hands_Up_Recoil : .Aim_Recoil)
	}
	#partial switch s.weapon.id {
	case .AK74, .M249, .MP5, .Eagle, .Steyr, .Colt, .Bow, .Bow2:
		if normal_pose && s.stance == .Stand do anim_apply(anims, body, .Small_Recoil)
		crouch_recoil(anims, s)
	case .Ruger:
		if normal_pose && s.stance == .Stand do anim_apply(anims, body, .Recoil)
		crouch_recoil(anims, s)
	case .Spas:
		if normal_pose && s.stance != .Prone do anim_apply(anims, body, .Shotgun)
		if s.stance == .Prone && body.id == .Reload do body.frame = anims[.Reload].num_frames
	case .M79:
		if normal_pose && s.stance != .Prone do anim_apply(anims, body, .Small_Recoil)
	case .Barrett:
		if normal_pose do anim_apply(anims, body, .Barret)
	case .Minigun:
		if normal_pose && s.stance == .Stand do anim_apply(anims, body, .Small_Recoil, 2)
	}
}

// Adds bink with diminishing returns as more accumulates (Weapons.pas CalculateBink).
calculate_bink :: proc(accumulated: u16, bink: int) -> u16 {
	if bink <= 0 do return accumulated
	acc := f32(accumulated)
	result := int(accumulated) + bink - round_half_even(acc * (acc / (10 * f32(bink) + acc)))
	return u16(clamp(result, 0, 65535))
}

// A hit disturbs the victim's aim by the bink of the weapon they hold, unless it came
// from a teammate without friendly fire.
hit_spray :: proc(ctx: ^Context, w: ^World, victim, attacker: u8) {
	v, a := &w.soldiers[victim], &w.soldiers[attacker]
	if victim != attacker && !w.round.friendly_fire && v.team != .None && v.team == a.team do return
	bink := ctx.weapons[v.weapon.id].bink
	if bink > 0 do v.hit_spray = calculate_bink(v.hit_spray, int(bink))
}

movement_inaccuracy :: proc(ctx: ^Context, s: ^Soldier) -> f32 {
	acc := ctx.weapons[s.weapon.id].movement_acc
	if acc <= 0 do return 0
	#partial switch s.legs.id {
	case .Jump, .Jump_Side, .Run, .Run_Back, .Roll, .Roll_Back:
		return acc * 7
	}
	if .Jet in s.controls && s.jets > 0 do return acc * 7
	lying_or_crouched := s.legs.id == .Prone || s.legs.id == .Prone_Move || s.legs.id == .Crouch || s.legs.id == .Crouch_Run || s.legs.id == .Crouch_Run_Back
	if (!s.on_ground_permanent && !lying_or_crouched) || s.legs.id == .Get_Up || (s.legs.id == .Prone && s.legs.frame < ctx.anims[.Prone].num_frames) {
		return acc * 3
	}
	return 0
}

// The grenade: hold to wind up (longer is further), release to throw.
@(private = "file")
throw_grenade :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	anims := ctx.anims
	body := &s.body
	throw := .Throw in s.controls

	if !throw do s.grenade_can_throw = true
	if s.grenade_can_throw && throw && body.id != .Roll && body.id != .Roll_Back do anim_apply(anims, body, .Throw)
	if body.id != .Throw || (throw && body.frame != 36) do return

	if body.frame > 14 && body.frame < 37 && s.grenades > 0 && s.cease_fire_counter < 0 {
		frag := &ctx.weapons[.Frag]
		pose := soldier_pose(anims, s, s.pos)
		dir := vec2_normalize(s.aim - pose[14])
		// a slight arc that disappears when aiming straight up or down
		arc := math.sign(dir.x) / 8 * (1 - abs(dir.y))
		dir.x += math.sin(dir.y * math.PI / 2) * arc
		dir.y -= math.sin(dir.x * math.PI / 2) * arc
		dir = vec2_normalize(dir)

		strength := f32(body.frame) / frag.speed
		if body.frame < 24 do strength *= 0.65
		vel := dir * strength + s.vel * frag.inherit

		origin := pose[14] + vel * 3 - {0, 2}
		head := s.pos - {0, 12}
		_, in_wall := collision_test(ctx.level, origin)
		_, blocked := ray_cast(ctx.level, head, origin, 50, {bullet = true, team = s.team})
		if !in_wall && !blocked {
			bullet_spawn(ctx, w, origin, vel, .Frag, index, frag.damage, events)
			s.grenades -= 1
			emit(events, Fire{player = index, weapon = .Frag, pos = origin, vel = vel})
			if frag.bink < 0 do s.hit_spray = calculate_bink(s.hit_spray, int(-frag.bink))
		}
	}
	if throw do s.grenade_can_throw = false

	weapon := &s.weapon
	info := &ctx.weapons[weapon.id]
	if weapon.ammo == 0 {
		if weapon.reload_count > info.clip_out_time do anim_apply(anims, body, .Clip_Out)
		if weapon.reload_count < info.clip_out_time do anim_apply(anims, body, .Clip_In)
		if weapon.reload_count < info.clip_in_time && weapon.reload_count > 0 do anim_apply(anims, body, .Slide_Back)
	}
}

hands_aim_direction :: proc(pose: ^Pose) -> Vec2 {
	return vec2_normalize(pose[14] - pose[15])
}

// Where the soldier is aiming from its position; the fallback is the way it faces.
aim_direction :: proc(s: ^Soldier) -> Vec2 {
	d := vec2_normalize(s.aim - s.pos)
	if d == {} do return {f32(s.direction), 0}
	return d
}
