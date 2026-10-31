// Application state: document, selection, tools, undo, and the frame loop glue.
package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"
import "../geom"
import mobio "../io"
import "../model"
import "../platform"
import "../render"
import "../ui"

Vec2 :: [2]f32
Vec3 :: [3]f32
Mat4 :: linalg.Matrix4f32
Id :: model.Id

UNDO_LIMIT :: 200

Tool :: enum u8 {
	Select,
	Move,
	Push_Pull,
	Panel,
	Turned,
	Swept,
}

TOOL_INFO := [Tool]struct {
	name: string,
	key:  string,
	tip:  string,
} {
	.Select    = {"Select", "V", "Select (V)\nClick a piece to select its group, double-click for the part.\nShift-click adds to the selection."},
	.Move      = {"Move", "M", "Move (M)\nDrag an arrow to move along an axis, drag the piece to slide it.\nType a distance while dragging, then Enter."},
	.Push_Pull = {"Push/Pull", "P", "Push/Pull (P)\nDrag a face of a panel to resize it.\nExpression-driven sizes edit the parameter behind them."},
	.Panel     = {"Panel", "B", "Place panel (B)\nClick on the floor or on a face."},
	.Turned    = {"Turned", "T", "Place turned part (T)\nLegs, knobs, spindles."},
	.Swept     = {"Swept", "S", "Place swept part (S)\nBent rails, arched aprons."},
}

Toast_Kind :: enum u8 {
	Info,
	Good,
	Error,
}

Toast :: struct {
	text: string,
	kind: Toast_Kind,
	age:  f32,
}

Dialog_Kind :: enum u8 {
	None,
	Open,
	Save_As,
	Export_Csv,
	Export_Svg,
	Export_Obj,
	Confirm_New,
}

Dialog :: struct {
	kind:  Dialog_Kind,
	path:  string, // heap
	focus: bool,
}

App :: struct {
	doc:            ^model.Document,
	res:            model.Eval_Result,
	need_eval:      bool,
	eval_ms:        f32,
	undo:           [dynamic]^model.Document,
	redo:           [dynamic]^model.Document,
	last_coalesce:  u64,
	coalesce_seq:   u64,
	selection:      [dynamic]Id,
	context_group:  Id,
	hover_ids:      [dynamic]Id,
	tool:           Tool,
	cam:            Orbit,
	r:              render.Renderer,
	ui:             ui.UI,
	path:           string, // heap; "" until saved
	modified:       bool,
	toasts:         [dynamic]Toast,
	drag:           Drag,
	last_op:        Drag, // for typed distances after a drag
	typed:          [dynamic]u8,
	show_room:      bool,
	show_edges:     bool,
	show_grid:      bool,
	show_dims:      bool,
	show_help:      bool,
	show_cutlist:   bool,
	dialog:         Dialog,
	editor:         Editor,
	asset_dir:      string,
	docs_dir:       string,
	viewport:       rl.Rectangle,
	frame_ms:       f32,
	pp_hover:       Face_Hit,
	gizmo_hover:    int,
	place_preview:  Place_Preview,
	quit:           bool,
	title_dirty:    bool,
	tree_drag:      Tree_Drag,
	scrub_key:      u64,
	idle_frames:    int,
	timings:        [4]f32,
	settings:       Settings,
	docs_dir_for_tests: string,
	settings_readonly: bool,
	rot_open:       Id, // node whose rotation fields are expanded
	show_settings:  bool,
}

app_init :: proc(a: ^App, asset_dir: string, open_path: string, demo := false) {
	a.asset_dir = strings.clone(asset_dir)
	home, _ := os.user_home_dir(context.temp_allocator)
	a.docs_dir, _ = filepath.join({home, "Documents", "mob"})
	a.show_edges = true
	a.show_grid = true
	a.show_dims = true
	a.gizmo_hover = -1
	render.init(&a.r)
	ui.init(&a.ui, asset_dir)
	orbit_init(&a.cam)
	load_settings(a)
	platform.install_gestures()

	// start with the given file, else the last project, else an empty scene
	loaded := false
	if open_path != "" {
		loaded = open_document(a, open_path)
	} else if !demo && a.settings.reopen_last && a.settings.last_file != "" && os.exists(a.settings.last_file) {
		loaded = open_document(a, a.settings.last_file)
	}
	if !loaded {
		a.doc = model.doc_new()
		if demo {
			append(&a.doc.root.children, model.template_vinyl_corner(a.doc))
			a.doc.name = model.str(a.doc, "Corner vinyl shelf")
		}
	}
	clear(&a.toasts) // no "Opened ..." toast at launch
	a.need_eval = true
	refresh(a)
	frame_all(a, true)
	a.title_dirty = true
}

app_shutdown :: proc(a: ^App) {
	save_settings(a)
	settings_shutdown(a)
	clear_history(a)
	delete(a.undo)
	delete(a.redo)
	model.doc_destroy(a.doc)
	model.eval_result_destroy(&a.res)
	render.shutdown(&a.r)
	ui.shutdown(&a.ui)
	delete(a.selection)
	delete(a.hover_ids)
	for t in a.toasts {delete(t.text)}
	delete(a.toasts)
	delete(a.typed)
	delete(a.drag.nodes)
	delete(a.last_op.nodes)
	delete(a.path)
	delete(a.dialog.path)
	delete(a.asset_dir)
	delete(a.docs_dir)
}

// ---------------------------------------------------------------------------
// Evaluation

refresh :: proc(a: ^App) {
	if !a.need_eval {return}
	a.need_eval = false
	t0 := rl.GetTime()
	model.evaluate(a.doc, &a.res)
	render.sync(&a.r, &a.res)
	a.eval_ms = f32((rl.GetTime() - t0) * 1000)
	// drop selected ids that no longer exist
	#reverse for id, i in a.selection {
		if _, ok := model.find_node(a.doc, id); !ok {ordered_remove(&a.selection, i)}
	}
	if a.context_group != 0 {
		if model.find_group(a.doc, a.context_group) == nil {a.context_group = 0}
	}
}

resolved_part :: proc(a: ^App, id: Id) -> ^model.Resolved_Part {
	for &rp in a.res.parts {
		if rp.id == id {return &rp}
	}
	return nil
}

resolved_group :: proc(a: ^App, id: Id) -> ^model.Resolved_Group {
	for &rg in a.res.groups {
		if rg.id == id {return &rg}
	}
	return nil
}

// World matrix of the group that contains `id` (identity for top level).
parent_world :: proc(a: ^App, id: Id) -> Mat4 {
	ref, ok := model.find_node(a.doc, id)
	if !ok || ref.parent == nil {return 1}
	if rg := resolved_group(a, ref.parent.id); rg != nil {return rg.world}
	return 1
}

node_world :: proc(a: ^App, id: Id) -> Mat4 {
	if rp := resolved_part(a, id); rp != nil {return rp.world}
	if rg := resolved_group(a, id); rg != nil {return rg.world}
	return 1
}

// All part ids under the given nodes.
collect_parts :: proc(a: ^App, ids: []Id, out: ^[dynamic]Id) {
	for id in ids {
		ref, ok := model.find_node(a.doc, id)
		if !ok {continue}
		walk :: proc(n: model.Node, out: ^[dynamic]Id) {
			switch v in n {
			case ^model.Part: append(out, v.id)
			case ^model.Group:
				for c in v.children {walk(c, out)}
			}
		}
		walk(ref.node, out)
	}
}

// World AABB over everything in `ids`.
nodes_bounds :: proc(a: ^App, ids: []Id) -> (lo, hi: Vec3, ok: bool) {
	parts := make([dynamic]Id, context.temp_allocator)
	collect_parts(a, ids, &parts)
	lo = {max(f32), max(f32), max(f32)}
	hi = -lo
	for pid in parts {
		rp := resolved_part(a, pid)
		if rp == nil {continue}
		plo, phi := render.part_world_bounds(&a.r, rp^)
		lo = linalg.min(lo, plo)
		hi = linalg.max(hi, phi)
		ok = true
	}
	return
}

// ---------------------------------------------------------------------------
// Commands and undo. Every document edit goes through apply(): it snapshots
// the document (unless the edit continues the same drag/scrub) and mutates it.

Cmd_Set_Field :: struct {
	field: ^model.Expr_Field,
	text:  string,
}

// Make a field evaluate to `target`, editing the param behind it if needed.
Cmd_Solve :: struct {
	owner: Id, // node whose scope the field is evaluated in
	field: ^model.Expr_Field,
	value: f64,
}

Cmd_Rename :: struct {
	name: ^string,
	text: string,
}

Cmd_Set_Material :: struct {
	ids:      []Id,
	material: Id,
}

Cmd_Add_Node :: struct {
	node:   model.Node, // allocated in the live document
	parent: Id, // 0 = root
	select: bool,
}

Cmd_Delete :: struct {
	ids: []Id,
}

Cmd_Duplicate :: struct {
	ids: []Id,
}

Cmd_Group :: struct {
	ids: []Id,
}

Cmd_Ungroup :: struct {
	id: Id,
}

Cmd_Reparent :: struct {
	id:     Id,
	parent: Id,
	index:  int, // -1 = append
}

Cmd_Add_Param :: struct {
	group: Id, // 0 = document
}

Cmd_Remove_Param :: struct {
	group: Id,
	index: int,
}

Cmd_Toggle :: struct {
	flag: ^bool,
}

// Free-form edit for small structural changes (points, holes, ...).
Cmd_Custom :: struct {
	fn:   proc(a: ^App, data: rawptr),
	data: rawptr,
}

Command :: union {
	Cmd_Set_Field,
	Cmd_Solve,
	Cmd_Rename,
	Cmd_Set_Material,
	Cmd_Add_Node,
	Cmd_Delete,
	Cmd_Duplicate,
	Cmd_Group,
	Cmd_Ungroup,
	Cmd_Reparent,
	Cmd_Add_Param,
	Cmd_Remove_Param,
	Cmd_Toggle,
	Cmd_Custom,
}

new_coalesce_key :: proc(a: ^App) -> u64 {
	a.coalesce_seq += 1
	return a.coalesce_seq
}

@(private)
snapshot :: proc(a: ^App, coalesce: u64) {
	if coalesce != 0 && coalesce == a.last_coalesce {return}
	a.last_coalesce = coalesce
	append(&a.undo, model.doc_clone(a.doc))
	if len(a.undo) > UNDO_LIMIT {
		model.doc_destroy(a.undo[0])
		ordered_remove(&a.undo, 0)
	}
	for d in a.redo {model.doc_destroy(d)}
	clear(&a.redo)
}

clear_history :: proc(a: ^App) {
	for d in a.undo {model.doc_destroy(d)}
	for d in a.redo {model.doc_destroy(d)}
	clear(&a.undo)
	clear(&a.redo)
	a.last_coalesce = 0
}

apply :: proc(a: ^App, cmd: Command, coalesce: u64 = 0) -> bool {
	snapshot(a, coalesce)
	d := a.doc
	ok := true
	switch c in cmd {
	case Cmd_Set_Field:
		model.field_set(d, c.field, c.text)
	case Cmd_Solve:
		path := model.group_path(d, c.owner)
		r := model.solve_field(d, path[:], c.field, c.value)
		if !r.ok {
			toast(a, r.msg, .Error)
			ok = false
		} else if r.param != "" && coalesce != a.drag.toast_key {
			toast(a, fmt.tprintf("Edited parameter %s", r.param), .Info)
			a.drag.toast_key = coalesce
		}
	case Cmd_Rename:
		c.name^ = model.str(d, strings.trim_space(c.text))
	case Cmd_Set_Material:
		for id in c.ids {
			if p := model.find_part(d, id); p != nil {p.material = c.material}
		}
	case Cmd_Add_Node:
		parent := c.parent == 0 ? d.root : model.find_group(d, c.parent)
		if parent == nil {parent = d.root}
		append(&parent.children, c.node)
		if c.select {set_selection(a, model.node_id(c.node))}
	case Cmd_Delete:
		for id in c.ids {model.detach(d, id)}
		clear(&a.selection)
	case Cmd_Duplicate:
		new_ids := make([dynamic]Id, context.temp_allocator)
		for id in c.ids {
			ref, found := model.find_node(d, id)
			if !found || ref.parent == nil {continue}
			n := model.node_copy(d, ref.node, true)
			name := model.node_name(n)
			switch v in n {
			case ^model.Part:  v.name = model.unique_name(d, name)
			case ^model.Group: v.name = model.unique_name(d, name)
			}
			inject_at(&ref.parent.children, ref.index + 1, n)
			append(&new_ids, model.node_id(n))
		}
		clear(&a.selection)
		append(&a.selection, ..new_ids[:])
	case Cmd_Group:
		group_nodes(a, c.ids)
	case Cmd_Ungroup:
		ungroup_node(a, c.id)
	case Cmd_Reparent:
		reparent(a, c.id, c.parent, c.index)
	case Cmd_Add_Param:
		params := &d.params
		if c.group != 0 {
			if g := model.find_group(d, c.group); g != nil {params = &g.params}
		}
		name := "p1"
		for i in 1 ..< 1000 {
			name = fmt.tprintf("p%d", i)
			if model.find_param(params[:], name) == nil {break}
		}
		model.add_param(d, params, name, "100")
	case Cmd_Remove_Param:
		params := &d.params
		if c.group != 0 {
			if g := model.find_group(d, c.group); g != nil {params = &g.params}
		}
		if c.index >= 0 && c.index < len(params) {ordered_remove(params, c.index)}
	case Cmd_Toggle:
		c.flag^ = !c.flag^
	case Cmd_Custom:
		c.fn(a, c.data)
	}
	a.need_eval = true
	if !a.modified {a.title_dirty = true}
	a.modified = true
	return ok
}

undo :: proc(a: ^App) {
	if len(a.undo) == 0 {
		toast(a, "Nothing to undo")
		return
	}
	append(&a.redo, a.doc)
	a.doc = pop(&a.undo)
	a.last_coalesce = 0
	a.need_eval = true
	a.modified = true
	cancel_drag(a)
	refresh(a)
}

redo :: proc(a: ^App) {
	if len(a.redo) == 0 {
		toast(a, "Nothing to redo")
		return
	}
	append(&a.undo, a.doc)
	a.doc = pop(&a.redo)
	a.last_coalesce = 0
	a.need_eval = true
	a.modified = true
	cancel_drag(a)
	refresh(a)
}

// ---------------------------------------------------------------------------
// Structural edits (run inside apply)

@(private)
group_nodes :: proc(a: ^App, ids: []Id) {
	d := a.doc
	if len(ids) == 0 {return}
	// all selected nodes must share a parent; otherwise use the first one's parent
	first, ok := model.find_node(d, ids[0])
	if !ok || first.parent == nil {return}
	parent := first.parent
	g := model.new_group(d, "Group")
	g.name = model.unique_name(d, "Group")
	insert_at := first.index
	for id in ids {
		ref, found := model.find_node(d, id)
		if !found || ref.parent == nil {continue}
		// keep the world placement: re-express in the new group's frame (identity
		// transform inside the same parent), so only reparenting is needed
		if ref.parent != parent {
			move_keep_world(a, id, parent)
			ref, _ = model.find_node(d, id)
		}
		n, _ := model.detach(d, id)
		append(&g.children, n)
	}
	insert_at = min(insert_at, len(parent.children))
	inject_at(&parent.children, insert_at, model.Node(g))
	clear(&a.selection)
	append(&a.selection, g.id)
}

@(private)
ungroup_node :: proc(a: ^App, id: Id) {
	d := a.doc
	ref, ok := model.find_node(d, id)
	if !ok || ref.parent == nil {return}
	g, is_group := ref.node.(^model.Group)
	if !is_group {return}
	if len(g.params) > 0 {
		// children reference the group's parameters; move them to the parent
		for p in g.params {
			if model.find_param(ref.parent.params[:], p.name) == nil {
				append(&ref.parent.params, p)
			}
		}
	}
	gw := node_world(a, g.id)
	pw := parent_world(a, g.id)
	local := linalg.inverse(pw) * gw
	children := g.children
	ordered_remove(&ref.parent.children, ref.index)
	clear(&a.selection)
	for c, i in children {
		inject_at(&ref.parent.children, ref.index + i, c)
		// compose the group's transform into the child when both are literal
		xf := model.node_xf(c)
		bake_transform(d, xf, local)
		append(&a.selection, model.node_id(c))
	}
}

// Pre-multiplies `m` into a transform made of literal fields (best effort for expressions).
@(private)
bake_transform :: proc(d: ^model.Document, xf: ^model.Transform_Def, m: Mat4) {
	if m == 1 {return}
	pos: [3]f32
	rot: [3]f32
	for i in 0 ..< 3 {
		pos[i] = f32(xf.pos[i].value)
		rot[i] = f32(xf.rot[i].value)
	}
	local := model.xf_local(pos, rot)
	nm := m * local
	p := Vec3{nm[0, 3], nm[1, 3], nm[2, 3]}
	e := euler_xyz_from_matrix(nm)
	for i in 0 ..< 3 {
		if model.field_is_literal(xf.pos[i]) {model.field_set_value(d, &xf.pos[i], f64(p[i]))}
		if model.field_is_literal(xf.rot[i]) {model.field_set_value(d, &xf.rot[i], f64(e[i]))}
	}
}

// Inverse of xf_local's rotation order (Rz * Ry * Rx), in degrees.
euler_xyz_from_matrix :: proc(m: Mat4) -> Vec3 {
	r := linalg.matrix3_from_matrix4(m)
	// normalize columns to remove scale
	for c in 0 ..< 3 {
		l := linalg.length(Vec3{r[0, c], r[1, c], r[2, c]})
		if l > 0 {for k in 0 ..< 3 {r[k, c] /= l}}
	}
	sy := -r[2, 0]
	sy = clamp(sy, -1, 1)
	y := asin_f32(sy)
	x, z: f32
	if abs(sy) < 0.9999 {
		x = atan2_f32(r[2, 1], r[2, 2])
		z = atan2_f32(r[1, 0], r[0, 0])
	} else {
		x = atan2_f32(-r[1, 2], r[1, 1])
		z = 0
	}
	deg :: 180.0 / 3.14159265358979
	out := Vec3{x, y, z} * deg
	for &v in out {
		v = f32(int(v * 1000 + (v >= 0 ? 0.5 : -0.5))) / 1000
		if v == -0 {v = 0}
	}
	return out
}

@(private)
reparent :: proc(a: ^App, id: Id, parent_id: Id, index: int) {
	d := a.doc
	parent := parent_id == 0 ? d.root : model.find_group(d, parent_id)
	if parent == nil {return}
	if parent.id == id {return}
	if g := model.find_group(d, id); g != nil && model.is_ancestor(g, parent.id) {return}
	move_keep_world(a, id, parent)
	ref, ok := model.find_node(d, id)
	if !ok {return}
	if index >= 0 && ref.parent == parent && ref.index < index {
		// detaching shifts later indices
		n, _ := model.detach(d, id)
		inject_at(&parent.children, min(index - 1, len(parent.children)), n)
		return
	}
	n, _ := model.detach(d, id)
	if index < 0 || index > len(parent.children) {
		append(&parent.children, n)
	} else {
		inject_at(&parent.children, index, n)
	}
}

// Moves a node under `parent`, adjusting its literal transform to keep it in place.
@(private)
move_keep_world :: proc(a: ^App, id: Id, parent: ^model.Group) {
	d := a.doc
	ref, ok := model.find_node(d, id)
	if !ok || ref.parent == parent {return}
	old_pw := parent_world(a, id)
	new_pw: Mat4 = 1
	if rg := resolved_group(a, parent.id); rg != nil {new_pw = rg.world}
	m := linalg.inverse(new_pw) * old_pw
	bake_transform(d, model.node_xf(ref.node), m)
	n, _ := model.detach(d, id)
	append(&parent.children, n)
}

// ---------------------------------------------------------------------------
// Selection

set_selection :: proc(a: ^App, ids: ..Id) {
	clear(&a.selection)
	append(&a.selection, ..ids)
	clear_last_op(a)
}

is_selected :: proc(a: ^App, id: Id) -> bool {
	for s in a.selection {if s == id {return true}}
	return false
}

toggle_selected :: proc(a: ^App, id: Id) {
	for s, i in a.selection {
		if s == id {
			ordered_remove(&a.selection, i)
			return
		}
	}
	append(&a.selection, id)
}

// The node a click on `part_id` selects: the outermost ancestor inside the context group.
click_target :: proc(a: ^App, part_id: Id) -> Id {
	path := model.group_path(a.doc, part_id)
	// path[0] is the root
	start := 1
	if a.context_group != 0 {
		found := false
		for g, i in path {
			if g.id == a.context_group {
				start = i + 1
				found = true
				break
			}
		}
		if !found {a.context_group = 0}
	}
	if start < len(path) {return path[start].id}
	return part_id
}

// ---------------------------------------------------------------------------
// Messages

toast :: proc(a: ^App, text: string, kind: Toast_Kind = .Info) {
	if len(a.toasts) >= 4 {
		delete(a.toasts[0].text)
		ordered_remove(&a.toasts, 0)
	}
	append(&a.toasts, Toast{text = strings.clone(text), kind = kind})
}

// ---------------------------------------------------------------------------
// Files

default_path :: proc(a: ^App, ext: string) -> string {
	if a.path != "" && ext == ".mob" {return a.path}
	name := a.doc.name
	if name == "" {name = "Untitled"}
	base := a.path != "" ? strings.trim_suffix(a.path, ".mob") : join_path({a.docs_dir, name})
	return strings.concatenate({base, ext}, context.temp_allocator)
}

ensure_dir :: proc(path: string) {
	dir := filepath.dir(path)
	if !os.exists(dir) {_ = os.make_directory_all(dir)}
}

save_to :: proc(a: ^App, path: string) -> bool {
	ensure_dir(path)
	if !mobio.save_document(a.doc, path) {
		toast(a, fmt.tprintf("Could not save %s", path), .Error)
		return false
	}
	if a.path != path {
		delete(a.path)
		a.path = strings.clone(path)
	}
	stem := filepath.stem(path)
	if stem != a.doc.name {a.doc.name = model.str(a.doc, stem)}
	a.modified = false
	a.title_dirty = true
	remember_file(a, path)
	toast(a, fmt.tprintf("Saved %s", filepath.base(path)), .Good)
	return true
}

open_document :: proc(a: ^App, path: string) -> bool {
	d, msg := mobio.load_document(path)
	if d == nil {
		toast(a, msg, .Error)
		return false
	}
	if a.doc != nil {model.doc_destroy(a.doc)}
	a.doc = d
	clear_history(a)
	clear(&a.selection)
	a.context_group = 0
	delete(a.path)
	a.path = strings.clone(path)
	if d.name == "" || d.name == "Untitled" {d.name = model.str(d, filepath.stem(path))}
	a.modified = false
	a.need_eval = true
	a.title_dirty = true
	refresh(a)
	frame_all(a, true)
	remember_file(a, path)
	toast(a, fmt.tprintf("Opened %s", filepath.base(path)), .Good)
	return true
}

new_document :: proc(a: ^App) {
	model.doc_destroy(a.doc)
	a.doc = model.doc_new()
	clear_history(a)
	clear(&a.selection)
	a.context_group = 0
	delete(a.path)
	a.path = ""
	a.modified = false
	a.need_eval = true
	a.title_dirty = true
	refresh(a)
	frame_all(a, false)
}

export_to :: proc(a: ^App, kind: Dialog_Kind, path: string) {
	ensure_dir(path)
	ok := false
	switch kind {
	case .Export_Csv:
		ok = mobio.write_cut_list(&a.res, path)
	case .Export_Svg:
		ids := make([dynamic]Id, context.temp_allocator)
		collect_parts(a, a.selection[:], &ids)
		ok = mobio.write_svg(&a.res, ids[:], path)
	case .Export_Obj:
		ok = mobio.write_obj(&a.res, path)
	case .None, .Open, .Save_As, .Confirm_New:
	}
	if ok {
		toast(a, fmt.tprintf("Exported %s", filepath.base(path)), .Good)
	} else {
		toast(a, fmt.tprintf("Could not write %s", path), .Error)
	}
}

update_title :: proc(a: ^App) {
	if !a.title_dirty {return}
	a.title_dirty = false
	t := fmt.ctprintf("%s%s — mob", a.doc.name, a.modified ? " •" : "")
	rl.SetWindowTitle(t)
}

// ---------------------------------------------------------------------------
// small math helpers

@(private)
asin_f32 :: proc(x: f32) -> f32 {return math.asin(x)}
@(private)
atan2_f32 :: proc(y, x: f32) -> f32 {return math.atan2(y, x)}

screen_ray :: proc(a: ^App, p: Vec2) -> geom.Ray {
	r := rl.GetScreenToWorldRay(p, orbit_camera(&a.cam))
	return {origin = r.position, dir = linalg.normalize(r.direction)}
}

join_path :: proc(elems: []string) -> string {
	p, _ := filepath.join(elems, context.temp_allocator)
	return p
}

remember_file :: proc(a: ^App, path: string) {
	abs_path, err := filepath.abs(path, context.temp_allocator)
	if err != nil {abs_path = path}
	if a.settings.last_file == abs_path {return}
	delete(a.settings.last_file)
	a.settings.last_file = strings.clone(abs_path)
	save_settings(a)
}
