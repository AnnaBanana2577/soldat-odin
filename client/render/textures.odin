#+private
package render

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

// The map's own images: its texture and its scenery, found the way the original
// finds them.

// Soldat's polygon UVs run past 0..1 to tile the texture across a polygon.
map_texture_load :: proc(base, name: string) -> rl.Texture2D {
	dir, _ := filepath.join({base, "textures"}, context.temp_allocator)
	path, found := find_image(dir, name)
	if !found {
		fmt.eprintfln("map texture %q not found; drawing the polygons untextured", name)
		return {}
	}
	tex := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
	if tex.id == 0 do return {}
	rl.SetTextureWrap(tex, .REPEAT)
	rl.GenTextureMipmaps(&tex)
	rl.SetTextureFilter(tex, .TRILINEAR)
	return tex
}

// Scenery is keyed on pure green rather than carrying an alpha channel, as in the
// original's ApplyColorKey: a fully opaque (0, 255, 0) pixel becomes transparent.
scenery_load :: proc(base: string, names: []string) -> []rl.Texture2D {
	dir, _ := filepath.join({base, "scenery-gfx"}, context.temp_allocator)
	out := make([]rl.Texture2D, len(names))
	missing := 0
	for name, i in names {
		path, found := find_image(dir, name)
		if !found {
			missing += 1 // map authors ship custom scenery that is not in the base assets
			continue
		}
		img := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
		if img.data == nil do continue
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
		pixels := ([^][4]u8)(img.data)[:img.width * img.height]
		for &p in pixels do if p == {0, 255, 0, 255} do p = {}
		out[i] = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
	}
	if missing > 0 do fmt.eprintfln("%d of %d scenery images not found in %s", missing, len(names), dir)
	return out
}

// Resolves an image name the way the original's FindImagePath does: case-insensitively,
// preferring .png whatever extension the map asked for, then the name as written.
find_image :: proc(dir, name: string) -> (path: string, found: bool) {
	if name == "" do return "", false
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return "", false

	lower := strings.to_lower(name, context.temp_allocator)
	stem := lower
	if dot := strings.last_index_byte(lower, '.'); dot > 0 do stem = lower[:dot]
	as_png := strings.concatenate({stem, ".png"}, context.temp_allocator)

	best := ""
	for info in infos {
		if info.type == .Directory do continue
		actual := strings.to_lower(info.name, context.temp_allocator)
		if actual == as_png {
			path, _ = filepath.join({dir, info.name}, context.temp_allocator)
			return path, true
		}
		if actual == lower do best = info.name
	}
	if best != "" {
		path, _ = filepath.join({dir, best}, context.temp_allocator)
		return path, true
	}
	return "", false
}
