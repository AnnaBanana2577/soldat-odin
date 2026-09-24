package sim

import "../polymap"

// A random active spawn point of the team's, or of the general ones, or the origin.
spawn_point :: proc(m: ^polymap.Polymap, team: Team, rng: ^u64) -> Vec2 {
	want := i32(team)
	for pass in 0 ..< 2 {
		count := 0
		for s in m.spawnpoints do if s.active && s.team == want do count += 1
		if count > 0 {
			pick := rand_int(rng, count)
			for s in m.spawnpoints {
				if !(s.active && s.team == want) do continue
				if pick == 0 do return s.pos
				pick -= 1
			}
		}
		if pass == 0 do want = 0
	}
	return {}
}
