package sim

// The one place health changes. A Hit becomes a wound here: the vest and berserker
// rules, the helmet, then death. Port of shared/sim/damage.lua.

BRUTAL_DEATH_HEALTH   :: -400.0
HEADCHOP_DEATH_HEALTH :: -90.0

damage_apply :: proc(ctx: ^Context, w: ^World, hit: Hit, events: ^Events) {
	s := &w.soldiers[hit.target]
	if !s.active do return
	attacker := &w.soldiers[hit.shooter]
	if !w.match.friendly_fire && s.team != .None && s.team == attacker.team && hit.target != hit.shooter do return
	if s.bonus == .Flame_God do return

	// HealthHit on a corpse: the wound lands and nothing else does. No knockback, no
	// tally, no second death — but the health goes on down, and with it the state the
	// corpses are torn from, so a body shot enough comes apart (Die's cuts, which the
	// original makes on every call, alive or not).
	if s.dead {
		amount := attacker.bonus == .Berserker && hit.shooter != hit.target ? 4 * hit.amount : hit.amount
		s.health = clamp(s.health - amount, BRUTAL_DEATH_HEALTH, DEFAULT_HEALTH)
		if s.health <= HEADCHOP_DEATH_HEALTH do s.death_part = hit.part
		return
	}

	amount := hit.amount
	vested := s.vest > 0
	if vested {
		s.vest -= 0.33 * amount
		amount = 0.25 * amount
	}
	if attacker.bonus == .Berserker && hit.shooter != hit.target do amount = 4 * hit.amount

	s.health = clamp(s.health - amount, BRUTAL_DEATH_HEALTH, DEFAULT_HEALTH)
	s.next_push += hit.push
	emit(events, Damage{attacker = hit.shooter, target = hit.target, weapon = hit.weapon, amount = amount, vest = vested})
	if s.health < 1 do die(ctx, w, hit, events)
}

die :: proc(ctx: ^Context, w: ^World, hit: Hit, events: ^Events) {
	s := &w.soldiers[hit.target]
	s.death_pos, s.death_vel, s.death_part = s.pos, s.vel, hit.part // the corpse starts from these, wherever it is drawn
	if s.weapon.id != .Flamer do dropped_gun_from_death(ctx, w, hit.target, s, hit.push, events)
	s.weapon = weapon_state(ctx, .None)
	s.dead = true
	s.vel = {}
	s.respawn_counter = w.match.respawn_time
	s.deaths += 1
	if hit.shooter != hit.target do w.soldiers[hit.shooter].kills += 1
	else if s.kills > 0 do s.kills -= 1
	emit(events, Kill{killer = hit.shooter, target = hit.target, weapon = hit.weapon, pos = s.pos, health = s.health, part = hit.part, kills = w.soldiers[hit.shooter].kills})
}
