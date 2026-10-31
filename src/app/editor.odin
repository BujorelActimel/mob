package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"
import "../geom"
import "../model"
import "../ui"

// 2D sketch editor for panel outlines, turned profiles and sweep paths.

Editor_Target :: enum u8 {
	Outline,
	Turned,
	Path,
}

Editor :: struct {
	open:       bool,
	part:       Id,
	target:     Editor_Target,
	pan:        Vec2, // sketch point at the canvas centre
	zoom:       f32, // pixels per mm
	fit:        bool,
	sel:        int,
	sel_hole:   int,
	drag_point: int,
	drag_hole:  int,
	drag_key:   u64,
	panning:    bool,
	guide:      [2]bool,
	guide_v:    Vec2,
}

open_editor :: proc(a: ^App, id: Id) {
	p := model.find_part(a.doc, id)
	if p == nil {return}
	e := &a.editor
	e^ = {open = true, part = id, fit = true, sel = -1, sel_hole = -1, drag_point = -1, drag_hole = -1}
	switch _ in p.shape {
	case model.Panel:  e.target = .Outline
	case model.Turned: e.target = .Turned
	case model.Swept:  e.target = .Path
	}
	a.tool = .Select
}

open_editor_for_selection :: proc(a: ^App) {
	if len(a.selection) == 1 {
		if model.find_part(a.doc, a.selection[0]) != nil {
			open_editor(a, a.selection[0])
			return
		}
	}
	toast(a, "Select a single part to edit its outline")
}

@(private)
editor_points :: proc(p: ^model.Part, target: Editor_Target) -> (^[dynamic]model.Sketch_Point, bool) {
	switch &s in p.shape {
	case model.Panel:
		if s.profile.kind == .Polygon {return &s.profile.points, true}
		return nil, true
	case model.Turned:
		return &s.points, false
	case model.Swept:
		return &s.path, false
	}
	return nil, false
}

@(private)
Convert :: struct {
	p: ^model.Part,
}

@(private)
convert_to_polygon :: proc(a: ^App, raw: rawptr) {
	c := (^Convert)(raw)
	d := a.doc
	panel := &c.p.shape.(model.Panel)
	pr := &panel.profile
	xs := [4]string{"0", pr.w.src, pr.w.src, "0"}
	ys := [4]string{"0", "0", pr.h.src, pr.h.src}
	corners := [4]model.Corner{.Front_Left, .Front_Right, .Back_Right, .Back_Left}
	clear(&pr.points)
	for i in 0 ..< 4 {
		append(&pr.points, model.Sketch_Point{model.field_make(d, xs[i]), model.field_make(d, ys[i]), model.field_make(d, pr.radii[corners[i]].src)})
	}
	pr.kind = .Polygon
}

@(private)
Insert :: struct {
	list:  ^[dynamic]model.Sketch_Point,
	index: int,
	pos:   Vec2,
}

@(private)
insert_point :: proc(a: ^App, raw: rawptr) {
	ins := (^Insert)(raw)
	d := a.doc
	q := model.Sketch_Point{model.field_num(d, f64(math.round(ins.pos.x))), model.field_num(d, f64(math.round(ins.pos.y))), model.field_num(d, 0)}
	inject_at(ins.list, ins.index, q)
}

@(private)
pick_step :: proc(zoom: f32) -> f32 {
	for s in ([]f32{1, 5, 10, 50, 100, 500, 1000, 5000}) {
		if s * zoom >= 14 {return s}
	}
	return 10000
}

editor_frame :: proc(a: ^App, area: rl.Rectangle) {
	e := &a.editor
	p := model.find_part(a.doc, e.part)
	rp := resolved_part(a, e.part)
	if p == nil || rp == nil {
		e.open = false
		return
	}
	card := area
	ui.shadowed_card(card, 14, {22, 23, 27, 250})
	ui.block(&a.ui, card)
	side := rl.Rectangle{card.x + 10, card.y + 10, 300, card.height - 20}
	canvas := rl.Rectangle{side.x + side.width + 10, card.y + 10, card.width - side.width - 30, card.height - 20}
	cc := Vec2{canvas.x + canvas.width * 0.5, canvas.y + canvas.height * 0.5}

	// geometry to draw, in sketch coordinates
	ta := context.temp_allocator
	outer := make([dynamic]Vec2, ta)
	holes := make([dynamic][dynamic]Vec2, ta)
	closed := true
	switch e.target {
	case .Outline:
		geom.tessellate_contour(rp.profile.outer, 0.2, &outer)
		for h in rp.profile.holes {
			hp := make([dynamic]Vec2, ta)
			geom.tessellate_contour(h, 0.2, &hp)
			append(&holes, hp)
		}
	case .Turned, .Path:
		append(&outer, ..rp.line)
		closed = false
	}
	pts, _ := editor_points(p, e.target)

	// fit view
	if e.fit && len(outer) > 0 {
		lo := outer[0]
		hi := outer[0]
		for q in outer {lo = linalg.min(lo, q); hi = linalg.max(hi, q)}
		if e.target == .Turned {lo.x = -hi.x}
		size := linalg.max(hi - lo, Vec2{50, 50})
		e.zoom = min(canvas.width / (size.x * 1.35), canvas.height / (size.y * 1.35))
		e.pan = (lo + hi) * 0.5
		e.fit = false
	}
	S :: proc(e: ^Editor, cc: Vec2, q: Vec2) -> Vec2 {return {cc.x + (q.x - e.pan.x) * e.zoom, cc.y - (q.y - e.pan.y) * e.zoom}}
	K :: proc(e: ^Editor, cc: Vec2, s: Vec2) -> Vec2 {return {e.pan.x + (s.x - cc.x) / e.zoom, e.pan.y - (s.y - cc.y) / e.zoom}}

	// ---- input on the canvas
	mouse := a.ui.mouse
	in_canvas := rl.CheckCollisionPointRec(mouse, canvas) && a.ui.popup.id == 0 && !ui.wants_keyboard(&a.ui)
	if in_canvas && a.ui.wheel != 0 {
		before := K(e, cc, mouse)
		e.zoom = clamp(e.zoom * math.exp(a.ui.wheel * 0.14), 0.02, 200)
		after := K(e, cc, mouse)
		e.pan += before - after
	}
	if in_canvas && (rl.IsMouseButtonPressed(.RIGHT) || rl.IsMouseButtonPressed(.MIDDLE)) {e.panning = true}
	if e.panning {
		dlt := a.ui.mouse_delta
		e.pan += Vec2{-dlt.x, dlt.y} / e.zoom
		if !rl.IsMouseButtonDown(.RIGHT) && !rl.IsMouseButtonDown(.MIDDLE) {e.panning = false}
	}

	// handles: free points, or the rectangle's corners
	Handle :: struct {
		pos:      Vec2,
		editable: bool,
	}
	handles := make([dynamic]Handle, ta)
	panel, is_panel := &p.shape.(model.Panel)
	rect_mode := is_panel && panel.profile.kind == .Rect
	if rect_mode {
		w := f32(panel.profile.w.value)
		h := f32(panel.profile.h.value)
		append(&handles, Handle{{0, 0}, false}, Handle{{w, 0}, true}, Handle{{w, h}, true}, Handle{{0, h}, true})
	} else if pts != nil {
		for q in pts {
			append(&handles, Handle{{f32(q.x.value), f32(q.y.value)}, model.field_is_literal(q.x) && model.field_is_literal(q.y)})
		}
	}
	hole_handles := make([dynamic]Vec2, ta)
	if is_panel {
		for h in panel.profile.holes {append(&hole_handles, Vec2{f32(h.cx.value), f32(h.cy.value)})}
	}

	if in_canvas && a.ui.pressed && e.drag_point < 0 && e.drag_hole < 0 {
		hit := -1
		for hd, i in handles {
			if linalg.length(S(e, cc, hd.pos) - mouse) < 9 {hit = i}
		}
		hhit := -1
		for hp, i in hole_handles {
			if linalg.length(S(e, cc, hp) - mouse) < 9 {hhit = i}
		}
		if hit >= 0 {
			e.sel = hit
			e.sel_hole = -1
			if handles[hit].editable {
				e.drag_point = hit
				e.drag_key = new_coalesce_key(a)
			} else if !rect_mode {
				toast(a, "This point is driven by an expression — edit it on the left")
			}
		} else if hhit >= 0 {
			e.sel_hole = hhit
			e.sel = -1
			e.drag_hole = hhit
			e.drag_key = new_coalesce_key(a)
		} else if a.ui.double_click && pts != nil && !rect_mode {
			// insert on the nearest edge
			n := len(pts)
			best := -1
			best_d: f32 = 8
			edges := closed ? n : n - 1
			for i in 0 ..< edges {
				d := dist_point_segment(mouse, S(e, cc, handles[i].pos), S(e, cc, handles[(i + 1) % n].pos))
				if d < best_d {best_d = d; best = i}
			}
			if best >= 0 {
				ins := Insert{list = pts, index = best + 1, pos = K(e, cc, mouse)}
				apply(a, Cmd_Custom{fn = insert_point, data = &ins})
				e.sel = best + 1
			}
		} else {
			e.sel = -1
			e.sel_hole = -1
		}
	}
	e.guide = {}
	if e.drag_point >= 0 {
		q := K(e, cc, mouse)
		step: f32 = ui.shift_down() ? 10 : 1
		q = {math.round(q.x / step) * step, math.round(q.y / step) * step}
		// align with other points
		for hd, i in handles {
			if i == e.drag_point {continue}
			if abs(hd.pos.x - q.x) * e.zoom < 6 {q.x = hd.pos.x; e.guide[0] = true; e.guide_v.x = q.x}
			if abs(hd.pos.y - q.y) * e.zoom < 6 {q.y = hd.pos.y; e.guide[1] = true; e.guide_v.y = q.y}
		}
		if e.target == .Turned {q.x = max(q.x, 0)}
		if rect_mode {
			pr := &panel.profile
			i := e.drag_point
			if (i == 1 || i == 2) && abs(f64(q.x) - pr.w.value) > 1e-6 && q.x > 1 {
				apply(a, Cmd_Solve{owner = p.id, field = &pr.w, value = f64(q.x)}, e.drag_key)
			}
			if (i == 2 || i == 3) && abs(f64(q.y) - pr.h.value) > 1e-6 && q.y > 1 {
				apply(a, Cmd_Solve{owner = p.id, field = &pr.h, value = f64(q.y)}, e.drag_key)
			}
		} else if pts != nil && e.drag_point < len(pts) {
			sp := &pts[e.drag_point]
			if abs(f64(q.x) - sp.x.value) > 1e-6 {apply(a, Cmd_Solve{owner = p.id, field = &sp.x, value = f64(q.x)}, e.drag_key)}
			if abs(f64(q.y) - sp.y.value) > 1e-6 {apply(a, Cmd_Solve{owner = p.id, field = &sp.y, value = f64(q.y)}, e.drag_key)}
		}
		if !a.ui.down {e.drag_point = -1}
	}
	if e.drag_hole >= 0 && is_panel {
		q := K(e, cc, mouse)
		step: f32 = ui.shift_down() ? 10 : 1
		q = {math.round(q.x / step) * step, math.round(q.y / step) * step}
		if e.drag_hole < len(panel.profile.holes) {
			h := &panel.profile.holes[e.drag_hole]
			if abs(f64(q.x) - h.cx.value) > 1e-6 {apply(a, Cmd_Solve{owner = p.id, field = &h.cx, value = f64(q.x)}, e.drag_key)}
			if abs(f64(q.y) - h.cy.value) > 1e-6 {apply(a, Cmd_Solve{owner = p.id, field = &h.cy, value = f64(q.y)}, e.drag_key)}
		}
		if !a.ui.down {e.drag_hole = -1}
	}
	if !ui.wants_keyboard(&a.ui) && (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE)) {
		if e.sel >= 0 && pts != nil && !rect_mode {
			min_n := closed ? 3 : 2
			if len(pts) > min_n {
				pe := Point_Edit{list = pts, index = e.sel}
				apply(a, Cmd_Custom{fn = edit_points, data = &pe})
				e.sel = -1
			} else {
				toast(a, "An outline needs at least three points", .Error)
			}
		} else if e.sel_hole >= 0 && is_panel {
			he := Hole_Edit{holes = &panel.profile.holes, index = e.sel_hole}
			apply(a, Cmd_Custom{fn = edit_holes, data = &he})
			e.sel_hole = -1
		}
	}
	if !ui.wants_keyboard(&a.ui) && (rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.E)) && e.drag_point < 0 {
		e.open = false
	}
	if !ui.wants_keyboard(&a.ui) && rl.IsKeyPressed(.F) {e.fit = true}

	// ---- draw canvas
	rl.BeginScissorMode(i32(canvas.x), i32(canvas.y), i32(canvas.width), i32(canvas.height))
	ui.rounded(canvas, 10, {30, 32, 37, 255})
	step := pick_step(e.zoom)
	lo := K(e, cc, {canvas.x, canvas.y + canvas.height})
	hi := K(e, cc, {canvas.x + canvas.width, canvas.y})
	x0 := math.floor(lo.x / step) * step
	for x := x0; x <= hi.x; x += step {
		s := S(e, cc, {x, 0})
		major := math.mod(abs(x), step * 10) < 0.001
		rl.DrawLineV({s.x, canvas.y}, {s.x, canvas.y + canvas.height}, major ? rl.Color{255, 255, 255, 22} : rl.Color{255, 255, 255, 9})
	}
	y0 := math.floor(lo.y / step) * step
	for y := y0; y <= hi.y; y += step {
		s := S(e, cc, {0, y})
		major := math.mod(abs(y), step * 10) < 0.001
		rl.DrawLineV({canvas.x, s.y}, {canvas.x + canvas.width, s.y}, major ? rl.Color{255, 255, 255, 22} : rl.Color{255, 255, 255, 9})
	}
	o := S(e, cc, {0, 0})
	rl.DrawLineV({canvas.x, o.y}, {canvas.x + canvas.width, o.y}, {226, 76, 70, 90})
	rl.DrawLineV({o.x, canvas.y}, {o.x, canvas.y + canvas.height}, e.target == .Turned ? rl.Color{94, 186, 84, 160} : rl.Color{94, 186, 84, 90})

	fillc := rl.Color{214, 180, 132, 70}
	linec := rl.Color{240, 214, 176, 255}
	if closed && len(outer) >= 3 {
		hs := make([dynamic][]Vec2, ta)
		for h in holes {append(&hs, h[:])}
		verts, tris := geom.triangulate(outer[:], hs[:], ta)
		for k := 0; k + 2 < len(tris); k += 3 {
			// screen space flips y, so swap winding for raylib
			A := S(e, cc, verts[tris[k]])
			B := S(e, cc, verts[tris[k + 1]])
			C := S(e, cc, verts[tris[k + 2]])
			rl.DrawTriangle(A, C, B, fillc)
			rl.DrawTriangle(A, B, C, fillc)
		}
	}
	draw_poly :: proc(e: ^Editor, cc: Vec2, pts: []Vec2, closed: bool, c: rl.Color, thick: f32, mirror := false) {
		n := len(pts)
		edges := closed ? n : n - 1
		for i in 0 ..< edges {
			p0 := pts[i]
			p1 := pts[(i + 1) % n]
			if mirror {p0.x = -p0.x; p1.x = -p1.x}
			rl.DrawLineEx(S(e, cc, p0), S(e, cc, p1), thick, c)
		}
	}
	draw_poly(e, cc, outer[:], closed, linec, 2)
	for h in holes {draw_poly(e, cc, h[:], true, linec, 2)}
	if e.target == .Turned {
		draw_poly(e, cc, outer[:], false, {240, 214, 176, 70}, 1.5, true)
	}
	// guides
	if e.guide[0] {
		s := S(e, cc, {e.guide_v.x, 0})
		rl.DrawLineV({s.x, canvas.y}, {s.x, canvas.y + canvas.height}, {220, 40, 160, 160})
	}
	if e.guide[1] {
		s := S(e, cc, {0, e.guide_v.y})
		rl.DrawLineV({canvas.x, s.y}, {canvas.x + canvas.width, s.y}, {220, 40, 160, 160})
	}
	// handles
	for hd, i in handles {
		s := S(e, cc, hd.pos)
		hov := linalg.length(s - mouse) < 9 && in_canvas
		r: f32 = hov || i == e.sel ? 6 : 4.5
		if hd.editable {
			rl.DrawCircleV(s, r + 1.5, {20, 20, 24, 255})
			rl.DrawCircleV(s, r, i == e.sel ? ui.THEME.accent : rl.WHITE)
		} else {
			rl.DrawCircleV(s, r + 1.5, {20, 20, 24, 255})
			rl.DrawRing(s, r - 1.8, r, 0, 360, 20, ui.THEME.expr)
		}
		if pts != nil && i < len(pts) && pts[i].r.value > 0 {
			ui.draw_text(&a.ui, fmt.tprintf("r%s", model.format_number(pts[i].r.value)), s.x + 8, s.y - 18, .Small, ui.THEME.text_dim)
		}
	}
	for hp, i in hole_handles {
		s := S(e, cc, hp)
		sel := i == e.sel_hole
		rl.DrawLineEx(s - {5, 0}, s + {5, 0}, 1.5, sel ? ui.THEME.accent : rl.WHITE)
		rl.DrawLineEx(s - {0, 5}, s + {0, 5}, 1.5, sel ? ui.THEME.accent : rl.WHITE)
	}
	// size readout
	if len(outer) > 0 {
		blo := outer[0]
		bhi := outer[0]
		for q in outer {blo = linalg.min(blo, q); bhi = linalg.max(bhi, q)}
		sz := bhi - blo
		label := fmt.tprintf("%s × %s mm", model.format_number(f64(sz.x)), model.format_number(f64(sz.y)))
		if e.target == .Turned {label = fmt.tprintf("Ø%s × %s mm", model.format_number(f64(2 * bhi.x)), model.format_number(f64(sz.y)))}
		ui.text_in(&a.ui, label, {canvas.x + 14, canvas.y + 10, 300, 20}, .Semibold, ui.THEME.text_dim)
		ui.text_in(&a.ui, fmt.tprintf("grid %s mm", model.format_number(f64(step))), {canvas.x, canvas.y + 10, canvas.width - 14, 20}, .Small, ui.THEME.text_faint, .Right)
	}
	mp := K(e, cc, mouse)
	if in_canvas {
		ui.text_in(&a.ui, fmt.tprintf("%s, %s", model.format_number(f64(math.round(mp.x))), model.format_number(f64(math.round(mp.y)))), {canvas.x, canvas.y + canvas.height - 28, canvas.width - 14, 20}, .Small, ui.THEME.text_faint, .Right)
	}
	rl.EndScissorMode()

	// ---- sidebar
	titles := [Editor_Target]string{.Outline = "Outline", .Turned = "Turned profile", .Path = "Sweep path"}
	ui.panel_begin(&a.ui, ui.id("editor-side"), side, titles[e.target], {34, 36, 41, 255})
	ui.label(&a.ui, p.name, .Semibold, ui.THEME.text_dim)
	if rect_mode {
		ui.label(&a.ui, "Drag the corners to resize.", .Small, ui.THEME.text_faint, 20)
		ui.label(&a.ui, "Size, radii and holes are", .Small, ui.THEME.text_faint, 20)
		ui.label(&a.ui, "in the inspector.", .Small, ui.THEME.text_faint, 20)
		ui.space(&a.ui, 4)
		if ui.button(&a.ui, "Convert to free outline", .Normal, "Turn the rectangle into editable points.\nW and D expressions are kept on the points.") {
			cv := Convert{p}
			apply(a, Cmd_Custom{fn = convert_to_polygon, data = &cv})
		}
	} else if pts != nil {
		xl := e.target == .Turned ? "r" : "X"
		yl := e.target == .Turned ? "h" : "Y"
		if e.sel >= 0 && e.sel < len(pts) {
			ui.heading(&a.ui, fmt.tprintf("Point %d", e.sel + 1))
			q := &pts[e.sel]
			field_row(a, p.id, "selpt", {xl, yl, "r"}, {&q.x, &q.y, &q.r})
		}
		ui.heading(&a.ui, fmt.tprintf("%d points", len(pts)))
		points_table(a, p.id, pts, xl, yl, closed ? 3 : 2)
		ui.label(&a.ui, "Double-click an edge: add point", .Small, ui.THEME.text_faint, 20)
		ui.label(&a.ui, "Delete: remove point", .Small, ui.THEME.text_faint, 20)
		ui.label(&a.ui, "Shift: snap to 10 mm", .Small, ui.THEME.text_faint, 20)
	}
	ui.space(&a.ui, 8)
	r := ui.next_row(&a.ui, 30)
	cols := ui.columns(r, {1, 1})
	if ui.button_rect(&a.ui, ui.id("ed-fit"), cols[0], "Fit  F") {e.fit = true}
	if ui.button_rect(&a.ui, ui.id("ed-done"), cols[1], "Done", .Primary) {e.open = false}
	ui.panel_end(&a.ui)
}
