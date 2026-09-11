package sim

// Kits: the medical and grenade kits that come back after a wait, and the bonus
// kits (flamer, predator, berserker, vest, cluster) that appear on the server's
// schedule and are gone once taken or timed out. Who may take which, and what each
// gives. Ported from the kit parts of things.lua and rules.lua.

KIT_RADIUS          :: 22.0
KIT_TIMEOUT         :: 3600
KIT_SPAWN_JITTER    :: 25.0
FLAMER_BONUS_TIME   :: 600
PREDATOR_BONUS_TIME :: 1500
BERSERK_BONUS_TIME  :: 900
DEFAULT_VEST        :: 100.0
CLUSTER_GRENADES    :: 3

// The spawn point kinds the bonus kits appear at.
BONUS_SPAWN := #partial [Thing_Style]i32{
	.Cluster_Kit = 9, .Vest_Kit = 10, .Flamer_Kit = 11, .Berserk_Kit = 12, .Predator_Kit = 13,
}

is_bonus_kit :: proc(style: Thing_Style) -> bool {
	#partial switch style {
	case .Flamer_Kit, .Predator_Kit, .Vest_Kit, .Berserk_Kit, .Cluster_Kit:
		return true
	}
	return false
}

kit_update :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, events: ^Events) {
	if !t.static do thing_physics(ctx, w, t, events)
	if is_bonus_kit(t.style) {
		t.timeout -= 1
		if t.timeout <= 0 do thing_clear(t)
	}
}

// An empty slot a taken kit will come back into.
kit_respawn_tick :: proc(ctx: ^Context, w: ^World, t: ^Thing) {
	if t.respawn_wait <= 0 do return
	t.respawn_wait -= 1
	if t.respawn_wait == 0 {
		style := t.respawn_style
		thing_clear(t)
		kit_spawn(ctx, w, style)
	}
}

// A medical or grenade kit at one of its spawn points, a little off it.
kit_spawn :: proc(ctx: ^Context, w: ^World, style: Thing_Style) {
	kind: i32 = style == .Medical_Kit ? SPAWN_MEDICAL_KIT : SPAWN_GRENADE_KIT
	pos, ok := level_thing_spawn(ctx.level, kind, &w.rng)
	if !ok do return
	pos.x += (rand_f32(&w.rng) * 2 - 1) * KIT_SPAWN_JITTER
	pos.y += (rand_f32(&w.rng) * 2 - 1) * KIT_SPAWN_JITTER
	thing_create(ctx, w, style, pos)
}

// A bonus kit at its own spawn kind, or any soldier spawn, with its lifetime.
bonus_spawn :: proc(ctx: ^Context, w: ^World, style: Thing_Style) {
	pos, ok := level_thing_spawn(ctx.level, BONUS_SPAWN[style], &w.rng)
	if !ok do pos = level_spawn_point(ctx.level, .None, &w.rng)
	if i, created := thing_create(ctx, w, style, pos); created do w.things[i].timeout = KIT_TIMEOUT
}

// Who may take a kit of this style (TThing.Update's pickup conditions).
kit_eligible :: proc(w: ^World, style: Thing_Style, s: ^Soldier) -> bool {
	#partial switch style {
	case .Medical_Kit:  return s.health < DEFAULT_HEALTH
	case .Grenade_Kit:  return s.grenades < w.round.max_grenades
	case .Flamer_Kit:   return s.bonus == .None && s.cease_fire_counter < 1 && s.weapon.id != .Bow && s.weapon.id != .Bow2
	case .Predator_Kit, .Berserk_Kit: return s.bonus == .None && s.cease_fire_counter < 1
	case .Vest_Kit:     return s.vest < DEFAULT_VEST
	case .Cluster_Kit:  return s.grenades == 0
	}
	return false
}

// May this soldier take it: one it can use, near.
kit_can_pickup :: proc(w: ^World, t: ^Thing, s: ^Soldier) -> bool {
	return kit_eligible(w, t.style, s) && vec2_length(thing_center(t) - s.pos) <= KIT_RADIUS
}

// The pickup: what the kit gives, the thing gone, its respawn timer set.
kit_pickup :: proc(ctx: ^Context, w: ^World, t: ^Thing, index: u8, soldier: u8, events: ^Events) {
	s := &w.soldiers[soldier]
	style := t.style
	#partial switch style {
	case .Medical_Kit:
		s.health = DEFAULT_HEALTH
	case .Grenade_Kit:
		s.grenades = w.round.max_grenades
	case .Flamer_Kit:
		s.secondary = s.weapon
		s.weapon = weapon_state(ctx, .Flamer)
		s.bonus, s.bonus_time = .Flame_God, FLAMER_BONUS_TIME
		s.health = DEFAULT_HEALTH
	case .Predator_Kit:
		s.bonus, s.bonus_time = .Predator, PREDATOR_BONUS_TIME
		s.health = DEFAULT_HEALTH
	case .Berserk_Kit:
		s.bonus, s.bonus_time = .Berserker, BERSERK_BONUS_TIME
		s.health = DEFAULT_HEALTH
	case .Vest_Kit:
		s.vest = DEFAULT_VEST
	case .Cluster_Kit:
		s.grenades = CLUSTER_GRENADES
	}
	emit(events, Kit_Pickup{player = soldier, thing = index, kit = style, pos = t.pos[0]})
	thing_clear(t)
	if !is_bonus_kit(style) {
		t.respawn_wait = w.round.respawn_time
		t.respawn_style = style
	}
}
