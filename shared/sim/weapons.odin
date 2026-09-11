package sim

// The weapons: names, how they reload and fire, and the balance numbers. The defaults
// are Soldat 1.7.1's, which is also OpenSoldat's built-in table; a server's weapons
// mod overrides them. Ported from Weapons.pas by way of the old Odin port.

Weapon_Id :: enum u8 {
	None, Eagle, MP5, AK74, Steyr, Spas, Ruger, M79, Barrett, M249, Minigun,
	Colt, Knife, Chainsaw, LAW, Bow2, Bow, Flamer, M2,
	Frag, Cluster_Nade, Cluster, Thrown_Knife,
}

PRIMARY_WEAPONS   :: bit_set[Weapon_Id]{.Eagle, .MP5, .AK74, .Steyr, .Spas, .Ruger, .M79, .Barrett, .M249, .Minigun}
SECONDARY_WEAPONS :: bit_set[Weapon_Id]{.Colt, .Knife, .Chainsaw, .LAW}

Bullet_Style :: enum u8 {
	Plain, Frag_Grenade, Shotgun, M79, Flame, Punch, Arrow, Flame_Arrow, Cluster_Nade, Cluster, Knife, LAW, Thrown_Knife, M2,
}

// ticks
BULLET_TIMEOUT   :: 60 * 7
GRENADE_TIMEOUT  :: 60 * 3
M2BULLET_TIMEOUT :: 60
FLAMER_TIMEOUT   :: 32
MELEE_TIMEOUT    :: 1

Weapon_Info :: struct {
	name:        string,
	clip_reload: bool, // a clip out and in, or shell by shell
	semi_auto:   bool, // the trigger must be released between shots

	damage:        f32, // "HitMultiply"
	fire_interval: i32,
	ammo:          i32,
	reload_time:   i32,
	speed:         f32,
	style:         Bullet_Style,
	startup:       i32, // the wind-up of the minigun and the LAW
	bink:          i32, // negative: self-bink per shot; positive: given to who it hits
	movement_acc:  f32,
	spread:        f32,
	push:          f32,
	inherit:       f32, // of the shooter's velocity
	mod_head, mod_chest, mod_legs: f32,

	// derived by weapons_finalize
	clip_out_time: i32,
	clip_in_time:  i32,
	timeout:       i32,
}

@(private = "file")
Weapon_Base :: struct {
	name:        string,
	clip_reload: bool,
	semi_auto:   bool,
}

@(private = "file")
WEAPON_BASE := [Weapon_Id]Weapon_Base{
	.None         = {"Hands", false, false},
	.Eagle        = {"Desert Eagles", true, true},
	.MP5          = {"HK MP5", true, false},
	.AK74         = {"Ak-74", true, false},
	.Steyr        = {"Steyr AUG", true, false},
	.Spas         = {"Spas-12", false, true},
	.Ruger        = {"Ruger 77", false, true},
	.M79          = {"M79", true, false},
	.Barrett      = {"Barrett M82A1", true, true},
	.M249         = {"FN Minimi", true, false},
	.Minigun      = {"XM214 Minigun", false, false},
	.Colt         = {"USSOCOM", true, true},
	.Knife        = {"Combat Knife", false, false},
	.Chainsaw     = {"Chainsaw", false, false},
	.LAW          = {"LAW", true, false},
	.Bow2         = {"Flame Bow", false, false},
	.Bow          = {"Bow", false, false},
	.Flamer       = {"Flamer", false, false},
	.M2           = {"M2 MG", false, false},
	.Frag         = {"Frag Grenade", false, false},
	.Cluster_Nade = {"Cluster Grenade", false, false},
	.Cluster      = {"Cluster", false, false},
	.Thrown_Knife = {"Combat Knife", false, false},
}

// The tunable numbers: what a weapons mod sets.
Weapon_Stats :: struct {
	damage:        f32,
	fire_interval: i32,
	ammo:          i32,
	reload_time:   i32,
	speed:         f32,
	style:         Bullet_Style,
	startup:       i32,
	bink:          i32,
	movement_acc:  f32,
	spread:        f32,
	push:          f32,
	inherit:       f32,
	mod_head, mod_chest, mod_legs: f32,
}

// Soldat 1.7.1. The cluster grenade, cluster and thrown knife derive from the frag
// grenade and the knife in weapons_finalize.
@(rodata)
WEAPON_DEFAULTS := #partial [Weapon_Id]Weapon_Stats{
	//          damage  fire ammo reload speed  style          startup bink moveacc  spread push     inherit head  chest legs
	.Eagle   = {1.81,   24,  7,   87,    19,    .Plain,        0,      0,   0.009,   0.15,  0.0176,  0.5,    1.1,  0.95, 0.85},
	.MP5     = {1.01,   6,   30,  105,   18.9,  .Plain,        0,      0,   0,       0.14,  0.0112,  0.5,    1.1,  0.95, 0.85},
	.AK74    = {1.004,  10,  35,  165,   24.6,  .Plain,        0,      -12, 0.011,   0.025, 0.01376, 0.5,    1.1,  0.95, 0.85},
	.Steyr   = {0.71,   7,   25,  125,   26,    .Plain,        0,      0,   0,       0.075, 0.0084,  0.5,    1.1,  0.95, 0.85},
	.Spas    = {1.22,   32,  7,   175,   14,    .Shotgun,      0,      0,   0,       0.8,   0.0188,  0.5,    1.1,  0.95, 0.85},
	.Ruger   = {2.49,   45,  4,   78,    33,    .Plain,        0,      0,   0.03,    0,     0.012,   0.5,    1.2,  1.05, 1.0},
	.M79     = {1550,   6,   1,   178,   10.7,  .M79,          0,      0,   0,       0,     0.036,   0.5,    1.15, 1,    0.9},
	.Barrett = {4.45,   225, 10,  70,    55,    .Plain,        19,     65,  0.05,    0,     0.018,   0.5,    1.0,  1.0,  1.0},
	.M249    = {0.85,   9,   50,  250,   27,    .Plain,        0,      0,   0.013,   0.064, 0.0128,  0.5,    1.1,  0.95, 0.85},
	.Minigun = {0.468,  3,   100, 480,   29,    .Plain,        25,     0,   0.0625,  0.3,   0.0104,  0.5,    1.1,  0.95, 0.85},
	.Colt    = {1.49,   10,  14,  60,    18,    .Plain,        0,      0,   0,       0,     0.02,    0.5,    1.1,  0.95, 0.85},
	.Knife   = {2150,   6,   1,   3,     6,     .Knife,        0,      0,   0,       0,     0.12,    0,      1.15, 1,    0.9},
	.Chainsaw = {50,    2,   200, 110,   8,     .Knife,        0,      0,   0,       0,     0.0028,  0,      1.15, 1.0,  0.9},
	.LAW     = {1550,   6,   1,   300,   23,    .LAW,          13,     0,   0,       0,     0.028,   0.5,    1.15, 1.0,  0.9},
	.Bow2    = {8,      10,  1,   39,    18,    .Flame_Arrow,  0,      0,   0,       0,     0,       0.5,    1.15, 1,    0.9},
	.Bow     = {12,     10,  1,   25,    21,    .Arrow,        0,      0,   0,       0,     0.0148,  0.5,    1.15, 1,    0.9},
	.Flamer  = {19,     6,   200, 5,     10.5,  .Flame,        0,      0,   0,       0,     0.016,   0.5,    1.15, 1,    0.9},
	.M2      = {1.8,    10,  100, 366,   36,    .M2,           0,      0,   0,       0,     0.0088,  0,      1.1,  0.95, 0.85},
	.None    = {330,    6,   1,   3,     5,     .Punch,        0,      0,   0,       0,     0,       0,      1.15, 1,    0.9},
	.Frag    = {1500,   80,  1,   20,    5,     .Frag_Grenade, 0,      0,   0,       0,     0,       1,      1.0,  1.0,  1.0},
}

Weapons :: [Weapon_Id]Weapon_Info

weapons_default :: proc(w: ^Weapons) {
	w^ = {}
	for &info, id in w {
		base := WEAPON_BASE[id]
		info.name, info.clip_reload, info.semi_auto = base.name, base.clip_reload, base.semi_auto
		weapon_set_stats(&info, WEAPON_DEFAULTS[id])
	}
	weapons_finalize(w)
}

weapon_set_stats :: proc(info: ^Weapon_Info, s: Weapon_Stats) {
	info.damage, info.fire_interval, info.ammo, info.reload_time = s.damage, s.fire_interval, s.ammo, s.reload_time
	info.speed, info.style, info.startup, info.bink = s.speed, s.style, s.startup, s.bink
	info.movement_acc, info.spread, info.push, info.inherit = s.movement_acc, s.spread, s.push, s.inherit
	info.mod_head, info.mod_chest, info.mod_legs = s.mod_head, s.mod_chest, s.mod_legs
}

// The derived weapons and numbers; call after changing any stats.
weapons_finalize :: proc(w: ^Weapons) {
	derive :: proc(w: ^Weapons, id, from: Weapon_Id, style: Bullet_Style) {
		base := WEAPON_BASE[id]
		w[id] = w[from]
		w[id].name, w[id].clip_reload, w[id].semi_auto = base.name, base.clip_reload, base.semi_auto
		w[id].style = style
	}
	derive(w, .Cluster_Nade, .Frag, .Cluster_Nade)
	derive(w, .Cluster, .Cluster_Nade, .Cluster)
	derive(w, .Thrown_Knife, .Knife, .Thrown_Knife)

	for &info in w {
		info.clip_out_time, info.clip_in_time = 0, 0
		if info.clip_reload {
			info.clip_out_time = i32(f32(info.reload_time) * 0.8)
			info.clip_in_time = i32(f32(info.reload_time) * 0.3)
		}
		#partial switch info.style {
		case .Frag_Grenade, .Cluster_Nade: info.timeout = GRENADE_TIMEOUT
		case .Flame:                       info.timeout = FLAMER_TIMEOUT
		case .Punch, .Knife:               info.timeout = MELEE_TIMEOUT
		case .M2:                          info.timeout = M2BULLET_TIMEOUT
		case:                              info.timeout = BULLET_TIMEOUT
		}
	}
}
