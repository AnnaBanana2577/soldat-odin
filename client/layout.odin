package client

import rl "vendor:raylib"

// Where the panes sit, and what dragging a splitter does to them.
//
// raygui has no docking and no layout manager: every control is drawn into a rectangle
// you worked out yourself. So this is that arithmetic, kept apart from the drawing
// because it is the part that can be wrong in a way a test can catch.
//
//   +------------------------------+
//   | toolbar                      |
//   +--------+---------------------+
//   | list   |  viewport           |
//   | (may   |=====================|  <- drag to resize the inspector
//   |  hide) |  inspector          |
//   +========+---------------------+  <- drag to resize the list
//   | status                       |
//   +------------------------------+

TOOLBAR_HEIGHT :: 30
STATUS_HEIGHT :: 24
// The grab band is wider than the line drawn in it: a 1px target is miserable to hit.
SPLITTER :: 6

MIN_LIST :: 140
MIN_VIEWPORT_W :: 220
MIN_VIEWPORT_H :: 140

// What the window is divided into. The splits are fractions rather than pixels, so a
// resize keeps the proportions the user chose.
Layout :: struct {
	list:      f32, // of the window width
	inspector: f32, // of the right column's height
	list_open: bool,
}

layout_default :: proc() -> Layout {
	return Layout{list = 0.18, inspector = 0.22, list_open = true}
}

Panes :: struct {
	toolbar:         rl.Rectangle,
	list:            rl.Rectangle, // zero width when the list is hidden
	viewport:        rl.Rectangle,
	inspector:       rl.Rectangle,
	status:          rl.Rectangle,
	list_splitter:   rl.Rectangle, // zero width when the list is hidden
	bottom_splitter: rl.Rectangle,
}

Splitter :: enum {
	None,
	List,
	Inspector,
}

// Divide a window. Sizes are clamped so no pane can be squeezed out of existence, which
// means the fractions a caller holds are advisory rather than obeyed exactly.
layout_panes :: proc(l: Layout, width, height: f32) -> Panes {
	w, h := max(width, 1), max(height, 1)
	top := f32(TOOLBAR_HEIGHT)
	body := max(h - top - STATUS_HEIGHT, 1)

	// The list, the splitter that resizes it, and whatever is left for the right column.
	list_w, gap: f32 = 0, 0
	if l.list_open {
		max_list := max(w - SPLITTER - MIN_VIEWPORT_W, MIN_LIST)
		list_w = min(clamp(l.list * w, MIN_LIST, max_list), max(w - SPLITTER, 1))
		gap = SPLITTER
	}
	right_x := list_w + gap
	right_w := max(w - right_x, 1)

	// The inspector eats into the bottom of the right column.
	max_inspector := max(body - SPLITTER - MIN_VIEWPORT_H, 0)
	inspector_h := clamp(l.inspector * body, 0, max_inspector)
	viewport_h := max(body - inspector_h - SPLITTER, 1)

	return Panes {
		toolbar         = {0, 0, w, top},
		list            = {0, top, list_w, body},
		list_splitter   = {list_w, top, gap, body},
		viewport        = {right_x, top, right_w, viewport_h},
		bottom_splitter = {right_x, top + viewport_h, right_w, SPLITTER},
		inspector       = {right_x, top + viewport_h + SPLITTER, right_w, inspector_h},
		status          = {0, top + body, w, STATUS_HEIGHT},
	}
}

in_rect :: proc(r: rl.Rectangle, p: rl.Vector2) -> bool {
	return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height
}

// Which splitter is under the pointer, if any. A hidden list has a zero-width band, so
// it can never be grabbed.
layout_hit :: proc(p: Panes, mouse: rl.Vector2) -> Splitter {
	if in_rect(p.list_splitter, mouse) do return .List
	if in_rect(p.bottom_splitter, mouse) do return .Inspector
	return .None
}

// Move a splitter to the pointer. The fraction is recomputed from the position rather
// than accumulated from deltas, so a drag cannot drift away from the cursor.
layout_drag :: proc(l: ^Layout, which: Splitter, mouse: rl.Vector2, width, height: f32) {
	w, h := max(width, 1), max(height, 1)
	body := max(h - TOOLBAR_HEIGHT - STATUS_HEIGHT, 1)
	switch which {
	case .None:
	case .List:
		l.list = clamp(mouse.x / w, 0, 1)
	case .Inspector:
		// The pointer sits on the inspector's top edge, so its height is what is below.
		l.inspector = clamp((body - (mouse.y - TOOLBAR_HEIGHT) - SPLITTER) / body, 0, 1)
	}
}
