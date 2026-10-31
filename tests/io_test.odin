package tests

import "core:strings"
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
