package editor

// The map editor, in the game's own window.
//
// The editor owns a pms.Map: the file as it really is, every field kept, down to the
// padding bytes (../../shared/pms). Everything drawn is *derived* from it, one way:
//
//	bytes := pms.write(map)   ->   sim.level_load(bytes)   ->   render.Map_View
//
// so the picture is built from exactly the bytes a save would write. A field the editor
// loses shows up as a change on screen rather than silently on disk, and there is no
// second copy of a map to keep in step. The game's loader is the right one to draw with
// and the wrong one to save from - it drops inactive props, scenery dates and the
// leftovers - which is why it is downstream of the codec and never the other way round.
//
//	client -cl_editor [-cl_base DIR] [-cl_map NAME]

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../render"
import "../../shared/pms"
import "../../shared/sim"

WHEEL_ZOOM :: 1.15

Detail :: struct {
	label: string,
	value: string, // owned
}

Editor :: struct {
	base:   string,
	names:  []string, // the .pms files in base/maps
	items:  cstring,  // the same, joined for raygui's list
	scroll: c.int,
	active: c.int,

	// The truth, and the picture derived from it.
	open:   pms.Map,
	level:  sim.Level,
	view:   render.Map_View,
	loaded: bool,

	camera:    render.Camera,
	layout:    Layout,
	drag:      Splitter,
	panning:   bool,
	wireframe: bool,

	status:  string, // owned
	details: [dynamic]Detail,
}

// Open the editor on a share and run until the window closes. The window must already
// be open; the caller owns it.
run :: proc(base: string, first_map: string) {
	e := Editor {
		base   = base,
		active = -1,
		layout = layout_default(),
		status = strings.clone("pick a map"),
	}
	defer editor_destroy(&e)

	names, ok := list_maps(base)
	if !ok || len(names) == 0 {
		fmt.eprintfln("no maps in %s/maps", base)
		return
	}
	e.names = names
	joined := strings.join(names, ";")
	defer delete(joined)
	e.items = strings.clone_to_cstring(joined)

	e.camera.zoom = 1
	theme_apply()
	if first_map != "" do open_named(&e, first_map)

	for !rl.WindowShouldClose() {
		free_all(context.temp_allocator)
		panes := layout_panes(e.layout, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
		update(&e, panes)
		draw(&e, panes)
	}
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
	if !rebuild(e) {
		set_status(e, fmt.aprintf("%s did not survive being rebuilt", e.names[index]))
		return
	}
	e.loaded = true
	render.camera_fit(&e.camera, render.map_view_bounds(&e.level))
	set_status(e, fmt.aprintf("%s  -  %d polygons", e.names[index], len(e.level.polys)))
	build_details(e)
}

// The one rule: the picture comes from the bytes a save would write.
@(private)
rebuild :: proc(e: ^Editor) -> bool {
	bytes := pms.write(&e.open)
	defer delete(bytes)

	render.map_view_unload(&e.view)
	if e.loaded do sim.level_destroy(&e.level)

	level, err := sim.level_load(bytes)
	if err != .None do return false
	e.level = level
	render.map_view_load(&e.view, e.base, &e.level)
	return true
}

@(private)
close_map :: proc(e: ^Editor) {
	if !e.loaded do return
	render.map_view_unload(&e.view)
	sim.level_destroy(&e.level)
	pms.destroy(&e.open)
	e.loaded = false
}

// ---- input ----

@(private)
update :: proc(e: ^Editor, panes: Panes) {
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
		render.camera_pan(&e.camera, {d.x, d.y})
	}
	if inside {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			factor: f32 = wheel > 0 ? WHEEL_ZOOM : 1 / WHEEL_ZOOM
			render.camera_zoom_at(&e.camera, factor, {mouse.x, mouse.y})
		}
	}

	if rl.IsKeyPressed(.F) do render.camera_fit(&e.camera, render.map_view_bounds(&e.level))
	if rl.IsKeyPressed(.W) do e.wireframe = !e.wireframe
	if rl.IsKeyPressed(.R) do e.layout = layout_default()
}

// ---- the frame ----

@(private)
draw :: proc(e: ^Editor, panes: Panes) {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	rl.ClearBackground(theme_color(BG))

	draw_viewport(e, panes)
	draw_list(e, panes)
	draw_inspector(e, panes)
	draw_splitters(e, panes)
	rl.GuiStatusBar(panes.status, temp_cstring(e.status))
}

@(private)
draw_viewport :: proc(e: ^Editor, panes: Panes) {
	vp := panes.viewport
	rl.BeginScissorMode(c.int(vp.x), c.int(vp.y), c.int(vp.width), c.int(vp.height))
	defer rl.EndScissorMode()

	if !e.loaded {
		rl.DrawRectangleRec(vp, theme_color(PANEL))
		rl.DrawText("pick a map on the left", c.int(vp.x) + 16, c.int(vp.y) + 16, 14, theme_color(TEXT_DIM))
		return
	}

	rl.DrawRectangleRec(vp, render.color_of(e.level.bg_bottom))
	rl.BeginMode2D(render.rl_camera(&e.camera))
	render.map_view_draw(&e.view, &e.camera, e.wireframe)
	rl.EndMode2D()
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
