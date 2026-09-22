#+private
package client

import "core:strings"
import rl "vendor:raylib"
import "../shared/net"
import "../shared/sim"

// Chat, from the original's: the line being typed (T to everyone, Y to my team, Enter
// sends it, Esc lets it go), the console of recent lines in the top left, and a line
// said over its speaker's head for as long as it takes to read it.
Chat :: struct {
	typing:  bool,
	team:    bool,
	reason:  bool, // what is being typed is the reason for a kick, not a line to say
	kick_slot: u8, // and who it is against
	line:    [net.MAX_CHAT]u8,
	len:     int,
	started: f64, // when typing began: the cursor blinks from then

	lines:  [CONSOLE_LINES]Console_Line, // oldest first
	count:  int,
	scroll: int, // ticks since the oldest last scrolled off, or a line came
	over:   [sim.MAX_PLAYERS]Over_Head,
}

Console_Line :: struct {
	text:  net.Text(128),
	color: rl.Color,
}

Over_Head :: struct {
	text:  net.Line,
	ticks: int, // left to show
}

CONSOLE_LINES    :: 6   // ui_console_length
CONSOLE_SCROLL   :: 150 // ticks the oldest line stays once nothing new has come
CONSOLE_LINE     :: 14.0
OVER_HEAD_LONGEST :: 60 // MORECHATTEXT: a longer line is only in the console
OVER_HEAD_MOST   :: 7 * sim.TICK_RATE + 40 // MAX_CHATDELAY

COLOR_CHAT      :: rl.Color{239, 254, 234, 238}
COLOR_TEAM_CHAT :: rl.Color{254, 218, 124, 238}
COLOR_SERVER    :: rl.Color{251, 218, 34, 249}
COLOR_OVER_HEAD :: rl.Color{253, 253, 249, 255}

// ---- typing ----

// This frame's keys for the chat. Returns whether they are the chat's: while a line is
// typed, nothing else hears the keyboard.
chat_input :: proc(c: ^Chat, g: ^Game) -> (keys_taken: bool) {
	if !c.typing {
		all, team := rl.IsKeyPressed(.T), rl.IsKeyPressed(.Y)
		if !all && !team do return false
		c.typing, c.team, c.len, c.started, c.reason = true, team, 0, rl.GetTime(), false
		for rl.GetCharPressed() != 0 {} // the T or Y that opened it
		rl.SetExitKey(.KEY_NULL)          // Esc lets go of the line, not of the game
		return true
	}
	longest := c.reason ? REASON_LONGEST : len(c.line)
	for ch := rl.GetCharPressed(); ch != 0; ch = rl.GetCharPressed() {
		if ch >= ' ' && ch <= '~' && c.len < longest {
			c.line[c.len] = u8(ch)
			c.len += 1
		}
	}
	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && c.len > 0 do c.len -= 1
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		if c.reason {
			// a reason of a few letters at least, as the original asks for
			if c.len > 3 do call_kick(g, c.kick_slot, string(c.line[:c.len]))
		} else if c.len > 0 {
			say(g, string(c.line[:c.len]), c.team)
		}
		chat_close(c)
	} else if rl.IsKeyPressed(.ESCAPE) {
		chat_close(c)
	}
	return true
}

chat_close :: proc(c: ^Chat) {
	c.typing, c.reason = false, false
}

// The kick window asks for a reason: what is typed now sends the vote (GameMenus.pas
// sets VoteKickReasonType).
chat_ask_reason :: proc(c: ^Chat, slot: u8) {
	c.typing, c.team, c.len, c.started = true, false, 0, rl.GetTime()
	c.reason, c.kick_slot = true, slot
}

// ---- hearing ----

// Once per tick: the lines heard into the console and over their speakers' heads, and
// the console scrolling off as the kill feed does.
chat_tick :: proc(c: ^Chat, g: ^Game) {
	for &m in g.heard do chat_hear(c, g, &m)
	for &o in c.over do if o.ticks > 0 do o.ticks -= 1
	if c.count == 0 do return
	c.scroll += 1
	if c.scroll >= CONSOLE_SCROLL do console_scroll(c)
}

@(private = "file")
chat_hear :: proc(c: ^Chat, g: ^Game, m: ^net.Chat) {
	said := net.text_string(&m.text)
	if int(m.slot) >= sim.MAX_PLAYERS {
		console_add(c, strings.concatenate({"*SERVER*: ", said}, context.temp_allocator), COLOR_SERVER)
		return
	}
	prefix := m.team ? "(TEAM) [" : "["
	line := strings.concatenate({prefix, name_of(g, m.slot), "] ", said}, context.temp_allocator)
	console_add(c, line, m.team ? COLOR_TEAM_CHAT : COLOR_CHAT)
	if len(said) >= OVER_HEAD_LONGEST do return
	// as long as it takes to read: by the words, or by the letters of a single word
	spaces := 0
	for ch in said do if ch == ' ' do spaces += 1
	o := &c.over[m.slot]
	o.text = m.text
	o.ticks = min(spaces > 0 ? spaces * 68 : len(said) * 25, OVER_HEAD_MOST)
}

@(private = "file")
console_add :: proc(c: ^Chat, line: string, color: rl.Color) {
	if c.count == CONSOLE_LINES do console_scroll(c)
	l := &c.lines[c.count]
	l.color = color
	net.text_set(&l.text, line)
	c.count += 1
	c.scroll = -CONSOLE_SCROLL // a new line holds the console a while longer
}

@(private = "file")
console_scroll :: proc(c: ^Chat) {
	copy(c.lines[:], c.lines[1:c.count])
	c.count -= 1
	c.scroll = 0
}

// ---- drawing ----

chat_draw :: proc(h: ^Hud, g: ^Game, sc: Screen, camera: ^Camera, alpha: f32) {
	c := &h.chat
	for &l, i in c.lines[:c.count] do text(h, sc, .Tiny, net.text_string(&l.text), 5, 1 + f32(i) * CONSOLE_LINE, l.color)

	// over the heads, where they are drawn
	for &o, i in c.over {
		s := &g.world.soldiers[i]
		if o.ticks <= 0 || !s.active || s.dead do continue
		head := world_to_screen(camera, drawn_pos(g, i, alpha) + {0, -45}) / sc.scale
		color := COLOR_OVER_HEAD
		color.a = u8(min(9 * o.ticks, 255))
		text(h, sc, .Small, net.text_string(&o.text), head.x, head.y, color, .Center)
	}

	if !c.typing do return
	prefix := c.team ? "Team Say: " : "Say: "
	line := string(c.line[:c.len])
	color := c.team ? COLOR_TEAM_CHAT : COLOR_CHAT
	text(h, sc, .Small, prefix, 5, 408, color)
	x := 5 + text_width(h, sc, .Small, prefix)
	text(h, sc, .Small, line, x, 408, color)
	blink := rl.GetTime() - c.started
	if blink - f64(int(blink)) <= 0.5 {
		cursor_x := x + text_width(h, sc, .Small, line) + 1
		rl.DrawRectangleV({cursor_x * sc.scale, 408 * sc.scale}, {max(sc.scale, 1), FONT_UNITS[.Small] * sc.scale}, {255, 230, 170, 255})
	}
}
