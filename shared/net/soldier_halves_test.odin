package net

import "base:runtime"
import "core:mem"
import "core:testing"
import "../sim"

// A soldier's two halves are each listed twice: what is copied out of a received state
// (sim.soldier_copy_owned, soldier_copy_served) and what crosses the wire (ser_owned,
// ser_served). A field in one list and not the other is a silent desync, so these hold
// the lists together: a soldier with something in every field, sent and read back, must
// be the same as that soldier copied.

@(test)
owned_half_in_step :: proc(t: ^testing.T) {
	anims := new(sim.Anims) // their pace is looked up on a copy; an empty table gives both the same
	defer free(anims)
	full, wired, copied: sim.Soldier
	fill(&full)

	buf: [MAX_PACKET]u8
	w := stream_writer(buf[:])
	ser_owned(&w, &full)
	r := stream_reader(buf[:w.pos])
	ser_owned(&r, &wired)
	testing.expect(t, stream_finish(&w) && stream_finish(&r))

	sim.soldier_copy_owned(anims, &copied, &full)
	wired.legs, wired.body = pace(wired.legs), pace(wired.body) // the wire carries an animation's id and frame
	testing.expect(t, mem.compare_ptrs(&wired, &copied, size_of(sim.Soldier)) == 0, "ser_owned and soldier_copy_owned list different fields")
}

@(test)
served_half_in_step :: proc(t: ^testing.T) {
	full, wired, copied: sim.Soldier
	fill(&full)

	buf: [MAX_PACKET]u8
	w := stream_writer(buf[:])
	ser_served(&w, &full)
	r := stream_reader(buf[:w.pos])
	ser_served(&r, &wired)
	testing.expect(t, stream_finish(&w) && stream_finish(&r))

	sim.soldier_copy_served(&copied, &full)
	testing.expect(t, mem.compare_ptrs(&wired, &copied, size_of(sim.Soldier)) == 0, "ser_served and soldier_copy_served list different fields")
}

// An animation as a copy leaves it: its id and frame, the rest looked up.
@(private = "file")
pace :: proc(a: sim.Anim) -> sim.Anim {
	return {id = a.id, frame = a.frame}
}

// Something small in every field, whatever the fields are: 1 in the integers, enums,
// booleans and bit sets, 1.5 in the floats. Small, so no wire type narrows it.
@(private = "file")
fill :: proc(s: ^sim.Soldier) {
	fill_any(s, type_info_of(sim.Soldier))
}

@(private = "file")
fill_any :: proc(p: rawptr, info: ^runtime.Type_Info) {
	#partial switch v in info.variant {
	case runtime.Type_Info_Named:
		fill_any(p, v.base)
	case runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count do fill_any(rawptr(uintptr(p) + v.offsets[i]), v.types[i])
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count do fill_any(rawptr(uintptr(p) + uintptr(i * v.elem_size)), v.elem)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count do fill_any(rawptr(uintptr(p) + uintptr(i * v.elem_size)), v.elem)
	case runtime.Type_Info_Float:
		if info.size == 4 do (^f32)(p)^ = 1.5
		else do (^f64)(p)^ = 1.5
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum, runtime.Type_Info_Boolean, runtime.Type_Info_Bit_Set:
		(^u8)(p)^ = 1 // little-endian: the value 1 at any width
	}
}

// Prediction needs the server's word on my own soldier to be the whole of it: the two
// halves and the rest together must leave nothing behind, or what the client replays
// its commands over is part its own stale state and it drifts.
@(test)
halves_and_rest_are_the_whole_soldier :: proc(t: ^testing.T) {
	anims := new(sim.Anims)
	defer free(anims)
	full, copied: sim.Soldier
	fill(&full)
	sim.soldier_copy_served(&copied, &full)
	sim.soldier_copy_owned(anims, &copied, &full)
	sim.soldier_copy_rest(&copied, &full)
	copied.legs.speed, copied.body.speed = full.legs.speed, full.body.speed // looked up, not carried
	for name in fields_apart(&full, &copied) do testing.expectf(t, false, "%s is in none of served, owned and rest", name)
}

@(test)
rest_in_step :: proc(t: ^testing.T) {
	full, wired, copied: sim.Soldier
	fill(&full)
	buf: [MAX_PACKET]u8
	w := stream_writer(buf[:])
	ser_rest(&w, &full)
	r := stream_reader(buf[:w.pos])
	ser_rest(&r, &wired)
	testing.expect(t, stream_finish(&w) && stream_finish(&r))
	sim.soldier_copy_rest(&copied, &full)
	testing.expect(t, mem.compare_ptrs(&wired, &copied, size_of(sim.Soldier)) == 0, "ser_rest and soldier_copy_rest list different fields")
}

// The fields of two soldiers that differ, by name: what a copy left behind.
@(private = "file")
fields_apart :: proc(a, b: ^sim.Soldier) -> (apart: [dynamic]string) {
	info := runtime.type_info_base(type_info_of(sim.Soldier)).variant.(runtime.Type_Info_Struct)
	for i in 0 ..< info.field_count {
		at, size := info.offsets[i], info.types[i].size
		if mem.compare_ptrs(rawptr(uintptr(a) + at), rawptr(uintptr(b) + at), size) != 0 {
			append(&apart, info.names[i])
		}
	}
	return
}
