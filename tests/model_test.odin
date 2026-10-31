package tests

import "core:math/linalg"
import "core:testing"
import "../src/expr"
import "../src/geom"
import "../src/model"

@(private = "file")
panel_size :: proc(rp: model.Resolved_Part) -> (w, h: f32) {
	b := geom.contour_bounds(rp.profile.outer)
	return b.max.x - b.min.x, b.max.y - b.min.y
}

@(private = "file")
find_rp :: proc(r: ^model.Eval_Result, name: string) -> ^model.Resolved_Part {
	for &rp in r.parts {
		if rp.part.name == name {return &rp}
	}
	return nil
}

@(test)
test_nested_group_params :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	model.add_param(d, &d.params, "t", "18")
	outer := model.new_group(d, "Outer")
	model.add_param(d, &outer.params, "W", "800")
	inner := model.new_group(d, "Inner")
	model.add_param(d, &inner.params, "inner_w", "W - 2*t")
	shelf := model.new_panel(d, "Shelf", "inner_w", "300")
	model.field_set(d, &shelf.xf.pos[1], "t + 100")
	append(&inner.children, shelf)
	append(&outer.children, inner)
	append(&d.root.children, outer)

	res: model.Eval_Result
	defer model.eval_result_destroy(&res)
	model.evaluate(d, &res)
	testing.expect_value(t, res.error_count, 0)
	rp := find_rp(&res, "Shelf")
	testing.expect(t, rp != nil)
	w, h := panel_size(rp^)
	testing.expect(t, abs(w - 764) < 1e-3)
	testing.expect(t, abs(h - 300) < 1e-3)
	testing.expect(t, abs(rp.thickness - 18) < 1e-3) // material default
	origin := rp.world * [4]f32{0, 0, 0, 1}
	testing.expect(t, abs(origin.y - 118) < 1e-3)

	// changing an outer param flows down
	p := model.find_param(outer.params[:], "W")
	model.field_set(d, &p.field, "1000")
	model.evaluate(d, &res)
	w, _ = panel_size(find_rp(&res, "Shelf")^)
	testing.expect(t, abs(w - 964) < 1e-3)
}

@(test)
test_cycles_and_unknown :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	g := model.new_group(d, "G")
	a := model.add_param(d, &g.params, "a", "b + 1")
	b := model.add_param(d, &g.params, "b", "a * 2")
	c := model.add_param(d, &g.params, "c", "nope + 1")
	append(&d.root.children, g)
	res: model.Eval_Result
	defer model.eval_result_destroy(&res)
	model.evaluate(d, &res)
	testing.expect(t, res.error_count >= 3)
	a = model.find_param(g.params[:], "a")
	b = model.find_param(g.params[:], "b")
	c = model.find_param(g.params[:], "c")
	testing.expect(t, a.field.err.kind == .Cycle || a.field.err.kind == .Bad_Ref)
	testing.expect(t, b.field.err.kind == .Cycle || b.field.err.kind == .Bad_Ref)
	testing.expect_value(t, c.field.err.kind, expr.Error_Kind.Unknown_Name)
}

@(test)
test_vinyl_shelf_resize :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	g := model.template_vinyl_corner(d)
	append(&d.root.children, g)
	res: model.Eval_Result
	defer model.eval_result_destroy(&res)
	model.evaluate(d, &res)
	testing.expect_value(t, res.error_count, 0)
	testing.expect_value(t, len(res.parts), 7)

	side_w, _ := panel_size(find_rp(&res, "Side")^)
	testing.expect(t, abs(side_w - (4 * 330 + 5 * 18)) < 1e-3)
	top := find_rp(&res, "Shelf 5")
	y := (top.world * [4]f32{0, 0, 0, 1}).y
	testing.expect(t, abs(y - 4 * (330 + 18)) < 1e-3)
	// rounded corner present on the shelf outline
	arcs := 0
	for s in top.profile.outer.segs {
		if a, ok := s.(geom.Arc); ok {
			arcs += 1
			testing.expect(t, abs(a.r - 120) < 1e-3)
		}
	}
	testing.expect_value(t, arcs, 1)

	// resize by one parameter
	hc := model.find_param(g.params[:], "H_comp")
	model.field_set(d, &hc.field, "350")
	model.evaluate(d, &res)
	side_w, _ = panel_size(find_rp(&res, "Side")^)
	testing.expect(t, abs(side_w - (4 * 350 + 5 * 18)) < 1e-3)
	back_w, back_h := panel_size(find_rp(&res, "Back")^)
	testing.expect(t, abs(back_h - (4 * 350 + 5 * 18)) < 1e-3)
	testing.expect(t, abs(back_w - 420) < 1e-3)
	for name, i in ([]string{"Shelf 1", "Shelf 2", "Shelf 3", "Shelf 4", "Shelf 5"}) {
		rp := find_rp(&res, name)
		y = (rp.world * [4]f32{0, 0, 0, 1}).y
		testing.expectf(t, abs(y - f32(i) * (350 + 18)) < 1e-3, "%s at %v", name, y)
	}
}

@(test)
test_solve_field_through_param :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	g := model.new_group(d, "G")
	model.add_param(d, &g.params, "W", "800")
	model.add_param(d, &g.params, "t", "18")
	p := model.new_panel(d, "Shelf", "W - 2*t", "300")
	append(&g.children, p)
	append(&d.root.children, g)
	path := model.group_path(d, p.id)
	panel := &p.shape.(model.Panel)
	res := model.solve_field(d, path[:], &panel.profile.w, 900)
	testing.expect(t, res.ok)
	testing.expect_value(t, res.param, "W")
	testing.expect_value(t, model.find_param(g.params[:], "W").field.value, 936)
	// literal fields are set directly
	res = model.solve_field(d, path[:], &panel.profile.h, 250)
	testing.expect(t, res.ok && res.param == "")
	testing.expect_value(t, panel.profile.h.src, "250")
}

@(test)
test_clone_document :: proc(t: ^testing.T) {
	d := model.doc_new()
	g := model.template_table(d)
	append(&d.root.children, g)
	c := model.doc_clone(d)
	model.doc_destroy(d)
	defer model.doc_destroy(c)
	res: model.Eval_Result
	defer model.eval_result_destroy(&res)
	model.evaluate(c, &res)
	testing.expect_value(t, res.error_count, 0)
	testing.expect_value(t, len(res.parts), 5)
	m: geom.Mesh_Data
	geom.mesh_init(&m, context.temp_allocator)
	for rp in res.parts {model.build_mesh(rp, &m)}
	testing.expect(t, len(m.positions) > 100)
	lo, hi := geom.mesh_bounds(m)
	_ = linalg.length(hi - lo)
}

@(test)
test_solve_into_negative :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	p := model.new_panel(d, "P", "600", "300")
	append(&d.root.children, p)
	path := model.group_path(d, p.id)
	for target in ([]f64{50, -5, -120, 30, -0.5}) {
		r := model.solve_field(d, path[:], &p.xf.pos[0], target)
		testing.expectf(t, r.ok, "solve to %v failed: %s", target, r.msg)
		testing.expect_value(t, p.xf.pos[0].value, target)
		testing.expect(t, model.field_is_literal(p.xf.pos[0]))
	}
}
