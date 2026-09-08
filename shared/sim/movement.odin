package sim

// The control state machines: input -> animation state -> forces.
//
// A soldier is driven by two coupled state machines, both using Anim_Id as the state:
// the legs (locomotion: Stand, Run, Jump, Crouch, Prone, Roll, Fall...) and the body
// (pose and weapon handling: Stand, Aim, Recoil, Reload, Change, Throw, Roll...).
// anim_apply is the raw transition; legs_apply the guarded one (lying down blocks leg
// transitions until Get_Up runs). Rolls force the two into lockstep, and finished
// one-shot body animations fall back to the pose for the stance. The stance itself is
// derived from the legs: they are the machine of record for posture.
//
// Transitions fire in a fixed order each tick, inherited from the original's
// ControlSoldier; the feel depends on that order:
//
//   resolve_left_right -> jets_control -> combat_control -> prone_control
//   -> animation_slowdown -> cover_check -> movement_control -> roll_control
//   -> body_pose_control
//
// Ported from OpenSoldat Sprites.pas / Control.pas by way of the old Odin port.

RUNSPEED       :: 0.118
RUNSPEEDUP     :: RUNSPEED / 6
FLYSPEED       :: 0.03
JUMPSPEED      :: 0.66
CROUCHRUNSPEED :: RUNSPEED / 0.6
PRONESPEED     :: RUNSPEED * 4.0
ROLLSPEED      :: RUNSPEED / 1.2
JUMPDIRSPEED   :: 0.30
JETSPEED       :: 0.10
SPRITE_RADIUS  :: 16 // a crouched teammate counts as cover within this distance

// One control tick's input after left+right conflict resolution. `prone` is a
// press latch: prone_control consumes it when the go-prone transition fires.
Control_Input :: struct {
	left, right, up, down, jet, prone: bool,
	pressed_left_right:                bool, // both held this tick, resolved to one
}

soldier_control :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	s.legs.speed = max(s.legs.speed, 1)
	s.body.speed = max(s.body.speed, 1)
	s.fired = false // set again by fire() if a shot goes off this tick

	input := resolve_left_right(s)
	jets_control(ctx, w, s, input)
	combat_control(ctx, w, index, events)
	prone_control(ctx, s, &input)
	animation_slowdown(s)
	cover_check(ctx, w, index)
	movement_control(ctx, s, input)
	roll_control(ctx, s, input)
	body_pose_control(ctx, s)
}

// Left+Right held together: keep the direction while jumping, else switch to the new
// one. Mutates s.controls so everything downstream agrees.
@(private = "file")
resolve_left_right :: proc(s: ^Soldier) -> (input: Control_Input) {
	if .Left in s.controls && .Right in s.controls {
		input.pressed_left_right = true
		if s.was_jumping == s.was_running_left do s.controls -= {.Right}
		else do s.controls -= {.Left}
	} else {
		s.was_running_left = .Left in s.controls
		s.was_jumping = .Jump in s.controls
	}
	input.left = .Left in s.controls
	input.right = .Right in s.controls
	input.up = .Jump in s.controls
	input.down = .Crouch in s.controls
	input.jet = .Jet in s.controls
	input.prone = .Prone in s.controls
	return
}

// Jets. Jetting against a side jump's direction is a backflip; otherwise thrust.
@(private = "file")
jets_control :: proc(ctx: ^Context, w: ^World, s: ^Soldier, input: Control_Input) {
	anims := ctx.anims
	legs, body := &s.legs, &s.body
	backflip := input.jet &&
		((legs.id == .Jump_Side && ((s.direction == -1 && input.right) || (s.direction == 1 && input.left) || input.pressed_left_right)) ||
		 (legs.id == .Roll_Back && input.up))
	if backflip {
		anim_apply(anims, body, .Roll_Back)
		legs_apply(anims, s, .Roll_Back)
	} else if input.jet && s.jets > 0 {
		jet_force := w.gravity > 0.05 ? f32(JETSPEED) : w.gravity * 2
		if s.on_ground do s.forces.y = -2.5 * jet_force
		else if s.stance != .Prone do s.forces.y -= jet_force
		else do s.forces.x += f32(s.direction) * jet_force / 2
		if legs.id != .Get_Up && body.id != .Roll && body.id != .Roll_Back do legs_apply(anims, s, .Fall)
		s.jets -= 1
		if s.jets == 1 do s.jets = 0 // the last unit is spent outright while the key is held
	}
}

// Prone entry and exit: the get-up doubles as a jump wind-up near its end.
@(private = "file")
prone_control :: proc(ctx: ^Context, s: ^Soldier, input: ^Control_Input) {
	anims := ctx.anims
	legs, body := &s.legs, &s.body

	if input.prone && legs.id != .Get_Up && legs.id != .Prone && legs.id != .Prone_Move {
		legs_apply(anims, s, .Prone)
		if body.id != .Reload && body.id != .Change && body.id != .Throw_Weapon do anim_apply(anims, body, .Prone)
		s.old_direction = s.direction
		input.prone = false
	}

	// Get up: pressing prone again, or turning around.
	if s.stance == .Prone && (input.prone || s.direction != s.old_direction) &&
	   ((legs.id == .Prone && legs.frame > 23) || legs.id == .Prone_Move) {
		if legs.id != .Get_Up do anim_set(anims, legs, .Get_Up, 9)
		if body.id != .Reload && body.id != .Change && body.id != .Throw_Weapon do anim_apply(anims, body, .Get_Up, 9)
	}

	unprone := false
	if legs.id == .Get_Up && legs.frame > 20 && s.on_ground && input.up {
		if input.left || input.right do legs_apply(anims, s, .Jump_Side, legs.frame - 20)
		else do legs_apply(anims, s, .Jump, legs.frame - 15)
		unprone = true
	} else if legs.id == .Get_Up && legs.frame > 23 {
		if input.left || input.right do legs_apply(anims, s, (s.direction == 1) != input.left ? .Run : .Run_Back)
		else if !s.on_ground && input.up do legs_apply(anims, s, .Run)
		else do legs_apply(anims, s, .Stand)
		unprone = true
	}
	if unprone {
		s.stance = .Stand
		if body.id != .Reload && body.id != .Change && body.id != .Throw_Weapon do anim_apply(anims, body, .Stand)
	}
}

// Every 10 ticks: how close the muzzle is to cover (Control.pas). Probes 8 units along
// the arm from 5 units above the head, against map colliders and, in team games,
// crouched teammates.
@(private = "file")
cover_check :: proc(ctx: ^Context, w: ^World, index: u8) {
	if w.tick % 10 != 0 do return
	s := &w.soldiers[index]
	s.collider_distance = 255

	pose := soldier_pose(ctx.anims, s, s.pos)
	arm := vec2_normalize(pose[14] - pose[15]) * 8
	probe := pose[11] - {0, 5} + arm

	for c in ctx.level.colliders {
		if !c.active do continue
		if d := vec2_length(probe - c.pos); d < c.radius {
			s.collider_distance = u8(round_half_even(min(d, 253)))
			break
		}
	}
	if s.team == .None || s.team == .Spectator do return
	for &other, i in w.soldiers {
		if u8(i) == index || !other.active || other.team != s.team || other.stance != .Crouch do continue
		if d := vec2_length(probe - other.pos); d < SPRITE_RADIUS {
			s.collider_distance = u8(round_half_even(min(d, 253)))
			break
		}
	}
}

// Slow down movement while an animation runs at more than normal speed.
@(private = "file")
animation_slowdown :: proc(s: ^Soldier) {
	legs := &s.legs
	if legs.speed > 1 {
		#partial switch legs.id {
		case .Jump, .Jump_Side, .Roll, .Roll_Back, .Prone, .Run, .Run_Back:
			s.vel /= f32(legs.speed)
		}
		if legs.speed > 2 && (legs.id == .Prone_Move || legs.id == .Crouch_Run) do s.vel /= f32(legs.speed)
	}
}

// Locomotion: one situation wins per tick, in priority order: rolling, crouch-slide,
// prone crawl, side jump, jump, crouch, run, idle. Some body poses freeze it.
@(private = "file")
movement_control :: proc(ctx: ^Context, s: ^Soldier, input: Control_Input) {
	anims := ctx.anims
	legs, body := &s.legs, &s.body
	dir := f32(s.direction)
	left, right, up, down := input.left, input.right, input.up, input.down

	#partial switch body.id {
	case .Take_Off, .Piss, .Mercy, .Mercy2, .Victory, .Own:
		return
	}

	switch {
	case body.id == .Roll || body.id == .Roll_Back:
		if legs.id == .Roll {
			s.forces.x = s.on_ground ? dir * ROLLSPEED : dir * 2 * FLYSPEED
		} else if legs.id == .Roll_Back {
			s.forces.x = s.on_ground ? -dir * ROLLSPEED : -dir * 2 * FLYSPEED
			if legs.frame > 1 && legs.frame < 8 && up {
				s.forces.y -= JUMPDIRSPEED * 1.5
				s.forces.x *= 0.5
				s.vel.x *= 0.8
			}
		}

	case (right || left) && down:
		if !s.on_ground do break
		sign: f32 = right ? 1 : -1
		facing_move := (s.direction == 1) == right
		can_roll := legs.id == .Run || legs.id == .Run_Back || legs.id == .Fall || legs.id == .Prone_Move ||
		            (legs.id == .Prone && legs.frame >= 24)
		if can_roll {
			if legs.id == .Prone_Move || (legs.id == .Prone && legs.frame == anims[.Prone].num_frames) do s.stance = .Stand
			roll: Anim_Id = facing_move ? .Roll : .Roll_Back
			anim_apply(anims, body, roll)
			anim_set(anims, legs, roll)
		} else {
			legs_apply(anims, s, facing_move ? .Crouch_Run : .Crouch_Run_Back)
		}
		#partial switch legs.id {
		case .Crouch_Run, .Crouch_Run_Back: s.forces.x = sign * CROUCHRUNSPEED
		case .Roll, .Roll_Back:             s.forces.x = sign * 2 * CROUCHRUNSPEED
		}

	case legs.id == .Prone || legs.id == .Prone_Move || (legs.id == .Get_Up && body.id != .Throw && body.id != .Punch):
		if !s.on_ground do break
		if (legs.id == .Prone && legs.frame > 25) || legs.id == .Prone_Move {
			if left || right {
				if legs.frame < 4 || legs.frame > 14 do s.forces.x = left ? -PRONESPEED : PRONESPEED
				legs_apply(anims, s, .Prone_Move)
				#partial switch body.id {
				case .Clip_In, .Clip_Out, .Slide_Back, .Reload, .Change, .Throw, .Throw_Weapon:
				case:
					anim_apply(anims, body, .Prone_Move)
				}
				if legs.id != .Prone_Move do anim_set(anims, legs, .Prone_Move)
			} else {
				if legs.id != .Prone do anim_set(anims, legs, .Prone)
				legs.frame = 26
			}
		}

	case (right || left) && up:
		sign: f32 = right ? 1 : -1
		if s.on_ground {
			#partial switch legs.id {
			case .Run, .Run_Back, .Stand, .Crouch, .Crouch_Run, .Crouch_Run_Back:
				legs_apply(anims, s, .Jump_Side)
			}
			if legs.frame == anims[legs.id].num_frames do legs_apply(anims, s, .Run)
		} else if legs.id == .Roll || legs.id == .Roll_Back {
			legs_apply(anims, s, (s.direction == 1) == right ? .Run : .Run_Back)
		}
		if legs.id == .Jump && legs.frame < 10 do legs_apply(anims, s, .Jump_Side)
		if legs.id == .Jump_Side && legs.frame > 3 && legs.frame < 11 do s.forces = {sign * JUMPDIRSPEED, -JUMPDIRSPEED / 1.2}

	case up:
		if s.on_ground {
			legs_apply(anims, s, .Jump)
			if legs.frame == anims[legs.id].num_frames do legs_apply(anims, s, .Stand)
		}
		if legs.id == .Jump {
			if legs.frame > 8 && legs.frame < 15 do s.forces.y = -JUMPSPEED
			if legs.frame == anims[.Jump].num_frames do legs_apply(anims, s, .Fall)
		}

	case down:
		if s.on_ground do legs_apply(anims, s, .Crouch)

	case right || left:
		sign: f32 = right ? 1 : -1
		legs_apply(anims, s, (s.direction == 1) == right ? .Run : .Run_Back)
		if s.on_ground do s.forces = {sign * RUNSPEED, -RUNSPEEDUP}
		else do s.forces.x = sign * FLYSPEED

	case:
		legs_apply(anims, s, s.on_ground ? .Stand : .Fall)
	}
}

// Rolls run on both machines in lockstep; whichever started, the other follows.
@(private = "file")
roll_control :: proc(ctx: ^Context, s: ^Soldier, input: Control_Input) {
	anims := ctx.anims
	legs, body := &s.legs, &s.body

	if legs.id == .Roll && body.id != .Roll do anim_apply(anims, body, .Roll)
	if body.id == .Roll && legs.id != .Roll do legs_apply(anims, s, .Roll)
	if legs.id == .Roll_Back && body.id != .Roll_Back do anim_apply(anims, body, .Roll_Back)
	if body.id == .Roll_Back && legs.id != .Roll_Back do legs_apply(anims, s, .Roll_Back)
	if (body.id == .Roll || body.id == .Roll_Back) && legs.frame != body.frame {
		if legs.frame > body.frame do body.frame = legs.frame
		else do legs.frame = body.frame
	}

	if (body.id == .Roll || body.id == .Roll_Back) && body.frame == anims[body.id].num_frames {
		backflip := !s.on_ground && body.id == .Roll_Back && input.up
		if backflip {
			if input.left || input.right do legs_apply(anims, s, (s.direction == 1) != input.left ? .Run : .Run_Back)
			else do legs_apply(anims, s, .Fall)
		} else if input.down {
			if input.left || input.right do legs_apply(anims, s, body.id == .Roll ? .Crouch_Run : .Crouch_Run_Back)
			else do legs_apply(anims, s, .Crouch, 15)
		}
		anim_apply(anims, body, .Stand)
	}
}

// One-shot body animations fall back to the pose for the stance when they finish (or
// at once for the replaceable ones); the stance itself follows the legs.
@(private = "file")
body_pose_control :: proc(ctx: ^Context, s: ^Soldier) {
	anims := ctx.anims
	legs, body := &s.legs, &s.body

	returns_to_stance := (.Throw not_in s.controls && body_idle_animation(body.id)) ||
	                     (body.frame == anims[body.id].num_frames && body.id != .Prone) ||
	                     (s.weapon.fire_count == 0 && body.id == .Barret)
	if s.weapon.ammo > 0 && returns_to_stance {
		switch s.stance {
		case .Stand:
			anim_apply(anims, body, .Stand)
		case .Crouch:
			// Near cover the gun comes up over it; out of a recoil it resumes partway in.
			if s.collider_distance < 255 do anim_apply(anims, body, .Hands_Up_Aim, body.id == .Hands_Up_Recoil ? 11 : 1)
			else do anim_apply(anims, body, .Aim, body.id == .Aim_Recoil ? 6 : 1)
		case .Prone:
			anim_apply(anims, body, .Prone, 26)
		}
	}

	#partial switch legs.id {
	case .Crouch, .Crouch_Run, .Crouch_Run_Back: s.stance = .Crouch
	case .Prone, .Prone_Move:                    s.stance = .Prone
	case:                                        s.stance = .Stand
	}
}

// Leg transitions are blocked while lying down; Get_Up is the only way out of Prone.
legs_apply :: proc(anims: ^Anims, s: ^Soldier, id: Anim_Id, frame: i32 = 1) {
	if s.legs.id == .Prone || s.legs.id == .Prone_Move do return
	anim_apply(anims, &s.legs, id, frame)
}

// Body animations that the stance pose may replace at any frame.
@(private = "file")
body_idle_animation :: proc(id: Anim_Id) -> bool {
	#partial switch id {
	case .Recoil, .Small_Recoil, .Aim_Recoil, .Hands_Up_Recoil, .Shotgun, .Barret, .Change,
	     .Throw_Weapon, .Weapon_None, .Punch, .Roll, .Roll_Back, .Reload_Bow, .Cigar, .Match,
	     .Smoke, .Wipe, .Take_Off, .Groin, .Piss, .Mercy, .Mercy2, .Victory, .Own, .Reload,
	     .Prone, .Get_Up, .Prone_Move, .Melee:
		return false
	}
	return true
}
