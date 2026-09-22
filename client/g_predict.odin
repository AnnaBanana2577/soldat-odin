package client

import "../shared/net"
import "../shared/sim"

// My own soldier, predicted. The server runs it, on the commands I send; I run the same
// step on the same commands the moment I make them, so what I press shows at once.
//
// Every update carries my soldier as the server has it and the number of the last
// command it ran. Over that word I replay the commands it has not run yet and end up
// where I already am, unless the server saw something I did not (a wound, a blast, a
// wall I was not at): then the difference is an offset that blends out over about a
// tenth of a second, so the correction is felt and not seen.
//
// My bullets are mine the same way: the ones from commands the server has not run are
// dropped and made again by the replay, so a bullet is never made twice and never
// missed. The server does not send me my own.

CLOCK_GAIN   :: 0.015 // of a command's worth of depth, per tick of my clock
CLOCK_MOST   :: 0.04  // and never faster or slower than this
DEPTH_EASE   :: 0.1   // how quickly the depth I steer by follows what the server reports

ERROR_KEPT  :: 0.85  // of the drawn offset, per tick: gone in about a tenth of a second
ERROR_SNAP  :: 120.0 // further out than this and the correction is shown at once

// The server's word on my soldier, as of the update's tick, with the last command it
// ran. What follows it is mine again.
reconcile :: proc(g: ^Game, e: ^net.Entry, tick: u32, ack: u32) {
	mine := &g.world.soldiers[g.me]
	drawn := mine.pos + g.error
	was_alive := mine.active && !mine.dead

	sim.soldier_copy_served(mine, &e.soldier)
	if e.has_owned do sim.soldier_copy_owned(g.content.ctx.anims, mine, &e.soldier)
	if e.has_rest do sim.soldier_copy_rest(mine, &e.soldier)

	// The weapons menu's pick, held over the server's word until that word carries it.
	// A pick reaches the server as an Act and not as a command, so the replay below
	// cannot make it again; without this the gun I just chose would go back to the old
	// one for half a round trip and then change a second time. It is mine to say only
	// while the life is one I have not moved in, which is the same rule the server arms
	// me under (server/odin's Loadout).
	if mine.active && !mine.dead && mine.spawn_still {
		if mine.weapon.id != g.primary || mine.secondary.id != g.secondary {
			sim.soldier_arm(&g.content.ctx, mine, g.primary, g.secondary)
		}
	}

	for len(g.pending) > 0 && g.pending[0].seq <= ack do ordered_remove(&g.pending, 0)
	// the bullets of the commands it has not run: the replay makes them again
	for &b in g.world.bullets {
		if b.active && b.owner == g.me && b.spawn_cmd > ack do b = {}
	}

	g.world.tick = tick // my clock is the server's, plus the commands it has not run
	scratch: sim.Events // the effects of these ticks were shown when they first ran
	for cmd in g.pending {
		sim.events_clear(&scratch)
		sim.soldier_step(&g.content.ctx, &g.world, g.me, cmd, &scratch)
		for &b, i in g.world.bullets {
			if b.active && b.owner == g.me && b.spawn_cmd > ack do sim.bullet_fast_forward(&g.content.ctx, &g.world, i, 1, &scratch)
		}
		g.world.tick += 1
	}

	// where the server put me against where I had myself: felt, not seen
	if was_alive && mine.active && !mine.dead {
		off := drawn - mine.pos
		g.error = sim.vec2_length(off) > ERROR_SNAP ? {} : off
		g.error_now = sim.vec2_length(g.error)
		g.error_worst = max(g.error_worst, g.error_now)
		g.error_sum += f64(g.error_now)
		g.error_count += 1
	} else {
		g.error, g.error_now = {}, 0
		g.my_prev = mine.pos
	}
}

// Once per tick: the offset blending out, and my clock held so the server has about
// g.clock_target of my commands waiting (net_clock_target; queue.odin's CATCH_UP_KEEP). Too few and it starves (a tick where my soldier
// does not move there); too many and everything I press waits.
predict_tick :: proc(g: ^Game) {
	g.error *= ERROR_KEPT
	if sim.vec2_length(g.error) < 0.05 do g.error = {}

	g.depth += (f64(g.server_depth) - g.depth) * DEPTH_EASE
	adjust := (g.clock_target - g.depth) * CLOCK_GAIN
	g.time_scale = 1 + clamp(adjust, -CLOCK_MOST, CLOCK_MOST)
}
