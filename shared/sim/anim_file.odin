package sim

import "core:fmt"
import "core:os"
import "core:path/filepath"

// The animations and the skeleton objects from the base assets folder: file I/O,
// kept out of the pure sim files.

anims_load_files :: proc(base_dir: string) -> (anims: ^Anims, ok: bool) {
	anims = new(Anims)
	for &anim, id in anims {
		info := ANIM_INFO[id]
		path, _ := filepath.join({base_dir, "anims", info.file}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("failed to read %s: %v", path, err)
			free(anims)
			return nil, false
		}
		anim_parse(&anim, info, string(data))
	}
	return anims, true
}

// A particle object (gostek.po, flag.po, kit.po) at the scale Anims.pas loads it.
po_load_file :: proc(base_dir, file: string, scale: f32) -> (obj: Particle_Object, ok: bool) {
	path, _ := filepath.join({base_dir, "objects", file}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("failed to read %s: %v", path, err)
		return obj, false
	}
	return po_parse(string(data), scale), true
}

// The particle objects: the flag's and kit's cloth, the parachute, the stationary gun,
// the gostek for the corpses, and the rifle at every gun length the original uses
// (RifleSkeleton10..55).
skeletons_load_files :: proc(base_dir: string) -> (sk: ^Skeletons, ok: bool) {
	sk = new(Skeletons)
	sk.flag, ok = po_load_file(base_dir, "flag.po", FLAG_SCALE)
	if !ok do return sk, false
	sk.kit, ok = po_load_file(base_dir, "kit.po", KIT_SCALE)
	if !ok do return sk, false
	sk.para, ok = po_load_file(base_dir, "para.po", PARA_SCALE)
	if !ok do return sk, false
	sk.stat, ok = po_load_file(base_dir, "stat.po", STAT_SCALE)
	if !ok do return sk, false
	sk.gostek, ok = po_load_file(base_dir, "gostek.po", GOSTEK_SKELETON_SCALE)
	if !ok do return sk, false
	for scale, i in GUN_SCALES {
		sk.rifles[i], ok = po_load_file(base_dir, "karabin.po", scale)
		if !ok do return sk, false
	}
	return sk, true
}
