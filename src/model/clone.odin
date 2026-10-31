package model

// Deep copies. Fields are re-compiled in the destination document so that their
// ASTs point into memory owned by it.

field_copy :: proc(dst: ^Document, f: Expr_Field) -> Expr_Field {
	out := field_make(dst, f.src)
	if !out.parse_err {out.value = f.value}
	if f.err.kind != .None && !out.parse_err {out.err = f.err}
	return out
}

xf_copy :: proc(dst: ^Document, xf: Transform_Def) -> Transform_Def {
	out: Transform_Def
	for i in 0 ..< 3 {
		out.pos[i] = field_copy(dst, xf.pos[i])
		out.rot[i] = field_copy(dst, xf.rot[i])
	}
	return out
}

params_copy :: proc(dst: ^Document, src: []Param) -> [dynamic]Param {
	out := make([dynamic]Param, 0, len(src), dst.allocator)
	for p in src {
		append(&out, Param{name = str(dst, p.name), field = field_copy(dst, p.field)})
	}
	return out
}

points_copy :: proc(dst: ^Document, src: []Sketch_Point) -> [dynamic]Sketch_Point {
	out := make([dynamic]Sketch_Point, 0, len(src), dst.allocator)
	for q in src {
		append(&out, Sketch_Point{field_copy(dst, q.x), field_copy(dst, q.y), field_copy(dst, q.r)})
	}
	return out
}

profile_copy :: proc(dst: ^Document, p: Profile_Def) -> Profile_Def {
	out := Profile_Def {
		kind   = p.kind,
		w      = field_copy(dst, p.w),
		h      = field_copy(dst, p.h),
		points = points_copy(dst, p.points[:]),
		holes  = make([dynamic]Hole_Def, 0, len(p.holes), dst.allocator),
	}
	for c in Corner {out.radii[c] = field_copy(dst, p.radii[c])}
	for h in p.holes {
		append(&out.holes, Hole_Def{kind = h.kind, cx = field_copy(dst, h.cx), cy = field_copy(dst, h.cy), w = field_copy(dst, h.w), h = field_copy(dst, h.h), r = field_copy(dst, h.r)})
	}
	return out
}

shape_copy :: proc(dst: ^Document, s: Shape) -> Shape {
	switch v in s {
	case Panel:
		return Panel{profile = profile_copy(dst, v.profile), thickness = field_copy(dst, v.thickness), edge = field_copy(dst, v.edge)}
	case Turned:
		return Turned{points = points_copy(dst, v.points[:]), segments = v.segments}
	case Swept:
		return Swept{section = profile_copy(dst, v.section), path = points_copy(dst, v.path[:])}
	}
	return nil
}

// fresh_ids: assign new ids (duplicate / paste); otherwise keep ids (snapshots).
part_copy :: proc(dst: ^Document, p: ^Part, fresh_ids: bool) -> ^Part {
	out := new(Part, dst.allocator)
	out^ = {
		id        = fresh_ids ? new_id(dst) : p.id,
		name      = str(dst, p.name),
		material  = p.material,
		xf        = xf_copy(dst, p.xf),
		shape     = shape_copy(dst, p.shape),
		grain_rot = p.grain_rot,
		hidden    = p.hidden,
	}
	return out
}

group_copy :: proc(dst: ^Document, g: ^Group, fresh_ids: bool) -> ^Group {
	out := new(Group, dst.allocator)
	out^ = {
		id       = fresh_ids ? new_id(dst) : g.id,
		name     = str(dst, g.name),
		xf       = xf_copy(dst, g.xf),
		params   = params_copy(dst, g.params[:]),
		children = make([dynamic]Node, 0, len(g.children), dst.allocator),
		expanded = g.expanded,
		hidden   = g.hidden,
	}
	for c in g.children {
		append(&out.children, node_copy(dst, c, fresh_ids))
	}
	return out
}

node_copy :: proc(dst: ^Document, n: Node, fresh_ids: bool) -> Node {
	switch v in n {
	case ^Part:  return part_copy(dst, v, fresh_ids)
	case ^Group: return group_copy(dst, v, fresh_ids)
	}
	return nil
}

doc_clone :: proc(src: ^Document) -> ^Document {
	d := doc_new(false)
	d.name = str(d, src.name)
	d.next_id = src.next_id
	d.params = params_copy(d, src.params[:])
	for m in src.materials {
		mm := m
		mm.name = str(d, m.name)
		append(&d.materials, mm)
	}
	d.root = group_copy(d, src.root, false)
	return d
}
