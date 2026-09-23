package geom

import "core:testing"

@(test)
test_rounds_halves_to_even :: proc(t: ^testing.T) {
	testing.expect_value(t, round_half_even(0.5), 0)
	testing.expect_value(t, round_half_even(1.5), 2)
	testing.expect_value(t, round_half_even(2.5), 2)
	testing.expect_value(t, round_half_even(2.4), 2)
	testing.expect_value(t, round_half_even(2.6), 3)
}

@(test)
test_a_near_zero_vector_normalizes_to_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, vec2_normalize({0.0001, 0}), Vec2{})
	testing.expect_value(t, vec2_normalize({3, 4}), Vec2{0.6, 0.8})
}

@(test)
test_a_segment_meets_a_circle_where_it_enters :: proc(t: ^testing.T) {
	p, hit := line_circle_collision({-10, 0}, {10, 0}, {0, 0}, 2)
	testing.expect(t, hit)
	testing.expect_value(t, p, Vec2{-2, 0})
	_, hit = line_circle_collision({-10, 5}, {10, 5}, {0, 0}, 2)
	testing.expect(t, !hit)
	p, hit = line_circle_collision({1, 0}, {10, 0}, {0, 0}, 2) // starts inside: the start
	testing.expect(t, hit)
	testing.expect_value(t, p, Vec2{1, 0})
}
