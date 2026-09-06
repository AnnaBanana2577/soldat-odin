package sim

import "core:math"

// The sim's own float paths, so every world computes the same numbers.

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

// xorshift64*: all sim randomness goes through World.rng.
rand_next :: proc(state: ^u64) -> u64 {
	x := state^
	if x == 0 do x = 0x9E3779B97F4A7C15
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	state^ = x
	return x * 0x2545F4914F6CDD1D
}

// Uniform in [0, 1).
rand_f32 :: proc(state: ^u64) -> f32 {
	return f32(rand_next(state) >> 40) / f32(1 << 24)
}

rand_int :: proc(state: ^u64, n: int) -> int {
	if n <= 0 do return 0
	return int(rand_next(state) % u64(n))
}
