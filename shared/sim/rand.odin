package sim

// The sim's own randomness, so every world rolls the same: xorshift64*, from World.rng,
// from a soldier's own rng for what its player rolls, and from a bullet's own numbers
// for what happens to it in flight.

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
