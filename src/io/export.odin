package mobio

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strings"
import "../geom"
import "../model"

// ---------------------------------------------------------------------------
// Cut list

Cut_Row :: struct {
	material:  string,
	kind:      model.Shape_Kind,
	names:     string,
	length:    f64,
	width:     f64,
	thickness: f64,
	qty:       int,
	shaped:    bool, // outline is not a plain rectangle, or has holes
	area_m2:   f64, // per piece, panels
	length_m:  f64, // per piece, turned / swept stock
	cost:      f64, // total for the row
}

@(private)
round1 :: proc(v: f32) -> f64 {return math.round(f64(v) * 10) / 10}

@(private)
polyline_length :: proc(pts: []geom.Vec2) -> f32 {
	l: f32
	for i in 1 ..< len(pts) {l += linalg.length(pts[i] - pts[i - 1])}
	return l
}

cut_list :: proc(res: ^model.Eval_Result, allocator := context.allocator) -> []Cut_Row {
	rows := make([dynamic]Cut_Row, allocator)
	names := make([dynamic][dynamic]string, context.temp_allocator)
	for rp in res.parts {
		r := Cut_Row {
			material = rp.material.name,
			kind     = rp.kind,
			qty      = 1,
		}
		switch rp.kind {
		case .Panel:
			b := geom.contour_bounds(rp.profile.outer)
			u := b.max.x - b.min.x
			v := b.max.y - b.min.y
			along, across := u, v
			if rp.part.grain_rot {along, across = v, u}
			if !rp.material.grain && across > along {along, across = across, along}
			r.length = round1(along)
			r.width = round1(across)
			r.thickness = round1(rp.thickness)
			r.shaped = !geom.contour_is_rect(rp.profile.outer) || len(rp.profile.holes) > 0
			r.area_m2 = f64(u) * f64(v) / 1e6
			r.cost = r.area_m2 * rp.material.price_m2
		case .Turned:
			lo, hi: f32 = max(f32), min(f32)
			rmax: f32
			for p in rp.line {
				lo = min(lo, p.y)
				hi = max(hi, p.y)
				rmax = max(rmax, p.x)
			}
			r.length = round1(hi - lo)
			r.width = round1(2 * rmax)
			r.thickness = r.width
			r.shaped = true
			r.length_m = r.length / 1000
			r.cost = r.length_m * rp.material.price_m
		case .Swept:
			b := geom.contour_bounds(rp.profile.outer)
			r.length = round1(polyline_length(rp.line))
			r.width = round1(b.max.x - b.min.x)
			r.thickness = round1(b.max.y - b.min.y)
			r.shaped = true
			r.length_m = r.length / 1000
			r.cost = r.length_m * rp.material.price_m
		}
		merged := false
		for &e, i in rows {
			if e.material == r.material && e.kind == r.kind && e.length == r.length && e.width == r.width && e.thickness == r.thickness && e.shaped == r.shaped {
				e.qty += 1
				e.cost += r.cost
				if !slice.contains(names[i][:], rp.part.name) {append(&names[i], rp.part.name)}
				merged = true
				break
			}
		}
		if !merged {
			append(&rows, r)
			n := make([dynamic]string, context.temp_allocator)
			append(&n, rp.part.name)
			append(&names, n)
		}
	}
	for &r, i in rows {
		r.names = strings.join(names[i][:], ", ", allocator)
	}
	slice.sort_by(rows[:], proc(a, b: Cut_Row) -> bool {
		if a.material != b.material {return a.material < b.material}
		if a.kind != b.kind {return a.kind < b.kind}
		return a.length * a.width > b.length * b.width
	})
	return rows[:]
}

@(private)
csv_quote :: proc(s: string) -> string {
	if strings.contains_any(s, ",\"\n") {
		q, _ := strings.replace_all(s, "\"", "\"\"", context.temp_allocator)
		return fmt.tprintf("\"%s\"", q)
	}
	return s
}

cut_list_csv :: proc(rows: []Cut_Row, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Material,Type,Parts,Qty,Length (mm),Width (mm),Thickness (mm),Shaped,Area per piece (m2),Cost\n")
	kind := [model.Shape_Kind]string{.Panel = "panel", .Turned = "turned", .Swept = "swept"}
	for r in rows {
		fmt.sbprintf(&b, "%s,%s,%s,%d,%s,%s,%s,%s,%.3f,%.2f\n", csv_quote(r.material), kind[r.kind], csv_quote(r.names), r.qty,
			model.format_number(r.length), model.format_number(r.width), model.format_number(r.thickness),
			r.shaped ? "yes" : "no", r.area_m2, r.cost)
	}
	return strings.to_string(b)
}

write_cut_list :: proc(res: ^model.Eval_Result, path: string) -> bool {
	rows := cut_list(res, context.temp_allocator)
	return os.write_entire_file(path, transmute([]byte)cut_list_csv(rows, context.temp_allocator)) == nil
}

// ---------------------------------------------------------------------------
// SVG: every panel outline at 1:1 (user units are millimetres).

@(private)
svg_contour :: proc(b: ^strings.Builder, c: geom.Contour, ox, oy, top: f32) {
	// flip y: svg y grows downward
	X :: proc(p: geom.Vec2, ox: f32) -> f32 {return p.x + ox}
	Y :: proc(p: geom.Vec2, oy, top: f32) -> f32 {return oy + (top - p.y)}
	if len(c.segs) == 0 {return}
	s0 := geom.seg_start(c.segs[0])
	fmt.sbprintf(b, "M%.3f %.3f", X(s0, ox), Y(s0, oy, top))
	for s in c.segs {
		switch v in s {
		case geom.Line:
			fmt.sbprintf(b, " L%.3f %.3f", X(v.b, ox), Y(v.b, oy, top))
		case geom.Arc:
			// split long arcs so every piece is < 180 degrees
			pieces := int(math.ceil(abs(v.sweep) / (math.PI * 0.99)))
			for k in 0 ..< pieces {
				e := geom.arc_point(v, f32(k + 1) / f32(pieces))
				sweep_flag := v.sweep > 0 ? 0 : 1 // y is flipped, which mirrors the turning direction
				fmt.sbprintf(b, " A%.3f %.3f 0 0 %d %.3f %.3f", v.r, v.r, sweep_flag, X(e, ox), Y(e, oy, top))
			}
		}
	}
	strings.write_string(b, " Z")
}

// Writes the outlines of the given parts (all panels when ids is empty).
panels_svg :: proc(res: ^model.Eval_Result, ids: []model.Id, allocator := context.allocator) -> string {
	GAP :: 30
	LABEL :: 14
	Item :: struct {
		rp: ^model.Resolved_Part,
		b:  geom.Bounds2,
	}
	items := make([dynamic]Item, context.temp_allocator)
	for &rp in res.parts {
		if rp.kind != .Panel {continue}
		if len(ids) > 0 && !slice.contains(ids, rp.id) {continue}
		append(&items, Item{&rp, geom.contour_bounds(rp.profile.outer, 0.01)})
	}
	width: f32 = 0
	height: f32 = GAP
	for it in items {
		width = max(width, it.b.max.x - it.b.min.x)
		height += it.b.max.y - it.b.min.y + LABEL + GAP
	}
	width += 2 * GAP
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%.3fmm\" height=\"%.3fmm\" viewBox=\"0 0 %.3f %.3f\">\n", width, height, width, height)
	strings.write_string(&b, "<!-- 1 user unit = 1 mm. Outlines are exact lines and arcs. -->\n")
	y: f32 = GAP
	for it in items {
		w := it.b.max.x - it.b.min.x
		h := it.b.max.y - it.b.min.y
		fmt.sbprintf(&b, "<text x=\"%.1f\" y=\"%.1f\" font-family=\"sans-serif\" font-size=\"8\" fill=\"#444\">%s — %s x %s x %s mm</text>\n",
			f32(GAP), y + 8, it.rp.part.name, model.format_number(f64(w)), model.format_number(f64(h)), model.format_number(f64(it.rp.thickness)))
		y += LABEL
		ox := GAP - it.b.min.x
		strings.write_string(&b, "<path fill=\"none\" stroke=\"#d02020\" stroke-width=\"0.25\" fill-rule=\"evenodd\" d=\"")
		svg_contour(&b, it.rp.profile.outer, ox, y, it.b.max.y)
		for hole in it.rp.profile.holes {
			strings.write_string(&b, " ")
			svg_contour(&b, hole, ox, y, it.b.max.y)
		}
		strings.write_string(&b, "\"/>\n")
		y += h + GAP
	}
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

write_svg :: proc(res: ^model.Eval_Result, ids: []model.Id, path: string) -> bool {
	s := panels_svg(res, ids, context.temp_allocator)
	return os.write_entire_file(path, transmute([]byte)s) == nil
}

// ---------------------------------------------------------------------------
// OBJ (world space, metres would be conventional but we keep millimetres)

objs :: proc(res: ^model.Eval_Result, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# mob export, units: mm\n")
	vbase := 1
	for rp in res.parts {
		m: geom.Mesh_Data
		geom.mesh_init(&m, context.temp_allocator)
		model.build_mesh(rp, &m)
		name, _ := strings.replace_all(rp.part.name, " ", "_", context.temp_allocator)
		fmt.sbprintf(&b, "o %s_%d\n", name, rp.id)
		nm := linalg.matrix3_from_matrix4(rp.world)
		for p in m.positions {
			w := rp.world * [4]f32{p.x, p.y, p.z, 1}
			fmt.sbprintf(&b, "v %.4f %.4f %.4f\n", w.x, w.y, w.z)
		}
		for n in m.normals {
			w := linalg.normalize(nm * n)
			fmt.sbprintf(&b, "vn %.4f %.4f %.4f\n", w.x, w.y, w.z)
		}
		for k := 0; k + 2 < len(m.positions); k += 3 {
			i := vbase + k
			fmt.sbprintf(&b, "f %d//%d %d//%d %d//%d\n", i, i, i + 1, i + 1, i + 2, i + 2)
		}
		vbase += len(m.positions)
	}
	return strings.to_string(b)
}

write_obj :: proc(res: ^model.Eval_Result, path: string) -> bool {
	s := objs(res, context.temp_allocator)
	return os.write_entire_file(path, transmute([]byte)s) == nil
}
