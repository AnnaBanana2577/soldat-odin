package sim

// The round: the settings that shape it, the scores, the time limit, cease fire,
// and the per-tick clock the server owns: respawn timers of the soldiers it does not
// step, kit and flag timers (in their files), the end of the round.
// Port of shared/sim/rules.lua.

Match_State :: enum u8 { Playing, Ended, Paused }

Round :: struct {
	state:         Match_State,
	scores:        [Team]i32,
	time_left:     i32,
	counter:       i32, // ticks until the next round after one ends
	respawn_time:  i32,
	max_grenades:  i32,
	friendly_fire: bool,
	kits_collide:  bool, // sv_kits_collide: bullets and blasts knock kits (flags always)
	score_limit:   i32,
}

DEFAULT_RESPAWN_TIME :: 180
DEFAULT_MAX_GRENADES :: 2
DEFAULT_TIME_LIMIT   :: 15 * 60 * TICK_RATE
DEFAULT_SCORE_LIMIT :: 10

round_init :: proc(r: ^Round) {
	r^ = {
		respawn_time = DEFAULT_RESPAWN_TIME,
		max_grenades = DEFAULT_MAX_GRENADES,
		time_left = DEFAULT_TIME_LIMIT,
		score_limit = DEFAULT_SCORE_LIMIT,
	}
}

round_tick :: proc(ctx: ^Context, w: ^World, events: ^Events) {
	r := &w.round
	for &s, i in w.soldiers {
		if s.active && s.dead do soldier_dead_tick(ctx, w, u8(i), events)
	}
	if r.state != .Playing do return
	r.time_left -= 1
	if r.time_left <= 0 || r.scores[.Alpha] >= r.score_limit || r.scores[.Bravo] >= r.score_limit {
		round_end(w, events)
	}
}

round_end :: proc(w: ^World, events: ^Events) {
	r := &w.round
	r.state = .Ended
	winner := Team.None
	if r.scores[.Alpha] > r.scores[.Bravo] do winner = .Alpha
	else if r.scores[.Bravo] > r.scores[.Alpha] do winner = .Bravo
	emit(events, Match_End{winner = winner})
}
