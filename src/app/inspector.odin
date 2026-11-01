package app

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"
import "../expr"
import "../model"
import "../ui"

fid :: proc(owner: Id, name: string, n: int = 0) -> ui.Id {
	return ui.id_n(ui.id(name, u64(owner) * 2654435761 + 17), n)
}

// An expression input bound to a document field. Label drag scrubs the value.
expr_input :: proc(a: ^App, r: rl.Rectangle, wid: ui.Id, label: string, f: ^model.Expr_Field, owner: Id, placeholder := "", step := 1.0) {
	is_expr := !model.field_is_literal(f^)
	opts := ui.Field_Opts {
		label       = label,
		scrub       = !f.parse_err,
		value       = f.value,
		scrub_step  = step,
		placeholder = placeholder,
		error       = model.field_has_error(f^),
	}
	if is_expr {
		opts.color = ui.THEME.expr
		opts.suffix = fmt.tprintf("= %s", model.format_number(f.value))
	}
	res := ui.text_field(&a.ui, wid, r, f.src, opts)
	if res.committed && res.text != f.src {
		apply(a, Cmd_Set_Field{field = f, text = res.text})
	}
	if res.scrubbing {
		if res.scrub_start {a.scrub_key = new_coalesce_key(a)}
		if res.value != f.value {apply(a, Cmd_Solve{owner = owner, field = f, value = res.value}, a.scrub_key)}
	}
	if model.field_has_error(f^) && ui.hovered(&a.ui, r) {
		ui.set_tooltip(&a.ui, wid, r, expr.format_error(f.err))
	} else if is_expr && ui.hovered(&a.ui, r) && a.ui.focus != wid {
		ui.set_tooltip(&a.ui, wid, r, fmt.tprintf("%s = %s mm\nDrag the label to change the parameter behind it.", f.src, model.format_number(f.value)))
	}
}

// One row of labelled expression fields.
field_row :: proc(a: ^App, owner: Id, key: string, labels: []string, fields: []^model.Expr_Field, placeholders: []string = nil, step := 1.0) {
	r := ui.next_row(&a.ui)
	weights := make([]f32, len(fields), context.temp_allocator)
	for &w in weights {w = 1}
	cols := ui.columns(r, weights)
	for f, i in fields {
		ph := ""
		if i < len(placeholders) {ph = placeholders[i]}
		expr_input(a, cols[i], fid(owner, key, i), labels[i], f, owner, ph, step)
	}
	for f in fields {
		if model.field_has_error(f^) {
			ui.label(&a.ui, expr.format_error(f.err), .Small, ui.THEME.error, 14)
			break
		}
	}
}

name_input :: proc(a: ^App, owner: Id, name: ^string) {
	r := ui.next_row(&a.ui, 30)
	res := ui.text_field(&a.ui, fid(owner, "name"), r, name^, {placeholder = "Name"})
	if res.committed && res.text != name^ && strings.trim_space(res.text) != "" {
		apply(a, Cmd_Rename{name = name, text = res.text})
	}
}

// ---------------------------------------------------------------------------

@(private)
Params_Edit :: struct {
	group: Id,
	index: int,
	name:  string,
}

params_table :: proc(a: ^App, params: ^[dynamic]model.Param, group: Id) {
	for &p, i in params {
		r := ui.next_row(&a.ui)
		cols := ui.columns(r, {0.9, 1.6, 0.28}, 4)
		nres := ui.text_field(&a.ui, fid(group, "pname", i), cols[0], p.name, {color = ui.THEME.expr})
		if nres.committed && nres.text != p.name {
			n := strings.trim_space(nres.text)
			switch {
			case !expr.is_valid_name(n):
				toast(a, fmt.tprintf("'%s' is not a valid parameter name", n), .Error)
			case model.find_param(params[:], n) != nil:
				toast(a, fmt.tprintf("'%s' already exists here", n), .Error)
			case:
				rename_param(a, &p, n)
			}
		}
		expr_input(a, cols[1], fid(group, "pexpr", i), "", &p.field, group)
		if ui.button_rect(&a.ui, fid(group, "pdel", i), cols[2], "×", .Ghost, tip = "Remove parameter") {
			apply(a, Cmd_Remove_Param{group = group, index = i})
			return
		}
		if model.field_has_error(p.field) {
			ui.label(&a.ui, expr.format_error(p.field.err), .Small, ui.THEME.error, 14)
		}
	}
	if ui.button_rect(&a.ui, fid(group, "padd"), ui.next_row(&a.ui, 26), "+ Parameter", .Ghost) {
		apply(a, Cmd_Add_Param{group = group})
	}
}

// Renaming a parameter also rewrites references to it in the subtree that sees it.
@(private)
rename_param :: proc(a: ^App, p: ^model.Param, new_name: string) {
	Data :: struct {
		p:        ^model.Param,
		old, new: string,
	}
	data := Data{p, strings.clone(p.name, context.temp_allocator), new_name}
	apply(a, Cmd_Custom{fn = proc(a: ^App, raw: rawptr) {
		d := (^Data)(raw)
		d.p.name = model.str(a.doc, d.new)
		rewrite_refs(a, d.old, d.new)
	}, data = &data})
}

@(private)
rewrite_field :: proc(a: ^App, f: ^model.Expr_Field, old, new: string) {
	if f.src == "" || f.parse_err {return}
	hit := false
	for n in f.ast.nodes {if n.kind == .Ident && n.name == old {hit = true}}
	if !hit {return}
	offs := make([dynamic]int, context.temp_allocator)
	for n in f.ast.nodes {
		if n.kind == .Ident && n.name == old {
			append(&offs, int(uintptr(raw_data(n.name)) - uintptr(raw_data(f.src))))
		}
	}
	for i in 1 ..< len(offs) {
		for j := i; j > 0 && offs[j - 1] > offs[j]; j -= 1 {offs[j - 1], offs[j] = offs[j], offs[j - 1]}
	}
	out := strings.builder_make(context.temp_allocator)
	last := 0
	for off in offs {
		strings.write_string(&out, f.src[last:off])
		strings.write_string(&out, new)
		last = off + len(old)
	}
	strings.write_string(&out, f.src[last:])
	model.field_set(a.doc, f, strings.to_string(out))
}

@(private)
rewrite_refs :: proc(a: ^App, old, new: string) {
	visit_profile :: proc(a: ^App, p: ^model.Profile_Def, old, new: string) {
		rewrite_field(a, &p.w, old, new)
		rewrite_field(a, &p.h, old, new)
		for c in model.Corner {rewrite_field(a, &p.radii[c], old, new)}
		for &q in p.points {
			rewrite_field(a, &q.x, old, new)
			rewrite_field(a, &q.y, old, new)
			rewrite_field(a, &q.r, old, new)
		}
		for &h in p.holes {
			rewrite_field(a, &h.cx, old, new)
			rewrite_field(a, &h.cy, old, new)
			rewrite_field(a, &h.w, old, new)
			rewrite_field(a, &h.h, old, new)
			rewrite_field(a, &h.r, old, new)
		}
	}
	visit_xf :: proc(a: ^App, xf: ^model.Transform_Def, old, new: string) {
		for i in 0 ..< 3 {
			rewrite_field(a, &xf.pos[i], old, new)
			rewrite_field(a, &xf.rot[i], old, new)
		}
	}
	visit :: proc(a: ^App, g: ^model.Group, old, new: string) {
		visit_xf(a, &g.xf, old, new)
		for &p in g.params {rewrite_field(a, &p.field, old, new)}
		for c in g.children {
			switch v in c {
			case ^model.Group: visit(a, v, old, new)
			case ^model.Part:
				visit_xf(a, &v.xf, old, new)
				switch &s in v.shape {
				case model.Panel:
					visit_profile(a, &s.profile, old, new)
					rewrite_field(a, &s.thickness, old, new)
					rewrite_field(a, &s.edge, old, new)
				case model.Turned:
					for &q in s.points {
						rewrite_field(a, &q.x, old, new)
						rewrite_field(a, &q.y, old, new)
						rewrite_field(a, &q.r, old, new)
					}
				case model.Swept:
					visit_profile(a, &s.section, old, new)
					for &q in s.path {
						rewrite_field(a, &q.x, old, new)
						rewrite_field(a, &q.y, old, new)
						rewrite_field(a, &q.r, old, new)
					}
				}
			}
		}
	}
	for &p in a.doc.params {rewrite_field(a, &p.field, old, new)}
	visit(a, a.doc.root, old, new)
}

// ---------------------------------------------------------------------------

transform_rows :: proc(a: ^App, owner: Id, xf: ^model.Transform_Def, is_panel: bool) {
	ui.heading(&a.ui, "Position")
	field_row(a, owner, "pos", {"X", "Y", "Z"}, {&xf.pos[0], &xf.pos[1], &xf.pos[2]})
	lit := model.field_is_literal(xf.rot[0]) && model.field_is_literal(xf.rot[1]) && model.field_is_literal(xf.rot[2])
	rx, ry, rz := xf.rot[0].value, xf.rot[1].value, xf.rot[2].value
	rotated := !lit || rx != 0 || ry != 0 || rz != 0
	show_rot := a.rot_open == owner
	if is_panel {
		cur := 3
		if lit {
			switch {
			case rx == 0 && ry == 0 && rz == 0: cur = 0
			case rx == 0 && ry == 0 && rz == 90: cur = 1
			case rx == 90 && ry == 0 && rz == 0: cur = 2
			}
		}
		if cur == 3 {show_rot = true}
		ui.heading(&a.ui, "Orientation")
		r := ui.next_row(&a.ui, 28)
		sel := ui.segmented(&a.ui, fid(owner, "orient"), r, {"Flat", "Side", "Back", "Custom"}, show_rot && cur != 3 ? 3 : cur)
		if sel == 3 && cur != 3 {a.rot_open = owner}
		if sel < 3 && (sel != cur || a.rot_open == owner) {
			a.rot_open = 0
			if !lit {
				toast(a, "Rotation is driven by expressions", .Error)
			} else if sel != cur {
				vals := [3][3]f64{{0, 0, 0}, {0, 0, 90}, {90, 0, 0}}
				key := new_coalesce_key(a)
				for i in 0 ..< 3 {
					apply(a, Cmd_Set_Field{field = &xf.rot[i], text = model.format_number(vals[sel][i])}, key)
				}
			}
		}
	} else if rotated {
		show_rot = true
	}
	if show_rot {
		if !is_panel {ui.heading(&a.ui, "Rotation")}
		field_row(a, owner, "rot", {"X", "Y", "Z"}, {&xf.rot[0], &xf.rot[1], &xf.rot[2]}, step = 1)
	} else if !is_panel {
		if ui.button_rect(&a.ui, fid(owner, "rot-open"), ui.next_row(&a.ui, 26), "Rotate...", .Ghost) {a.rot_open = owner}
	}
}

@(private)
Point_Edit :: struct {
	list:  ^[dynamic]model.Sketch_Point,
	index: int,
	add:   bool,
}

@(private)
edit_points :: proc(a: ^App, raw: rawptr) {
	e := (^Point_Edit)(raw)
	d := a.doc
	if !e.add {
		if e.index >= 0 && e.index < len(e.list) {ordered_remove(e.list, e.index)}
		return
	}
	n := len(e.list)
	np: model.Sketch_Point
	if n >= 2 {
		// extend past the last point along the last segment
		p := e.list[n - 2]
		q := e.list[n - 1]
		np = {model.field_num(d, q.x.value + (q.x.value - p.x.value) * 0.5), model.field_num(d, q.y.value + (q.y.value - p.y.value) * 0.5), model.field_num(d, 0)}
	} else {
		np = {model.field_num(d, 0), model.field_num(d, 100), model.field_num(d, 0)}
	}
	append(e.list, np)
}

points_table :: proc(a: ^App, owner: Id, list: ^[dynamic]model.Sketch_Point, xl, yl: string, min_points: int) {
	for &q, i in list {
		r := ui.next_row(&a.ui)
		cols := ui.columns(r, {1, 1, 0.9, 0.28}, 4)
		expr_input(a, cols[0], fid(owner, "ptx", i), xl, &q.x, owner)
		expr_input(a, cols[1], fid(owner, "pty", i), yl, &q.y, owner)
		expr_input(a, cols[2], fid(owner, "ptr", i), "r", &q.r, owner)
		if ui.button_rect(&a.ui, fid(owner, "ptdel", i), cols[3], "×", .Ghost, tip = "Remove point") {
			if len(list) <= min_points {
				toast(a, "Need at least that many points", .Error)
			} else {
				pe := Point_Edit{list = list, index = i}
				apply(a, Cmd_Custom{fn = edit_points, data = &pe})
				return
			}
		}
	}
	if ui.button_rect(&a.ui, fid(owner, "ptadd"), ui.next_row(&a.ui, 26), "+ Point", .Ghost) {
		pe := Point_Edit{list = list, add = true}
		apply(a, Cmd_Custom{fn = edit_points, data = &pe})
	}
}

@(private)
Hole_Edit :: struct {
	holes: ^[dynamic]model.Hole_Def,
	index: int,
	kind:  model.Hole_Kind,
	add:   bool,
	w, h:  f64,
}

@(private)
edit_holes :: proc(a: ^App, raw: rawptr) {
	e := (^Hole_Edit)(raw)
	d := a.doc
	if !e.add {
		if e.index >= 0 && e.index < len(e.holes) {ordered_remove(e.holes, e.index)}
		return
	}
	h := model.Hole_Def {
		kind = e.kind,
		cx   = model.field_num(d, e.w * 0.5),
		cy   = model.field_num(d, e.h * 0.5),
		w    = model.field_num(d, e.kind == .Circle ? 35 : 80),
		h    = model.field_num(d, 30),
		r    = model.field_num(d, e.kind == .Circle ? 0 : 15),
	}
	append(e.holes, h)
}

holes_table :: proc(a: ^App, owner: Id, holes: ^[dynamic]model.Hole_Def, size: [2]f64) {
	for &h, i in holes {
		r := ui.next_row(&a.ui)
		if h.kind == .Circle {
			cols := ui.columns(r, {1, 1, 1, 0.28}, 4)
			expr_input(a, cols[0], fid(owner, "hx", i), "X", &h.cx, owner)
			expr_input(a, cols[1], fid(owner, "hy", i), "Y", &h.cy, owner)
			expr_input(a, cols[2], fid(owner, "hd", i), "Ø", &h.w, owner)
			if ui.button_rect(&a.ui, fid(owner, "hdel", i), cols[3], "×", .Ghost, tip = "Remove hole") {
				he := Hole_Edit{holes = holes, index = i}
				apply(a, Cmd_Custom{fn = edit_holes, data = &he})
				return
			}
		} else {
			cols := ui.columns(r, {1, 1, 0.28}, 4)
			expr_input(a, cols[0], fid(owner, "hx", i), "X", &h.cx, owner)
			expr_input(a, cols[1], fid(owner, "hy", i), "Y", &h.cy, owner)
			if ui.button_rect(&a.ui, fid(owner, "hdel", i), cols[2], "×", .Ghost, tip = "Remove slot") {
				he := Hole_Edit{holes = holes, index = i}
				apply(a, Cmd_Custom{fn = edit_holes, data = &he})
				return
			}
			r2 := ui.next_row(&a.ui)
			c2 := ui.columns(r2, {1, 1, 1, 0.28}, 4)
			expr_input(a, c2[0], fid(owner, "hw", i), "W", &h.w, owner)
			expr_input(a, c2[1], fid(owner, "hh", i), "H", &h.h, owner)
			expr_input(a, c2[2], fid(owner, "hr", i), "r", &h.r, owner)
		}
	}
	r := ui.next_row(&a.ui, 26)
	cols := ui.columns(r, {1, 1})
	if ui.button_rect(&a.ui, fid(owner, "haddc"), cols[0], "+ Round hole", .Ghost) {
		he := Hole_Edit{holes = holes, add = true, kind = .Circle, w = size[0], h = size[1]}
		apply(a, Cmd_Custom{fn = edit_holes, data = &he})
	}
	if ui.button_rect(&a.ui, fid(owner, "hadds"), cols[1], "+ Slot", .Ghost) {
		he := Hole_Edit{holes = holes, add = true, kind = .Slot, w = size[0], h = size[1]}
		apply(a, Cmd_Custom{fn = edit_holes, data = &he})
	}
}

material_picker :: proc(a: ^App, ids: []Id, current: Id) {
	names := make([]string, len(a.doc.materials), context.temp_allocator)
	cur_name := "Mixed"
	for m, i in a.doc.materials {
		names[i] = fmt.tprintf("%s · %smm", m.name, model.format_number(m.thickness))
		if m.id == current {cur_name = names[i]}
	}
	r := ui.next_row(&a.ui, 28)
	// colour swatch
	if m := model.find_material(a.doc, current); m != nil && current != 0 {
		sw := rl.Rectangle{r.x, r.y + 4, 20, 20}
		ui.rounded(sw, 5, {m.color[0], m.color[1], m.color[2], 255})
		r.x += 26
		r.width -= 26
	}
	choice, changed := ui.dropdown(&a.ui, fid(ids[0], "material", len(ids)), r, cur_name, names)
	if changed && choice >= 0 {
		apply(a, Cmd_Set_Material{ids = ids, material = a.doc.materials[choice].id})
	}
}

// ---------------------------------------------------------------------------

part_inspector :: proc(a: ^App, p: ^model.Part) {
	owner := p.id
	name_input(a, owner, &p.name)
	material_picker(a, {p.id}, p.material)
	mat := model.find_material(a.doc, p.material)
	rp := resolved_part(a, p.id)

	switch &s in p.shape {
	case model.Panel:
		ui.heading(&a.ui, "Panel")
		ph := mat != nil ? fmt.tprintf("%s", model.format_number(mat.thickness)) : ""
		if s.profile.kind == .Rect {
			field_row(a, owner, "size", {"W", "D", "T"}, {&s.profile.w, &s.profile.h, &s.thickness}, {"", "", ph})
			edge_rows(a, owner, &s)
			ui.heading(&a.ui, "Corner radii")
			field_row(a, owner, "radii", {"FL", "FR", "BR", "BL"}, {&s.profile.radii[.Front_Left], &s.profile.radii[.Front_Right], &s.profile.radii[.Back_Right], &s.profile.radii[.Back_Left]})
		} else {
			field_row(a, owner, "thick", {"T"}, {&s.thickness}, {ph})
			edge_rows(a, owner, &s)
			ui.label(&a.ui, fmt.tprintf("Free outline · %d points", len(s.profile.points)), .Regular, ui.THEME.text_dim)
		}
		if ui.button(&a.ui, "Edit outline   E", .Normal, "Open the 2D outline editor") {open_editor(a, p.id)}
		ui.heading(&a.ui, "Holes")
		size := [2]f64{s.profile.w.value, s.profile.h.value}
		if rp != nil && s.profile.kind == .Polygon {
			size = {f64(pp_value(rp, 0)), f64(pp_value(rp, 2))}
		}
		holes_table(a, owner, &s.profile.holes, size)
		if mat != nil && mat.grain {
			if ui.checkbox(&a.ui, "Grain along depth", &p.grain_rot) {
				p.grain_rot = !p.grain_rot // checkbox already flipped it; route through apply
				apply(a, Cmd_Toggle{flag = &p.grain_rot})
			}
		}
	case model.Turned:
		ui.heading(&a.ui, "Turned profile (radius, height)")
		points_table(a, owner, &s.points, "r", "h", 2)
		if ui.button(&a.ui, "Edit profile   E") {open_editor(a, p.id)}
		r := ui.next_row(&a.ui)
		ui.text_in(&a.ui, "Smoothness", r, .Regular, ui.THEME.text_dim)
		seg := s.segments
		segs := []int{16, 32, 48, 64}
		idx := 1
		for v, i in segs {if v == seg {idx = i}}
		r2 := ui.Rect{r.x + 90, r.y, r.width - 90, r.height}
		ni := ui.segmented(&a.ui, fid(owner, "segs"), r2, {"16", "32", "48", "64"}, idx)
		if ni != idx {
			Seg :: struct {
				s: ^model.Turned,
				v: int,
			}
			sd := Seg{&s, segs[ni]}
			apply(a, Cmd_Custom{fn = proc(a: ^App, raw: rawptr) {
				x := (^Seg)(raw)
				x.s.segments = x.v
			}, data = &sd})
		}
	case model.Swept:
		ui.heading(&a.ui, "Cross-section")
		field_row(a, owner, "sec", {"W", "H"}, {&s.section.w, &s.section.h})
		field_row(a, owner, "secr", {"r1", "r2", "r3", "r4"}, {&s.section.radii[.Front_Left], &s.section.radii[.Front_Right], &s.section.radii[.Back_Right], &s.section.radii[.Back_Left]})
		ui.heading(&a.ui, "Path (in the floor plane)")
		points_table(a, owner, &s.path, "X", "Y", 2)
		if ui.button(&a.ui, "Edit path   E") {open_editor(a, p.id)}
	}

	transform_rows(a, owner, &p.xf, shape_kind_is_panel(p))
	if ui.checkbox(&a.ui, "Show name in view", &p.label) {
		p.label = !p.label // checkbox already flipped it; route through apply
		apply(a, Cmd_Toggle{flag = &p.label})
	}

	// the parameters that drive this part, editable in place
	ref, ok := model.find_node(a.doc, p.id)
	if ok && ref.parent != nil && ref.parent != a.doc.root {
		g := ref.parent
		ui.heading(&a.ui, fmt.tprintf("Parameters · %s", g.name))
		params_table(a, &g.params, g.id)
		if ui.button(&a.ui, fmt.tprintf("Select %s", g.name), .Ghost) {
			set_selection(a, g.id)
		}
	}
}

// Edge radius, plus which faces get it once a radius is set.
@(private)
edge_rows :: proc(a: ^App, owner: Id, s: ^model.Panel) {
	field_row(a, owner, "edge", {"Rounded edges"}, {&s.edge}, {"0"})
	if s.edge.value <= 0 && model.field_is_literal(s.edge) {return}
	r := ui.next_row(&a.ui, 28)
	cur := int(s.edge_sides)
	sel := ui.segmented(&a.ui, fid(owner, "edge-sides"), r, {"Top & bottom", "Top", "Bottom"}, cur)
	if sel != cur {
		Sides :: struct {
			p: ^model.Panel,
			v: model.Edge_Sides,
		}
		x := Sides{s, model.Edge_Sides(sel)}
		apply(a, Cmd_Custom{fn = proc(a: ^App, raw: rawptr) {v := (^Sides)(raw); v.p.edge_sides = v.v}, data = &x})
	}
}

@(private)
shape_kind_is_panel :: proc(p: ^model.Part) -> bool {
	_, ok := p.shape.(model.Panel)
	return ok
}

group_inspector :: proc(a: ^App, g: ^model.Group) {
	name_input(a, g.id, &g.name)
	ui.label(&a.ui, fmt.tprintf("%d parts · double-click a part to edit it", model.count_parts(g)), .Regular, ui.THEME.text_faint)
	ui.heading(&a.ui, "Parameters")
	params_table(a, &g.params, g.id)
	transform_rows(a, g.id, &g.xf, false)
	ui.space(&a.ui, 6)
	if ui.button(&a.ui, "Ungroup   Shift+G", .Ghost) {apply(a, Cmd_Ungroup{id = g.id})}
}

document_inspector :: proc(a: ^App) {
	d := a.doc
	name_input(a, 0, &d.name)
	ui.label(&a.ui, fmt.tprintf("%d parts · %d errors", len(a.res.parts), a.res.error_count), .Regular, a.res.error_count > 0 ? ui.THEME.error : ui.THEME.text_dim)
	ui.heading(&a.ui, "Document parameters")
	params_table(a, &d.params, 0)
	ui.heading(&a.ui, "Materials")
	for &m in d.materials {
		r := ui.next_row(&a.ui, 28)
		ui.rounded({r.x, r.y + 5, 18, 18}, 2, {m.color[0], m.color[1], m.color[2], 255})
		cols := ui.columns({r.x + 26, r.y, r.width - 26, r.height}, {1.7, 0.8, 1})
		res := ui.text_field(&a.ui, fid(m.id, "mname"), cols[0], m.name, {})
		if res.committed && res.text != m.name {apply(a, Cmd_Rename{name = &m.name, text = res.text})}
		material_number(a, cols[1], fid(m.id, "mt"), "T", &m.thickness)
		material_number(a, cols[2], fid(m.id, "mp"), "€", &m.price_m2)
	}
	ui.label(&a.ui, "T = thickness (mm) · € = price per m2", .Small, ui.THEME.text_faint, 18)
	if ui.button(&a.ui, "+ Material", .Ghost) {
		apply(a, Cmd_Custom{fn = add_material_cmd})
	}
}

@(private)
material_number :: proc(a: ^App, r: rl.Rectangle, wid: ui.Id, label: string, v: ^f64) {
	Set :: struct {
		p: ^f64,
		v: f64,
	}
	set :: proc(a: ^App, raw: rawptr) {s := (^Set)(raw); s.p^ = s.v}
	res := ui.text_field(&a.ui, wid, r, model.format_number(v^), {label = label, scrub = true, value = v^, scrub_step = 1})
	if res.committed {
		if x, ok := model.parse_number(res.text); ok && x >= 0 {
			s := Set{v, x}
			apply(a, Cmd_Custom{fn = set, data = &s})
		} else {
			toast(a, "Not a number", .Error)
		}
	}
	if res.scrubbing && res.value != v^ && res.value >= 0 {
		if res.scrub_start {a.scrub_key = new_coalesce_key(a)}
		s := Set{v, res.value}
		apply(a, Cmd_Custom{fn = set, data = &s}, a.scrub_key)
	}
}

multi_inspector :: proc(a: ^App) {
	ui.label(&a.ui, fmt.tprintf("%d items selected", len(a.selection)), .Semibold)
	parts := make([dynamic]Id, context.temp_allocator)
	collect_parts(a, a.selection[:], &parts)
	if len(parts) > 0 {
		cur := Id(0)
		if p := model.find_part(a.doc, parts[0]); p != nil {cur = p.material}
		for id in parts {
			if p := model.find_part(a.doc, id); p != nil && p.material != cur {cur = 0}
		}
		ui.heading(&a.ui, "Material")
		material_picker(a, parts[:], cur)
	}
	ui.space(&a.ui, 6)
	if ui.button(&a.ui, "Group  G", .Normal) {apply(a, Cmd_Group{ids = a.selection[:]})}
	if ui.button(&a.ui, "Duplicate   Cmd+D", .Normal) {duplicate_selection(a)}
	if ui.button(&a.ui, "Delete", .Danger) {delete_selection(a)}
}

inspector :: proc(a: ^App, r: rl.Rectangle) {
	title := "Document"
	if len(a.selection) == 1 {
		ref, ok := model.find_node(a.doc, a.selection[0])
		if ok {
			switch v in ref.node {
			case ^model.Part:
				kind := [model.Shape_Kind]string{.Panel = "Panel", .Turned = "Turned part", .Swept = "Swept part"}
				title = kind[model.shape_kind(v.shape)]
			case ^model.Group:
				title = "Group"
			}
		}
	} else if len(a.selection) > 1 {
		title = "Selection"
	}
	ui.panel_begin(&a.ui, ui.id("inspector"), r, title)
	switch {
	case len(a.selection) == 0:
		document_inspector(a)
	case len(a.selection) > 1:
		multi_inspector(a)
	case:
		ref, ok := model.find_node(a.doc, a.selection[0])
		if ok {
			switch v in ref.node {
			case ^model.Part:  part_inspector(a, v)
			case ^model.Group: group_inspector(a, v)
			}
		}
	}
	ui.panel_end(&a.ui)
}

@(private)
add_material_cmd :: proc(app: ^App, raw: rawptr) {
	d := app.doc
	model.add_material(d, model.unique_name(d, "Material"), .Wood, 18, {200, 170, 130}, 40)
}
