package net

import "base:intrinsics"
import "core:math"
import "../sim"

// A Stream either reads or writes, and every message has one serialize procedure
// used for both directions, so the two layouts can never drift apart. Reads are
// bounds-checked and a failure sticks: once `failed` is set every later read gives
// zero and the message is rejected whole. Floats that are not finite and enums out
// of range fail the read.

MAX_PACKET :: 8192 // a full world update fits; ENet fragments what a datagram cannot hold

Stream :: struct {
	writing: bool,
	buf:     []u8,
	pos:     int,
	failed:  bool,
}

stream_writer :: proc(buf: []u8) -> Stream { return {writing = true, buf = buf} }
stream_reader :: proc(data: []u8) -> Stream { return {buf = data} }

// A reader must consume the packet exactly: trailing bytes mean a malformed or
// mismatched message.
stream_finish :: proc(s: ^Stream) -> bool {
	return !s.failed && (s.writing || s.pos == len(s.buf))
}

@(private)
take :: proc(s: ^Stream, n: int) -> []u8 {
	if s.failed || s.pos + n > len(s.buf) {
		s.failed = true
		return nil
	}
	b := s.buf[s.pos:][:n]
	s.pos += n
	return b
}

ser_u8 :: proc(s: ^Stream, v: ^u8) {
	b := take(s, 1)
	if b == nil do return
	if s.writing do b[0] = v^
	else do v^ = b[0]
}

ser_u16 :: proc(s: ^Stream, v: ^u16) {
	b := take(s, 2)
	if b == nil do return
	if s.writing do b[0], b[1] = u8(v^), u8(v^ >> 8)
	else do v^ = u16(b[0]) | u16(b[1]) << 8
}

ser_u32 :: proc(s: ^Stream, v: ^u32) {
	b := take(s, 4)
	if b == nil do return
	if s.writing do b[0], b[1], b[2], b[3] = u8(v^), u8(v^ >> 8), u8(v^ >> 16), u8(v^ >> 24)
	else do v^ = u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

ser_u64 :: proc(s: ^Stream, v: ^u64) {
	low, high := u32(v^), u32(v^ >> 32)
	ser_u32(s, &low)
	ser_u32(s, &high)
	if !s.writing do v^ = u64(low) | u64(high) << 32
}

ser_f32 :: proc(s: ^Stream, v: ^f32) {
	bits := transmute(u32)v^
	ser_u32(s, &bits)
	if s.writing do return
	v^ = transmute(f32)bits
	if math.is_nan(v^) || math.is_inf(v^) {
		v^ = 0
		s.failed = true
	}
}

ser_bool :: proc(s: ^Stream, v: ^bool) {
	b := u8(v^)
	ser_u8(s, &b)
	if !s.writing do v^ = b != 0
}

ser_vec2 :: proc(s: ^Stream, v: ^sim.Vec2) {
	ser_f32(s, &v.x)
	ser_f32(s, &v.y)
}

// A value that fits a narrower wire type: an enum, a small count, a short counter.
ser_as :: proc(s: ^Stream, v: ^$T, $Wire: typeid) {
	when Wire == u8 {
		w := u8(v^)
		ser_u8(s, &w)
		if !s.writing do v^ = T(w)
	} else when Wire == u16 {
		w := u16(v^)
		ser_u16(s, &w)
		if !s.writing do v^ = T(w)
	} else when Wire == i16 {
		w := u16(i16(v^))
		ser_u16(s, &w)
		if !s.writing do v^ = T(i16(w))
	} else when Wire == u32 {
		w := u32(v^)
		ser_u32(s, &w)
		if !s.writing do v^ = T(w)
	} else when Wire == i32 {
		w := u32(i32(v^))
		ser_u32(s, &w)
		if !s.writing do v^ = T(i32(w))
	} else {
		#panic("ser_as: unsupported wire type")
	}
}

// An enum in a byte. A value it does not have is refused: it would index a table.
ser_enum :: proc(s: ^Stream, v: ^$T) where intrinsics.type_is_enum(T) {
	w := u8(v^)
	ser_u8(s, &w)
	if s.writing do return
	if int(w) > int(max(T)) do s.failed = true
	else do v^ = T(w)
}

// A count of what follows, never more than the array that will hold it.
ser_count :: proc(s: ^Stream, n: ^int, limit: int) {
	ser_as(s, n, u8)
	if !s.writing && n^ > limit {
		n^ = 0
		s.failed = true
	}
}

ser_buttons :: proc(s: ^Stream, v: ^sim.Buttons) {
	bits := transmute(u16)v^
	ser_u16(s, &bits)
	if !s.writing do v^ = transmute(sim.Buttons)bits
}

// A short string: its length in a byte, then the bytes. Read, it points into the
// packet; clone it to keep it.
ser_string :: proc(s: ^Stream, v: ^string) {
	n := min(len(v^), 255)
	ser_as(s, &n, u8)
	b := take(s, n)
	if b == nil do return
	if s.writing do copy(b, v^[:n])
	else do v^ = string(b)
}
