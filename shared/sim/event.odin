package sim

// What happened this tick, for whoever is listening: the client's sparks, sounds and
// messages, the server's commits, the shooter's hit claims. A tagged union, so each
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
Bullet_End :: struct { id: u16, weapon: Weapon_Id, pos: Vec2, impact: bool }
Wall_Hit :: struct { id: u16, weapon: Weapon_Id, pos, vel: Vec2 }
Ricochet :: struct { id: u16, pos, vel: Vec2 }
Collider_Hit :: struct { id: u16, pos, vel: Vec2 }
Grenade_Bounce :: struct { id: u16, pos: Vec2 }
Cluster_Split :: struct { id: u16, pos: Vec2 }
Blood :: struct { shooter, target: u8, pos, vel: Vec2 }
Explosion :: struct { id: u16, player: u8, weapon: Weapon_Id, pos: Vec2, radius: f32 }

// A bullet or blast of `shooter` wounded `target`: the damage the sim computed, the
// skeleton part hit (0 for a blast), the point hit, and the knockback to give. Nothing
// has changed yet; the caller applies it with damage_apply, or claims it.
Hit :: struct { shooter, target: u8, weapon: Weapon_Id, amount: f32, part: u8, pos, push: Vec2 }

Damage :: struct { attacker, target: u8, weapon: Weapon_Id, amount: f32, vest: bool }
Kill :: struct { killer, target: u8, weapon: Weapon_Id, pos: Vec2, health: f32, part: u8 }
Respawn :: struct { target: u8, pos: Vec2 }
// The pickups carry the thing's index: a client claims them by it.
Flag_Grab :: struct { player: u8, thing: u8, flag: Thing_Style, pos: Vec2 }
Flag_Return :: struct { player: u8, flag: Thing_Style, pos: Vec2 } // player 255: timed out
Flag_Score :: struct { player: u8, flag: Thing_Style, pos: Vec2 }
Kit_Pickup :: struct { player: u8, thing: u8, kit: Thing_Style, pos: Vec2 }
Weapon_Pickup :: struct { player: u8, thing: u8, weapon: Weapon_Id, pos: Vec2 }
Weapon_Drop :: struct { player: u8, weapon: Weapon_Id, ammo: i32, thrown: bool } // thrown by hand, or let go of by a death
Thing_Hit :: struct { thing: Thing_Style, pos, vel: Vec2, part: u8 }
Match_End :: struct { winner: Team }
Poly_Effect :: struct { target: u8, type: Poly_Type, pos: Vec2, spark: bool } // a hurting, lava, regenerating or exploding poly touched

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
