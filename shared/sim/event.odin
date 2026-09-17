package sim

// What happened this tick, for whoever is listening: the client's sparks, sounds and
// messages, the server's wounds. A tagged union, so each
// kind carries its own fields by name.
Event :: union {
	Fire,
	Bullet_Spawn,
	Bullet_End,
	Wall_Hit,
	Ricochet,
	Collider_Hit,
	Grenade_Bounce,
	Cluster_Split,
	Blood,
	Explosion,
	Hit,
	Damage,
	Kill,
	Respawn,
	Flag_Grab,
	Flag_Return,
	Flag_Score,
	Kit_Pickup,
	Weapon_Pickup,
	Weapon_Drop,
	Thing_Hit,
	Poly_Effect,
	Match_End,
}

Fire :: struct { player: u8, weapon: Weapon_Id, pos, vel: Vec2 }
Bullet_Spawn :: struct { id: u16, player: u8, weapon: Weapon_Id, pos, vel: Vec2, damage: f32 }
Bullet_End :: struct { id: u16, owner: u8, weapon: Weapon_Id, pos: Vec2, impact: bool }
Wall_Hit :: struct { id: u16, owner: u8, weapon: Weapon_Id, pos, vel: Vec2 }
Ricochet :: struct { id: u16, owner: u8, pos, vel: Vec2 }
Collider_Hit :: struct { id: u16, owner: u8, pos, vel: Vec2 }
Grenade_Bounce :: struct { id: u16, owner: u8, pos: Vec2 }
Cluster_Split :: struct { id: u16, owner: u8, pos: Vec2 }
Blood :: struct { shooter, target: u8, pos, vel: Vec2 }
Explosion :: struct { id: u16, player: u8, weapon: Weapon_Id, pos: Vec2, radius: f32 }

// A bullet or blast of `shooter` wounded `target`: the damage the sim computed, the
// skeleton part hit (0 for a blast), the point hit, and the knockback to give. Nothing
// has changed yet; the server applies it with damage_apply, a client only shows it.
Hit :: struct { shooter, target: u8, weapon: Weapon_Id, amount: f32, part: u8, pos, push: Vec2 }

Damage :: struct { attacker, target: u8, weapon: Weapon_Id, amount: f32, vest: bool }
Kill :: struct { killer, target: u8, weapon: Weapon_Id, pos: Vec2, health: f32, part: u8 }
Respawn :: struct { target: u8, pos: Vec2 }
// The pickups carry the thing's index.
Flag_Grab :: struct { player: u8, thing: u8, flag: Thing_Style, pos: Vec2 }
Flag_Return :: struct { player: u8, flag: Thing_Style, pos: Vec2 } // player 255: timed out
Flag_Score :: struct { player: u8, flag: Thing_Style, pos: Vec2 }
Kit_Pickup :: struct { player: u8, thing: u8, kit: Thing_Style, pos: Vec2 }
Weapon_Pickup :: struct { player: u8, thing: u8, weapon: Weapon_Id, pos: Vec2 }
Weapon_Drop :: struct { player: u8, weapon: Weapon_Id, ammo: i32, thrown: bool } // thrown by hand, or let go of by a death
Thing_Hit :: struct { thing: Thing_Style, pos, vel: Vec2, part: u8 }
Match_End :: struct { winner: Team }
Poly_Effect :: struct { target: u8, type: Poly_Type, pos: Vec2, spark: bool } // a hurting, lava, regenerating or exploding poly touched

// Who an event is down to, when a client could have predicted it: the player whose
// action it is. A fact only the server decides (a wound, a death, a respawn, a score,
// a thing landing) is nobody'"'"'s, and predictable is false.
event_owner :: proc(e: Event) -> (owner: u8, predictable: bool) {
	#partial switch v in e {
	case Fire:           return v.player, true
	case Bullet_Spawn:   return v.player, true
	case Bullet_End:     return v.owner, true
	case Wall_Hit:       return v.owner, true
	case Ricochet:       return v.owner, true
	case Collider_Hit:   return v.owner, true
	case Grenade_Bounce: return v.owner, true
	case Cluster_Split:  return v.owner, true
	case Blood:          return v.shooter, true
	case Explosion:      return v.player, true
	case Hit:            return v.shooter, true
	case Flag_Grab:      return v.player, true
	case Kit_Pickup:     return v.player, true
	case Weapon_Pickup:  return v.player, true
	case Weapon_Drop:    return v.player, true
	case Poly_Effect:    return v.target, true
	}
	return 0, false
}

MAX_EVENTS :: 256

Events :: struct {
	items: [MAX_EVENTS]Event,
	count: int,
}

emit :: proc(ev: ^Events, e: Event) {
	if ev.count < MAX_EVENTS {
		ev.items[ev.count] = e
		ev.count += 1
	}
}

events_clear :: proc(ev: ^Events) {
	ev.count = 0
}

events_slice :: proc(ev: ^Events) -> []Event {
	return ev.items[:ev.count]
}
