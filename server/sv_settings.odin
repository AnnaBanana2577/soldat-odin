package server

import "core:fmt"
import "core:os"
import "core:strings"
import "../shared/cvar"
import "../shared/sim"

// What the server can be told, and where each setting lives. They come from config.cfg
// and then from the command line, which has the last word:
//
//   server -sv_map ctf_Ash,Arena -sv_bots 5 -sv_timelimit 3
//
// `-cvars` prints the lot with what they are set to. A setting's value here is its
// default.
Settings :: struct {
	base:        string,
	maps:        string, // one name, or several in turn, a round each
	port:        int,
	bots:        int,
	bots_difficulty: int, // 300 stupid, 100 normal, 10 impossible
	bots_chat:   bool,
	vote_percent: int, // of those who can vote, how many must agree
	time_limit:  f32, // minutes a round lasts
	score_limit: int, // captures that win it
	respawn:     f32, // seconds a soldier waits to be placed again
	grenades:    int, // a soldier carries at most this many
	friendly_fire: bool,
	kits_collide:  bool, // bullets and blasts knock the kits about (the flags always move)
	max_rewind:  int, // ms: how far back a shot is judged at most; a slower shooter leads
	update_others: int, // ticks between words of the soldiers that are not the receiver's
	config:      string,
	list_cvars:  bool,
}

settings_default :: proc() -> Settings {
	return {
		base          = ".",
		maps          = "ctf_Ash",
		port          = 23073,
		time_limit    = f32(sim.DEFAULT_TIME_LIMIT) / sim.TICK_RATE / 60,
		score_limit   = int(sim.DEFAULT_SCORE_LIMIT),
		respawn       = f32(sim.DEFAULT_RESPAWN_TIME) / sim.TICK_RATE,
		grenades      = int(sim.DEFAULT_MAX_GRENADES),
		kits_collide  = true,
		bots_difficulty = 100,
		bots_chat     = true,
		vote_percent  = 60,
		max_rewind    = 300,
		update_others = 2,
	}
}

settings_declare :: proc(c: ^cvar.Set, s: ^Settings) {
	cvar.add(c, "sv_base", &s.base, "where the maps, the art and config.cfg are read from")
	cvar.add(c, "sv_map", &s.maps, "the map, or several by comma, played in turn a round each")
	cvar.add(c, "sv_port", &s.port, "the port to listen on")
	cvar.add(c, "sv_bots", &s.bots, "bots the server plays itself")
	cvar.add(c, "sv_bots_difficulty", &s.bots_difficulty, "how well they aim: 300 stupid, 100 normal, 10 impossible")
	cvar.add(c, "sv_bots_chat", &s.bots_chat, "and they say what their personality files give them to say")
	cvar.add(c, "sv_timelimit", &s.time_limit, "minutes a round lasts")
	cvar.add(c, "sv_scorelimit", &s.score_limit, "captures that win a round")
	cvar.add(c, "sv_respawn_time", &s.respawn, "seconds a soldier waits to be placed again")
	cvar.add(c, "sv_maxgrenades", &s.grenades, "grenades a soldier carries at most")
	cvar.add(c, "sv_friendlyfire", &s.friendly_fire, "a team's own bullets wound it")
	cvar.add(c, "sv_kits_collide", &s.kits_collide, "bullets and blasts knock the kits about")
	cvar.add(c, "sv_maxrewind", &s.max_rewind, "ms: how far back a shot is judged at most")
	cvar.add(c, "sv_update_others", &s.update_others, "ticks between words of the other soldiers")
	cvar.add(c, "sv_votepercent", &s.vote_percent, "percent of the players who can vote that must agree for one to pass")
	cvar.add(c, "sv_config", &s.config, "the settings file read at startup")
	cvar.add(c, "cvars", &s.list_cvars, "print every setting and what it is set to, and stop")
}

// The settings file, then the command line over it. What is not a setting is said,
// since it is a misspelling and not something the server silently ignores.
settings_read :: proc(s: ^Settings) {
	c: cvar.Set
	settings_declare(&c, s)
	// the base and the file name themselves, so they are found on the command line first
	for arg, i in os.args[1:] {
		if arg == "-sv_base"   && i + 2 < len(os.args) do s.base = os.args[i + 2]
		if arg == "-sv_config" && i + 2 < len(os.args) do s.config = os.args[i + 2]
	}
	if s.config == "" do s.config = strings.concatenate({s.base, "/config.cfg"})
	cvar.load(&c, s.config, {"cl_", "net_", "snd_", "r_", "ui_", "dbg_"}) // the client's may share the file
	for arg in cvar.parse(&c, os.args[1:]) do fmt.eprintfln("%s is no setting of the server", arg)
	if s.list_cvars {
		cvar.list(&c)
		os.exit(0)
	}
}


// The maps named by sv_map, in the order they are played.
settings_maps :: proc(s: ^Settings) -> []string {
	return strings.split(s.maps, ",")
}
