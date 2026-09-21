// Package cvar is where a setting lives: a name, a value, a default and a line of help.
// Each program declares its own at startup (sv_ on the server, cl_, net_, r_, snd_ and
// ui_ on the client), and they are set from two places, the file first and the command
// line over it:
//
//   config.cfg   one setting a line, "name value"; # or // starts a comment
//   the command  -name value, or -name alone for a true
//
// A name nothing knows is said and passed over, so one config.cfg can hold the settings
// of both programs.
package cvar

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// What a cvar points at: the variable itself, wherever it lives.
Value :: union {
	^bool,
	^int,
	^f32,
	^string,
}

Cvar :: struct {
	name:  string,
	help:  string,
	value: Value,
}

MAX_CVARS :: 128

Set :: struct {
	cvars: [MAX_CVARS]Cvar,
	count: int,
}

// A setting, with where its value lives and what it is for. The variable's value when
// it is declared is its default.
add :: proc(s: ^Set, name: string, value: Value, help: string) {
	if s.count == MAX_CVARS {
		fmt.eprintfln("more than %d settings: %s is lost", MAX_CVARS, name)
		return
	}
	s.cvars[s.count] = {name = name, help = help, value = value}
	s.count += 1
}

find :: proc(s: ^Set, name: string) -> ^Cvar {
	for &c in s.cvars[:s.count] do if c.name == name do return &c
	return nil
}

// A setting to what `text` says. False when there is no such setting, or the text is
// not of its kind.
set :: proc(s: ^Set, name, text: string) -> bool {
	c := find(s, name)
	if c == nil do return false
	switch v in c.value {
	case ^bool:
		switch strings.to_lower(text, context.temp_allocator) {
		case "1", "true", "yes", "on", "":  v^ = true
		case "0", "false", "no", "off":     v^ = false
		case:                               return false
		}
	case ^int:
		n, ok := strconv.parse_int(text)
		if !ok do return false
		v^ = n
	case ^f32:
		f, ok := strconv.parse_f32(text)
		if !ok do return false
		v^ = f
	case ^string:
		v^ = text
	}
	return true
}

// What a setting says now, for listing them.
text :: proc(c: ^Cvar) -> string {
	switch v in c.value {
	case ^bool:   return v^ ? "1" : "0"
	case ^int:    return fmt.tprint(v^)
	case ^f32:    return fmt.tprintf("%g", v^)
	case ^string: return v^
	}
	return ""
}

// The settings in `path`, one a line: `name value`, with # or // starting a comment.
// A missing file is no error: it is how a program with no config runs. A name beginning
// with one of `elsewhere` belongs to the other program and is passed over without a
// word, so one file can hold the settings of both; any other unknown name is a
// misspelling and is said.
load :: proc(s: ^Set, path: string, elsewhere: []string = {}) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	for line, number in strings.split_lines(string(data), context.temp_allocator) {
		text := strings.trim_space(line)
		if cut := strings.index(text, "#"); cut >= 0 do text = text[:cut]
		if cut := strings.index(text, "//"); cut >= 0 do text = text[:cut]
		text = strings.trim_space(text)
		if text == "" do continue
		name := text
		rest := ""
		if cut := strings.index_any(text, " \t"); cut >= 0 {
			name = text[:cut]
			rest = strings.trim_space(text[cut + 1:])
		}
		// the file outlives this call, so what a text setting keeps is its own copy
		if c := find(s, name); c != nil {
			if _, is_text := c.value.(^string); is_text do rest = strings.clone(rest)
		}
		if set(s, name, rest) do continue
		theirs := false
		for prefix in elsewhere do if strings.has_prefix(name, prefix) do theirs = true
		if !theirs do fmt.eprintfln("%s:%d: %s is no setting, or %q is not its kind", path, number + 1, name, rest)
	}
	return true
}

// The settings named on the command line: `-name value`, or `-name` alone for a true.
// Whatever is not a setting comes back, in order, for the program to make sense of.
parse :: proc(s: ^Set, args: []string) -> (rest: []string) {
	left: [dynamic]string
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if len(arg) < 2 || arg[0] != '-' {
			append(&left, arg)
			continue
		}
		c := find(s, arg[1:])
		if c == nil {
			append(&left, arg)
			continue
		}
		_, flag := c.value.(^bool)
		value := ""
		if i + 1 < len(args) && (!flag || !strings.has_prefix(args[i + 1], "-")) {
			value = args[i + 1]
			i += 1
		}
		if !set(s, arg[1:], value) do fmt.eprintfln("%q is not what %s takes", value, arg[1:])
	}
	return left[:]
}

// Every setting, its value and what it is for.
list :: proc(s: ^Set) {
	for &c in s.cvars[:s.count] do fmt.printfln("%-18s %-10s %s", c.name, text(&c), c.help)
}
