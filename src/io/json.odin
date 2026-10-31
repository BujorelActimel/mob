// File formats: .mob JSON documents, cut list CSV, SVG part templates, OBJ.
package mobio

import "core:encoding/json"
import "core:fmt"
import "core:os"
import vmem "core:mem/virtual"
import "../model"

FORMAT :: "mob-document"
VERSION :: 1

// On-disk shapes. Every number-ish field is stored as its expression text.
F_Param :: struct {
	name: string,
	expr: string,
}

F_Hole :: struct {
	kind:             string,
	cx, cy, w, h, r: string,
}

F_Profile :: struct {
	kind:   string,
	w, h:   string,
	radii:  [4]string,
	points: [][3]string,
	holes:  []F_Hole,
}

F_Node :: struct {
	type:      string, // group | panel | turned | swept
	id:        u32,
	name:      string,
	pos:       [3]string,
	rot:       [3]string,
	hidden:    bool,
	params:    []F_Param,
	children:  []F_Node,
	expanded:  bool,
	material:  u32,
	grain_rot: bool,
	profile:   F_Profile,
	thickness: string,
	points:    [][3]string,
	segments:  int,
	path:      [][3]string,
}

F_Material :: struct {
	id:        u32,
	name:      string,
	kind:      string,
	thickness: f64,
	color:     [3]u8,
	grain:     bool,
	price_m2:  f64,
	price_m:   f64,
}

F_Doc :: struct {
	format:    string,
	version:   int,
	name:      string,
	units:     string,
	next_id:   u32,
	params:    []F_Param,
	materials: []F_Material,
	root:      F_Node,
}

// ---------------------------------------------------------------------------
// Save

@(private)
to_params :: proc(ps: []model.Param) -> []F_Param {
	out := make([]F_Param, len(ps), context.temp_allocator)
	for p, i in ps {out[i] = {p.name, p.field.src}}
	return out
}

@(private)
to_points :: proc(ps: []model.Sketch_Point) -> [][3]string {
	out := make([][3]string, len(ps), context.temp_allocator)
	for p, i in ps {out[i] = {p.x.src, p.y.src, p.r.src}}
	return out
}

@(private)
to_profile :: proc(p: model.Profile_Def) -> F_Profile {
	out := F_Profile {
		kind   = p.kind == .Rect ? "rect" : "polygon",
		w      = p.w.src,
		h      = p.h.src,
		points = to_points(p.points[:]),
		holes  = make([]F_Hole, len(p.holes), context.temp_allocator),
	}
	for c, i in model.Corner {out.radii[i] = p.radii[c].src}
	for h, i in p.holes {
		out.holes[i] = {h.kind == .Circle ? "circle" : "slot", h.cx.src, h.cy.src, h.w.src, h.h.src, h.r.src}
	}
	return out
}

@(private)
to_node :: proc(n: model.Node) -> F_Node {
	out: F_Node
	xf := model.node_xf(n)
	for i in 0 ..< 3 {
		out.pos[i] = xf.pos[i].src
		out.rot[i] = xf.rot[i].src
	}
	switch v in n {
	case ^model.Group:
		out.type = "group"
		out.id = v.id
		out.name = v.name
		out.hidden = v.hidden
		out.expanded = v.expanded
		out.params = to_params(v.params[:])
		out.children = make([]F_Node, len(v.children), context.temp_allocator)
		for c, i in v.children {out.children[i] = to_node(c)}
	case ^model.Part:
		out.id = v.id
		out.name = v.name
		out.hidden = v.hidden
		out.material = v.material
		out.grain_rot = v.grain_rot
		switch s in v.shape {
		case model.Panel:
			out.type = "panel"
			out.profile = to_profile(s.profile)
			out.thickness = s.thickness.src
		case model.Turned:
			out.type = "turned"
			out.points = to_points(s.points[:])
			out.segments = s.segments
		case model.Swept:
			out.type = "swept"
			out.profile = to_profile(s.section)
			out.path = to_points(s.path[:])
		}
	}
	return out
}

KIND_NAMES := [model.Material_Kind]string {
	.Wood    = "wood",
	.Painted = "painted",
	.Metal   = "metal",
}

marshal_document :: proc(d: ^model.Document, allocator := context.allocator) -> ([]byte, bool) {
	fd := F_Doc {
		format    = FORMAT,
		version   = VERSION,
		name      = d.name,
		units     = "mm",
		next_id   = d.next_id,
		params    = to_params(d.params[:]),
		materials = make([]F_Material, len(d.materials), context.temp_allocator),
		root      = to_node(d.root),
	}
	for m, i in d.materials {
		fd.materials[i] = {m.id, m.name, KIND_NAMES[m.kind], m.thickness, m.color, m.grain, m.price_m2, m.price_m}
	}
	data, err := json.marshal(fd, {pretty = true, use_spaces = true, spaces = 2}, allocator)
	return data, err == nil
}

save_document :: proc(d: ^model.Document, path: string) -> bool {
	data, ok := marshal_document(d, context.temp_allocator)
	if !ok {return false}
	return os.write_entire_file(path, data) == nil
}

// ---------------------------------------------------------------------------
// Load

@(private)
from_points :: proc(d: ^model.Document, ps: [][3]string) -> [dynamic]model.Sketch_Point {
	out := make([dynamic]model.Sketch_Point, 0, len(ps), d.allocator)
	for p in ps {
		append(&out, model.Sketch_Point{model.field_make(d, p[0]), model.field_make(d, p[1]), model.field_make(d, p[2])})
	}
	return out
}

@(private)
from_params :: proc(d: ^model.Document, ps: []F_Param) -> [dynamic]model.Param {
	out := make([dynamic]model.Param, 0, len(ps), d.allocator)
	for p in ps {
		append(&out, model.Param{name = model.str(d, p.name), field = model.field_make(d, p.expr)})
	}
	return out
}

@(private)
from_profile :: proc(d: ^model.Document, fp: F_Profile) -> model.Profile_Def {
	p: model.Profile_Def
	model.profile_init_rect(d, &p, fp.w, fp.h)
	p.kind = fp.kind == "polygon" ? .Polygon : .Rect
	for c, i in model.Corner {model.field_set(d, &p.radii[c], fp.radii[i])}
	p.points = from_points(d, fp.points)
	for h in fp.holes {
		append(&p.holes, model.Hole_Def{
			kind = h.kind == "slot" ? .Slot : .Circle,
			cx = model.field_make(d, h.cx),
			cy = model.field_make(d, h.cy),
			w = model.field_make(d, h.w),
			h = model.field_make(d, h.h),
			r = model.field_make(d, h.r),
		})
	}
	return p
}

@(private)
from_node :: proc(d: ^model.Document, fn: F_Node) -> model.Node {
	xf: model.Transform_Def
	for i in 0 ..< 3 {
		xf.pos[i] = model.field_make(d, fn.pos[i] == "" ? "0" : fn.pos[i])
		xf.rot[i] = model.field_make(d, fn.rot[i] == "" ? "0" : fn.rot[i])
	}
	if fn.type == "group" {
		g := new(model.Group, d.allocator)
		g^ = {
			id       = fn.id,
			name     = model.str(d, fn.name),
			xf       = xf,
			params   = from_params(d, fn.params),
			children = make([dynamic]model.Node, 0, len(fn.children), d.allocator),
			expanded = fn.expanded,
			hidden   = fn.hidden,
		}
		for c in fn.children {
			if n := from_node(d, c); n != nil {append(&g.children, n)}
		}
		return g
	}
	p := new(model.Part, d.allocator)
	p^ = {
		id        = fn.id,
		name      = model.str(d, fn.name),
		material  = fn.material,
		xf        = xf,
		grain_rot = fn.grain_rot,
		hidden    = fn.hidden,
	}
	switch fn.type {
	case "panel":
		p.shape = model.Panel{profile = from_profile(d, fn.profile), thickness = model.field_make(d, fn.thickness)}
	case "turned":
		p.shape = model.Turned{points = from_points(d, fn.points), segments = fn.segments > 0 ? fn.segments : 32}
	case "swept":
		p.shape = model.Swept{section = from_profile(d, fn.profile), path = from_points(d, fn.path)}
	case:
		return nil
	}
	return p
}

unmarshal_document :: proc(data: []byte) -> (d: ^model.Document, err_msg: string) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	fd: F_Doc
	if err := json.unmarshal(data, &fd, allocator = vmem.arena_allocator(&arena)); err != nil {
		return nil, fmt.tprintf("invalid JSON: %v", err)
	}
	if fd.format != FORMAT {return nil, "not a mob document"}
	if fd.version > VERSION {return nil, "document is from a newer version"}

	d = model.doc_new(false)
	d.name = model.str(d, fd.name)
	d.params = from_params(d, fd.params)
	for m in fd.materials {
		kind := model.Material_Kind.Wood
		for name, k in KIND_NAMES {if name == m.kind {kind = k}}
		append(&d.materials, model.Material{
			id = m.id,
			name = model.str(d, m.name),
			kind = kind,
			thickness = m.thickness,
			color = m.color,
			grain = m.grain,
			price_m2 = m.price_m2,
			price_m = m.price_m,
		})
	}
	if len(d.materials) == 0 {model.add_default_materials(d)}
	root, is_group := from_node(d, fd.root).(^model.Group)
	if !is_group {
		model.doc_destroy(d)
		return nil, "document has no root group"
	}
	d.root = root
	// ids must stay unique even for hand-edited files
	max_id := fd.next_id
	bump :: proc(g: ^model.Group, m: ^u32) {
		m^ = max(m^, g.id + 1)
		for c in g.children {
			switch v in c {
			case ^model.Part:  m^ = max(m^, v.id + 1)
			case ^model.Group: bump(v, m)
			}
		}
	}
	bump(d.root, &max_id)
	for m in d.materials {max_id = max(max_id, m.id + 1)}
	d.next_id = max_id
	return d, ""
}

load_document :: proc(path: string) -> (^model.Document, string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return nil, fmt.tprintf("cannot read %s", path)}
	return unmarshal_document(data)
}
