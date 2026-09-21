package editor

// The strip along the top: what to open, what to save, and what to draw.
//
// The layer checkboxes are generated from the Layer enum rather than listed by hand, so
// adding a layer is one enum member and one case in the drawing - the toolbar follows.

import "core:c"
import "core:fmt"
import rl "vendor:raylib"

import "../render"

BUTTON_H :: 22
BUTTON_W :: 64
CHECK_W :: 92 // label included
GAP :: 6

// What the viewport draws. Each of these is a checkbox up here.
Layer :: enum {
	Background,
	Polygons,
	Scenery,
	Wireframe,
	Spawns,
	Colliders,
	Waypoints,
}
Layers :: bit_set[Layer]

DEFAULT_LAYERS :: Layers{.Background, .Polygons, .Scenery}

// The four layers that belong to the map itself, as the renderer wants them.
layer_parts :: proc(l: Layers) -> render.Map_Parts {
	parts: render.Map_Parts
	if .Background in l do parts += {.Background}
	if .Polygons in l do parts += {.Polygons}
	if .Scenery in l do parts += {.Scenery}
	if .Wireframe in l do parts += {.Wireframe}
	return parts
}

@(private)
draw_toolbar :: proc(e: ^Editor, panes: Panes) {
	bar := panes.toolbar
	rl.DrawRectangleRec(bar, theme_color(PANEL))
	rl.DrawRectangleRec({bar.x, bar.y + bar.height - 1, bar.width, 1}, theme_color(LINE))

	x := bar.x + GAP
	y := bar.y + (bar.height - BUTTON_H) / 2

	// Opening the list is a toggle, so the button shows whether it is open.
	open := e.layout.list_open
	if rl.GuiToggle({x, y, BUTTON_W, BUTTON_H}, "Maps", &open) != 0 {
		e.layout.list_open = open
	}
	x += BUTTON_W + GAP

	if rl.GuiButton({x, y, BUTTON_W, BUTTON_H}, "New") do dialog_open_new(e)
	x += BUTTON_W + GAP

	// Nothing to save until a map is open.
	rl.GuiSetState(c.int(e.loaded ? rl.GuiState.STATE_NORMAL : rl.GuiState.STATE_DISABLED))
	if rl.GuiButton({x, y, BUTTON_W, BUTTON_H}, "Save") do save_map(e)
	x += BUTTON_W + GAP
	if rl.GuiButton({x, y, BUTTON_W, BUTTON_H}, "Fit") {
		render.camera_fit(&e.camera, render.map_view_bounds(&e.level))
	}
	rl.GuiSetState(c.int(rl.GuiState.STATE_NORMAL))
	x += BUTTON_W + GAP

	rl.DrawRectangleRec({x, bar.y + 6, 1, bar.height - 12}, theme_color(LINE))
	x += GAP

	// One checkbox per layer, in the enum's order.
	for layer in Layer {
		if x + CHECK_W > bar.x + bar.width do break // a narrow window simply shows fewer
		on := layer in e.show
		rl.GuiCheckBox({x, y + 3, 16, 16}, temp_cstring(fmt.tprint(layer)), &on)
		if on do e.show += {layer}
		else do e.show -= {layer}
		x += CHECK_W
	}
}
