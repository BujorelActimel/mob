// Pure document data: materials, parts, parametric groups. No rendering here.
// Every allocation of a document lives in its own arena, so a document (or an
// undo snapshot) is freed in one go.
package model

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "../expr"

Id :: u32

// A number or an expression. `src` is always the user-visible text.
Expr_Field :: struct {
	src:       string,
	ast:       expr.Expr,
	value:     f64, // literal value, or last successfully evaluated value
	err:       expr.Error, // parse or evaluation error
	parse_err: bool,
}

Param :: struct {
	name:  string,
	field: Expr_Field,
}

Material_Kind :: enum u8 {
	Wood,
	Painted,
	Metal,
}

Material :: struct {
	id:        Id,
	name:      string,
	kind:      Material_Kind,
	thickness: f64,
	color:     [3]u8, // sRGB
	grain:     bool, // has a grain direction (cut list notes it)
	price_m2:  f64,
	price_m:   f64,
}

// A sketch vertex: coordinates plus the fillet radius at that corner.
Sketch_Point :: struct {
	x, y, r: Expr_Field,
}

Profile_Kind :: enum u8 {
	Rect, // w x h with four corner radii
	Polygon, // free outline
}

Hole_Kind :: enum u8 {
	Circle, // cx, cy, w = diameter
	Slot, // cx, cy, w x h, corner radius r
}

Hole_Def :: struct {
	kind:         Hole_Kind,
	cx, cy, w, h: Expr_Field,
	r:            Expr_Field,
}

// Corners of a Rect profile, counter-clockwise from the origin. In a panel the
// profile's y axis points away from the viewer, so corners 0 and 1 are at the front.
Corner :: enum u8 {
	Front_Left,
	Front_Right,
	Back_Right,
	Back_Left,
}

Profile_Def :: struct {
	kind:   Profile_Kind,
	w, h:   Expr_Field,
	radii:  [Corner]Expr_Field,
	points: [dynamic]Sketch_Point,
	holes:  [dynamic]Hole_Def,
}

// Flat board: outline in the part's XZ plane, extruded along +Y.
Panel :: struct {
	profile:   Profile_Def,
	thickness: Expr_Field, // empty = material thickness
	edge:      Expr_Field, // radius of the rounded (sanded) edges; empty = sharp
}

// Lathe part: points are (radius, height), revolved around local +Y.
Turned :: struct {
	points:   [dynamic]Sketch_Point,
	segments: int,
}

// Cross-section (Rect profile, centered on the path horizontally) swept along a planar path.
Swept :: struct {
	section: Profile_Def,
	path:    [dynamic]Sketch_Point,
}

Shape :: union {
	Panel,
	Turned,
	Swept,
}

Shape_Kind :: enum u8 {
	Panel,
	Turned,
	Swept,
}

shape_kind :: proc(s: Shape) -> Shape_Kind {
	switch _ in s {
	case Panel:  return .Panel
	case Turned: return .Turned
	case Swept:  return .Swept
	}
	return .Panel
}

Transform_Def :: struct {
	pos: [3]Expr_Field,
	rot: [3]Expr_Field, // degrees, applied X then Y then Z
}

Part :: struct {
	id:        Id,
	name:      string,
	material:  Id,
	xf:        Transform_Def,
	shape:     Shape,
	grain_rot: bool, // grain runs along local Z instead of X
	hidden:    bool,
}

Group :: struct {
	id:       Id,
	name:     string,
	xf:       Transform_Def,
	params:   [dynamic]Param,
	children: [dynamic]Node,
	expanded: bool,
	hidden:   bool,
}

Node :: union {
	^Part,
	^Group,
}

Document :: struct {
	arena:     vmem.Arena,
	allocator: mem.Allocator,
	name:      string,
	params:    [dynamic]Param,
	materials: [dynamic]Material,
	root:      ^Group,
	next_id:   Id,
}

// ---------------------------------------------------------------------------
// Lifetime

doc_new :: proc(with_defaults := true) -> ^Document {
	d := new(Document)
	_ = vmem.arena_init_growing(&d.arena)
	d.allocator = vmem.arena_allocator(&d.arena)
	d.params = make([dynamic]Param, d.allocator)
	d.materials = make([dynamic]Material, d.allocator)
	d.next_id = 1
	d.name = "Untitled"
	d.root = new_group(d, "Scene")
	d.root.expanded = true
	if with_defaults {add_default_materials(d)}
	return d
}

doc_destroy :: proc(d: ^Document) {
	if d == nil {return}
	vmem.arena_destroy(&d.arena)
	free(d)
}

new_id :: proc(d: ^Document) -> Id {
	id := d.next_id
	d.next_id += 1
	return id
}

str :: proc(d: ^Document, s: string) -> string {
	return strings.clone(s, d.allocator)
}

// ---------------------------------------------------------------------------
// Fields

format_number :: proc(v: f64, allocator := context.temp_allocator) -> string {
	r := f64(i64(v * 1000 + (v >= 0 ? 0.5 : -0.5))) / 1000
	if r == f64(i64(r)) {
		return fmt.aprintf("%d", i64(r), allocator = allocator)
	}
	s := fmt.aprintf("%.3f", r, allocator = allocator)
	s = strings.trim_right(s, "0")
	return s
}

// Sets the text of a field and compiles it. Empty text is allowed (means "default").
field_set :: proc(d: ^Document, f: ^Expr_Field, src: string) {
	text := strings.trim_space(src)
	f.src = str(d, text)
	f.ast = {}
	f.err = {}
	f.parse_err = false
	if text == "" {return}
	e, err := expr.parse(f.src, d.allocator)
	if err.kind != .None {
		f.err = err
		f.parse_err = true
		return
	}
	f.ast = e
	if v, ok := expr.literal_value(e); ok {f.value = v}
}

field_set_value :: proc(d: ^Document, f: ^Expr_Field, v: f64) {
	field_set(d, f, format_number(v))
	f.value = v
}

field_make :: proc(d: ^Document, src: string) -> Expr_Field {
	f: Expr_Field
	field_set(d, &f, src)
	return f
}

field_num :: proc(d: ^Document, v: f64) -> Expr_Field {
	f: Expr_Field
	field_set_value(d, &f, v)
	return f
}

field_is_literal :: proc(f: Expr_Field) -> bool {
	return f.src == "" || (!f.parse_err && expr.is_literal(f.ast))
}

field_is_empty :: proc(f: Expr_Field) -> bool {return f.src == ""}

field_has_error :: proc(f: Expr_Field) -> bool {return f.err.kind != .None}

// Parses a plain number (with optional unit) without touching any document.
parse_number :: proc(s: string) -> (f64, bool) {
	e, err := expr.parse(s, context.temp_allocator)
	if err.kind != .None {return 0, false}
	if v, ok := expr.literal_value(e); ok {return v, true}
	if v, eerr := expr.eval(e, {}); eerr.kind == .None {return v, true}
	return 0, false
}

// ---------------------------------------------------------------------------
// Construction helpers

add_default_materials :: proc(d: ^Document) {
	add_material(d, "Birch plywood", .Wood, 18, {214, 180, 132}, 45)
	add_material(d, "Oak", .Wood, 20, {176, 128, 82}, 95)
	add_material(d, "Walnut", .Wood, 20, {112, 72, 48}, 140)
	add_material(d, "White MDF", .Painted, 18, {236, 234, 228}, 22)
	add_material(d, "Black steel", .Metal, 3, {52, 54, 58}, 60)
}

add_material :: proc(d: ^Document, name: string, kind: Material_Kind, thickness: f64, color: [3]u8, price_m2: f64) -> Id {
	m := Material {
		id        = new_id(d),
		name      = str(d, name),
		kind      = kind,
		thickness = thickness,
		color     = color,
		grain     = kind == .Wood,
		price_m2  = price_m2,
		price_m   = price_m2 * 0.05,
	}
	append(&d.materials, m)
	return m.id
}

find_material :: proc(d: ^Document, id: Id) -> ^Material {
	for &m in d.materials {
		if m.id == id {return &m}
	}
	if len(d.materials) > 0 {return &d.materials[0]}
	return nil
}

transform_init :: proc(d: ^Document, xf: ^Transform_Def, pos: [3]f64 = {}, rot: [3]f64 = {}) {
	for i in 0 ..< 3 {
		xf.pos[i] = field_num(d, pos[i])
		xf.rot[i] = field_num(d, rot[i])
	}
}

new_group :: proc(d: ^Document, name: string) -> ^Group {
	g := new(Group, d.allocator)
	g.id = new_id(d)
	g.name = str(d, name)
	g.params = make([dynamic]Param, d.allocator)
	g.children = make([dynamic]Node, d.allocator)
	g.expanded = true
	transform_init(d, &g.xf)
	return g
}

profile_init_rect :: proc(d: ^Document, p: ^Profile_Def, w, h: string) {
	p.kind = .Rect
	p.w = field_make(d, w)
	p.h = field_make(d, h)
	for c in Corner {p.radii[c] = field_num(d, 0)}
	p.points = make([dynamic]Sketch_Point, d.allocator)
	p.holes = make([dynamic]Hole_Def, d.allocator)
}

new_part :: proc(d: ^Document, name: string) -> ^Part {
	p := new(Part, d.allocator)
	p.id = new_id(d)
	p.name = str(d, name)
	if len(d.materials) > 0 {p.material = d.materials[0].id}
	transform_init(d, &p.xf)
	return p
}

new_panel :: proc(d: ^Document, name: string, w, depth: string, thickness := "") -> ^Part {
	p := new_part(d, name)
	panel: Panel
	profile_init_rect(d, &panel.profile, w, depth)
	panel.thickness = field_make(d, thickness)
	p.shape = panel
	return p
}

new_turned :: proc(d: ^Document, name: string) -> ^Part {
	p := new_part(d, name)
	t := Turned{segments = 32, points = make([dynamic]Sketch_Point, d.allocator)}
	// a tapered leg with a rounded foot and a collar
	profile := [][3]f64{{17, 0, 4}, {19, 120, 0}, {24, 130, 0}, {24, 150, 0}, {21, 160, 0}, {25, 420, 0}, {25, 430, 0}}
	for q in profile {
		append(&t.points, Sketch_Point{field_num(d, q[0]), field_num(d, q[1]), field_num(d, q[2])})
	}
	p.shape = t
	if len(d.materials) > 1 {p.material = d.materials[1].id}
	return p
}

new_swept :: proc(d: ^Document, name: string) -> ^Part {
	p := new_part(d, name)
	s := Swept{path = make([dynamic]Sketch_Point, d.allocator)}
	profile_init_rect(d, &s.section, "40", "20")
	for c in Corner {s.section.radii[c] = field_num(d, 3)}
	pts := [][3]f64{{0, 0, 0}, {300, 120, 400}, {600, 0, 0}}
	for q in pts {
		append(&s.path, Sketch_Point{field_num(d, q[0]), field_num(d, q[1]), field_num(d, q[2])})
	}
	p.shape = s
	if len(d.materials) > 1 {p.material = d.materials[1].id}
	return p
}

add_param :: proc(d: ^Document, params: ^[dynamic]Param, name, src: string) -> ^Param {
	append(params, Param{name = str(d, name), field = field_make(d, src)})
	return &params[len(params) - 1]
}

find_param :: proc(params: []Param, name: string) -> ^Param {
	for &p in params {
		if p.name == name {return &p}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Tree queries

node_id :: proc(n: Node) -> Id {
	switch v in n {
	case ^Part:  return v.id
	case ^Group: return v.id
	}
	return 0
}

node_name :: proc(n: Node) -> string {
	switch v in n {
	case ^Part:  return v.name
	case ^Group: return v.name
	}
	return ""
}

node_xf :: proc(n: Node) -> ^Transform_Def {
	switch v in n {
	case ^Part:  return &v.xf
	case ^Group: return &v.xf
	}
	return nil
}

Node_Ref :: struct {
	node:   Node,
	parent: ^Group,
	index:  int,
}

find_node :: proc(d: ^Document, id: Id) -> (ref: Node_Ref, ok: bool) {
	if d.root.id == id {return {node = d.root, parent = nil, index = -1}, true}
	return find_in(d.root, id)
}

@(private)
find_in :: proc(g: ^Group, id: Id) -> (Node_Ref, bool) {
	for c, i in g.children {
		if node_id(c) == id {return {node = c, parent = g, index = i}, true}
		if sub, is_group := c.(^Group); is_group {
			if r, ok := find_in(sub, id); ok {return r, true}
		}
	}
	return {}, false
}

find_part :: proc(d: ^Document, id: Id) -> ^Part {
	ref, ok := find_node(d, id)
	if !ok {return nil}
	p, _ := ref.node.(^Part)
	return p
}

find_group :: proc(d: ^Document, id: Id) -> ^Group {
	ref, ok := find_node(d, id)
	if !ok {return nil}
	g, _ := ref.node.(^Group)
	return g
}

// Groups from the root down to (and including) the group that directly contains `id`.
group_path :: proc(d: ^Document, id: Id, allocator := context.temp_allocator) -> [dynamic]^Group {
	path := make([dynamic]^Group, allocator)
	walk :: proc(g: ^Group, id: Id, path: ^[dynamic]^Group) -> bool {
		append(path, g)
		for c in g.children {
			if node_id(c) == id {return true}
			if sub, ok := c.(^Group); ok {
				if walk(sub, id, path) {return true}
			}
		}
		pop(path)
		return false
	}
	if id == d.root.id {return path}
	walk(d.root, id, &path)
	return path
}

is_ancestor :: proc(g: ^Group, id: Id) -> bool {
	for c in g.children {
		if node_id(c) == id {return true}
		if sub, ok := c.(^Group); ok && is_ancestor(sub, id) {return true}
	}
	return false
}

detach :: proc(d: ^Document, id: Id) -> (Node, bool) {
	ref, ok := find_node(d, id)
	if !ok || ref.parent == nil {return nil, false}
	ordered_remove(&ref.parent.children, ref.index)
	return ref.node, true
}

count_parts :: proc(g: ^Group) -> int {
	n := 0
	for c in g.children {
		switch v in c {
		case ^Part:  n += 1
		case ^Group: n += count_parts(v)
		}
	}
	return n
}

// Unique-ish display name: "Shelf", "Shelf 2", ...
unique_name :: proc(d: ^Document, base: string) -> string {
	taken :: proc(g: ^Group, name: string) -> bool {
		if g.name == name {return true}
		for c in g.children {
			switch v in c {
			case ^Part:  if v.name == name {return true}
			case ^Group: if taken(v, name) {return true}
			}
		}
		return false
	}
	if !taken(d.root, base) {return str(d, base)}
	for i in 2 ..< 10000 {
		n := fmt.tprintf("%s %d", base, i)
		if !taken(d.root, n) {return str(d, n)}
	}
	return str(d, base)
}
