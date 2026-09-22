package sim

import "core:strings"

// What is read from disk once and then only read: the animations, the skeletons, the
// weapon table and the map in play. The client and the server load the same things the
// same way, so they load them from here.
//
// The Context points into this and is set when the content is, so the two cannot fall
// out of step. Everything that simulates takes the Context and never the Content.
Content :: struct {
	ctx:       Context,
	level:     Level,
	anims:     ^Anims,
	skeletons: ^Skeletons,
	base:      string, // where the maps and the art are read from
	map_name:  string, // the map in play, once one is loaded
	loads:     int,    // maps loaded so far: what anything built per map is rebuilt by
}

// The data every map shares. False when it is not there to read, which is fatal to both
// programs: nothing can be simulated without the animations and the skeletons.
content_load :: proc(c: ^Content, base: string) -> bool {
	ok: bool
	c.base = base
	if c.anims, ok = anims_load_files(base); !ok do return false
	if c.skeletons, ok = skeletons_load_files(base); !ok do return false
	c.ctx.level = &c.level
	c.ctx.anims = c.anims
	c.ctx.skeletons = c.skeletons
	weapons_default(&c.ctx.weapons)
	return true
}

// The named map in place of whatever was loaded before it. False when the map is not
// here, and what was loaded before is left alone.
content_load_map :: proc(c: ^Content, name: string) -> bool {
	level, ok := level_load_file(c.base, name)
	if !ok do return false
	if c.loads > 0 do level_destroy(&c.level)
	c.level = level
	c.ctx.level = &c.level // the level moved, so what points at it follows
	delete(c.map_name)
	c.map_name = strings.clone(name)
	c.loads += 1
	return true
}

content_destroy :: proc(c: ^Content) {
	if c.loads > 0 do level_destroy(&c.level)
	delete(c.map_name)
	free(c.anims)
	free(c.skeletons)
}
