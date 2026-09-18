package audio

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import "../game"
import "../../shared/sim"

// Sounds, from Sound.pas and the play sites in Sprites.pas and Bullets.pas by way of
// the Lua port, on raylib's audio:
//
//   - one Sound per wav, read on first use, with a few aliases so a sample can overlap
//     itself; a play takes the next alias in turn
//   - every play is placed from the listener, our soldier: gain volume * (1 - d / 750),
//     cut past that, pan from the direction; a sound with no place comes from the camera
//   - four reserved voices per soldier (reload, jets, gattling, gattling2, the layout
//     of Sprites.pas): a voice already playing is refreshed, not restarted. That is how
//     the loops (jets, chainsaw, flamer) live, by being played every tick, and how a
//     wind-up is cut by stopping its voice
//   - past half the range a shot or blast also plays its distant sample; a blast next
//     to us rings the ears (hum) and fades everything else for a few seconds
//
// What plays when: the events (audio_event), each soldier's state against the tick
// before (audio_soldier), bullets passing us (audio_bullets) and the clock's beeps,
// all from `tick` once per tick. Corpse thuds, shell casings and the antics are
// not here yet.

SOUND_MAXDIST       :: 750.0
SOUND_METERLENGTH   :: 2000.0
DEFAULT_VOLUME      :: 0.12 // snd_volume 50 through the original's curve
ALIASES             :: 6    // how many times one sample can overlap itself
GRENADE_EFFECT_DIST :: 38.0
GRENADE_EFFECT_TIME :: 320

Voice :: enum u8 { Reload, Jets, Gattling, Gattling2 }

Audio :: struct {
	dir:      string,            // the sfx directory
	samples:  map[string]Sample, // by file name, read on first use
	voices:   [sim.MAX_PLAYERS][Voice]Reserved,
	prev:     [sim.MAX_PLAYERS]sim.Soldier, // everyone as of the tick before
	whizzed:  [sim.MAX_BULLETS]bool,        // bullets that have already whizzed past us
	listener: sim.Vec2,
	camera:   sim.Vec2,
	ringing:  int, // ticks of ringing ears left
	rng:      u64,
	volume:   f32,
	ready:    bool,
}

Sample :: struct {
	base:    rl.Sound,
	aliases: [ALIASES]rl.Sound,
	next:    int,
	ok:      bool,
}

Reserved :: struct {
	sound:  rl.Sound, // an alias of its own
	name:   string,
	paused: bool,
}

init :: proc(a: ^Audio, base: string) {
	rl.InitAudioDevice()
	a.ready = rl.IsAudioDeviceReady()
	a.dir, _ = filepath.join({base, "sfx"})
	a.volume = DEFAULT_VOLUME
	a.rng = 0x9E3779B1
}

destroy :: proc(a: ^Audio) {
	for &per_soldier in a.voices do for &r in per_soldier do voice_release(&r)
	for _, &s in a.samples {
		if !s.ok do continue
		for al in s.aliases do rl.UnloadSoundAlias(al)
		rl.UnloadSound(s.base)
	}
	delete(a.samples)
	delete(a.dir)
	rl.CloseAudioDevice()
}

// Once per tick: where we listen from (my soldier, or the view's centre `camera` when
// there is none), then everything that sounded this tick.
tick :: proc(a: ^Audio, g: ^game.Game, camera: sim.Vec2) {
	if !a.ready do return
	me := &g.world.soldiers[g.me]
	a.camera = camera
	a.listener = me.active ? me.pos : a.camera
	if a.ringing > -1 do a.ringing -= 1
	audio_clock(a, &g.world.round)
	for e in sim.events_slice(&g.events) do audio_event(a, e, g)
	for &s, i in g.world.soldiers do audio_soldier(a, &g.ctx, u8(i), &s, g.world.tick)
	audio_bullets(a, g)
}

// ---- playing ----

// Gain and pan for a sound at `at`, and whether it is within earshot. The pan is what
// OpenAL gave the original: the source at (dx, dy, -1000) meters, heard on x.
@(private = "file")
place :: proc(a: ^Audio, at: sim.Vec2, distant: bool) -> (gain, pan: f32, audible: bool) {
	d := at - a.listener
	dist := sim.vec2_length(d) / SOUND_MAXDIST
	if distant do dist = dist > 1 ? dist - 1 : 1 - 2 * dist
	if a.ringing > 0 do dist += (1 - dist) * math.sqrt(f32(a.ringing) / 280)
	if dist > 1 do return 0, 0, false
	gain = clamp(a.volume * (1 - dist), 0, 1)
	src := [3]f32{d.x, d.y, -1000} / SOUND_METERLENGTH
	pan = 0.5 + 0.5 * src.x / linalg.length(src)
	return gain, pan, true
}

// A sample by file name, read the first time it is asked for.
@(private = "file")
sample :: proc(a: ^Audio, name: string) -> ^Sample {
	if s := &a.samples[name]; s != nil do return s
	path, _ := filepath.join({a.dir, name}, context.temp_allocator)
	s: Sample
	s.base = rl.LoadSound(strings.clone_to_cstring(path, context.temp_allocator))
	s.ok = s.base.frameCount > 0
	if s.ok do for &al in s.aliases do al = rl.LoadSoundAlias(s.base)
	else do fmt.eprintfln("sfx %s not found", name)
	a.samples[name] = s
	return &a.samples[name]
}

// Sound.pas FPlaySound: a one-shot at `at`. Past half the range a shot or blast also
// plays its distant sample, which has its own fade.
sound_play :: proc(a: ^Audio, name: string, at: sim.Vec2, distant := false) {
	if !a.ready || name == "" do return
	if !distant && sim.vec2_length(at - a.listener) > SOUND_MAXDIST / 2 {
		if alt := distant_sample(a, name); alt != "" do sound_play(a, alt, at, distant = true)
	}
	gain, pan, audible := place(a, at, distant)
	if !audible do return
	s := sample(a, name)
	if !s.ok do return
	al := s.aliases[s.next]
	s.next = (s.next + 1) % ALIASES
	rl.SetSoundVolume(al, gain)
	rl.SetSoundPan(al, pan)
	play(al)
}

// raylib's PlaySound is this one line, under a name the linker resolves to the Windows
// multimedia API's PlaySound instead (winmm.lib comes first), which silently plays nothing.
@(private = "file")
play :: proc(s: rl.Sound) {
	rl.PlayAudioStream(s.stream)
}

// A sound with no place: it comes from the camera.
sound_flat :: proc(a: ^Audio, name: string) {
	sound_play(a, name, a.camera)
}

// A soldier's reserved voice: refreshed while it plays, restarted with `name` once it
// has ended, so a loop lives by being played every tick.
voice_play :: proc(a: ^Audio, slot: u8, voice: Voice, name: string, at: sim.Vec2) {
	if !a.ready || name == "" do return
	r := &a.voices[slot][voice]
	gain, pan, audible := place(a, at, false)
	if !audible {
		voice_stop(a, slot, voice)
		return
	}
	if r.name == "" || !rl.IsSoundPlaying(r.sound) || r.paused {
		voice_release(r)
		s := sample(a, name)
		if !s.ok do return
		r^ = {sound = rl.LoadSoundAlias(s.base), name = name}
		play(r.sound)
	}
	rl.SetSoundVolume(r.sound, gain)
	rl.SetSoundPan(r.sound, pan)
}

voice_stop :: proc(a: ^Audio, slot: u8, voice: Voice) {
	voice_release(&a.voices[slot][voice])
}

// SetSoundPaused: pauses only a playing voice, resumes only a paused one.
voice_pause :: proc(a: ^Audio, slot: u8, voice: Voice, paused: bool) {
	r := &a.voices[slot][voice]
	if r.name == "" do return
	if paused && !r.paused && rl.IsSoundPlaying(r.sound) {
		rl.PauseSound(r.sound)
		r.paused = true
	} else if !paused && r.paused {
		rl.ResumeSound(r.sound)
		r.paused = false
	}
}

@(private = "file")
voice_release :: proc(r: ^Reserved) {
	if r.name != "" {
		rl.StopSound(r.sound)
		rl.UnloadSoundAlias(r.sound)
	}
	r^ = {}
}

@(private = "file")
pick :: proc(a: ^Audio, names: []string) -> string {
	return names[sim.rand_int(&a.rng, len(names))]
}

// ---- the tables ----

// Fire sounds by weapon (TSprite.Fire). The knife, the fists and the chainsaw make no
// sound when they fire: their swings and the chainsaw loop follow the animation.
FIRE_SOUNDS := #partial [sim.Weapon_Id]string{
	.Eagle = "deserteagle-fire.wav", .MP5 = "mp5-fire.wav", .AK74 = "ak74-fire.wav", .Steyr = "steyraug-fire.wav",
	.Spas = "spas12-fire.wav", .Ruger = "ruger77-fire.wav", .M79 = "m79-fire.wav", .Barrett = "barretm82-fire.wav",
	.M249 = "m249-fire.wav", .Minigun = "minigun-fire.wav", .Colt = "colt1911-fire.wav", .LAW = "law.wav",
	.Bow = "bow-fire.wav", .Bow2 = "bow-fire.wav", .M2 = "m2fire.wav", .Frag = "grenade-throw.wav",
	.Cluster_Nade = "grenade-throw.wav",
}

RELOAD_SOUNDS := #partial [sim.Weapon_Id]string{
	.Eagle = "deserteagle-reload.wav", .MP5 = "mp5-reload.wav", .AK74 = "ak74-reload.wav", .Steyr = "steyraug-reload.wav",
	.Ruger = "ruger77-reload.wav", .M79 = "m79-reload.wav", .Barrett = "barretm82-reload.wav", .M249 = "m249-reload.wav",
	.Minigun = "minigun-reload.wav", .Colt = "colt1911-reload.wav",
}

KIT_SOUNDS := #partial [sim.Thing_Style]string{
	.Medical_Kit = "takemedikit.wav", .Grenade_Kit = "pickupgun.wav", .Flamer_Kit = "godflame.wav",
	.Predator_Kit = "predator.wav", .Vest_Kit = "vesttake.wav", .Berserk_Kit = "berserker.wav", .Cluster_Kit = "pickupgun.wav",
}

RIC       := []string{"ric.wav", "ric2.wav", "ric3.wav", "ric4.wav"}
RICOCHETS := []string{"ric5.wav", "ric6.wav", "ric7.wav"}
HIT_ARG   := []string{"hit-arg.wav", "hit-arg2.wav", "hit-arg3.wav"}
DEATHS    := []string{"death.wav", "death2.wav", "death3.wav"}
FLAGS     := []string{"flag.wav", "flag2.wav"}
KIT_FALL  := []string{"kit-fall.wav", "kit-fall2.wav"}
DIST_GUNS := []string{"dist-gun1.wav", "dist-gun2.wav", "dist-gun3.wav", "dist-gun4.wav"}
WHIZ      := []string{"bulletby2.wav", "bulletby3.wav", "bulletby4.wav", "bulletby5.wav"}
STEPS     := []string{"step.wav", "step2.wav", "step3.wav", "step4.wav", "step5.wav", "step6.wav", "step7.wav", "step8.wav"}

// The far versions (Sound.pas FPlaySound): blasts by kind, gunfire as one of four.
@(private = "file")
distant_sample :: proc(a: ^Audio, name: string) -> string {
	switch name {
	case "m79-explosion.wav": return "dist-m79.wav"
	case "grenade-explosion.wav", "clustergrenade.wav", "cluster-explosion.wav": return "dist-grenade.wav"
	case "ak74-fire.wav", "m249-fire.wav", "ruger77-fire.wav", "spas12-fire.wav", "deserteagle-fire.wav",
	     "steyraug-fire.wav", "barretm82-fire.wav", "minigun-fire.wav", "colt1911-fire.wav":
		return pick(a, DIST_GUNS)
	}
	return ""
}

// ---- the events ----

audio_event :: proc(a: ^Audio, e: sim.Event, g: ^game.Game) {
	w := &g.world
	#partial switch v in e {
	case sim.Fire:
		if w.soldiers[v.player].bonus == .Predator do return // a predator fires silently
		if v.weapon == .Flamer do voice_play(a, v.player, .Gattling, "flamer.wav", v.pos)
		else do sound_play(a, FIRE_SOUNDS[v.weapon], v.pos)
	case sim.Explosion:
		me := &w.soldiers[g.me]
		if me.active && me.health > -50 && sim.vec2_length(v.pos - a.listener) < GRENADE_EFFECT_DIST {
			a.ringing = GRENADE_EFFECT_TIME
			sound_flat(a, "hum.wav")
		}
		name := "explosion-erg.wav"
		#partial switch v.weapon {
		case .M79:  name = "m79-explosion.wav"
		case .M2:   name = "m2explode.wav"
		case .Frag: name = v.radius <= 35 ? "cluster-explosion.wav" : "grenade-explosion.wav"
		}
		sound_play(a, name, v.pos)
		for &s in w.soldiers {
			if s.active && !s.dead && s.team != .Spectator && sim.vec2_length(s.pos - v.pos) < v.radius do sound_play(a, "explosion-erg.wav", s.pos)
		}
	case sim.Cluster_Split:  sound_play(a, "clustergrenade.wav", v.pos)
	case sim.Grenade_Bounce: sound_play(a, "grenade-bounce.wav", v.pos)
	case sim.Ricochet:       sound_play(a, pick(a, RICOCHETS), v.pos)
	case sim.Wall_Hit:       sound_play(a, pick(a, RIC), v.pos)
	case sim.Collider_Hit:
		sound_play(a, "colliderhit.wav", v.pos)
		sound_play(a, pick(a, RIC), v.pos)
	case sim.Blood:
		target := &w.soldiers[v.target]
		if target.dead do sound_play(a, "dead-hit.wav", v.pos)
		else if target.vest > 0 do sound_play(a, "vesthit.wav", v.pos)
		else do sound_play(a, pick(a, HIT_ARG), v.pos)
	case sim.Kill:
		audio_kill(a, v, g.me)
		if w.soldiers[v.killer].bonus == .Berserker && v.killer != v.target do sound_play(a, "killberserk.wav", v.pos - {0, 12})
	case sim.Respawn:
		if v.target == g.me do sound_play(a, "wermusic.wav", v.pos)
		else do sound_play(a, "spawn.wav", v.pos)
	case sim.Poly_Effect:
		#partial switch v.type {
		case .Hurts:       sound_play(a, "arg.wav", v.pos)
		case .Lava:        sound_play(a, "lava.wav", v.pos)
		case .Regenerates: sound_play(a, "regenerate.wav", v.pos)
		case .Explodes:    sound_play(a, "explosion-erg.wav", v.pos)
		}
	case sim.Flag_Grab:   sound_play(a, "capture.wav", v.pos)
	case sim.Flag_Return: sound_flat(a, "capture.wav")
	case sim.Flag_Score:  sound_flat(a, "ctf.wav")
	case sim.Kit_Pickup:
		name := KIT_SOUNDS[v.kit]
		sound_play(a, name != "" ? name : "pickupgun.wav", v.pos)
	case sim.Weapon_Pickup: sound_play(a, "takegun.wav", v.pos)
	case sim.Thing_Hit:
		// a landing, or (part 0) cloth flapping
		#partial switch v.thing {
		case .Alpha_Flag, .Bravo_Flag, .Parachute: sound_play(a, pick(a, FLAGS), v.pos)
		case .Weapon: sound_play(a, "weaponhit.wav", v.pos)
		case .Stat_Gun:
		case: if v.part != 0 do sound_play(a, pick(a, KIT_FALL), v.pos)
		}
	}
}

// TSprite.Die and the kill message: the death by how bad it was.
@(private = "file")
audio_kill :: proc(a: ^Audio, e: sim.Kill, me: u8) {
	head := e.pos - {0, 12}
	headchop := e.health <= sim.HEADCHOP_DEATH_HEALTH || (e.part == 12 && e.weapon == .Ruger)
	switch {
	case e.health <= sim.BRUTAL_DEATH_HEALTH:
		sound_play(a, "bryzg.wav", head)
	case headchop:
		if e.part == 12 && (e.weapon == .Barrett || e.weapon == .Ruger) {
			if e.weapon == .Barrett do sound_play(a, "bryzg.wav", head)
			if e.killer == me do sound_flat(a, "boomheadshot.wav")
		}
		sound_play(a, "headchop.wav", head)
	case:
		sound_play(a, pick(a, DEATHS), e.pos)
	}
	if e.weapon == .Flamer do sound_play(a, "burn.wav", head)
	voice_stop(a, e.target, .Reload)
	if e.target == me do sound_flat(a, "playerdeath.wav")
}

// The time-left beeps, closer together toward the end.
@(private = "file")
audio_clock :: proc(a: ^Audio, r: ^sim.Round) {
	if r.state != .Playing do return
	t := r.time_left
	beep := false
	switch {
	case t >= 1 && t <= 600:      beep = t % 60 == 0
	case t > 600 && t <= 3600:    beep = t % 600 == 0
	case t > 3600 && t <= 18000:  beep = t % 3600 == 0
	case t > 18000:               beep = t % 18000 == 0
	}
	if beep do sound_flat(a, "signal.wav")
}

// ---- the soldiers, tick to tick ----

Anim_Ids :: bit_set[sim.Anim_Id]

// Whether an animation went past `frame` between two ticks. A restart of the same
// animation (the frame going backwards) counts the frames after the wrap.
@(private = "file")
crossed :: proc(prev, cur: sim.Anim, id: sim.Anim_Id, frame: i32) -> bool {
	if cur.id != id do return false
	if prev.id != id do return cur.frame >= frame && cur.frame <= frame + 1
	if cur.frame >= prev.frame do return prev.frame < frame && frame <= cur.frame
	return frame > prev.frame || frame <= cur.frame
}

// One soldier for one tick against how it was the tick before: the sounds its
// animations and weapon make (the play sites of Sprites.pas).
@(private = "file")
audio_soldier :: proc(a: ^Audio, ctx: ^sim.Context, slot: u8, s: ^sim.Soldier, tick: u32) {
	p := a.prev[slot]
	a.prev[slot] = s^
	if !s.active || s.dead {
		if p.active && !p.dead do for v in Voice do voice_stop(a, slot, v)
		return
	}
	fresh := !p.active || p.dead
	info := &ctx.weapons[s.weapon.id]
	at := s.pos
	c := s.controls

	// jets: the rocket loop while jetting, except during a jet-assisted backflip
	backflip := .Jet in c && ((s.legs.id == .Jump_Side && ((s.direction == -1 && .Right in c) || (s.direction == 1 && .Left in c))) ||
	                          (s.legs.id == .Roll_Back && .Jump in c))
	if !backflip {
		if .Jet in c && s.jets > 0 do voice_play(a, slot, .Jets, "rocketz.wav", at)
		else do voice_stop(a, slot, .Jets)
	}

	// the chainsaw: its idle rattle every 15 ticks, the cutting loop while the trigger is held
	fire := .Fire in c && s.cease_fire_counter < 0
	if s.weapon.id == .Chainsaw {
		if tick % 15 == 0 {
			if s.weapon.ammo == 0 do voice_play(a, slot, .Gattling, "chainsaw-o.wav", at)
			else do sound_play(a, "chainsaw-m.wav", at)
		}
		if .Fire in c && s.weapon.ammo > 0 do voice_play(a, slot, .Gattling, "chainsaw-r.wav", at)
	}

	// wind-ups: the first wind-up tick shows as the start-up counter stepping down
	firing_allowed := (s.weapon.id == .Chainsaw || s.body.id not_in (Anim_Ids{.Roll, .Roll_Back, .Melee, .Change})) &&
	                  (s.body.id != .Hands_Up_Aim || s.body.frame == 11)
	if firing_allowed && !fresh && p.weapon.id == s.weapon.id {
		su := info.startup
		law_ready := s.on_ground && (s.legs.id in (Anim_Ids{.Crouch_Run, .Crouch_Run_Back}) ||
		             (s.legs.id == .Crouch && s.legs.frame > 13) || (s.legs.id == .Prone && s.legs.frame > 23))
		if fire {
			if su > 0 && p.weapon.startup_count == su && s.weapon.startup_count == su - 1 {
				voice_stop(a, slot, .Gattling2)
				#partial switch s.weapon.id {
				case .Barrett: voice_play(a, slot, .Gattling, "law-start.wav", at)
				case .Minigun: voice_play(a, slot, .Gattling, "minigun-start.wav", at)
				case .LAW:     if law_ready do voice_play(a, slot, .Gattling, "law-start.wav", at)
				}
			}
		} else {
			voice_stop(a, slot, .Gattling)
			if su > 0 && p.weapon.startup_count < su && s.weapon.startup_count == su {
				if s.weapon.id == .Minigun do voice_play(a, slot, .Gattling2, "minigun-end.wav", at)
				else if s.weapon.id == .LAW && law_ready do voice_play(a, slot, .Gattling2, "law-end.wav", at)
			}
		}
	} else if firing_allowed && !fire {
		voice_stop(a, slot, .Gattling)
	}

	// reloading: the clip sound starts with the reload and pauses while the soldier
	// rolls, changes weapons or throws a grenade
	if s.weapon.ammo == 0 {
		started := fresh || p.weapon.ammo != 0 || p.weapon.id != s.weapon.id || s.weapon.reload_count > p.weapon.reload_count
		if started do voice_play(a, slot, .Reload, RELOAD_SOUNDS[s.weapon.id], at)
		busy := s.body.id in (Anim_Ids{.Roll, .Roll_Back, .Melee, .Change, .Throw, .Throw_Weapon})
		if s.weapon.id == .Chainsaw || !busy do voice_pause(a, slot, .Reload, false)
	}
	if !fresh {
		if (s.body.id == .Change && p.body.id != .Change) || (s.body.id == .Throw && p.body.id != .Throw) do voice_pause(a, slot, .Reload, true)
		if s.body.id == .Throw_Weapon && p.body.id != .Throw_Weapon do voice_stop(a, slot, .Reload)
	}
	if crossed(p.body, s.body, .Reload, 7) do voice_play(a, slot, .Reload, "spas12-reload.wav", at)

	// the weapon change: the sound of the one being drawn
	if crossed(p.body, s.body, .Change, 2) {
		#partial switch s.secondary.id {
		case .Colt:     sound_play(a, "changespin.wav", at)
		case .Knife:    sound_play(a, "knife.wav", at)
		case .Chainsaw: sound_play(a, "chainsaw-d.wav", at)
		case:           sound_play(a, "changeweapon.wav", at)
		}
	}
	if crossed(p.body, s.body, .Throw_Weapon, 2) do sound_play(a, "throwgun.wav", at)

	// melee: a knife stab or a rifle butt
	if crossed(p.body, s.body, .Punch, 11) && s.weapon.id == .Knife do sound_play(a, "slash.wav", at)
	if crossed(p.body, s.body, .Melee, 12) do sound_play(a, "slash.wav", at)

	// the grenade's pin, from about where the hand is
	if crossed(p.body, s.body, .Throw, 15) && s.grenades > 0 && s.cease_fire_counter < 0 do sound_play(a, "grenade-pullout.wav", at - {0, 2})

	if fresh do return

	// legs: going prone, standing up, rolling, jumping, crouching, stopping
	if s.legs.id == .Prone && p.legs.id not_in (Anim_Ids{.Prone, .Prone_Move, .Get_Up}) do sound_play(a, "goprone.wav", at)
	if s.legs.id == .Get_Up && p.legs.id != .Get_Up do sound_play(a, "standup.wav", at)
	if s.legs.id in (Anim_Ids{.Roll, .Roll_Back}) && p.legs.id not_in (Anim_Ids{.Roll, .Roll_Back}) {
		sound_play(a, "roll.wav", at)
		voice_pause(a, slot, .Reload, true)
	}
	if s.legs.id in (Anim_Ids{.Jump, .Jump_Side}) && p.legs.id not_in (Anim_Ids{.Jump, .Jump_Side}) && p.on_ground do sound_play(a, "jump.wav", at)
	if s.legs.id == .Crouch && p.legs.id not_in (Anim_Ids{.Crouch, .Crouch_Run, .Crouch_Run_Back}) && s.on_ground do sound_play(a, "crouch.wav", at)
	if s.legs.id == .Stand && p.legs.id != .Stand && s.on_ground && .Left not_in c && .Right not_in c do sound_play(a, "stop.wav", at)

	// footsteps, while touching the ground
	if s.on_ground {
		if s.legs.id in (Anim_Ids{.Run, .Run_Back}) && (crossed(p.legs, s.legs, s.legs.id, 16) || crossed(p.legs, s.legs, s.legs.id, 32)) {
			switch {
			case ctx.level.weather == 1: sound_play(a, "water-step.wav", at)
			case ctx.level.steps == 0:   sound_play(a, STEPS[sim.rand_int(&a.rng, 4)], at)
			case:                        sound_play(a, STEPS[4 + sim.rand_int(&a.rng, 4)], at)
			}
		}
		if s.legs.id in (Anim_Ids{.Crouch_Run, .Crouch_Run_Back}) && (crossed(p.legs, s.legs, s.legs.id, 15) || crossed(p.legs, s.legs, s.legs.id, 1)) {
			if sim.rand_int(&a.rng, 2) == 0 do sound_play(a, "crouch-move.wav", at)
			else if sim.rand_int(&a.rng, 2) == 0 do sound_play(a, "crouch-movel.wav", at)
		}
		if crossed(p.legs, s.legs, .Prone_Move, 8) do sound_play(a, "prone-move.wav", at)
	}

	// landing, by how fast the soldier was falling
	if s.on_ground && !p.on_ground {
		vy := abs(p.vel.y)
		if vy > 2.2 && vy < 3.4 do sound_play(a, "fall.wav", at)
		if vy > 3.5 do sound_play(a, "fall-hard.wav", at)
	}
}

// ---- bullets passing us ----

// A whistle 25 ticks into any round's flight but a shotgun's, and a whiz the first time
// another's bullet enters the box around us.
@(private = "file")
audio_bullets :: proc(a: ^Audio, g: ^game.Game) {
	me := &g.world.soldiers[g.me]
	for &b, i in g.world.bullets {
		if !b.active {
			a.whizzed[i] = false
			continue
		}
		if b.timeout == g.ctx.weapons[b.weapon].timeout - 25 && b.style != .Shotgun do sound_play(a, "bulletby.wav", b.pos)
		if a.whizzed[i] || b.owner == g.me || b.style == .Punch || b.style == .Flame || !me.active do continue
		d := b.pos - a.listener
		if d.x > -200 && d.x < 200 && d.y > -350 && d.y < 100 {
			sound_play(a, pick(a, WHIZ), b.pos)
			a.whizzed[i] = true
		}
	}
}
