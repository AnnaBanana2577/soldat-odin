package sim

// The bots, ported from OpenSoldat's AI.pas. A bot is not a second kind of soldier:
// every tick it fills in the keys a player would hold and where that player's cursor
// would be, and the sim steps its soldier on them like anyone else's. What it does
// falls in two halves: while it sees nobody it walks the paths the map author laid
// (bot_path.odin, ControlBot), and when it sees someone it fights (bot_fight.odin,
// SimpleDecision). Its temper, its aim and what it says come from its personality
// file (bot_file.odin).
//
// The distances here are the original's pixels, which are this sim's too, so its
// numbers stand as they are.
//
// The server plays its bots with this. The headless test client plays its own soldier
// with it as well, on the world as that client shows it, so the netcode has something
// to carry.

// Soldat's one-axis distance buckets (AI.pas CheckDistance).
DIST_TOO_CLOSE  :: 35
DIST_VERY_CLOSE :: 55
DIST_CLOSE      :: 95
DIST_ROCK_THROW :: 180
DIST_FAR        :: 350
DIST_VERY_FAR   :: 500
DIST_TOO_FAR    :: 730
DIST_AWAY       :: 731

BOT_SIGHT          :: 651.0 // how far a bot looks
WAYPOINT_RADIUS    :: 21.0  // near enough to count as reached
WAYPOINT_REACH     :: 350.0 // and how far it looks for one when it has none
WAYPOINT_GIVE_UP   :: 320   // ticks on the way to one before falling back to the last
WAYPOINT_STUCK     :: 480   // ticks on the same one before dropping the path
HURT_HEALTH        :: 25.0  // hurt enough to say so
DEAD_INTEREST      :: 180   // ticks a body is still worth shooting at
FLAG_INTEREST_TIME :: 25 * TICK_RATE // how long the bots keep going for a flag

NOBODY :: u8(255) // no target, no friend

// The primaries a bot draws when it is not taking its favourite (Random(9) + 1).
@(rodata)
BOT_PRIMARIES := [?]Weapon_Id{.Eagle, .MP5, .AK74, .Steyr, .Spas, .Ruger, .M79, .Barrett, .M249}

// The keys a bot holds this tick, and where it points: Soldat's TControl.
Bot_Control :: struct {
	left, right, up, down: bool,
	fire, jet, throw_nade: bool,
	change, throw_weapon:  bool,
	reload, prone:         bool,
	aim:                   Vec2, // the cursor, in the world
}

// One bot: its personality, its brain (TBotData), and the keys it holds now.
Bot :: struct {
	playing:    bool, // this slot is a bot
	prof:       Bot_Profile,
	rng:        u64,
	difficulty: int,    // bots_difficulty: 300 stupid, 100 normal, 10 impossible
	chatty:     bool,   // it talks
	accuracy:   int,    // the profile's, scaled by the difficulty
	friend:     u8,     // the slot of the player it will not shoot at
	says:       string, // a line for the server to pass on, cleared as it takes it
	taunts:     u8,     // and a slot to name in it

	ctl:  Bot_Control,
	live: bool, // its soldier was alive last tick

	// TBotData (Sprites.pas): who it is after, and where it is on the path.
	target:          u8,
	pissed_off:      u8,   // whoever wounded it last: hunted even out of sight
	go_thing:        bool, // walking to a flag or a kit, not along the path
	path:            u8,   // the path it follows: its team's, or the other's with the flag
	current:         int,  // the waypoint it stands on, 0 for none
	next, old, last: int,  // the one it walks to, the one before, the one it was on
	waypoint_time:   int,  // ticks on the same waypoint
	give_up:         int,  // ticks left to reach the one it walks to
	one_place:       int,  // ticks spent going nowhere, or waiting on a waypoint
	fall_save:       bool, // falling fast: jet before it lands
}

// Every slot's bot: the server keeps one, and a bot reads another's to see whether
// the soldier it is fighting is a camper.
Bots :: [MAX_PLAYERS]Bot

bot_init :: proc(b: ^Bot, prof: Bot_Profile, seed: u64, difficulty := 100, chatty := true) {
	b^ = {
		playing    = true,
		prof       = prof,
		rng        = seed | 1,
		difficulty = difficulty,
		chatty     = chatty,
		accuracy   = int(f32(prof.accuracy) * f32(difficulty) / 100),
		friend     = NOBODY,
		target     = NOBODY,
		pissed_off = NOBODY,
		taunts     = NOBODY,
	}
}

// A personality at random for a new bot, as ServerHelper.pas RandomBot picks one:
// never the Boogie Man, who plays as the Sniper. A plain one when there are no files.
bot_profile_any :: proc(profiles: []Bot_Profile, rng: ^u64) -> Bot_Profile {
	if len(profiles) == 0 {
		return {name = "Bot", accuracy = 10, grenade_freq = 500, chat_freq = 1, use = 255}
	}
	p := profiles[rand_int(rng, len(profiles))]
	if p.name == "Boogie Man" {
		for q in profiles do if q.name == "Sniper" do return q
	}
	return p
}

// This tick's command for the bot in `slot`: one turn of ControlBot, with the controls
// it leaves behind read off as buttons.
bot_command :: proc(bots: ^Bots, ctx: ^Context, w: ^World, slot: u8) -> (cmd: Command) {
	b := &bots[slot]
	s := &w.soldiers[slot]
	if !s.active || s.dead {
		if b.live {
			b.live = false
			bot_died(b, s)
		}
		b.ctl = {}
		cmd.aim = s.pos + {f32(s.direction) * 100, 0}
		return
	}
	if !b.live {
		b.live = true
		bot_placed(b, s)
	}
	bot_walk(bots, ctx, w, slot)

	ctl := b.ctl
	if ctl.left do cmd.buttons += {.Left}
	if ctl.right do cmd.buttons += {.Right}
	if ctl.up do cmd.buttons += {.Jump}
	if ctl.down do cmd.buttons += {.Crouch}
	if ctl.prone do cmd.buttons += {.Prone}
	if ctl.jet do cmd.buttons += {.Jet}
	if ctl.fire do cmd.buttons += {.Fire}
	if ctl.throw_nade do cmd.buttons += {.Throw}
	if ctl.reload do cmd.buttons += {.Reload}
	if ctl.change do cmd.buttons += {.Change}
	if ctl.throw_weapon do cmd.buttons += {.Drop}
	cmd.aim = ctl.aim
	return
}

// TSprite.Die's part of it: its temper cools, and it draws the weapons it will carry
// next time now, since the server places it again on its own.
bot_died :: proc(b: ^Bot, s: ^Soldier) {
	b.pissed_off = NOBODY
	bot_loadout(b, s)
}

// TSprite.Respawn's part: no waypoint yet, its team's path, and the idle antic its
// file asks for.
bot_placed :: proc(b: ^Bot, s: ^Soldier) {
	b.pissed_off = NOBODY
	b.current = 0
	b.path = u8(s.team)
	switch b.prof.use {
	case 1: s.idle = {time = 0, random = 1}
	case 2: s.idle = {time = 0, random = 0}
	}
}

// What it will spawn with: half the time its favourite, otherwise one of the nine
// primaries; a favourite that is a sidearm, a knife or bare hands is all it carries.
// The secondary is its file's pick.
bot_loadout :: proc(b: ^Bot, s: ^Soldier) {
	fav := b.prof.favourite
	if fav in PRIMARY_WEAPONS {
		s.primary_choice = rand_int(&b.rng, 2) == 0 ? fav : BOT_PRIMARIES[rand_int(&b.rng, len(BOT_PRIMARIES))]
		s.secondary_choice = b.prof.secondary
	} else {
		s.primary_choice, s.secondary_choice = fav, .None
	}
}

// What this tick's events do to the bots' tempers, and what they make them say: a
// wound makes the attacker what the bot is after wherever it goes (Bullets.pas
// HealthHit), a kill calms it. The server hands over every event it applies.
bot_event :: proc(bots: ^Bots, w: ^World, e: Event) {
	#partial switch v in e {
	case Damage:
		if v.attacker >= MAX_PLAYERS || v.attacker == v.target do return
		b := &bots[v.target]
		if !b.playing do return
		b.pissed_off = v.attacker
		b.target = v.attacker
		if b.chatty && w.soldiers[v.target].health < HURT_HEALTH && rand_int(&b.rng, 10 * b.prof.chat_freq) == 0 {
			b.says = b.prof.chat_low_health
		}
	case Kill:
		if b := &bots[v.target]; b.playing {
			if b.chatty && rand_int(&b.rng, b.prof.chat_freq / 2) == 0 do b.says = b.prof.chat_dead
		}
		if v.killer >= MAX_PLAYERS do return
		if b := &bots[v.killer]; b.playing {
			b.pissed_off = NOBODY
			if b.chatty && v.killer != v.target && rand_int(&b.rng, b.prof.chat_freq / 3) == 0 {
				b.says = b.prof.chat_kill
			}
		}
	}
}

// The bucket a one-axis distance falls in (AI.pas CheckDistance).
bot_distance :: proc(a, b: f32) -> int {
	d := abs(a - b)
	switch {
	case d <= DIST_TOO_CLOSE:  return DIST_TOO_CLOSE
	case d <= DIST_VERY_CLOSE: return DIST_VERY_CLOSE
	case d <= DIST_CLOSE:      return DIST_CLOSE
	case d <= DIST_ROCK_THROW: return DIST_ROCK_THROW
	case d <= DIST_FAR:        return DIST_FAR
	case d <= DIST_VERY_FAR:   return DIST_VERY_FAR
	case d <= DIST_TOO_FAR:    return DIST_TOO_FAR
	}
	return DIST_AWAY
}

// Every key up, the aim where it was: TSprite.FreeControls.
bot_free_controls :: proc(b: ^Bot) {
	b.ctl = {aim = b.ctl.aim}
}

// Where a soldier looks from, and where it is aimed at: point 12 of its skeleton, or
// of its corpse once it is dead.
bot_head :: proc(ctx: ^Context, w: ^World, index: u8) -> Vec2 {
	s := &w.soldiers[index]
	if s.dead && w.ragdolls[index].active do return w.ragdolls[index].pos[11]
	pose := soldier_pose(ctx.anims, s, s.pos)
	return pose[11]
}

// The flag this soldier carries, if it carries one.
bot_flag_held :: proc(w: ^World, index: u8) -> ^Thing {
	if !w.soldiers[index].holding_flag do return nil
	for &t in w.things {
		if is_flag(t.style) && t.holder == index + 1 do return &t
	}
	return nil
}

// A team's own flag.
bot_team_flag :: proc(w: ^World, team: Team) -> ^Thing {
	for &t in w.things {
		if is_flag(t.style) && flag_team(t.style) == team do return &t
	}
	return nil
}

// Who is winning: most captures, then most kills, then fewest deaths (SortedPlayers).
bot_leader :: proc(w: ^World) -> u8 {
	best := NOBODY
	for &s, i in w.soldiers {
		if !s.active do continue
		if best == NOBODY {
			best = u8(i)
			continue
		}
		o := &w.soldiers[best]
		if s.flags > o.flags ||
		   (s.flags == o.flags && (s.kills > o.kills || (s.kills == o.kills && s.deaths < o.deaths))) {
			best = u8(i)
		}
	}
	return best
}
