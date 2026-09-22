package client

// A dark theme for raygui.
//
// raygui styling is a flat table: sixteen control classes, each with twelve colours
// across four states plus a border width, padding and alignment. There is no cascade,
// but setting a property on DEFAULT propagates it to every control that has not been
// given its own - so this goes broad strokes first, exceptions after.

import "core:c"
import rl "vendor:raylib"

// 0xRRGGBBAA
BG :: 0x16181cff // the window behind everything
PANEL :: 0x1c1f24ff // control backgrounds
PANEL_HOVER :: 0x22262dff
SELECTED :: 0x263041ff
LINE :: 0x2a2e35ff // borders and separators
TEXT :: 0xe6e8eaff
TEXT_DIM :: 0x8b939eff
TEXT_OFF :: 0x59616bff // disabled
ACCENT :: 0x6ea8feff

@(private = "file")
style :: proc(control: rl.GuiControl, property: rl.GuiControlProperty, value: u32) {
	rl.GuiSetStyle(control, c.int(property), cast(c.int)value)
}

@(private = "file")
style_default :: proc(property: rl.GuiDefaultProperty, value: u32) {
	rl.GuiSetStyle(.DEFAULT, c.int(property), cast(c.int)value)
}

theme_apply :: proc() {
	style(.DEFAULT, .BORDER_COLOR_NORMAL, LINE)
	style(.DEFAULT, .BASE_COLOR_NORMAL, PANEL)
	style(.DEFAULT, .TEXT_COLOR_NORMAL, TEXT)

	style(.DEFAULT, .BORDER_COLOR_FOCUSED, ACCENT)
	style(.DEFAULT, .BASE_COLOR_FOCUSED, PANEL_HOVER)
	style(.DEFAULT, .TEXT_COLOR_FOCUSED, TEXT)

	style(.DEFAULT, .BORDER_COLOR_PRESSED, ACCENT)
	style(.DEFAULT, .BASE_COLOR_PRESSED, SELECTED)
	style(.DEFAULT, .TEXT_COLOR_PRESSED, ACCENT)

	style(.DEFAULT, .BORDER_COLOR_DISABLED, LINE)
	style(.DEFAULT, .BASE_COLOR_DISABLED, BG)
	style(.DEFAULT, .TEXT_COLOR_DISABLED, TEXT_OFF)

	style(.DEFAULT, .BORDER_WIDTH, 1)
	style(.DEFAULT, .TEXT_PADDING, 6)

	style_default(.TEXT_SIZE, 14)
	style_default(.TEXT_SPACING, 1)
	style_default(.LINE_COLOR, LINE)
	style_default(.BACKGROUND_COLOR, BG)
	style_default(.TEXT_LINE_SPACING, 18)

	// The map list is where the eye spends most of its time.
	style(.LISTVIEW, .BASE_COLOR_FOCUSED, PANEL_HOVER)
	style(.LISTVIEW, .TEXT_COLOR_FOCUSED, TEXT)
	style(.LISTVIEW, .BASE_COLOR_PRESSED, SELECTED)
	style(.LISTVIEW, .TEXT_COLOR_PRESSED, ACCENT)
	style(.LISTVIEW, .BORDER_COLOR_PRESSED, LINE)
	style(.LISTVIEW, .TEXT_PADDING, 8)

	// Labels carry the inspector's values, so they should not look clickable.
	style(.LABEL, .TEXT_COLOR_FOCUSED, TEXT)
	style(.LABEL, .TEXT_COLOR_PRESSED, TEXT)
	style(.LABEL, .TEXT_PADDING, 0)

	style(.BUTTON, .BASE_COLOR_NORMAL, 0x262b33ff)
	style(.BUTTON, .BASE_COLOR_FOCUSED, 0x2f3540ff)
	style(.BUTTON, .TEXT_COLOR_FOCUSED, TEXT)

	style(.STATUSBAR, .BASE_COLOR_NORMAL, PANEL)
	style(.STATUSBAR, .TEXT_COLOR_NORMAL, TEXT_DIM)
	style(.STATUSBAR, .TEXT_PADDING, 8)

	style(.SCROLLBAR, .BASE_COLOR_NORMAL, BG)
	style(.SCROLLBAR, .BASE_COLOR_PRESSED, ACCENT)
}

// A theme colour as raylib wants it, for the parts the editor draws itself.
theme_color :: proc(packed: u32) -> rl.Color {
	return {u8(packed >> 24), u8(packed >> 16), u8(packed >> 8), u8(packed)}
}
