package editor

// The panels around the viewport: the map list, the inspector, the splitters between
// them. raygui draws all of it; where each piece goes comes from layout.odin.

import "core:fmt"
import rl "vendor:raylib"

import "../render"
import "../../shared/pms"

PAD :: 8
ROW :: 18

@(private)
draw_list :: proc(e: ^Editor, panes: Panes) {
	rl.GuiPanel(panes.list, "maps")

	list := rl.Rectangle {
		panes.list.x + PAD,
		panes.list.y + 28,
		max(panes.list.width - 2 * PAD, 1),
		max(panes.list.height - 28 - PAD - 26, 1),
	}
	before := e.active
	rl.GuiListView(list, e.items, &e.scroll, &e.active)
	if e.active != before && e.active >= 0 do open_index(e, int(e.active))

	fit := rl.Rectangle {
		panes.list.x + PAD,
		panes.list.y + panes.list.height - PAD - 22,
		max(panes.list.width - 2 * PAD, 1),
		22,
	}
	if rl.GuiButton(fit, "Fit  (F)") && e.loaded {
		render.camera_fit(&e.camera, render.map_view_bounds(&e.level))
	}
}

@(private)
draw_inspector :: proc(e: ^Editor, panes: Panes) {
	if panes.inspector.height < 4 do return // dragged shut
	rl.GuiPanel(panes.inspector, "map")
	if !e.loaded do return

	// As many label/value rows as fit, in as many columns as the pane allows.
	top := panes.inspector.y + 26
	available := panes.inspector.height - 26 - PAD
	rows := max(int(available / ROW), 1)
	columns := max((len(e.details) + rows - 1) / rows, 1)
	column_w := max((panes.inspector.width - 2 * PAD) / f32(columns), 120)

	for detail, i in e.details {
		x := panes.inspector.x + PAD + f32(i / rows) * column_w
		y := top + f32(i % rows) * ROW
		if y + ROW > panes.inspector.y + panes.inspector.height do continue
		rl.GuiLabel({x, y, 74, ROW}, temp_cstring(detail.label))
		rl.GuiLabel({x + 78, y, column_w - 82, ROW}, temp_cstring(detail.value))
	}
}

@(private)
draw_splitters :: proc(e: ^Editor, panes: Panes) {
	hover := layout_hit(panes, rl.GetMousePosition())
	band :: proc(r: rl.Rectangle, lit: bool) {
		rl.DrawRectangleRec(r, theme_color(BG))
		// A thin line down the middle of the grab band: the target is six pixels wide,
		// but it should not look like six pixels of dead space.
		colour := theme_color(lit ? ACCENT : LINE)
		if r.width < r.height {
			rl.DrawRectangleRec({r.x + r.width / 2 - 0.5, r.y, 1, r.height}, colour)
		} else {
			rl.DrawRectangleRec({r.x, r.y + r.height / 2 - 0.5, r.width, 1}, colour)
		}
	}
	band(panes.list_splitter, hover == .List || e.drag == .List)
	band(panes.bottom_splitter, hover == .Inspector || e.drag == .Inspector)
}

// ---- what the inspector shows ----

@(private)
clear_details :: proc(e: ^Editor) {
	for detail in e.details do delete(detail.value)
	clear(&e.details)
}

// Read off the pms.Map, not the level: the point of the inspector is to show what is in
// the file, including the parts the game's loader throws away.
@(private)
build_details :: proc(e: ^Editor) {
	clear_details(e)
	m := &e.open

	add :: proc(e: ^Editor, label: string, value: string) {
		append(&e.details, Detail{label = label, value = value})
	}

	drawn, active_spawns, active_waypoints := 0, 0, 0
	for &p in m.props {
		if p.active != 0 && p.level <= 2 && p.style > 0 && int(p.style) <= len(m.scenery) do drawn += 1
	}
	for &s in m.spawnpoints do if s.active != 0 do active_spawns += 1
	for &w in m.waypoints do if w.active != 0 do active_waypoints += 1

	low, high := render.map_view_bounds(&e.level)

	add(e, "name", fmt.aprint(pms.text_of(m.name[:])))
	add(e, "texture", fmt.aprint(pms.text_of(m.texture[:])))
	add(e, "polygons", fmt.aprintf("%d", len(m.polygons)))
	add(e, "extents", fmt.aprintf("%.0f x %.0f", high.x - low.x, high.y - low.y))
	add(e, "props", fmt.aprintf("%d (%d drawn)", len(m.props), drawn))
	add(e, "scenery", fmt.aprintf("%d", len(m.scenery)))
	add(e, "colliders", fmt.aprintf("%d", len(m.colliders)))
	add(e, "spawns", fmt.aprintf("%d", active_spawns))
	add(e, "waypoints", fmt.aprintf("%d (%d active)", len(m.waypoints), active_waypoints))
	// The bytes past the end of a previous, longer save. The game never sees these.
	add(e, "leftovers", len(m.trailing) == 0 ? fmt.aprint("none") : fmt.aprintf("%d bytes", len(m.trailing)))
	add(e, "jet", fmt.aprintf("%d raw", m.start_jet))
}
