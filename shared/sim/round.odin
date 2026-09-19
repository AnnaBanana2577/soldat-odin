package sim

// The round: the settings that shape it, the scores, the time limit, and the per-tick
// clock of the world that decides: what it keeps of every soldier (soldier_served_tick),
// the kit and flag timers (in their files), the end of the round. A round that has
// ended counts down to the next (round_over); starting it, on the same map or another,
// is the server's, since it may load a map.
// Port of shared/sim/rules.lua.

Match_State :: enum u8 { Playing, Ended, Paused }

Round :: struct {
	state:         Match_State,
	scores:        [Team]i32,
	time_left:     i32,
	counter:       i32, // after it ends: ticks until the next round
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
ROUND_END_TICKS     :: 5 * TICK_RATE + 20 // the scores stand this long before the next round (DEFAULT_MAPCHANGE_TIME)

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
	for i in 0 ..< MAX_PLAYERS do soldier_served_tick(ctx, w, u8(i), events)
	if r.state == .Ended && r.counter > 0 do r.counter -= 1
	if r.state != .Playing do return
	r.time_left -= 1
	if r.time_left <= 0 || r.scores[.Alpha] >= r.score_limit || r.scores[.Bravo] >= r.score_limit {
		round_end(w, events)
	}
}

round_end :: proc(w: ^World, events: ^Events) {
	r := &w.round
	r.state = .Ended
	r.counter = ROUND_END_TICKS
	winner := Team.None
	if r.scores[.Alpha] > r.scores[.Bravo] do winner = .Alpha
	else if r.scores[.Bravo] > r.scores[.Alpha] do winner = .Bravo
	emit(events, Match_End{winner = winner})
}

// The round has ended and its scores have stood long enough: time for the next.
round_over :: proc(r: ^Round) -> bool {
	return r.state == .Ended && r.counter <= 0
}
