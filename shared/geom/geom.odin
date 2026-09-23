// Package geom is the arithmetic the sim shares: Vec2, the vector procedures, the
// distances and the one rounding, on the sim's own float paths so that every world
// computes the same numbers. It knows no type but Vec2; what tests a point against a
// polygon is the level's, and what rolls the dice is the sim's.
package geom

import "core:math"

Vec2 :: [2]f32

vec2_length :: proc(v: Vec2) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// Near-zero vectors normalize to zero rather than NaN (matches OpenSoldat).
vec2_normalize :: proc(v: Vec2) -> Vec2 {
	l := vec2_length(v)
	if l < 0.001 && l > -0.001 do return {}
	return v / l
}

vec2_dot :: proc(a, b: Vec2) -> f32 {
	return a.x * b.x + a.y * b.y
}

sqrt_f32 :: proc(x: f32) -> f32 {
	return math.sqrt(x)
}

// Distance from p3 to the infinite line through p1 and p2.
point_line_distance :: proc(p1, p2, p3: Vec2) -> f32 {
	d := p2 - p1
	u := ((p3.x - p1.x) * d.x + (p3.y - p1.y) * d.y) / max(math.F32_MIN, d.x * d.x + d.y * d.y)
	closest := p1 + u * d
	return vec2_length(closest - p3)
}

// Pascal's Round() uses banker's rounding; sector lookups depend on it.
round_half_even :: proc(x: f32) -> int {
	f := math.floor(x)
	diff := x - f
	switch {
	case diff > 0.5: return int(f) + 1
	case diff < 0.5: return int(f)
	}
	i := int(f)
	return i % 2 == 0 ? i : i + 1
}

// First intersection of segment start-end with a circle (the start if already inside).
line_circle_collision :: proc(start, end, center: Vec2, radius: f32) -> (point: Vec2, hit: bool) {
	r2 := radius * radius
	if vec2_dot(start - center, start - center) <= r2 do return start, true
	if vec2_dot(end - center, end - center) <= r2 do return end, true
	d := end - start
	a := vec2_dot(d, d)
	if a < 1e-10 do return {}, false
	f := start - center
	b := 2 * vec2_dot(f, d)
	c := vec2_dot(f, f) - r2
	disc := b * b - 4 * a * c
	if disc < 0 do return {}, false
	sq := sqrt_f32(disc)
	t1 := (-b - sq) / (2 * a)
	t2 := (-b + sq) / (2 * a)
	if t1 >= 0 && t1 <= 1 do return start + d * t1, true
	if t2 >= 0 && t2 <= 1 do return start + d * t2, true
	return {}, false
}
