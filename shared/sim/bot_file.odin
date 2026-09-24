package sim

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../polymap"

// The bots' personality files from the base assets folder (assets/bots/*.bot): file
// I/O, kept out of the pure sim files. Each file is one of the original's bots, and
// says how it looks, what it likes to carry, how well it shoots, how bold it is and
// what it says. Ported from SharedConfig.pas LoadBotConfig.

// One .bot file. What the brain reads of it is in bot.odin.
Bot_Profile :: struct {
	name:      string,
	// The look. Nothing draws it yet: the roster carries names only.
	shirt, pants, hair_color, skin: polymap.Color,
	hair, headgear, chain: u8,

	favourite:    Weapon_Id, // what it likes to spawn with, .None for bare hands
	secondary:    Weapon_Id,
	friend:       string, // a player of this name is never shot at
	accuracy:     int,    // pixels its aim is off by, before the difficulty
	shoot_dead:   bool,   // it keeps firing at a body
	grenade_freq: int,    // a throw is rolled at one in this many ticks; -1 never
	camper:       u8,     // 0 never, over 127 by preference: it lies down and waits
	use:          u8,     // the antic it idles with when placed, 255 none
	chat_freq:    int,    // the lower, the more it talks
	chat_kill, chat_dead, chat_low_health, chat_see_enemy, chat_winning: string,
}

// The Secondary_Weapon field's four choices.
@(rodata)
BOT_SECONDARIES := [4]Weapon_Id{.Colt, .Knife, .Chainsaw, .LAW}

// Every .bot file in base/bots, by name. Empty when there are none: bot_profile_any
// then gives a plain one.
bot_profiles_load :: proc(base_dir: string, allocator := context.allocator) -> []Bot_Profile {
	context.allocator = allocator
	pattern, _ := filepath.join({base_dir, "bots", "*.bot"}, context.temp_allocator)
	paths, err := filepath.glob(pattern, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("failed to read %s: %v", pattern, err)
		return nil
	}
	slice.sort(paths)
	profiles := make([dynamic]Bot_Profile)
	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintfln("failed to read %s: %v", path, read_err)
			continue
		}
		if p, ok := bot_profile_parse(string(data)); ok do append(&profiles, p)
	}
	return profiles[:]
}

// One file's [BOT] section, key by key. The accuracy is still the file's own here;
// the difficulty scales it in bot_init.
bot_profile_parse :: proc(text: string, allocator := context.allocator) -> (p: Bot_Profile, ok: bool) {
	context.allocator = allocator
	value :: proc(text, key: string) -> string {
		lines := text
		in_section := false
		for raw in strings.split_lines_iterator(&lines) {
			line := strings.trim_space(raw)
			if strings.has_prefix(line, "[") {
				in_section = strings.equal_fold(line, "[BOT]")
				continue
			}
			if !in_section do continue
			eq := strings.index_byte(line, '=')
			if eq < 0 do continue
			if strings.equal_fold(strings.trim_space(line[:eq]), key) {
				return strings.trim_space(line[eq + 1:])
			}
		}
		return ""
	}
	number :: proc(text, key: string, missing := 0) -> int {
		field := value(text, key)
		if field == "" do return missing
		n, parsed := strconv.parse_int(field, 10)
		return parsed ? n : missing
	}
	// $00RRGGBB, or plain decimal.
	color :: proc(text, key: string) -> polymap.Color {
		field := value(text, key)
		n: u64
		if strings.has_prefix(field, "$") {
			n, _ = strconv.parse_u64_of_base(field[1:], 16)
		} else {
			n, _ = strconv.parse_u64_of_base(field, 10)
		}
		return {u8(n >> 16), u8(n >> 8), u8(n), 255}
	}

	name := value(text, "Name")
	if name == "" do return p, false
	p = {
		name            = strings.clone(name),
		shirt           = color(text, "Color1"),
		pants           = color(text, "Color2"),
		hair_color      = color(text, "Hair_Color"),
		skin            = color(text, "Skin_Color"),
		hair            = u8(number(text, "Hair")),
		headgear        = u8(number(text, "Headgear")),
		chain           = u8(number(text, "Chain")),
		favourite       = weapon_named(value(text, "Favourite_Weapon")),
		friend          = strings.clone(value(text, "Friend")),
		accuracy        = number(text, "Accuracy", 10),
		shoot_dead      = number(text, "Shoot_Dead") == 1,
		grenade_freq    = number(text, "Grenade_Frequency", 500),
		camper          = u8(number(text, "Camping")),
		use             = u8(number(text, "OnStartUse", 255)),
		chat_freq       = int(2.5 * f32(number(text, "Chat_Frequency", 1))),
		chat_kill       = strings.clone(value(text, "Chat_Kill")),
		chat_dead       = strings.clone(value(text, "Chat_Dead")),
		chat_low_health = strings.clone(value(text, "Chat_Lowhealth")),
		chat_see_enemy  = strings.clone(value(text, "Chat_SeeEnemy")),
		chat_winning    = strings.clone(value(text, "Chat_Winning")),
	}
	if second := number(text, "Secondary_Weapon", -1); second >= 0 && second < len(BOT_SECONDARIES) {
		p.secondary = BOT_SECONDARIES[second]
	}
	if p.chat_freq < 1 do p.chat_freq = 1 // it is a divisor and a multiplier
	return p, true
}

bot_profiles_destroy :: proc(profiles: []Bot_Profile, allocator := context.allocator) {
	context.allocator = allocator
	for p in profiles {
		delete(p.name)
		delete(p.friend)
		delete(p.chat_kill)
		delete(p.chat_dead)
		delete(p.chat_low_health)
		delete(p.chat_see_enemy)
		delete(p.chat_winning)
	}
	delete(profiles)
}
