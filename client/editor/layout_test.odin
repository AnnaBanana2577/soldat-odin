package editor

// The panes have to tile the window exactly, survive being dragged to both extremes, and
// track the pointer. All of that is arithmetic, so none of it needs a window.

import "core:testing"

@(private = "file")
near :: proc(a, b: f32, tolerance: f32 = 0.01) -> bool {
	return abs(a - b) <= tolerance
}

@(test)
test_panes_tile_the_window :: proc(t: ^testing.T) {
	width, height: f32 = 1280, 800
	p := layout_panes(layout_default(), width, height)

	testing.expect(t, near(p.list.width + SPLITTER + p.viewport.width, width), "columns do not fill the width")
	testing.expect(t, near(p.viewport.x, p.list.width + SPLITTER), "the viewport is not against the splitter")
	testing.expect(
		t,
		near(p.viewport.height + SPLITTER + p.inspector.height, height - STATUS_HEIGHT),
		"the right column does not fill the height",
	)
	testing.expect(t, near(p.inspector.y, p.viewport.y + p.viewport.height + SPLITTER), "the inspector floats")
	testing.expect(t, near(p.status.y, height - STATUS_HEIGHT), "the status bar is misplaced")
	testing.expect(t, near(p.status.width, width), "the status bar is not full width")
	testing.expect(t, near(p.inspector.x, p.viewport.x), "the inspector is not under the viewport")
}

@(test)
test_panes_keep_minimum_sizes :: proc(t: ^testing.T) {
	width, height: f32 = 1000, 700

	p := layout_panes(Layout{list = -5, inspector = 0.2}, width, height)
	testing.expectf(t, p.list.width >= MIN_LIST, "list collapsed to %v", p.list.width)

	p = layout_panes(Layout{list = 5, inspector = 0.2}, width, height)
	testing.expectf(t, p.viewport.width >= MIN_VIEWPORT_W, "viewport collapsed to %v", p.viewport.width)

	p = layout_panes(Layout{list = 0.2, inspector = 5}, width, height)
	testing.expectf(t, p.viewport.height >= MIN_VIEWPORT_H, "viewport height collapsed to %v", p.viewport.height)

	// The inspector may be dragged shut, but never at the viewport's expense.
	p = layout_panes(Layout{list = 0.2, inspector = -1}, width, height)
	testing.expect(t, p.inspector.height >= 0, "the inspector went negative")
	testing.expect(t, p.viewport.height > 0, "the viewport vanished")
}

// A user can drag a window smaller than the minimums put together.
@(test)
test_panes_survive_a_tiny_window :: proc(t: ^testing.T) {
	for size in ([?][2]f32{{1, 1}, {40, 30}, {200, 120}, {0, 0}}) {
		p := layout_panes(layout_default(), size[0], size[1])
		testing.expectf(t, p.list.width > 0, "list width %v at %v", p.list.width, size)
		testing.expectf(t, p.viewport.width > 0, "viewport width %v at %v", p.viewport.width, size)
		testing.expectf(t, p.viewport.height > 0, "viewport height %v at %v", p.viewport.height, size)
		testing.expectf(t, p.inspector.height >= 0, "inspector height %v at %v", p.inspector.height, size)
	}
}

@(test)
test_hit_testing_finds_the_splitters :: proc(t: ^testing.T) {
	p := layout_panes(layout_default(), 1280, 800)

	testing.expect_value(t, layout_hit(p, {p.list_splitter.x + SPLITTER / 2, 300}), Splitter.List)
	testing.expect_value(
		t,
		layout_hit(p, {p.bottom_splitter.x + 200, p.bottom_splitter.y + SPLITTER / 2}),
		Splitter.Inspector,
	)
	testing.expect_value(t, layout_hit(p, {p.list.width / 2, 200}), Splitter.None)
	testing.expect_value(t, layout_hit(p, {p.viewport.x + 100, p.viewport.height / 2}), Splitter.None)
	testing.expect_value(t, layout_hit(p, {100, p.status.y + 5}), Splitter.None)
}

// A splitter that drifts away from the cursor during a drag is the classic bug here.
@(test)
test_dragging_puts_the_splitter_under_the_pointer :: proc(t: ^testing.T) {
	width, height: f32 = 1280, 800
	l := layout_default()

	for target in ([?]f32{300, 500, 800, 220}) {
		layout_drag(&l, .List, {target, 400}, width, height)
		p := layout_panes(l, width, height)
		testing.expectf(
			t,
			near(p.list_splitter.x, target, 1),
			"dragged the list splitter to %v, it landed at %v",
			target,
			p.list_splitter.x,
		)
	}

	for target in ([?]f32{600, 400, 700}) {
		layout_drag(&l, .Inspector, {900, target}, width, height)
		p := layout_panes(l, width, height)
		testing.expectf(
			t,
			near(p.bottom_splitter.y, target, 1),
			"dragged the bottom splitter to %v, it landed at %v",
			target,
			p.bottom_splitter.y,
		)
	}
}

@(test)
test_dragging_does_not_move_the_other_splitter :: proc(t: ^testing.T) {
	width, height: f32 = 1280, 800
	l := layout_default()
	before := layout_panes(l, width, height)

	layout_drag(&l, .List, {420, 300}, width, height)
	after := layout_panes(l, width, height)

	testing.expect(t, !near(after.list_splitter.x, before.list_splitter.x), "the list splitter did not move")
	testing.expect(
		t,
		near(after.bottom_splitter.y, before.bottom_splitter.y),
		"dragging the list splitter moved the bottom one",
	)
}

// The fractions are proportions, so the same layout in a bigger window keeps its shape.
@(test)
test_layout_scales_with_the_window :: proc(t: ^testing.T) {
	l := Layout{list = 0.25, inspector = 0.3}
	small := layout_panes(l, 1000, 700)
	large := layout_panes(l, 2000, 1400)

	testing.expect(t, near(small.list.width * 2, large.list.width, 1), "the list did not scale with the width")
	testing.expect(
		t,
		near(
			small.viewport.width / small.viewport.height,
			large.viewport.width / large.viewport.height,
			0.05,
		),
		"the viewport changed shape",
	)
}

@(test)
test_dragging_is_clamped_by_the_panes :: proc(t: ^testing.T) {
	width, height: f32 = 900, 600
	l := layout_default()

	layout_drag(&l, .List, {width + 500, 300}, width, height)
	p := layout_panes(l, width, height)
	testing.expectf(t, p.viewport.width >= MIN_VIEWPORT_W, "viewport squeezed to %v", p.viewport.width)

	layout_drag(&l, .Inspector, {500, -200}, width, height)
	p = layout_panes(l, width, height)
	testing.expectf(t, p.viewport.height >= MIN_VIEWPORT_H, "viewport squeezed to %v", p.viewport.height)
}
