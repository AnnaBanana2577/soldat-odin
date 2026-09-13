package sim

import "core:strconv"
import "core:strings"

// Keyframe animations (.poa). The soldier's movement state machine is driven by the
// legs and body animation ids and frame numbers, so this is gameplay data, not just
// visuals. Frame numbers are 1-based to keep the original's tuning constants readable.
// Ported from the old Odin port (Anims.pas).

MAX_ANIM_FRAMES :: 40
MAX_ANIM_POINTS :: 20

Anim_Id :: enum u8 {
	Stand, Run, Run_Back, Jump, Jump_Side, Fall, Crouch, Crouch_Run, Reload, Throw,
	Recoil, Small_Recoil, Shotgun, Clip_Out, Clip_In, Slide_Back, Change, Throw_Weapon,
	Weapon_None, Punch, Reload_Bow, Barret, Roll, Roll_Back, Crouch_Run_Back, Cigar, Match,
	Smoke, Wipe, Groin, Piss, Mercy, Mercy2, Take_Off, Prone, Victory, Aim, Hands_Up_Aim,
	Prone_Move, Get_Up, Aim_Recoil, Hands_Up_Recoil, Melee, Own,
}

Anim_Info :: struct {
	file:  string,
	speed: i32,
	loop:  bool,
}

ANIM_INFO := [Anim_Id]Anim_Info{
	.Stand           = {"stoi.poa", 3, true},
	.Run             = {"biega.poa", 1, true},
	.Run_Back        = {"biegatyl.poa", 1, true},
	.Jump            = {"skok.poa", 1, false},
	.Jump_Side       = {"skokwbok.poa", 1, false},
	.Fall            = {"spada.poa", 1, false},
	.Crouch          = {"kuca.poa", 1, false},
	.Crouch_Run      = {"kucaidzie.poa", 2, true},
	.Reload          = {"laduje.poa", 2, false},
	.Throw           = {"rzuca.poa", 1, false},
	.Recoil          = {"odrzut.poa", 1, false},
	.Small_Recoil    = {"odrzut2.poa", 1, false},
	.Shotgun         = {"shotgun.poa", 1, false},
	.Clip_Out        = {"clipout.poa", 3, false},
	.Clip_In         = {"clipin.poa", 3, false},
	.Slide_Back      = {"slideback.poa", 2, true},
	.Change          = {"change.poa", 1, false},
	.Throw_Weapon    = {"wyrzuca.poa", 1, false},
	.Weapon_None     = {"bezbroni.poa", 3, false},
	.Punch           = {"bije.poa", 1, false},
	.Reload_Bow      = {"strzala.poa", 1, false},
	.Barret          = {"barret.poa", 9, false},
	.Roll            = {"skokdolobrot.poa", 1, false},
	.Roll_Back       = {"skokdolobrottyl.poa", 1, false},
	.Crouch_Run_Back = {"kucaidzietyl.poa", 2, true},
	.Cigar           = {"cigar.poa", 3, false},
	.Match           = {"match.poa", 3, false},
	.Smoke           = {"smoke.poa", 4, false},
	.Wipe            = {"wipe.poa", 4, false},
	.Groin           = {"krocze.poa", 2, false},
	.Piss            = {"szcza.poa", 8, false},
	.Mercy           = {"samo.poa", 3, false},
	.Mercy2          = {"samo2.poa", 3, false},
	.Take_Off        = {"takeoff.poa", 2, false},
	.Prone           = {"lezy.poa", 1, false},
	.Victory         = {"cieszy.poa", 3, false},
	.Aim             = {"celuje.poa", 2, false},
	.Hands_Up_Aim    = {"gora.poa", 2, false},
	.Prone_Move      = {"lezyidzie.poa", 2, true},
	.Get_Up          = {"wstaje.poa", 1, false},
	.Aim_Recoil      = {"celujeodrzut.poa", 1, false},
	.Hands_Up_Recoil = {"goraodrzut.poa", 1, false},
	.Melee           = {"kolba.poa", 1, false},
	.Own             = {"rucha.poa", 3, false},
}

Anim_Data :: struct {
	frames:     [MAX_ANIM_FRAMES][MAX_ANIM_POINTS]Vec2,
	num_frames: i32,
	speed:      i32,
	loop:       bool,
}

Anims :: [Anim_Id]Anim_Data

// Per-soldier playback state: simulated and networked.
Anim :: struct {
	id:    Anim_Id,
	frame: i32, // 1-based
	count: i32,
	speed: i32,
}

// Parses a .poa keyframe file, keeping speed and loop from ANIM_INFO.
anim_parse :: proc(anim: ^Anim_Data, info: Anim_Info, text: string) {
	ANIM_SCALE :: 3
	anim^ = {}
	anim.num_frames = 1
	anim.speed = info.speed
	anim.loop = info.loop

	lines := text
	next_line :: proc(s: ^string) -> (string, bool) {
		line, ok := strings.split_lines_iterator(s)
		return strings.trim_space(line), ok
	}
	for {
		tag, ok := next_line(&lines)
		if !ok || tag == "ENDFILE" do break
		if tag == "NEXTFRAME" {
			if anim.num_frames == MAX_ANIM_FRAMES do break
			anim.num_frames += 1
			continue
		}
		xs, _ := next_line(&lines)
		_, _ = next_line(&lines) // y: depth, unused in 2D
		zs, _ := next_line(&lines)
		point, _ := strconv.parse_int(tag, 10)
		x, _ := strconv.parse_f32(xs)
		z, _ := strconv.parse_f32(zs)
		if point >= 1 && point <= MAX_ANIM_POINTS {
			anim.frames[anim.num_frames - 1][point - 1] = {-ANIM_SCALE * x / 1.1, -ANIM_SCALE * z}
		}
	}
}

anim_frame :: proc(anims: ^Anims, s: Anim) -> ^[MAX_ANIM_POINTS]Vec2 {
	f := clamp(s.frame, 1, MAX_ANIM_FRAMES)
	return &anims[s.id].frames[f - 1]
}

anim_advance :: proc(anims: ^Anims, s: ^Anim) {
	s.count += 1
	if s.count == s.speed {
		s.count = 0
		s.frame += 1
		data := &anims[s.id]
		if s.frame > data.num_frames do s.frame = data.loop ? 1 : data.num_frames
	}
}

// Switches animation unconditionally.
anim_set :: proc(anims: ^Anims, s: ^Anim, id: Anim_Id, frame: i32 = 1) {
	s^ = {id = id, frame = frame, speed = anims[id].speed}
}

// Switches animation only if it isn't already playing.
anim_apply :: proc(anims: ^Anims, s: ^Anim, id: Anim_Id, frame: i32 = 1) {
	if s.id != id do anim_set(anims, s, id, frame)
}
