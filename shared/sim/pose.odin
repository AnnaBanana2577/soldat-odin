package sim

import "core:strconv"
import "core:strings"

// The skeleton pose: where each of the gostek's points is for a soldier, from its
// legs and body animation frames, its stance and its aim. Gameplay only moves the
// body particle; the pose is derived on demand for hit tests, hands and drawing.
// Ported from the old Odin port.

POSE_POINTS :: MAX_ANIM_POINTS

Pose :: [POSE_POINTS]Vec2 // 0-based; point n in the original data is index n-1

// Particle/constraint object (.po): the gostek, flag and kit skeletons.
Particle_Object :: struct {
	points:      [dynamic]Vec2,
	constraints: [dynamic][2]int, // 0-based point indices
}

po_parse :: proc(text: string, scale: f32, allocator := context.allocator) -> (obj: Particle_Object) {
	obj.points = make([dynamic]Vec2, allocator)
	obj.constraints = make([dynamic][2]int, allocator)
	lines := text
	next :: proc(s: ^string) -> (string, bool) {
		line, ok := strings.split_lines_iterator(s)
		return strings.trim_space(line), ok
	}
	for {
		name, ok := next(&lines)
		if !ok || name == "CONSTRAINTS" do break
		xs, _ := next(&lines)
		_, _ = next(&lines)
		zs, _ := next(&lines)
		x, _ := strconv.parse_f32(xs)
		z, _ := strconv.parse_f32(zs)
		append(&obj.points, Vec2{-x * scale / 1.2, -z * scale})
	}
	for {
		a, ok := next(&lines)
		if !ok || a == "ENDFILE" do break
		b, _ := next(&lines)
		if len(a) < 2 || len(b) < 2 do break
		pa, _ := strconv.parse_int(a[1:], 10)
		pb, _ := strconv.parse_int(b[1:], 10)
		append(&obj.constraints, [2]int{pa - 1, pb - 1})
	}
	return
}

po_destroy :: proc(obj: ^Particle_Object) {
	delete(obj.points)
	delete(obj.constraints)
}

// The pose of a living soldier drawn at pos (usually an interpolated position).
soldier_pose :: proc(anims: ^Anims, s: ^Soldier, pos: Vec2) -> (p: Pose) {
	dir := f32(s.direction)
	legs := anim_frame(anims, s.legs)
	body := anim_frame(anims, s.body)

	body_y: f32
	switch s.stance {
	case .Stand:  body_y = 8
	case .Crouch: body_y = 9
	case .Prone:
		body_y = 9
		if s.body.id == .Prone do body_y = s.body.frame > 9 ? -2 : 14 - f32(s.body.frame)
		if s.body.id == .Prone_Move do body_y = 0
	}
	if s.body.id == .Get_Up do body_y = s.body.frame > 18 ? 8 : 4

	LEG_POINTS :: bit_set[0 ..< POSE_POINTS]{0, 1, 2, 3, 4, 5, 16, 17}
	for i in 0 ..< POSE_POINTS {
		if i in LEG_POINTS do p[i] = pos + {dir * legs[i].x, legs[i].y}
	}
	hip_y := p[5].y
	for i in 0 ..< POSE_POINTS {
		if i not_in LEG_POINTS do p[i] = {pos.x + dir * body[i].x, hip_y + body_y + body[i].y}
	}

	// The head and arms turn toward the aim point.
	head := vec2_normalize(p[11] - s.aim)
	p[11] = p[8] + dir * Vec2{-head.y, head.x} * 0.1

	#partial switch s.body.id {
	case .Reload, .Reload_Bow, .Clip_In, .Clip_Out, .Slide_Back, .Change, .Throw_Weapon,
	     .Weapon_None, .Punch, .Roll, .Roll_Back, .Cigar, .Match, .Smoke, .Wipe, .Take_Off,
	     .Groin, .Piss, .Mercy, .Mercy2, .Victory, .Own, .Melee:
	case:
		throwing := s.body.id == .Throw
		p[14] = p[15] + vec2_normalize(p[14] - s.aim) * (throwing ? -5 : -7)
		p[18] = p[15] + {0, -4} + vec2_normalize(p[18] - s.aim) * (throwing ? -6 : -8)
	}
	return
}
