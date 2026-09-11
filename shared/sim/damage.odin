package sim

// The one place health changes. A Hit becomes a wound here: the vest and berserker
// rules, the helmet, then death. Port of shared/sim/damage.lua.

BRUTAL_DEATH_HEALTH   :: -400.0
HEADCHOP_DEATH_HEALTH :: -90.0

damage_apply :: proc(ctx: ^Context, w: ^World, hit: Hit, events: ^Events) {
	s := &w.soldiers[hit.target]
	if !s.active || s.dead do return
	attacker := &w.soldiers[hit.shooter]
	if !w.round.friendly_fire && s.team != .None && s.team == attacker.team && hit.target != hit.shooter do return
	if s.bonus == .Flame_God do return

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
	ragdoll_start(ctx, w, hit.target) // before the velocity goes, so the corpse keeps it
	ragdoll_tear(w, hit.target, s.health, hit.part)
	if s.weapon.id != .Flamer do dropped_gun_from_death(ctx, w, hit.target, s, hit.push, events)
	s.weapon = weapon_state(ctx, .None)
	s.dead = true
	s.vel = {}
	s.respawn_counter = w.round.respawn_time
	s.deaths += 1
	if hit.shooter != hit.target do w.soldiers[hit.shooter].kills += 1
	else if s.kills > 0 do s.kills -= 1
	emit(events, Kill{killer = hit.shooter, target = hit.target, weapon = hit.weapon, pos = s.pos, health = s.health, part = hit.part})
}
