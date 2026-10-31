package model

import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import vmem "core:mem/virtual"
import "../expr"
import "../geom"

Mat4 :: linalg.Matrix4f32

// Arc tolerance (mm) used for turned profiles and sweep paths.
LINE_TOL :: 0.1

Resolved_Part :: struct {
	id:        Id,
	part:      ^Part,
	parent:    ^Group,
	material:  Material,
	world:     Mat4,
	kind:      Shape_Kind,
	profile:   geom.Profile2D, // panel outline / swept cross-section
	thickness: f32,
	line:      []geom.Vec2, // turned half-profile (r, h) / swept path, tessellated
	segments:  int,
	hash:      u64,
	errors:    int,
}

Resolved_Group :: struct {
	id:     Id,
	group:  ^Group,
	parent: Id,
	world:  Mat4,
}

Eval_Result :: struct {
	arena:       vmem.Arena,
	allocator:   mem.Allocator,
	parts:       [dynamic]Resolved_Part,
	groups:      [dynamic]Resolved_Group,
	error_count: int,
	initialized: bool,
}

eval_result_destroy :: proc(r: ^Eval_Result) {
	if r.initialized {vmem.arena_destroy(&r.arena)}
	r^ = {}
}

// ---------------------------------------------------------------------------
// Scopes

Scope :: struct {
	params: []Param,
	values: []f64,
	errs:   []expr.Error,
	state:  []u8, // 0 = todo, 1 = in progress, 2 = done
	parent: ^Scope,
}

scope_make :: proc(params: []Param, parent: ^Scope, allocator := context.temp_allocator) -> ^Scope {
	s := new(Scope, allocator)
	s.params = params
	s.values = make([]f64, len(params), allocator)
	s.errs = make([]expr.Error, len(params), allocator)
	s.state = make([]u8, len(params), allocator)
	s.parent = parent
	return s
}

@(private)
scope_ensure :: proc(s: ^Scope, i: int) -> (f64, expr.Error) {
	name := s.params[i].name
	switch s.state[i] {
	case 1:
		return 0, {kind = .Cycle, name = name}
	case 2:
		if s.errs[i].kind != .None {return 0, {kind = .Bad_Ref, name = name}}
		return s.values[i], {}
	}
	s.state[i] = 1
	v, err := field_eval_pure(s.params[i].field, s)
	s.values[i] = v
	s.errs[i] = err
	s.state[i] = 2
	if err.kind != .None {return 0, {kind = .Bad_Ref, name = name}}
	return v, {}
}

@(private)
scope_lookup :: proc(data: rawptr, name: string) -> (f64, expr.Error) {
	for s := (^Scope)(data); s != nil; s = s.parent {
		for p, i in s.params {
			if p.name == name {
				if s.state[i] == 1 {return 0, {kind = .Cycle, name = name}}
				return scope_ensure(s, i)
			}
		}
	}
	return 0, {kind = .Unknown_Name, name = name}
}

resolver :: proc(s: ^Scope) -> expr.Resolver {
	return {data = s, lookup = scope_lookup}
}

// Evaluates without mutating the field.
field_eval_pure :: proc(f: Expr_Field, s: ^Scope) -> (f64, expr.Error) {
	if f.src == "" {return 0, {kind = .Empty}}
	if f.parse_err {return f.value, f.err}
	return expr.eval(f.ast, resolver(s))
}

// Scope chain for nodes inside `path` (root first). Returns the innermost scope.
build_chain :: proc(d: ^Document, path: []^Group, allocator := context.temp_allocator) -> ^Scope {
	s := scope_make(d.params[:], nil, allocator)
	for g in path {s = scope_make(g.params[:], s, allocator)}
	return s
}

// ---------------------------------------------------------------------------
// Evaluation

@(private)
Ctx :: struct {
	d:      ^Document,
	out:    ^Eval_Result,
	errors: int,
}

// Evaluates a field in place: stores value/error. Empty fields yield `fallback`.
@(private)
ev :: proc(c: ^Ctx, f: ^Expr_Field, s: ^Scope, fallback: f64 = 0) -> f64 {
	if f.src == "" {
		f.err = {}
		f.value = fallback
		return fallback
	}
	if f.parse_err {
		c.errors += 1
		return f.value
	}
	v, err := expr.eval(f.ast, resolver(s))
	f.err = err
	if err.kind != .None {
		c.errors += 1
		return f.value
	}
	f.value = v
	return v
}

@(private)
eval_params :: proc(c: ^Ctx, s: ^Scope) {
	for i in 0 ..< len(s.params) {
		scope_ensure(s, i)
		f := &s.params[i].field
		f.err = s.errs[i]
		if f.parse_err {
			c.errors += 1
		} else if s.errs[i].kind != .None {
			c.errors += 1
		} else {
			f.value = s.values[i]
		}
	}
}

xf_local :: proc(pos, rot_deg: [3]f32) -> Mat4 {
	r := rot_deg * (math.PI / 180)
	return linalg.matrix4_translate_f32(pos) * linalg.matrix4_rotate_f32(r.z, {0, 0, 1}) * linalg.matrix4_rotate_f32(r.y, {0, 1, 0}) * linalg.matrix4_rotate_f32(r.x, {1, 0, 0})
}

@(private)
eval_xf :: proc(c: ^Ctx, xf: ^Transform_Def, s: ^Scope) -> Mat4 {
	pos, rot: [3]f32
	for i in 0 ..< 3 {
		pos[i] = f32(ev(c, &xf.pos[i], s))
		rot[i] = f32(ev(c, &xf.rot[i], s))
	}
	return xf_local(pos, rot)
}

evaluate :: proc(d: ^Document, out: ^Eval_Result) {
	if !out.initialized {
		_ = vmem.arena_init_growing(&out.arena)
		out.allocator = vmem.arena_allocator(&out.arena)
		out.initialized = true
	} else {
		vmem.arena_free_all(&out.arena)
	}
	out.parts = make([dynamic]Resolved_Part, out.allocator)
	out.groups = make([dynamic]Resolved_Group, out.allocator)
	out.error_count = 0

	c := Ctx{d = d, out = out}
	doc_scope := scope_make(d.params[:], nil)
	eval_params(&c, doc_scope)
	walk_group(&c, d.root, doc_scope, 1, 0)
	out.error_count = c.errors
}

@(private)
walk_group :: proc(c: ^Ctx, g: ^Group, parent_scope: ^Scope, parent_world: Mat4, parent_id: Id) {
	local := eval_xf(c, &g.xf, parent_scope)
	world := parent_world * local
	s := scope_make(g.params[:], parent_scope)
	eval_params(c, s)
	append(&c.out.groups, Resolved_Group{id = g.id, group = g, parent = parent_id, world = world})
	for child in g.children {
		switch v in child {
		case ^Part:
			if !v.hidden && !g.hidden {resolve_part(c, v, g, s, world)}
		case ^Group:
			if !g.hidden {walk_group(c, v, s, world, g.id)}
		}
	}
}

@(private)
resolve_profile :: proc(c: ^Ctx, p: ^Profile_Def, s: ^Scope, offset: geom.Vec2 = {}) -> geom.Profile2D {
	a := c.out.allocator
	prof: geom.Profile2D
	prof.holes = make([dynamic]geom.Contour, a)
	switch p.kind {
	case .Rect:
		w := f32(max(ev(c, &p.w, s), 0.1))
		h := f32(max(ev(c, &p.h, s), 0.1))
		pts := []geom.Vec2{{0, 0}, {w, 0}, {w, h}, {0, h}}
		for &q in pts {q += offset}
		radii: [4]f32
		for corner, i in Corner {radii[i] = f32(max(ev(c, &p.radii[corner], s), 0))}
		prof.outer = geom.contour_from_polygon(pts, radii[:], true, a)
	case .Polygon:
		n := len(p.points)
		pts := make([]geom.Vec2, n, context.temp_allocator)
		radii := make([]f32, n, context.temp_allocator)
		for &q, i in p.points {
			pts[i] = {f32(ev(c, &q.x, s)), f32(ev(c, &q.y, s))} + offset
			radii[i] = f32(max(ev(c, &q.r, s), 0))
		}
		if n < 3 {
			pts = []geom.Vec2{{0, 0}, {10, 0}, {10, 10}}
			radii = nil
		}
		prof.outer = geom.contour_from_polygon(pts, radii, true, a)
		pts2 := make([dynamic]geom.Vec2, context.temp_allocator)
		geom.tessellate_contour(prof.outer, 0.5, &pts2)
		if geom.polygon_area(pts2[:]) < 0 {geom.contour_reverse(&prof.outer)}
	}
	for &h in p.holes {
		cx := f32(ev(c, &h.cx, s)) + offset.x
		cy := f32(ev(c, &h.cy, s)) + offset.y
		switch h.kind {
		case .Circle:
			dia := f32(ev(c, &h.w, s))
			if dia > 0.1 {append(&prof.holes, geom.contour_circle({cx, cy}, dia * 0.5, false, a))}
		case .Slot:
			hw := f32(ev(c, &h.w, s)) * 0.5
			hh := f32(ev(c, &h.h, s)) * 0.5
			r := f32(max(ev(c, &h.r, s), 0))
			if hw > 0.05 && hh > 0.05 {
				pts := []geom.Vec2{{cx - hw, cy - hh}, {cx + hw, cy - hh}, {cx + hw, cy + hh}, {cx - hw, cy + hh}}
				rr := []f32{r, r, r, r}
				hc := geom.contour_from_polygon(pts, rr, true, a)
				geom.contour_reverse(&hc)
				append(&prof.holes, hc)
			}
		}
	}
	return prof
}

@(private)
resolve_polyline :: proc(c: ^Ctx, pts_def: []Sketch_Point, s: ^Scope) -> []geom.Vec2 {
	n := len(pts_def)
	pts := make([]geom.Vec2, n, context.temp_allocator)
	radii := make([]f32, n, context.temp_allocator)
	for &q, i in pts_def {
		pts[i] = {f32(ev(c, &q.x, s)), f32(ev(c, &q.y, s))}
		radii[i] = f32(max(ev(c, &q.r, s), 0))
	}
	if n < 2 {return nil}
	contour := geom.contour_from_polygon(pts, radii, false, context.temp_allocator)
	out := make([dynamic]geom.Vec2, c.out.allocator)
	geom.tessellate_contour(contour, LINE_TOL, &out)
	return out[:]
}

@(private)
resolve_part :: proc(c: ^Ctx, p: ^Part, parent: ^Group, s: ^Scope, parent_world: Mat4) {
	before := c.errors
	local := eval_xf(c, &p.xf, s)
	mat := find_material(c.d, p.material)
	rp := Resolved_Part {
		id     = p.id,
		part   = p,
		parent = parent,
		world  = parent_world * local,
		kind   = shape_kind(p.shape),
	}
	if mat != nil {rp.material = mat^}
	switch &sh in p.shape {
	case Panel:
		fallback := mat != nil ? mat.thickness : 18
		rp.thickness = f32(max(ev(c, &sh.thickness, s, fallback), 0.1))
		rp.profile = resolve_profile(c, &sh.profile, s)
	case Turned:
		rp.line = resolve_polyline(c, sh.points[:], s)
		rp.segments = clamp(sh.segments, 8, 128)
	case Swept:
		w := max(ev(c, &sh.section.w, s), 0.1)
		rp.profile = resolve_profile(c, &sh.section, s, {f32(-w * 0.5), 0})
		rp.line = resolve_polyline(c, sh.path[:], s)
	}
	rp.errors = c.errors - before
	rp.hash = shape_hash(rp)
	append(&c.out.parts, rp)
}

shape_hash :: proc(rp: Resolved_Part) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: ^u64, data: []byte) {
		h^ = hash.fnv64a(data, h^)
	}
	k := rp.kind
	mix(&h, mem.ptr_to_bytes(&k))
	t := rp.thickness
	mix(&h, mem.ptr_to_bytes(&t))
	sg := rp.segments
	mix(&h, mem.ptr_to_bytes(&sg))
	contour :: proc(h: ^u64, c: geom.Contour) {
		for seg in c.segs {
			switch v in seg {
			case geom.Line:
				x := v
				tag: u8 = 1
				mix(h, mem.ptr_to_bytes(&tag))
				mix(h, mem.ptr_to_bytes(&x))
			case geom.Arc:
				x := v
				tag: u8 = 2
				mix(h, mem.ptr_to_bytes(&tag))
				mix(h, mem.ptr_to_bytes(&x))
			}
		}
		sep: u8 = 0xff
		mix(h, mem.ptr_to_bytes(&sep))
	}
	contour(&h, rp.profile.outer)
	for hc in rp.profile.holes {contour(&h, hc)}
	if len(rp.line) > 0 {mix(&h, mem.slice_to_bytes(rp.line))}
	return h
}

// Builds the local-space mesh of a resolved part.
build_mesh :: proc(rp: Resolved_Part, m: ^geom.Mesh_Data, tol: f32 = 0.15) {
	switch rp.kind {
	case .Panel:
		geom.extrude_profile(rp.profile, rp.thickness, tol, m)
	case .Turned:
		geom.lathe(rp.line, rp.segments, m)
	case .Swept:
		sec := make([dynamic]geom.Vec2, context.temp_allocator)
		geom.tessellate_contour(rp.profile.outer, tol, &sec)
		geom.sweep(sec[:], rp.line, m)
	}
}

// ---------------------------------------------------------------------------
// Solving: make a field evaluate to a target value, editing the parameter
// that drives it when the field is an expression.

Solve_Result :: struct {
	ok:    bool,
	param: string, // name of the parameter that was changed, if any
	msg:   string,
}

solve_field :: proc(d: ^Document, path: []^Group, f: ^Expr_Field, target: f64) -> Solve_Result {
	if field_is_literal(f^) {
		field_set_value(d, f, target)
		return {ok = true}
	}
	if f.parse_err {return {msg = "field has a syntax error"}}
	s0 := build_chain(d, path)
	f0, err := field_eval_pure(f^, s0)
	if err.kind != .None {return {msg = "field has an error"}}

	Cand :: struct {
		depth, index: int,
	}
	// scope depth 0 = document, 1.. = groups in path
	scopes := make([]^Scope, len(path) + 1, context.temp_allocator)
	{
		i := len(path)
		for s := s0; s != nil; s = s.parent {
			scopes[i] = s
			i -= 1
		}
	}
	cands := make([dynamic]Cand, context.temp_allocator)
	add_cand :: proc(cands: ^[dynamic]Cand, depth, index: int) {
		for c in cands {if c.depth == depth && c.index == index {return}}
		append(cands, Cand{depth, index})
	}
	find :: proc(scopes: []^Scope, name: string) -> (int, int, bool) {
		#reverse for s, depth in scopes {
			for p, i in s.params {
				if p.name == name {return depth, i, true}
			}
		}
		return 0, 0, false
	}
	for n in f.ast.nodes {
		if n.kind != .Ident {continue}
		if depth, i, ok := find(scopes, n.name); ok {add_cand(&cands, depth, i)}
	}
	#reverse for s, depth in scopes {
		for _, i in s.params {add_cand(&cands, depth, i)}
	}
	for cd in cands {
		param := &scopes[cd.depth].params[cd.index]
		if !field_is_literal(param.field) || field_is_empty(param.field) {continue}
		p0 := param.field.value
		probe := build_chain(d, path)
		// walk to the same depth in the fresh chain and pin the value
		ps := probe
		for _ in 0 ..< len(path) - cd.depth {ps = ps.parent}
		ps.state[cd.index] = 2
		ps.values[cd.index] = p0 + 1
		f1, e1 := field_eval_pure(f^, probe)
		if e1.kind != .None {continue}
		deriv := f1 - f0
		if abs(deriv) < 1e-9 {continue}
		np := p0 + (target - f0) / deriv
		field_set_value(d, &param.field, math.round(np * 1000) / 1000)
		return {ok = true, param = param.name}
	}
	return {msg = "no editable parameter drives this value"}
}
