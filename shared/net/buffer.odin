package net

import "core:encoding/endian"
import "core:mem"

// Little-endian byte writer and reader over a fixed buffer. A reader that runs out
// of bytes sets ok = false and returns zeros from then on, so decoders check ok once
// at the end instead of after every field.

MAX_PACKET :: 96 * 1024 // a snapshot of everything fits; ENet fragments what a datagram cannot hold

Writer :: struct {
	buf:      [MAX_PACKET]u8,
	len:      int,
	overflow: bool, // a write did not fit: the packet must not go out
}

Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

writer_bytes :: proc(w: ^Writer) -> []u8 {
	return w.buf[:w.len]
}

write_u8 :: proc(w: ^Writer, v: u8) {
	if w.len < MAX_PACKET {
		w.buf[w.len] = v
		w.len += 1
	} else do w.overflow = true
}

// A struct byte for byte: the same build runs on both ends.
write_raw :: proc(w: ^Writer, p: rawptr, n: int) {
	if w.len + n > MAX_PACKET {
		w.overflow = true
		return
	}
	mem.copy(&w.buf[w.len], p, n)
	w.len += n
}

read_raw :: proc(r: ^Reader, p: rawptr, n: int) {
	if r.pos + n > len(r.data) {
		r.ok = false
		return
	}
	mem.copy(p, &r.data[r.pos], n)
	r.pos += n
}

write_u16 :: proc(w: ^Writer, v: u16) {
	if w.len + 2 <= MAX_PACKET {
		endian.put_u16(w.buf[w.len:], .Little, v)
		w.len += 2
	}
}

write_u32 :: proc(w: ^Writer, v: u32) {
	if w.len + 4 <= MAX_PACKET {
		endian.put_u32(w.buf[w.len:], .Little, v)
		w.len += 4
	}
}

write_f32 :: proc(w: ^Writer, v: f32) {
	if w.len + 4 <= MAX_PACKET {
		endian.put_f32(w.buf[w.len:], .Little, v)
		w.len += 4
	}
}

write_f64 :: proc(w: ^Writer, v: f64) {
	if w.len + 8 <= MAX_PACKET {
		endian.put_f64(w.buf[w.len:], .Little, v)
		w.len += 8
	}
}

write_bool :: proc(w: ^Writer, v: bool) {
	write_u8(w, v ? 1 : 0)
}

reader_make :: proc(data: []u8) -> Reader {
	return {data = data, ok = true}
}

read_u8 :: proc(r: ^Reader) -> u8 {
	if r.pos + 1 > len(r.data) {
		r.ok = false
		return 0
	}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

read_u16 :: proc(r: ^Reader) -> u16 {
	if r.pos + 2 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_u16(r.data[r.pos:], .Little)
	r.pos += 2
	return v
}

read_u32 :: proc(r: ^Reader) -> u32 {
	if r.pos + 4 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_u32(r.data[r.pos:], .Little)
	r.pos += 4
	return v
}

read_f32 :: proc(r: ^Reader) -> f32 {
	if r.pos + 4 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_f32(r.data[r.pos:], .Little)
	r.pos += 4
	return v
}

read_f64 :: proc(r: ^Reader) -> f64 {
	if r.pos + 8 > len(r.data) {
		r.ok = false
		return 0
	}
	v, _ := endian.get_f64(r.data[r.pos:], .Little)
	r.pos += 8
	return v
}

read_bool :: proc(r: ^Reader) -> bool {
	return read_u8(r) != 0
}

// A short string: its length in a byte, then the bytes. The reader's string points
// into the packet; clone it to keep it.
write_string :: proc(w: ^Writer, s: string) {
	n := min(len(s), 255)
	write_u8(w, u8(n))
	for i in 0 ..< n do write_u8(w, s[i])
}

read_string :: proc(r: ^Reader) -> string {
	n := int(read_u8(r))
	if r.pos + n > len(r.data) {
		r.ok = false
		return ""
	}
	s := string(r.data[r.pos:r.pos + n])
	r.pos += n
	return s
}

// ---- deltas: a struct as the 4-byte words that changed against a base ----

// Whether two structs of `n` bytes differ anywhere.
differs :: proc(a, b: rawptr, n: int) -> bool {
	return mem.compare(([^]u8)(a)[:n], ([^]u8)(b)[:n]) != 0
}

// A mask of the words that changed, then those words. Structs up to 64 words.
write_words :: proc(w: ^Writer, new, base: rawptr, n: int) {
	words := n / 4
	a, b := ([^]u32)(new), ([^]u32)(base)
	mask: u64
	for i in 0 ..< words do if a[i] != b[i] do mask |= 1 << u64(i)
	write_u64(w, mask)
	for i in 0 ..< words do if mask & (1 << u64(i)) != 0 do write_u32(w, a[i])
}

// Over `dst`, which holds the base already.
read_words :: proc(r: ^Reader, dst: rawptr, n: int) {
	words := n / 4
	d := ([^]u32)(dst)
	mask := read_u64(r)
	for i in 0 ..< words do if mask & (1 << u64(i)) != 0 do d[i] = read_u32(r)
}

write_u64 :: proc(w: ^Writer, v: u64) {
	write_u32(w, u32(v))
	write_u32(w, u32(v >> 32))
}

read_u64 :: proc(r: ^Reader) -> u64 {
	lo := u64(read_u32(r))
	return lo | u64(read_u32(r)) << 32
}
