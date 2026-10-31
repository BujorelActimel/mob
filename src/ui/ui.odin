// Small immediate-mode UI drawn with raylib primitives and the bundled Inter font.
package ui

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

Id :: u64
Rect :: rl.Rectangle
Color :: rl.Color
Vec2 :: [2]f32

Font_Kind :: enum u8 {
	Regular,
	Small,
	Semibold,
	Title,
	Big,
}

// Pixel Operator Bold is drawn on a 16-pixel em: at 16 pt every font pixel
// is one point (two device pixels on Retina), so text stays perfectly crisp.
PIXEL_FONT_SIZE :: 16

FONT_SIZES := [Font_Kind]f32 {
	.Regular  = PIXEL_FONT_SIZE,
	.Small    = PIXEL_FONT_SIZE,
	.Semibold = PIXEL_FONT_SIZE,
	.Title    = PIXEL_FONT_SIZE,
	.Big      = PIXEL_FONT_SIZE * 2,
}

Theme :: struct {
	bg_panel:     Color,
	bg_panel_alt: Color,
	border:       Color,
	text:         Color,
	text_dim:     Color,
	text_faint:   Color,
	accent:       Color,
	accent_soft:  Color,
	field:        Color,
	field_hover:  Color,
	button:       Color,
	button_hover: Color,
	button_down:  Color,
	error:        Color,
	expr:         Color,
	good:         Color,
	shadow:       Color,
}

THEME := Theme {
	bg_panel     = {30, 29, 36, 245},
	bg_panel_alt = {38, 37, 46, 255},
	border       = {68, 64, 82, 255},
	text         = {238, 234, 226, 255},
	text_dim     = {170, 164, 176, 255},
	text_faint   = {116, 111, 128, 255},
	accent       = {255, 150, 48, 255},
	accent_soft  = {255, 150, 48, 52},
	field        = {19, 18, 24, 255},
	field_hover  = {25, 24, 31, 255},
	button       = {48, 46, 58, 255},
	button_hover = {60, 57, 72, 255},
	button_down  = {72, 68, 86, 255},
	error        = {240, 92, 84, 255},
	expr         = {120, 190, 255, 255},
	good         = {120, 210, 140, 255},
	shadow       = {0, 0, 0, 70},
}

ROW_H :: 28
GAP :: 6
PAD :: 12
RADIUS :: 7

Layout :: struct {
	rect: Rect, // content area
	y:    f32,
	x:    f32,
	w:    f32,
}

Edit :: struct {
	id:      Id,
	buf:     [dynamic]u8,
	cursor:  int,
	anchor:  int,
	blink:   f32,
	numeric: bool,
}

Popup :: struct {
	id:      Id,
	anchor:  Rect,
	options: []string,
	rect:    Rect,
	hover:   int,
}

Result :: struct {
	committed: bool, // text field: Enter / Tab / click-away
	cancelled: bool,
	text:      string, // temp-allocated committed text
	scrubbing: bool, // value is being dragged
	scrub_start: bool,
	value:     f64, // scrubbed value
}

UI :: struct {
	fonts:          [Font_Kind]rl.Font,
	dpi:            f32,
	dt:             f32,
	time:           f64,
	mouse:          Vec2,
	mouse_delta:    Vec2,
	pressed:        bool,
	released:       bool,
	down:           bool,
	double_click:   bool,
	last_click_t:   f64,
	last_click_pos: Vec2,
	wheel:          f32,
	wheel_used:     bool,
	hot:            Id,
	active:         Id,
	focus:          Id,
	focus_seen:     bool,
	tab_from:       Id, // focus moves to the field drawn after this one
	tab_pending:    bool,
	last_field:     Id,
	edit:           Edit,
	popup:          Popup,
	popup_choice:   int,
	popup_choice_id: Id,
	blockers:       [dynamic]Rect,
	prev_blockers:  [dynamic]Rect,
	input_enabled:  bool,
	lay:            Layout,
	scroll:         map[Id]f32,
	content_h:      map[Id]f32,
	panel_id:       Id,
	anim:           map[Id]f32,
	animating:      bool,
	hover_id:       Id,
	hover_time:     f32,
	tooltip:        string,
	tooltip_rect:   Rect,
	cursor:         rl.MouseCursor,
	scrub_id:       Id,
	scrub_origin:   f64,
	scrub_accum:    f32,
	chars:          [dynamic]rune,
	in_panel:       bool, // visibility clipping only applies inside a scrolling panel
	// simulated mouse for automated tests
	sim:            bool,
	sim_mouse:      Vec2,
	sim_down:       bool,
	sim_was_down:   bool,
	sim_shift:      bool,
	sim_cmd:        bool,
	sim_wheel:      Vec2,
	wheel_v:        Vec2, // scroll this frame (x, y)
	rects:          map[Id]Rect, // last rect of each button, for tests
	advance:        [Font_Kind][128]f32,
}

// ---------------------------------------------------------------------------
// Setup

EXTRA_GLYPHS := []rune{'×', '—', '–', '…', '°', '·', '•', '±', '€', 'Ø', 'ø', 'ä', 'ö', 'ü', 'é'}

// Rasterizes at the exact pixel-grid size and hardens the alpha so glyphs
// are solid pixels without an anti-aliased fringe.
@(private)
load_font :: proc(path: cstring, size_pt, dpi: f32) -> rl.Font {
	cps := make([dynamic]rune, context.temp_allocator)
	for c in 32 ..= 126 {append(&cps, rune(c))}
	append(&cps, ..EXTRA_GLYPHS)
	size_px := i32(math.round(size_pt * dpi))
	data_size: i32
	data := rl.LoadFileData(path, &data_size)
	if data == nil {return rl.GetFontDefault()}
	defer rl.UnloadFileData(data)
	f: rl.Font
	f.baseSize = size_px
	f.glyphCount = i32(len(cps))
	f.glyphPadding = 4
	f.glyphs = rl.LoadFontData(data, data_size, size_px, raw_data(cps), i32(len(cps)), .DEFAULT, &f.glyphCount)
	atlas := rl.GenImageFontAtlas(f.glyphs, &f.recs, f.glyphCount, size_px, f.glyphPadding, 0)
	if atlas.format == .UNCOMPRESSED_GRAY_ALPHA {
		px := ([^]u8)(atlas.data)
		for i in 0 ..< int(atlas.width * atlas.height) {
			a := &px[i * 2 + 1]
			a^ = a^ > 110 ? 255 : 0
		}
	}
	f.texture = rl.LoadTextureFromImage(atlas)
	rl.UnloadImage(atlas)
	rl.SetTextureFilter(f.texture, .POINT)
	return f
}

init :: proc(ui: ^UI, asset_dir: string) {
	scale := rl.GetWindowScaleDPI()
	ui.dpi = max(math.round(scale.x), 1)
	path := strings.clone_to_cstring(strings.concatenate({asset_dir, "/fonts/PixelOperator-Bold.ttf"}, context.temp_allocator), context.temp_allocator)
	// one face, one size; emphasis comes from colour
	ui.fonts[.Regular] = load_font(path, FONT_SIZES[.Regular], ui.dpi)
	ui.fonts[.Small] = ui.fonts[.Regular]
	ui.fonts[.Semibold] = ui.fonts[.Regular]
	ui.fonts[.Title] = ui.fonts[.Regular]
	ui.fonts[.Big] = load_font(path, FONT_SIZES[.Big], ui.dpi)
	build_advances(ui)
	ui.input_enabled = true
	ui.popup_choice = -1
}

shutdown :: proc(ui: ^UI) {
	rl.UnloadFont(ui.fonts[.Regular])
	rl.UnloadFont(ui.fonts[.Big])
	delete(ui.blockers)
	delete(ui.prev_blockers)
	delete(ui.scroll)
	delete(ui.content_h)
	delete(ui.anim)
	delete(ui.edit.buf)
	delete(ui.chars)
	delete(ui.rects)
}

id :: proc(s: string, seed: Id = 0) -> Id {
	return hash.fnv64a(transmute([]u8)s, seed == 0 ? 0xcbf29ce484222325 : seed)
}

id_n :: proc(base: Id, n: int) -> Id {
	x := u64(n)
	return hash.fnv64a(([^]u8)(&x)[:8], base)
}

// ---------------------------------------------------------------------------
// Frame

begin_frame :: proc(ui: ^UI) {
	ui.dt = rl.GetFrameTime()
	ui.time = rl.GetTime()
	ui.mouse = rl.GetMousePosition()
	ui.mouse_delta = rl.GetMouseDelta()
	ui.pressed = rl.IsMouseButtonPressed(.LEFT)
	ui.released = rl.IsMouseButtonReleased(.LEFT)
	ui.down = rl.IsMouseButtonDown(.LEFT)
	if ui.sim {
		ui.mouse_delta = ui.sim_mouse - ui.mouse
		ui.mouse = ui.sim_mouse
		ui.pressed = ui.sim_down && !ui.sim_was_down
		ui.released = !ui.sim_down && ui.sim_was_down
		ui.down = ui.sim_down
		ui.sim_was_down = ui.sim_down
	}
	sim_shift_held = ui.sim && ui.sim_shift
	sim_cmd_held = ui.sim && ui.sim_cmd
	ui.double_click = false
	if ui.pressed {
		if ui.time - ui.last_click_t < 0.35 && abs(ui.mouse.x - ui.last_click_pos.x) < 4 && abs(ui.mouse.y - ui.last_click_pos.y) < 4 {
			ui.double_click = true
			ui.last_click_t = 0
		} else {
			ui.last_click_t = ui.time
		}
		ui.last_click_pos = ui.mouse
	}
	ui.wheel_v = rl.GetMouseWheelMoveV()
	if ui.sim {
		ui.wheel_v = ui.sim_wheel
		ui.sim_wheel = {}
	}
	ui.wheel = ui.wheel_v.y
	ui.wheel_used = false
	ui.prev_blockers, ui.blockers = ui.blockers, ui.prev_blockers
	clear(&ui.blockers)
	ui.animating = false
	ui.tooltip = ""
	ui.cursor = .DEFAULT
	ui.focus_seen = false
	ui.last_field = 0
	ui.input_enabled = true
	clear(&ui.chars)
	for {
		c := rl.GetCharPressed()
		if c == 0 {break}
		append(&ui.chars, c)
	}
	if !ui.down && ui.active != 0 && !ui.released {ui.active = 0}
}

end_frame :: proc(ui: ^UI) {
	draw_popup(ui)
	if ui.focus != 0 && !ui.focus_seen {ui.focus = 0}
	if ui.tab_pending && ui.last_field != 0 && ui.focus == 0 {
		// tab from the last field wraps nowhere; just drop it
		ui.tab_pending = false
	}
	// tooltip
	if ui.tooltip != "" {
		if ui.hover_time > 0.45 {
			draw_tooltip(ui)
		} else {
			ui.animating = true
		}
	}
	if ui.released {
		ui.active = 0
		ui.scrub_id = 0
	}
	if ui.edit.id != 0 && ui.focus != 0 {
		ui.edit.blink += ui.dt
	}
	rl.SetMouseCursor(ui.cursor)
}

// True when the mouse is over UI drawn last frame, or the UI owns the mouse.
wants_mouse :: proc(ui: ^UI) -> bool {
	if ui.active != 0 || ui.scrub_id != 0 {return true}
	if ui.popup.id != 0 {return true}
	for r in ui.prev_blockers {
		if rl.CheckCollisionPointRec(ui.mouse, r) {return true}
	}
	return false
}

wants_keyboard :: proc(ui: ^UI) -> bool {return ui.focus != 0}

block :: proc(ui: ^UI, r: Rect) {append(&ui.blockers, r)}

@(private)
popup_blocks :: proc(ui: ^UI) -> bool {
	return ui.popup.id != 0 && rl.CheckCollisionPointRec(ui.mouse, ui.popup.rect)
}

hovered :: proc(ui: ^UI, r: Rect) -> bool {
	if !ui.input_enabled || popup_blocks(ui) {return false}
	return rl.CheckCollisionPointRec(ui.mouse, r)
}

anim_to :: proc(ui: ^UI, aid: Id, target: f32, speed: f32 = 16) -> f32 {
	v, ok := ui.anim[aid]
	if !ok {v = target}
	k := 1 - math.exp(-ui.dt * speed)
	v += (target - v) * k
	if abs(target - v) < 0.002 {
		v = target
	} else {
		ui.animating = true
	}
	ui.anim[aid] = v
	return v
}

set_tooltip :: proc(ui: ^UI, wid: Id, r: Rect, text: string) {
	if ui.hover_id != wid {
		ui.hover_id = wid
		ui.hover_time = 0
	}
	ui.hover_time += ui.dt
	ui.tooltip = text
	ui.tooltip_rect = r
}

// ---------------------------------------------------------------------------
// Drawing helpers

lerp_color :: proc(a, b: Color, t: f32) -> Color {
	t := clamp(t, 0, 1)
	return {
		u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
		u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
		u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
		u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
	}
}

fade :: proc(c: Color, a: f32) -> Color {return {c.r, c.g, c.b, u8(f32(c.a) * clamp(a, 0, 1))}}

// Pixel-style box: corners are notched by one or two points instead of rounded.
rounded :: proc(r: Rect, radius: f32, c: Color) {
	if r.width <= 0 || r.height <= 0 {return}
	x := math.round(r.x)
	y := math.round(r.y)
	w := math.round(r.width)
	h := math.round(r.height)
	k: f32 = radius >= 6 ? 2 : (radius > 0 ? 1 : 0)
	k = min(k, math.floor(min(w, h) * 0.5))
	if k == 0 {
		rl.DrawRectangleRec({x, y, w, h}, c)
		return
	}
	rl.DrawRectangleRec({x + k, y, w - 2 * k, h}, c)
	rl.DrawRectangleRec({x, y + k, k, h - 2 * k}, c)
	rl.DrawRectangleRec({x + w - k, y + k, k, h - 2 * k}, c)
	if k == 2 {
		rl.DrawRectangleRec({x + 1, y + 1, 1, 1}, c)
		rl.DrawRectangleRec({x + w - 2, y + 1, 1, 1}, c)
		rl.DrawRectangleRec({x + 1, y + h - 2, 1, 1}, c)
		rl.DrawRectangleRec({x + w - 2, y + h - 2, 1, 1}, c)
	}
}

// One-point pixel outline matching rounded().
rounded_lines :: proc(r: Rect, radius: f32, thick: f32, c: Color) {
	if r.width <= 0 || r.height <= 0 {return}
	x := math.round(r.x)
	y := math.round(r.y)
	w := math.round(r.width)
	h := math.round(r.height)
	t := max(math.round(thick), 1)
	k: f32 = radius >= 6 ? 2 : (radius > 0 ? 1 : 0)
	rl.DrawRectangleRec({x + k, y, w - 2 * k, t}, c)
	rl.DrawRectangleRec({x + k, y + h - t, w - 2 * k, t}, c)
	rl.DrawRectangleRec({x, y + k, t, h - 2 * k}, c)
	rl.DrawRectangleRec({x + w - t, y + k, t, h - 2 * k}, c)
	if k == 2 {
		rl.DrawRectangleRec({x + 1, y + 1, 1, 1}, c)
		rl.DrawRectangleRec({x + w - 2, y + 1, 1, 1}, c)
		rl.DrawRectangleRec({x + 1, y + h - 2, 1, 1}, c)
		rl.DrawRectangleRec({x + w - 2, y + h - 2, 1, 1}, c)
	}
}

// Card with a hard pixel drop shadow and a one-point border.
shadowed_card :: proc(r: Rect, radius: f32, bg: Color) {
	rounded({r.x + 3, r.y + 4, r.width, r.height}, radius, {0, 0, 0, u8(min(int(bg.a), 70))})
	rounded(r, radius, bg)
	rounded_lines(r, radius, 1, THEME.border)
}

inset :: proc(r: Rect, d: f32) -> Rect {return {r.x + d, r.y + d, r.width - 2 * d, r.height - 2 * d}}

font_size :: proc(k: Font_Kind) -> f32 {return FONT_SIZES[k]}

@(private)
glyph_advance :: proc(f: rl.Font, r: rune) -> f32 {
	gi := rl.GetGlyphIndex(f, r)
	adv := f.glyphs[gi].advanceX
	return adv != 0 ? f32(adv) : f.recs[gi].width
}

// ASCII advances in points, measured once per font so text layout avoids
// raylib's per-character glyph search.
@(private)
build_advances :: proc(ui: ^UI) {
	for k in Font_Kind {
		f := ui.fonts[k]
		scale := FONT_SIZES[k] / f32(f.baseSize)
		for c in 0 ..< 128 {ui.advance[k][c] = glyph_advance(f, rune(c)) * scale}
	}
}

@(private)
char_width :: #force_inline proc(ui: ^UI, r: rune, k: Font_Kind) -> f32 {
	if r < 128 {return ui.advance[k][r]}
	f := ui.fonts[k]
	return glyph_advance(f, r) * FONT_SIZES[k] / f32(f.baseSize)
}

text_width :: proc(ui: ^UI, s: string, k: Font_Kind = .Regular) -> f32 {
	w: f32
	for r in s {w += char_width(ui, r, k)}
	return w
}

draw_text :: proc(ui: ^UI, s: string, x, y: f32, k: Font_Kind = .Regular, c: Color = THEME.text) {
	if len(s) == 0 {return}
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	rl.DrawTextEx(ui.fonts[k], cs, {math.round(x), math.round(y)}, FONT_SIZES[k], 0, c)
}

Align :: enum u8 {
	Left,
	Center,
	Right,
}

// Draws text vertically centered in r, clipped with an ellipsis.
text_in :: proc(ui: ^UI, s: string, r: Rect, k: Font_Kind = .Regular, c: Color = THEME.text, align: Align = .Left) {
	s := s
	w := text_width(ui, s, k)
	if w > r.width && len(s) > 1 {
		// keep the longest prefix that fits together with the ellipsis
		budget := r.width - char_width(ui, '…', k)
		used: f32
		cut := 0
		for ch, i in s {
			cw := char_width(ui, ch, k)
			if used + cw > budget {break}
			used += cw
			cut = i + utf8.rune_size(ch)
		}
		s = strings.concatenate({s[:max(cut, 1)], "…"}, context.temp_allocator)
		w = text_width(ui, s, k)
	}
	size := FONT_SIZES[k]
	y := r.y + (r.height - size * 1.2) * 0.5 + 0.5
	x := r.x
	switch align {
	case .Left:
	case .Center: x = r.x + (r.width - w) * 0.5
	case .Right:  x = r.x + r.width - w
	}
	draw_text(ui, s, x, y, k, c)
}

draw_tooltip :: proc(ui: ^UI) {
	lines := strings.split_lines(ui.tooltip, context.temp_allocator)
	w: f32 = 0
	for l in lines {w = max(w, text_width(ui, l, .Small))}
	lh := FONT_SIZES[.Small] * 1.35
	h := f32(len(lines)) * lh + 10
	x := ui.tooltip_rect.x
	y := ui.tooltip_rect.y + ui.tooltip_rect.height + 6
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	if x + w + 16 > sw {x = sw - w - 20}
	if y + h > sh {y = ui.tooltip_rect.y - h - 6}
	r := Rect{x, y, w + 16, h}
	shadowed_card(r, 5, {14, 15, 17, 245})
	for l, i in lines {
		draw_text(ui, l, x + 8, y + 5 + f32(i) * lh, .Small, THEME.text)
	}
}

// ---------------------------------------------------------------------------
// Panels and layout

panel_begin :: proc(ui: ^UI, pid: Id, r: Rect, title: string = "", bg: Color = THEME.bg_panel) {
	shadowed_card(r, 10, bg)
	block(ui, r)
	ui.panel_id = pid
	content := inset(r, PAD)
	if title != "" {
		text_in(ui, title, {content.x, content.y, content.width, 18}, .Title, THEME.text)
		content.y += 26
		content.height -= 26
	}
	ch := ui.content_h[pid]
	sc := ui.scroll[pid]
	max_scroll := max(0, ch - content.height)
	if ui.input_enabled && rl.CheckCollisionPointRec(ui.mouse, r) && ui.wheel != 0 && !ui.wheel_used && max_scroll > 0 {
		sc -= ui.wheel * 28
		ui.wheel_used = true
	}
	sc = clamp(sc, 0, max_scroll)
	ui.scroll[pid] = sc
	ui.lay = {
		rect = content,
		x    = content.x,
		y    = content.y - sc,
		w    = content.width - (max_scroll > 0 ? 6 : 0),
	}
	rl.BeginScissorMode(i32(content.x - 4), i32(content.y - 2), i32(content.width + 8), i32(content.height + 4))
	ui.in_panel = true
}

panel_end :: proc(ui: ^UI) {
	rl.EndScissorMode()
	ui.in_panel = false
	l := ui.lay
	sc := ui.scroll[ui.panel_id]
	used := l.y + sc - l.rect.y
	ui.content_h[ui.panel_id] = used
	if used > l.rect.height {
		// scrollbar
		frac := l.rect.height / used
		bar_h := max(24, l.rect.height * frac)
		t := sc / (used - l.rect.height)
		y := l.rect.y + (l.rect.height - bar_h) * t
		rounded({l.rect.x + l.rect.width - 3, y, 3, bar_h}, 1.5, {255, 255, 255, 40})
	}
}

next_row :: proc(ui: ^UI, h: f32 = ROW_H) -> Rect {
	r := Rect{ui.lay.x, ui.lay.y, ui.lay.w - (ui.lay.x - ui.lay.rect.x), h}
	ui.lay.y += h + GAP
	return r
}

space :: proc(ui: ^UI, h: f32 = 6) {ui.lay.y += h}

indent :: proc(ui: ^UI, d: f32) {ui.lay.x += d}

// Splits a row into columns with the given relative widths.
columns :: proc(r: Rect, weights: []f32, gap: f32 = GAP, allocator := context.temp_allocator) -> []Rect {
	total: f32
	for w in weights {total += w}
	out := make([]Rect, len(weights), allocator)
	avail := r.width - gap * f32(len(weights) - 1)
	x := r.x
	for w, i in weights {
		cw := avail * w / total
		out[i] = {x, r.y, cw, r.height}
		x += cw + gap
	}
	return out
}

is_visible :: proc(ui: ^UI, r: Rect) -> bool {
	if !ui.in_panel {return true}
	return r.y + r.height >= ui.lay.rect.y - 2 && r.y <= ui.lay.rect.y + ui.lay.rect.height + 2
}

// ---------------------------------------------------------------------------
// Widgets

label :: proc(ui: ^UI, s: string, k: Font_Kind = .Regular, c: Color = THEME.text, h: f32 = 20) {
	r := next_row(ui, h)
	text_in(ui, s, r, k, c)
}

heading :: proc(ui: ^UI, s: string) {
	space(ui, 6)
	r := next_row(ui, 16)
	text_in(ui, strings.to_upper(s, context.temp_allocator), r, .Small, THEME.text_faint)
}

separator :: proc(ui: ^UI) {
	r := next_row(ui, 1)
	rl.DrawRectangleRec({r.x, r.y, r.width, 1}, {255, 255, 255, 14})
}

Button_Style :: enum u8 {
	Normal,
	Primary,
	Ghost,
	Danger,
}

button_rect :: proc(ui: ^UI, bid: Id, r: Rect, text: string, style := Button_Style.Normal, on := false, tip := "", k := Font_Kind.Semibold) -> bool {
	ui.rects[bid] = r
	hov := hovered(ui, r) && is_visible(ui, r)
	if hov && ui.pressed {ui.active = bid}
	down := ui.active == bid && ui.down
	clicked := hov && ui.released && ui.active == bid
	t := anim_to(ui, bid, hov ? 1 : 0)
	base, hi, fg: Color
	switch style {
	case .Normal:
		base, hi, fg = THEME.button, THEME.button_hover, THEME.text
	case .Primary:
		base, hi, fg = THEME.accent, {255, 160, 72, 255}, {30, 20, 10, 255}
	case .Ghost:
		base, hi, fg = {0, 0, 0, 0}, {255, 255, 255, 18}, THEME.text_dim
		if hov {fg = THEME.text}
	case .Danger:
		base, hi, fg = THEME.button, {120, 46, 42, 255}, THEME.error
	}
	if on {
		base = THEME.accent_soft
		hi = {245, 142, 46, 72}
		fg = THEME.accent
	}
	c := lerp_color(base, hi, t)
	if down {c = lerp_color(c, THEME.button_down, 0.5)}
	rounded(r, 6, c)
	if text != "" {text_in(ui, text, r, k, fg, .Center)}
	if hov && tip != "" {set_tooltip(ui, bid, r, tip)}
	return clicked
}

button :: proc(ui: ^UI, text: string, style := Button_Style.Normal, tip := "") -> bool {
	r := next_row(ui, 28)
	return button_rect(ui, id(text, ui.panel_id), r, text, style, false, tip)
}

checkbox :: proc(ui: ^UI, text: string, v: ^bool) -> bool {
	r := next_row(ui, 22)
	cid := id(text, ui.panel_id + 7)
	hov := hovered(ui, r) && is_visible(ui, r)
	if hov && ui.pressed {ui.active = cid}
	changed := false
	if hov && ui.released && ui.active == cid {
		v^ = !v^
		changed = true
	}
	box := Rect{r.x, r.y + 3, 16, 16}
	rounded(box, 2, v^ ? THEME.accent : (hov ? THEME.button_hover : THEME.button))
	if v^ {icon(.Check, {box.x + box.width * 0.5, box.y + box.height * 0.5}, {30, 20, 10, 255})}
	text_in(ui, text, {r.x + 22, r.y, r.width - 22, r.height}, .Regular, THEME.text)
	return changed
}

// Segmented control; returns the (possibly new) index.
segmented :: proc(ui: ^UI, sid: Id, r: Rect, options: []string, current: int) -> int {
	rounded(r, 6, THEME.field)
	cols := columns(inset(r, 2), make([]f32, len(options), context.temp_allocator), 2)
	out := current
	for o, i in options {
		c := cols[i]
		c.width = (r.width - 4 - 2 * f32(len(options) - 1)) / f32(len(options))
		c.x = r.x + 2 + f32(i) * (c.width + 2)
		bid := id_n(sid, i)
		ui.rects[bid] = c
		hov := hovered(ui, c) && is_visible(ui, c)
		if hov && ui.pressed {ui.active = bid}
		if hov && ui.released && ui.active == bid {out = i}
		if i == current {
			rounded(c, 5, THEME.button_hover)
		} else if hov {
			rounded(c, 5, {255, 255, 255, 10})
		}
		text_in(ui, o, c, .Small, i == current ? THEME.text : THEME.text_dim, .Center)
	}
	return out
}

// ---------------------------------------------------------------------------
// Text editing

@(private)
edit_begin :: proc(ui: ^UI, fid: Id, text: string) {
	ui.focus = fid
	ui.edit.id = fid
	clear(&ui.edit.buf)
	append(&ui.edit.buf, text)
	ui.edit.anchor = 0
	ui.edit.cursor = len(ui.edit.buf)
	ui.edit.blink = 0
}

@(private)
edit_delete_selection :: proc(e: ^Edit) -> bool {
	if e.anchor == e.cursor {return false}
	a := min(e.anchor, e.cursor)
	b := max(e.anchor, e.cursor)
	remove_range(&e.buf, a, b)
	e.cursor = a
	e.anchor = a
	return true
}

@(private)
key :: proc(k: rl.KeyboardKey) -> bool {return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)}

sim_cmd_held: bool

cmd_down :: proc() -> bool {
	return sim_cmd_held || rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) || rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

sim_shift_held: bool

shift_down :: proc() -> bool {return sim_shift_held || rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)}

alt_down :: proc() -> bool {return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)}

@(private)
prev_rune_start :: proc(b: []u8, i: int) -> int {
	j := i - 1
	for j > 0 && (b[j] & 0xC0) == 0x80 {j -= 1}
	return max(j, 0)
}

@(private)
next_rune_end :: proc(b: []u8, i: int) -> int {
	j := i + 1
	for j < len(b) && (b[j] & 0xC0) == 0x80 {j += 1}
	return min(j, len(b))
}

// Handles keyboard input for the focused field. Returns commit/cancel flags.
@(private)
edit_keys :: proc(ui: ^UI) -> (commit, cancel, tab: bool) {
	e := &ui.edit
	moved := false
	for c in ui.chars {
		if cmd_down() {continue}
		edit_delete_selection(e)
		bytes, n := utf8.encode_rune(c)
		inject_at(&e.buf, e.cursor, ..bytes[:n])
		e.cursor += n
		e.anchor = e.cursor
		moved = true
	}
	shift := shift_down()
	if key(.BACKSPACE) {
		if !edit_delete_selection(e) && e.cursor > 0 {
			p := cmd_down() ? 0 : prev_rune_start(e.buf[:], e.cursor)
			remove_range(&e.buf, p, e.cursor)
			e.cursor = p
			e.anchor = p
		}
		moved = true
	}
	if key(.DELETE) {
		if !edit_delete_selection(e) && e.cursor < len(e.buf) {
			n := next_rune_end(e.buf[:], e.cursor)
			remove_range(&e.buf, e.cursor, n)
		}
		moved = true
	}
	if key(.LEFT) {
		if !shift && e.anchor != e.cursor {
			e.cursor = min(e.anchor, e.cursor)
		} else {
			e.cursor = cmd_down() ? 0 : prev_rune_start(e.buf[:], e.cursor)
		}
		if !shift {e.anchor = e.cursor}
		moved = true
	}
	if key(.RIGHT) {
		if !shift && e.anchor != e.cursor {
			e.cursor = max(e.anchor, e.cursor)
		} else {
			e.cursor = cmd_down() ? len(e.buf) : next_rune_end(e.buf[:], e.cursor)
		}
		if !shift {e.anchor = e.cursor}
		moved = true
	}
	if key(.HOME) || key(.UP) {
		e.cursor = 0
		if !shift {e.anchor = 0}
		moved = true
	}
	if key(.END) || key(.DOWN) {
		e.cursor = len(e.buf)
		if !shift {e.anchor = e.cursor}
		moved = true
	}
	if cmd_down() {
		if rl.IsKeyPressed(.A) {
			e.anchor = 0
			e.cursor = len(e.buf)
		}
		if rl.IsKeyPressed(.C) || rl.IsKeyPressed(.X) {
			a, b := min(e.anchor, e.cursor), max(e.anchor, e.cursor)
			if a == b {a, b = 0, len(e.buf)}
			rl.SetClipboardText(strings.clone_to_cstring(string(e.buf[a:b]), context.temp_allocator))
			if rl.IsKeyPressed(.X) {edit_delete_selection(e)}
		}
		if rl.IsKeyPressed(.V) {
			clip := string(rl.GetClipboardText())
			clip, _ = strings.replace_all(clip, "\n", " ", context.temp_allocator)
			edit_delete_selection(e)
			inject_at(&e.buf, e.cursor, clip)
			e.cursor += len(clip)
			e.anchor = e.cursor
		}
	}
	if moved {e.blink = 0}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {commit = true}
	if rl.IsKeyPressed(.TAB) {
		commit = true
		tab = true
	}
	if rl.IsKeyPressed(.ESCAPE) {cancel = true}
	return
}

Field_Opts :: struct {
	color:       Color, // text color when not editing
	suffix:      string, // dim text right-aligned (e.g. "= 764")
	error:       bool,
	placeholder: string,
	label:       string, // small label inside the left edge
	scrub:       bool, // label drag changes the value
	value:       f64,
	scrub_step:  f64,
	align_right: bool,
}

// A single-line text input. Emits `committed` with the new text when editing ends.
text_field :: proc(ui: ^UI, fid: Id, r: Rect, text: string, opts: Field_Opts = {}) -> Result {
	res: Result
	vis := is_visible(ui, r)
	hov := hovered(ui, r) && vis
	focused := ui.focus == fid
	label_w: f32 = 0
	if opts.label != "" {label_w = max(text_width(ui, opts.label, .Small) + 12, 20)}
	label_r := Rect{r.x, r.y, label_w, r.height}

	// tab focus: this is the field after the one that tabbed
	if ui.tab_pending && ui.last_field == ui.tab_from && ui.tab_from != 0 && vis {
		ui.tab_pending = false
		edit_begin(ui, fid, text)
		focused = true
	}
	ui.last_field = fid

	// scrubbing on the label
	if opts.scrub && opts.label != "" && !focused {
		lh := hovered(ui, label_r) && vis
		if lh {ui.cursor = .RESIZE_EW}
		if lh && ui.pressed {
			ui.active = fid
			ui.scrub_id = fid
			ui.scrub_origin = opts.value
			ui.scrub_accum = 0
			res.scrub_start = true
		}
		if ui.scrub_id == fid && ui.down {
			ui.cursor = .RESIZE_EW
			step := opts.scrub_step != 0 ? opts.scrub_step : 1
			if shift_down() {step *= 10}
			if alt_down() {step *= 0.1}
			ui.scrub_accum += ui.mouse_delta.x
			if ui.mouse_delta.x != 0 || res.scrub_start {
				res.scrubbing = true
				res.value = ui.scrub_origin + f64(math.round(ui.scrub_accum)) * step
				res.value = math.round(res.value / step) * step
			}
		}
	}

	if !focused && hov && ui.pressed && !(opts.scrub && rl.CheckCollisionPointRec(ui.mouse, label_r)) {
		edit_begin(ui, fid, text)
		focused = true
		ui.active = fid
	}
	if focused {
		ui.focus_seen = true
		if hov {ui.cursor = .IBEAM}
		commit, cancel, tab := edit_keys(ui)
		if ui.pressed && !hov && ui.active != fid {commit = true}
		if commit || cancel {
			if commit {
				res.committed = true
				res.text = strings.clone(string(ui.edit.buf[:]), context.temp_allocator)
			}
			res.cancelled = cancel
			ui.focus = 0
			ui.edit.id = 0
			focused = false
			if tab {
				ui.tab_from = fid
				ui.tab_pending = true
			}
		}
	} else if hov {
		ui.cursor = .IBEAM
		if opts.scrub && rl.CheckCollisionPointRec(ui.mouse, label_r) {ui.cursor = .RESIZE_EW}
	}
	if !vis {return res}

	// draw
	t := anim_to(ui, fid, (hov || focused) ? 1 : 0)
	bg := lerp_color(THEME.field, THEME.field_hover, t)
	rounded(r, 5, bg)
	if focused {
		rounded_lines(r, 5, 1.5, fade(THEME.accent, 0.9))
	} else if opts.error {
		rounded_lines(r, 5, 1.2, THEME.error)
	}
	if opts.label != "" {
		lc := THEME.text_faint
		if ui.scrub_id == fid {lc = THEME.accent}
		text_in(ui, opts.label, {r.x + 7, r.y, label_w - 7, r.height}, .Small, lc)
	}
	tr := Rect{r.x + 7 + label_w, r.y, r.width - 14 - label_w, r.height}
	if opts.label != "" {tr.x -= 4; tr.width += 4}
	if focused {
		s := string(ui.edit.buf[:])
		size := FONT_SIZES[.Regular]
		ty := tr.y + (tr.height - size * 1.2) * 0.5 + 0.5
		// keep the caret visible
		cx := text_width(ui, s[:ui.edit.cursor])
		off: f32 = 0
		if cx > tr.width - 4 {off = cx - tr.width + 4}
		rl.BeginScissorMode(i32(tr.x), i32(r.y), i32(tr.width + 2), i32(r.height))
		if ui.edit.anchor != ui.edit.cursor {
			a, b := min(ui.edit.anchor, ui.edit.cursor), max(ui.edit.anchor, ui.edit.cursor)
			xa := tr.x + text_width(ui, s[:a]) - off
			xb := tr.x + text_width(ui, s[:b]) - off
			rl.DrawRectangleRec({xa, r.y + 4, xb - xa, r.height - 8}, {245, 142, 46, 90})
		}
		draw_text(ui, s, tr.x - off, ty, .Regular, THEME.text)
		if math.mod(ui.edit.blink, 1.0) < 0.6 {
			rl.DrawRectangleRec({math.round(tr.x + cx - off), r.y + 5, 2, r.height - 10}, THEME.accent)
		}
		rl.EndScissorMode()
		ui.animating = true // caret blink
		// restore the panel scissor
		reapply_panel_scissor(ui)
	} else {
		shown := text
		c := opts.color.a != 0 ? opts.color : THEME.text
		if shown == "" {
			shown = opts.placeholder
			c = THEME.text_faint
		}
		suffix_w: f32 = 0
		if opts.suffix != "" {
			suffix_w = text_width(ui, opts.suffix, .Small) + 6
			text_in(ui, opts.suffix, {tr.x, tr.y, tr.width, tr.height}, .Small, THEME.text_faint, .Right)
		}
		text_in(ui, shown, {tr.x, tr.y, tr.width - suffix_w, tr.height}, .Regular, c, opts.align_right && opts.suffix == "" ? .Right : .Left)
	}
	return res
}

reapply_panel_scissor :: proc(ui: ^UI) {
	c := ui.lay.rect
	rl.BeginScissorMode(i32(c.x - 4), i32(c.y - 2), i32(c.width + 8), i32(c.height + 4))
}

// ---------------------------------------------------------------------------
// Dropdown

dropdown :: proc(ui: ^UI, did: Id, r: Rect, current: string, options: []string, swatches: []Color = nil) -> (choice: int, changed: bool) {
	choice = -1
	if ui.popup_choice_id == did && ui.popup_choice >= 0 {
		choice = ui.popup_choice
		changed = true
		ui.popup_choice = -1
		ui.popup_choice_id = 0
	}
	vis := is_visible(ui, r)
	hov := hovered(ui, r) && vis
	open := ui.popup.id == did
	if hov && ui.pressed && !open {
		ui.popup = {id = did, anchor = r}
		ui.active = did
		open = true
	}
	if open {
		// options live for this frame; the popup is drawn at end_frame
		ui.popup.options = options
		ui.popup.anchor = r
	}
	if !vis {return}
	t := anim_to(ui, did, (hov || open) ? 1 : 0)
	rounded(r, 5, lerp_color(THEME.field, THEME.field_hover, t))
	text_in(ui, current, {r.x + 9, r.y, r.width - 30, r.height}, .Regular, THEME.text)
	icon(.Chevron_Down, {r.x + r.width - 14, r.y + r.height * 0.5}, THEME.text_dim)
	return
}

@(private)
draw_popup :: proc(ui: ^UI) {
	p := &ui.popup
	if p.id == 0 {return}
	if len(p.options) == 0 {
		p^ = {}
		return
	}
	item_h: f32 = 30
	w := p.anchor.width
	for o in p.options {w = max(w, text_width(ui, o) + 30)}
	h := item_h * f32(len(p.options)) + 8
	x := p.anchor.x
	y := p.anchor.y + p.anchor.height + 4
	if y + h > f32(rl.GetScreenHeight()) - 8 {y = p.anchor.y - h - 4}
	p.rect = {x, y, w, h}
	shadowed_card(p.rect, 7, {36, 38, 43, 252})
	clicked := -1
	for o, i in p.options {
		ir := Rect{x + 4, y + 4 + f32(i) * item_h, w - 8, item_h}
		ui.rects[id_n(p.id, i)] = ir
		hov := rl.CheckCollisionPointRec(ui.mouse, ir)
		if hov {
			rounded(ir, 5, THEME.accent_soft)
			if ui.released || (ui.pressed && ui.active != p.id) {clicked = i}
		}
		text_in(ui, o, {ir.x + 8, ir.y, ir.width - 16, ir.height}, .Regular, hov ? THEME.text : THEME.text_dim)
	}
	if clicked >= 0 {
		ui.popup_choice = clicked
		ui.popup_choice_id = p.id
		p^ = {}
		ui.active = 0
		ui.animating = true
	} else if (ui.pressed && !rl.CheckCollisionPointRec(ui.mouse, p.rect) && !rl.CheckCollisionPointRec(ui.mouse, p.anchor)) || rl.IsKeyPressed(.ESCAPE) {
		p^ = {}
	}
	p.options = nil
}

// ---------------------------------------------------------------------------
// Tree rows

Tree_Result :: struct {
	clicked:      bool,
	double:       bool,
	toggled:      bool,
	drag_started: bool,
	hovered:      bool,
}

tree_row :: proc(ui: ^UI, rid: Id, depth: int, text: string, sub: string, selected, has_children, expanded: bool, dim := false) -> Tree_Result {
	res: Tree_Result
	r := next_row(ui, 28)
	r.y -= GAP - 2
	ui.lay.y -= GAP - 2
	vis := is_visible(ui, r)
	hov := hovered(ui, r) && vis
	res.hovered = hov
	x := r.x + 4 + f32(depth) * 14
	arrow := Rect{x, r.y, 14, r.height}
	if hov && ui.pressed {
		if has_children && rl.CheckCollisionPointRec(ui.mouse, arrow) {
			res.toggled = true
		} else {
			res.clicked = true
			res.double = ui.double_click
			ui.active = rid
		}
	}
	if !vis {return res}
	if selected {
		rounded(r, 5, THEME.accent_soft)
	} else if hov {
		rounded(r, 5, {255, 255, 255, 10})
	}
	if has_children {
		cx := x + 5
		cy := r.y + r.height * 0.5
		c := THEME.text_dim
		icon(expanded ? .Arrow_Down : .Arrow_Right, {cx, cy}, c)
	}
	tc := selected ? THEME.text : (dim ? THEME.text_faint : THEME.text_dim)
	sw: f32 = 0
	if sub != "" {
		sw = text_width(ui, sub, .Small) + 8
		text_in(ui, sub, {r.x, r.y, r.width - 8, r.height}, .Small, THEME.text_faint, .Right)
	}
	text_in(ui, text, {x + 16, r.y, r.x + r.width - x - 16 - sw, r.height}, has_children ? .Semibold : .Regular, tc)
	return res
}

// Horizontal slider; returns the new value and whether it changed this frame.
slider :: proc(ui: ^UI, sid: Id, r: Rect, value, lo, hi: f32, format := "%.2f") -> (f32, bool) {
	ui.rects[sid] = r
	vis := is_visible(ui, r)
	val_w: f32 = 54
	track := Rect{r.x, r.y + r.height * 0.5 - 2, r.width - val_w - 10, 4}
	hit := Rect{track.x - 6, r.y, track.width + 12, r.height}
	hov := hovered(ui, hit) && vis
	if hov && ui.pressed {ui.active = sid}
	out := value
	changed := false
	if ui.active == sid && ui.down {
		t := clamp((ui.mouse.x - track.x) / track.width, 0, 1)
		out = lo + (hi - lo) * t
		out = math.round(out * 20) / 20
		changed = out != value
		ui.cursor = .RESIZE_EW
	}
	if !vis {return out, changed}
	t := clamp((out - lo) / (hi - lo), 0, 1)
	rounded(track, 2, THEME.field)
	rounded({track.x, track.y, track.width * t, track.height}, 2, THEME.accent)
	k := anim_to(ui, sid, (hov || ui.active == sid) ? 1 : 0)
	kn := 10 + math.round(k * 2)
	rounded({math.round(track.x + track.width * t - kn * 0.5), math.round(track.y + 2 - kn * 0.5), kn, kn}, 2, rl.WHITE)
	text_in(ui, fmt.tprintf(format, out), {r.x + r.width - val_w, r.y, val_w, r.height}, .Small, THEME.text_dim, .Right)
	return out, changed
}
