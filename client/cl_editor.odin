package client

// The map editor, in the game's own window.
//
// The editor owns a pms.Map: the file as it really is, every field kept, down to the
// padding bytes (../../shared/pms). Everything drawn is *derived* from it, one way:
//
//	bytes := pms.write(map)   ->   sim.level_load(bytes)   ->   Map_View
//
// so the picture is built from exactly the bytes a save would write. A field the editor
// loses shows up as a change on screen rather than silently on disk, and there is no
// second copy of a map to keep in step. The game's loader is the right one to draw with
// and the wrong one to save from - it drops inactive props, scenery dates and the
// leftovers - which is why it is downstream of the codec and never the other way round.
//
//	client -cl_editor [-cl_base DIR] [-cl_map NAME]
//
//   toolbar.odin   the strip on top: open, save, and what to draw
//   layout.odin    where the panes sit, and the splitters between them
//   panels.odin    the map list and the inspector
//   overlays.odin  spawns, colliders and bot paths, over the map
//   newmap.odin    making a map and writing one back
//   theme.odin     the dark raygui palette

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../shared/pms"
import "../shared/sim"

WHEEL_ZOOM :: 1.15
NAME_MAX :: 64

Detail :: struct {
	label: string,
	value: string, // owned
}

// The one modal the editor has.
Dialog :: enum {
	None,
	New,
}

Editor :: struct {
	base:   string,
	names:  []string, // the .pms files in base/maps
	items:  cstring,  // the same, joined for raygui's list
	scroll: c.int,
	active: c.int,

	// The truth, and the picture derived from it.
	open:   pms.Map,
	file:   string, // what it is called on disk, owned
	level:  sim.Level,
	view:   Map_View,
	loaded: bool,

	camera:  Camera,
	layout:  Layout,
	drag:    Splitter,
	panning: bool,
	show:    Layers,

	dialog:   Dialog,
	name_buf: [NAME_MAX]u8, // the new map's name, as raygui edits it

	status:  string, // owned
	details: [dynamic]Detail,
}

// Open the editor on a share and run until the window closes. The window must already
// be open; the caller owns it.
// The editor as the client's other mode: opened, stepped a frame at a time by
// client_run, and closed. It shares the window with the game and owns nothing else.
editor_open :: proc(e: ^Editor, base: string, first_map: string) -> bool {
	e^ = Editor {
		base   = base,
		active = -1,
		layout = layout_default(),
		show   = DEFAULT_LAYERS,
		status = strings.clone("pick a map"),
	}
	reload_names(e)
	if len(e.names) == 0 {
		fmt.eprintfln("no maps in %s/maps", base)
		return false
	}
	e.camera.zoom = 1
	theme_apply()
	if first_map != "" do open_named(e, first_map)
	return true
}

editor_frame :: proc(e: ^Editor) {
	free_all(context.temp_allocator)
	panes := layout_panes(e.layout, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
	update(e, panes)
	editor_draw(e, panes)
}

@(private)
editor_destroy :: proc(e: ^Editor) {
	close_map(e)
	delete(e.items)
	delete(e.status)
	clear_details(e)
	delete(e.details)
	for name in e.names do delete(name)
	delete(e.names)
}

// ---- the map ----

// The .pms files on disk, and the joined copy raygui's list wants. Called again when a
// map is created, so the new one appears without a restart.
@(private)
reload_names :: proc(e: ^Editor) {
	for name in e.names do delete(name)
	delete(e.names)
	delete(e.items)

	names, _ := list_maps(e.base)
	e.names = names
	joined := strings.join(names, ";")
	defer delete(joined)
	e.items = strings.clone_to_cstring(joined)
}

@(private)
open_named :: proc(e: ^Editor, name: string) {
	wanted := name
	if !strings.has_suffix(wanted, ".pms") do wanted = fmt.tprintf("%s.pms", wanted)
	for candidate, i in e.names {
		if strings.equal_fold(candidate, wanted) {
			e.active = c.int(i)
			open_index(e, i)
			return
		}
	}
	set_status(e, fmt.aprintf("no map called %s", name))
}

@(private)
open_index :: proc(e: ^Editor, index: int) {
	if index < 0 || index >= len(e.names) do return
	path, _ := filepath.join({e.base, "maps", e.names[index]}, context.temp_allocator)

	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		set_status(e, fmt.aprintf("cannot read %s: %v", path, read_err))
		return
	}
	m, err := pms.read(data)
	if err != .None {
		set_status(e, fmt.aprintf("%s is not a map: %v", e.names[index], err))
		return
	}

	close_map(e)
	e.open = m
	e.file = strings.clone(e.names[index])
	if !rebuild(e) {
		set_status(e, fmt.aprintf("%s did not survive being rebuilt", e.names[index]))
		return
	}
	e.loaded = true
	camera_fit(&e.camera, map_view_bounds(&e.level))
	set_status(e, fmt.aprintf("%s  -  %d polygons", e.file, len(e.level.polys)))
	build_details(e)
}

// The one rule: the picture comes from the bytes a save would write.
@(private)
rebuild :: proc(e: ^Editor) -> bool {
	bytes := pms.write(&e.open)
	defer delete(bytes)

	map_view_unload(&e.view)
	if e.loaded do sim.level_destroy(&e.level)

	level, err := sim.level_load(bytes)
	if err != .None do return false
	e.level = level
	map_view_load(&e.view, e.base, &e.level)
	return true
}

@(private)
close_map :: proc(e: ^Editor) {
	if !e.loaded do return
	map_view_unload(&e.view)
	sim.level_destroy(&e.level)
	pms.destroy(&e.open)
	delete(e.file)
	e.file = ""
	e.loaded = false
}

// ---- input ----

@(private)
update :: proc(e: ^Editor, panes: Panes) {
	if e.dialog != .None do return // the modal has the keyboard and the mouse

	mouse := rl.GetMousePosition()
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	e.camera.viewport = panes.viewport

	// Splitters take the pointer first, so a drag that wanders over the viewport keeps
	// resizing rather than starting a pan.
	if e.drag != .None {
		layout_drag(&e.layout, e.drag, mouse, w, h)
		if rl.IsMouseButtonReleased(.LEFT) do e.drag = .None
	} else if rl.IsMouseButtonPressed(.LEFT) {
		e.drag = layout_hit(panes, mouse)
	}

	hover := e.drag != .None ? e.drag : layout_hit(panes, mouse)
	switch hover {
	case .List:      rl.SetMouseCursor(.RESIZE_EW)
	case .Inspector: rl.SetMouseCursor(.RESIZE_NS)
	case .None:      rl.SetMouseCursor(.DEFAULT)
	}

	if !e.loaded || e.drag != .None do return
	inside := in_rect(panes.viewport, mouse)

	if e.panning && !rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonDown(.MIDDLE) do e.panning = false
	if inside && (rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.MIDDLE)) do e.panning = true
	if e.panning {
		d := rl.GetMouseDelta()
		camera_pan(&e.camera, {d.x, d.y})
	}
	if inside {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			factor: f32 = wheel > 0 ? WHEEL_ZOOM : 1 / WHEEL_ZOOM
			camera_zoom_at(&e.camera, factor, {mouse.x, mouse.y})
		}
	}

	if rl.IsKeyPressed(.F) do camera_fit(&e.camera, map_view_bounds(&e.level))
	if rl.IsKeyPressed(.R) do e.layout = layout_default()
	if rl.IsKeyPressed(.M) do e.layout.list_open = !e.layout.list_open
	if rl.IsKeyPressed(.W) do toggle(e, .Wireframe)
	if rl.IsKeyPressed(.S) do toggle(e, .Scenery)
	if rl.IsKeyPressed(.P) do toggle(e, .Spawns)
	if rl.IsKeyPressed(.C) do toggle(e, .Colliders)
	if rl.IsKeyPressed(.B) do toggle(e, .Waypoints)
}

@(private)
toggle :: proc(e: ^Editor, layer: Layer) {
	if layer in e.show do e.show -= {layer}
	else do e.show += {layer}
}

// ---- the frame ----

@(private)
editor_draw :: proc(e: ^Editor, panes: Panes) {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	rl.ClearBackground(theme_color(BG))

	// A modal owns the window while it is up, so everything behind it is locked out.
	if e.dialog != .None do rl.GuiLock()

	draw_viewport(e, panes)
	if e.layout.list_open do draw_list(e, panes)
	draw_inspector(e, panes)
	draw_splitters(e, panes)
	draw_toolbar(e, panes)
	rl.GuiStatusBar(panes.status, temp_cstring(e.status))

	if e.dialog != .None {
		rl.GuiUnlock()
		draw_dialog(e)
	}
}

@(private)
draw_viewport :: proc(e: ^Editor, panes: Panes) {
	vp := panes.viewport
	rl.BeginScissorMode(c.int(vp.x), c.int(vp.y), c.int(vp.width), c.int(vp.height))
	defer rl.EndScissorMode()

	if !e.loaded {
		rl.DrawRectangleRec(vp, theme_color(PANEL))
		rl.DrawText("pick a map, or make one", c.int(vp.x) + 16, c.int(vp.y) + 16, 14, theme_color(TEXT_DIM))
		return
	}

	rl.DrawRectangleRec(vp, color_of(e.level.bg_bottom))
	rl.BeginMode2D(rl_camera(&e.camera))
	map_view_draw(&e.view, &e.camera, layer_parts(e.show))
	draw_overlays(e)
	rl.EndMode2D()
}

// ---- the new map dialog ----

@(private)
dialog_open_new :: proc(e: ^Editor) {
	e.dialog = .New
	e.name_buf = {}
}

@(private)
draw_dialog :: proc(e: ^Editor) {
	if e.dialog != .New do return
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	box := rl.Rectangle{w / 2 - 180, h / 2 - 70, 360, 140}
	text := cstring(raw_data(e.name_buf[:]))

	// -1 while it is still up; 0 is the close corner, then the buttons from 1.
	switch rl.GuiTextInputBox(box, "New map", "Name", "Cancel;Create", text, NAME_MAX - 1, nil) {
	case 0, 1:
		e.dialog = .None
	case 2:
		e.dialog = .None
		create_map(e, string(text))
	}
}

// ---- odds and ends ----

@(private)
set_status :: proc(e: ^Editor, owned: string) {
	delete(e.status)
	e.status = owned
}

@(private)
temp_cstring :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// The .pms files in a share's maps folder, sorted.
@(private)
list_maps :: proc(base: string, allocator := context.allocator) -> ([]string, bool) {
	dir, _ := filepath.join({base, "maps"}, context.temp_allocator)
	handle, open_err := os.open(dir)
	if open_err != nil do return nil, false
	defer os.close(handle)

	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil do return nil, false

	names := make([dynamic]string, 0, len(entries), allocator)
	for entry in entries {
		if entry.type != .Directory && strings.equal_fold(filepath.ext(entry.name), ".pms") {
			append(&names, strings.clone(entry.name, allocator))
		}
	}
	// Small lists; insertion sort keeps the dependency list short.
	for i in 1 ..< len(names) {
		item := names[i]
		j := i
		for j > 0 && strings.compare(names[j - 1], item) > 0 {
			names[j] = names[j - 1]
			j -= 1
		}
		names[j] = item
	}
	return names[:], true
}
