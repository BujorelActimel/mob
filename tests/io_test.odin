package tests

import "core:strings"
import "../src/geom"
import "core:testing"
import mobio "../src/io"
import "../src/model"

@(test)
test_json_roundtrip :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	append(&d.root.children, model.template_vinyl_corner(d))
	append(&d.root.children, model.template_table(d))
	sw := model.new_swept(d, "Rail")
	append(&d.root.children, sw)
	data, ok := mobio.marshal_document(d, context.temp_allocator)
	testing.expect(t, ok)

	d2, msg := mobio.unmarshal_document(data)
	testing.expectf(t, d2 != nil, "load failed: %s", msg)
	defer model.doc_destroy(d2)
	a, b: model.Eval_Result
	defer model.eval_result_destroy(&a)
	defer model.eval_result_destroy(&b)
	model.evaluate(d, &a)
	model.evaluate(d2, &b)
	testing.expect_value(t, b.error_count, 0)
	testing.expect_value(t, len(b.parts), len(a.parts))
	for i in 0 ..< len(a.parts) {
		testing.expect_value(t, b.parts[i].hash, a.parts[i].hash)
		testing.expect_value(t, b.parts[i].id, a.parts[i].id)
	}
	testing.expect(t, d2.next_id >= d.next_id)
	// expressions are stored as source text
	testing.expect(t, strings.contains(string(data), "\"4*H_comp + 5*t\""))
}

@(test)
test_cut_list_and_svg :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	append(&d.root.children, model.template_vinyl_corner(d))
	res: model.Eval_Result
	defer model.eval_result_destroy(&res)
	model.evaluate(d, &res)
	rows := mobio.cut_list(&res, context.temp_allocator)
	// back, side, and 5 identical shaped shelves
	testing.expect_value(t, len(rows), 3)
	shelves := 0
	for r in rows {
		if r.qty == 5 {
			shelves += 1
			testing.expect(t, r.shaped)
			testing.expect_value(t, r.length, 402) // W - t along the grain
			testing.expect_value(t, r.width, 362)
			testing.expect_value(t, r.thickness, 18)
		}
	}
	testing.expect_value(t, shelves, 1)
	csv := mobio.cut_list_csv(rows, context.temp_allocator)
	testing.expect(t, strings.has_prefix(csv, "Material,"))
	testing.expect_value(t, strings.count(csv, "\n"), 4)

	ids := []model.Id{res.parts[2].id} // Shelf 1
	svg := mobio.panels_svg(&res, ids, context.temp_allocator)
	testing.expect(t, strings.contains(svg, "width=\"462.000mm\""))
	testing.expect(t, strings.contains(svg, " A120.000 120.000 0 0 0 "))
}

@(test)
test_rounded_edges_model :: proc(t: ^testing.T) {
	d := model.doc_new()
	defer model.doc_destroy(d)
	g := model.new_group(d, "G")
	model.add_param(d, &g.params, "e", "3")
	p := model.new_panel(d, "Board", "400", "300")
	panel := &p.shape.(model.Panel)
	model.field_set(d, &panel.edge, "e")
	panel.edge_sides = .Bottom
	q := model.new_panel(d, "Too round", "400", "300", "10")
	qp := &q.shape.(model.Panel)
	model.field_set(d, &qp.edge, "8")
	append(&g.children, p, q)
	append(&d.root.children, g)

	res: model.Eval_Result
	defer model.eval_result_destroy(&res)
	model.evaluate(d, &res)
	testing.expect_value(t, res.error_count, 0)
	testing.expect_value(t, res.parts[0].edge, 3)
	testing.expect(t, res.parts[1].edge < 5) // clamped below half the thickness
	arcs := 0
	for s in res.parts[0].profile.outer.segs {
		if a, ok := s.(geom.Arc); ok {
			arcs += 1
			testing.expect(t, abs(a.r - 3) < 1e-4)
		}
	}
	testing.expect_value(t, arcs, 4) // corners raised to the edge radius

	rows := mobio.cut_list(&res, context.temp_allocator)
	board := rows[0].names == "Board" ? rows[0] : rows[1]
	testing.expect(t, !board.shaped)
	testing.expect_value(t, board.edge, 3)
	csv := mobio.cut_list_csv(rows, context.temp_allocator)
	testing.expect(t, strings.contains(csv, "Edge radius (mm),Rounded edges"))
	testing.expect(t, strings.contains(csv, ",3,bottom only,"))

	data, _ := mobio.marshal_document(d, context.temp_allocator)
	d2, _ := mobio.unmarshal_document(data)
	defer model.doc_destroy(d2)
	res2: model.Eval_Result
	defer model.eval_result_destroy(&res2)
	model.evaluate(d2, &res2)
	testing.expect_value(t, res2.parts[0].edge, 3)
	testing.expect_value(t, res2.parts[0].edge_sides, model.Edge_Sides.Bottom)
	testing.expect_value(t, res2.parts[0].hash, res.parts[0].hash)
}
