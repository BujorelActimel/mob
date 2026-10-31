package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../geom"
import "../model"
import "../platform"
import "../render"
import "../ui"

Drag_Kind :: enum u8 {
	None,
	Pending, // button down, not yet decided between click and drag
	Orbit,
	Pan,
	Move_Axis,
	Move_Plane,
	Push_Pull,
}

Moving :: struct {
	id:        Id,
	pw_inv:    Mat4, // inverse of the parent's world matrix
	start_pos: [3]f64,
}

Face_Hit :: struct {
	valid:     bool,
	part:      Id,
	axis:      int, // local axis
	sign:      f32, // sign of the local outward normal
	world_dir: Vec3,
	point:     Vec3,
}

Drag :: struct {
	kind:        Drag_Kind,
	button:      rl.MouseButton,
	start_mouse: Vec2,
	coalesce:    u64,
	toast_key:   u64,
	applied:     bool,
	axis:        int,
	origin:      Vec3,
	start_t:     f32,
	plane_start: Vec3,
	nodes:       [dynamic]Moving,
	lo, hi:      Vec3,
	delta:       Vec3,
	face:        Face_Hit,
	dim_start:   f64,
	local_rot:   Mat4,
	pp_delta:    f32,
	snapped:     bool,
	snap_from:   Vec3,
	snap_to:     Vec3,
	exclude:     [dynamic]Id,
	pan_on_drag: bool,
}

Place_Preview :: struct {
	valid:  bool,
	pos:    Vec3, // world
	orient: int, // 0 flat, 1 side, 2 back
	size:   Vec3, // world-aligned box size for the preview
}

AXIS_COLORS := [3]rl.Color{{226, 76, 70, 255}, {94, 186, 84, 255}, {70, 128, 232, 255}}
AXIS_DIRS := [3]Vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}

drag_free :: proc(d: ^Drag) {
	delete(d.nodes)
	delete(d.exclude)
	d^ = {}
}

clear_last_op :: proc(a: ^App) {
	drag_free(&a.last_op)
	clear(&a.typed)
}

@(private)
reset_drag :: proc(a: ^App) {drag_free(&a.drag)}

// Snapshot of a node's position for a drag that edits it.
moving_of :: proc(a: ^App, id: Id) -> (m: Moving, ok: bool) {
	ref := model.find_node(a.doc, id) or_return
	if ref.parent == nil {return}
	xf := model.node_xf(ref.node)
	m = {id = id, pw_inv = linalg.inverse(parent_world(a, id))}
	for i in 0 ..< 3 {m.start_pos[i] = xf.pos[i].value}
	return m, true
}

// Ends a drag; move/push-pull drags become the target of typed distances.
@(private)
finish_drag :: proc(a: ^App) {
	#partial switch a.drag.kind {
	case .Move_Axis, .Move_Plane, .Push_Pull:
		drag_free(&a.last_op)
		a.last_op = a.drag
		a.last_op.snapped = false
		a.drag = {}
	case:
		reset_drag(a)
	}
}

cancel_drag :: proc(a: ^App) {
	if a.drag.applied {
		reset_drag(a)
		undo(a)
		return
	}
	reset_drag(a)
}

// ---------------------------------------------------------------------------

@(private)
world_to_screen :: proc(a: ^App, p: Vec3) -> Vec2 {
	return rl.GetWorldToScreen(p, orbit_camera(&a.cam))
}

@(private)
units_per_px_at :: proc(a: ^App, p: Vec3) -> f32 {
	d := linalg.length(p - orbit_eye(&a.cam))
	return 2 * d * math.tan(math.to_radians(a.cam.fovy) * 0.5) / f32(rl.GetScreenHeight())
}

@(private)
dist_point_segment :: proc(p, a, b: Vec2) -> f32 {
	ab := b - a
	l2 := linalg.length2(ab)
	t: f32 = l2 > 0 ? clamp(linalg.dot(p - a, ab) / l2, 0, 1) : 0
	return linalg.length(p - (a + ab * t))
}

@(private)
in_list :: proc(ids: []Id, id: Id) -> bool {
	for x in ids {if x == id {return true}}
	return false
}

// ---------------------------------------------------------------------------
// Gizmo

gizmo_origin :: proc(a: ^App) -> (Vec3, bool) {
	if len(a.selection) == 0 {return {}, false}
	lo, hi, ok := nodes_bounds(a, a.selection[:])
	if !ok {return {}, false}
	return Vec3{(lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5}, true
}

@(private)
gizmo_len :: proc(a: ^App, o: Vec3) -> f32 {return units_per_px_at(a, o) * 90}

@(private)
gizmo_pick :: proc(a: ^App, mouse: Vec2) -> int {
	o, ok := gizmo_origin(a)
	if !ok {return -1}
	l := gizmo_len(a, o)
	s0 := world_to_screen(a, o)
	best := -1
	best_d: f32 = 10
	for i in 0 ..< 3 {
		s1 := world_to_screen(a, o + AXIS_DIRS[i] * l)
		d := dist_point_segment(mouse, s0 + (s1 - s0) * 0.15, s1)
		if d < best_d {
			best_d = d
			best = i
		}
	}
	return best
}

draw_gizmo :: proc(a: ^App) {
	if a.tool != .Move {return}
	o, ok := gizmo_origin(a)
	if !ok {return}
	if a.drag.kind == .Move_Axis || a.drag.kind == .Move_Plane {o = a.drag.origin + a.drag.delta}
	l := gizmo_len(a, o)
	upp := units_per_px_at(a, o)
	rlgl.DrawRenderBatchActive()
	rlgl.DisableDepthTest()
	for i in 0 ..< 3 {
		c := AXIS_COLORS[i]
		active := (a.drag.kind == .Move_Axis && a.drag.axis == i) || (a.drag.kind == .None && a.gizmo_hover == i)
		if a.drag.kind == .Move_Axis && a.drag.axis != i {c.a = 70}
		if active {c = ui.lerp_color(c, rl.WHITE, 0.35)}
		dir := AXIS_DIRS[i]
		shaft_end := o + dir * l * 0.78
		r := upp * (active ? 2.0 : 1.4)
		rl.DrawCylinderEx(o + dir * l * 0.12, shaft_end, r, r, 8, c)
		rl.DrawCylinderEx(shaft_end, o + dir * l, r * 3.4, 0, 14, c)
	}
	rl.DrawSphereEx(o, upp * 4, 8, 8, {250, 250, 250, 220})
	rlgl.DrawRenderBatchActive()
	rlgl.EnableDepthTest()
}

// ---------------------------------------------------------------------------
// Snapping

Snap :: struct {
	ok:       bool,
	adjust:   f32,
	from, to: Vec3,
}

// Snaps moving coordinates along `axis` to other parts' bounds planes (min, center, max).
@(private)
snap_axis :: proc(a: ^App, axis: int, lo, hi: Vec3, exclude: []Id, thresh: f32) -> Snap {
	best := Snap{}
	best_d := thresh
	mine := [3]f32{lo[axis], (lo[axis] + hi[axis]) * 0.5, hi[axis]}
	mc := (lo + hi) * 0.5
	try :: proc(best: ^Snap, best_d: ^f32, mine: [3]f32, mc: Vec3, c: f32, axis: int, target_center: Vec3) {
		for v in mine {
			d := abs(c - v)
			if d < best_d^ {
				best_d^ = d
				best.ok = true
				best.adjust = c - v
				best.from = mc
				best.from[axis] = c
				best.to = target_center
				best.to[axis] = c
			}
		}
	}
	if axis == 1 {try(&best, &best_d, mine, mc, 0, axis, Vec3{mc.x, 0, mc.z})}
	for rp in a.res.parts {
		if in_list(exclude, rp.id) {continue}
		plo, phi := render.part_world_bounds(&a.r, rp)
		pc := (plo + phi) * 0.5
		try(&best, &best_d, mine, mc, plo[axis], axis, pc)
		try(&best, &best_d, mine, mc, pc[axis], axis, pc)
		try(&best, &best_d, mine, mc, phi[axis], axis, pc)
	}
	return best
}

@(private)
grid_step :: proc(a: ^App) -> f32 {
	s := max(a.settings.grid_step, 0.1)
	if ui.cmd_down() {return s * 10}
	return s
}

// Object snapping is on per the settings; ⌥ flips it while dragging.
@(private)
snapping :: proc(a: ^App) -> bool {return a.settings.object_snap != ui.alt_down()}

// ---------------------------------------------------------------------------
// Move

@(private)
start_move :: proc(a: ^App, kind: Drag_Kind, axis: int, mouse: Vec2) -> bool {
	o, ok := gizmo_origin(a)
	if !ok {return false}
	reset_drag(a)
	a.drag.kind = kind
	a.drag.axis = axis
	a.drag.origin = o
	a.drag.coalesce = new_coalesce_key(a)
	a.drag.start_mouse = mouse
	a.drag.lo, a.drag.hi, _ = nodes_bounds(a, a.selection[:])
	collect_parts(a, a.selection[:], &a.drag.exclude)
	for id in a.selection {
		if m, ok := moving_of(a, id); ok {append(&a.drag.nodes, m)}
	}
	ray := screen_ray(a, mouse)
	if kind == .Move_Axis {
		a.drag.start_t = geom.closest_on_line_to_ray(o, AXIS_DIRS[axis], ray)
	} else {
		p, hit := plane_hit(ray, a.drag.plane_start.y)
		if hit {a.drag.plane_start = p}
	}
	return true
}

@(private)
plane_hit :: proc(ray: geom.Ray, y: f32) -> (Vec3, bool) {
	t, ok := geom.ray_plane(ray, {0, y, 0}, {0, 1, 0})
	if !ok {return {}, false}
	return ray.origin + ray.dir * t, true
}

apply_move :: proc(a: ^App, op: ^Drag, delta: Vec3) {
	op.delta = delta
	for m in op.nodes {
		ref, ok := model.find_node(a.doc, m.id)
		if !ok {continue}
		xf := model.node_xf(ref.node)
		ld := (m.pw_inv * [4]f32{delta.x, delta.y, delta.z, 0}).xyz
		for i in 0 ..< 3 {
			target := m.start_pos[i] + f64(ld[i])
			if abs(ld[i]) < 1e-4 && abs(xf.pos[i].value - m.start_pos[i]) < 1e-6 {continue}
			if abs(xf.pos[i].value - target) < 1e-6 {continue}
			apply(a, Cmd_Solve{owner = m.id, field = &xf.pos[i], value = math.round(target * 1000) / 1000}, op.coalesce)
			op.applied = true
		}
	}
}

@(private)
update_move :: proc(a: ^App, mouse: Vec2) {
	d := &a.drag
	ray := screen_ray(a, mouse)
	no_snap := !snapping(a)
	thresh := units_per_px_at(a, d.origin) * a.settings.snap_distance
	d.snapped = false
	delta: Vec3
	if d.kind == .Move_Axis {
		t := geom.closest_on_line_to_ray(d.origin, AXIS_DIRS[d.axis], ray)
		raw := t - d.start_t
		step := grid_step(a)
		amount := math.round(raw / step) * step
		if !no_snap {
			lo, hi := d.lo, d.hi
			lo[d.axis] += raw
			hi[d.axis] += raw
			if s := snap_axis(a, d.axis, lo, hi, d.exclude[:], thresh); s.ok {
				amount = raw + s.adjust
				d.snapped = true
				d.snap_from = s.from
				d.snap_to = s.to
			}
		}
		delta[d.axis] = amount
	} else {
		p, ok := plane_hit(ray, d.plane_start.y)
		if !ok {return}
		raw := p - d.plane_start
		raw.y = 0
		step := grid_step(a)
		delta = {math.round(raw.x / step) * step, 0, math.round(raw.z / step) * step}
		if !no_snap {
			for axis in ([]int{0, 2}) {
				lo, hi := d.lo, d.hi
				lo[axis] += raw[axis]
				hi[axis] += raw[axis]
				if s := snap_axis(a, axis, lo, hi, d.exclude[:], thresh); s.ok {
					delta[axis] = raw[axis] + s.adjust
					d.snapped = true
					d.snap_from = s.from
					d.snap_to = s.to
				}
			}
		}
	}
	if delta != d.delta {apply_move(a, d, delta)}
}

// ---------------------------------------------------------------------------
// Push / pull

face_under :: proc(a: ^App, mouse: Vec2) -> Face_Hit {
	pk := render.pick(&a.r, &a.res, screen_ray(a, mouse))
	if !pk.hit {return {}}
	rp := &a.res.parts[pk.index]
	panel, is_panel := rp.part.shape.(model.Panel)
	if !is_panel {return {part = rp.id}}
	n := pk.local_normal
	axis := -1
	for i in 0 ..< 3 {
		if abs(n[i]) > 0.995 {axis = i}
	}
	if axis < 0 {return {part = rp.id}}
	if axis != 1 && panel.profile.kind != .Rect {return {part = rp.id}}
	return {valid = true, part = rp.id, axis = axis, sign = n[axis] > 0 ? 1 : -1, world_dir = pk.normal, point = pk.point}
}

@(private)
pp_field :: proc(p: ^model.Part, axis: int) -> ^model.Expr_Field {
	panel := &p.shape.(model.Panel)
	switch axis {
	case 0: return &panel.profile.w
	case 1: return &panel.thickness
	case 2: return &panel.profile.h
	}
	return nil
}

@(private)
pp_value :: proc(rp: ^model.Resolved_Part, axis: int) -> f64 {
	b := geom.contour_bounds(rp.profile.outer, 0.01)
	switch axis {
	case 0: return f64(b.max.x - b.min.x)
	case 1: return f64(rp.thickness)
	case 2: return f64(b.max.y - b.min.y)
	}
	return 0
}

@(private)
// Prepares a push/pull of face `f`; the caller owns `d` (free with drag_free).
init_push_pull :: proc(a: ^App, d: ^Drag, f: Face_Hit) -> bool {
	rp := resolved_part(a, f.part)
	if rp == nil {return false}
	m := moving_of(a, f.part) or_return
	d^ = {kind = .Push_Pull, face = f, coalesce = new_coalesce_key(a), origin = f.point}
	d.dim_start = pp_value(rp, f.axis)
	// the part's rotation inside its parent
	d.local_rot = m.pw_inv * rp.world
	d.local_rot[0, 3], d.local_rot[1, 3], d.local_rot[2, 3] = 0, 0, 0
	append(&d.nodes, m)
	append(&d.exclude, f.part)
	d.lo, d.hi = render.part_world_bounds(&a.r, rp^)
	return true
}

@(private)
start_push_pull :: proc(a: ^App, f: Face_Hit, mouse: Vec2) {
	reset_drag(a)
	if !init_push_pull(a, &a.drag, f) {return}
	a.drag.start_mouse = mouse
	a.drag.start_t = geom.closest_on_line_to_ray(f.point, f.world_dir, screen_ray(a, mouse))
	if !is_selected(a, f.part) {
		clear(&a.selection)
		append(&a.selection, f.part)
	}
}

apply_push_pull :: proc(a: ^App, op: ^Drag, amount: f32) {
	op.pp_delta = amount
	p := model.find_part(a.doc, op.face.part)
	if p == nil {return}
	f := op.face
	new_dim := max(op.dim_start + f64(amount), 0.5)
	real := f32(new_dim - op.dim_start)
	apply(a, Cmd_Solve{owner = p.id, field = pp_field(p, f.axis), value = math.round(new_dim * 1000) / 1000}, op.coalesce)
	op.applied = true
	grows_from_origin := f.axis == 2 ? f.sign < 0 : f.sign > 0
	if !grows_from_origin {
		local := Vec3{}
		local[f.axis] = f.sign * real
		shift := (op.local_rot * [4]f32{local.x, local.y, local.z, 0}).xyz
		m := op.nodes[0]
		for i in 0 ..< 3 {
			if abs(shift[i]) < 1e-5 && abs(p.xf.pos[i].value - m.start_pos[i]) < 1e-6 {continue}
			target := m.start_pos[i] + f64(shift[i])
			if abs(p.xf.pos[i].value - target) < 1e-6 {continue}
			apply(a, Cmd_Solve{owner = p.id, field = &p.xf.pos[i], value = math.round(target * 1000) / 1000}, op.coalesce)
		}
	}
}

@(private)
update_push_pull :: proc(a: ^App, mouse: Vec2) {
	d := &a.drag
	t := geom.closest_on_line_to_ray(d.origin, d.face.world_dir, screen_ray(a, mouse))
	raw := t - d.start_t
	step := grid_step(a)
	amount := math.round(raw / step) * step
	d.snapped = false
	if snapping(a) {
		// snap the moving face plane to other parts' planes (world-axis aligned faces only)
		wd := d.face.world_dir
		axis := -1
		for i in 0 ..< 3 {if abs(wd[i]) > 0.995 {axis = i}}
		if axis >= 0 {
			face_c := d.origin + wd * raw
			v := face_c[axis]
			lo := face_c
			hi := face_c
			lo[axis] = v
			hi[axis] = v
			if s := snap_axis(a, axis, lo, hi, d.exclude[:], units_per_px_at(a, d.origin) * a.settings.snap_distance); s.ok {
				amount = raw + s.adjust * (wd[axis] > 0 ? 1 : -1)
				d.snapped = true
				d.snap_from = s.from
				d.snap_to = s.to
			}
		}
	}
	if amount != d.pp_delta {apply_push_pull(a, d, amount)}
}

draw_face_highlight :: proc(a: ^App, f: Face_Hit, c: rl.Color) {
	if !f.valid {return}
	rp := resolved_part(a, f.part)
	if rp == nil {return}
	g := render.mesh_of(&a.r, rp^)
	if g == nil {return}
	lo, hi := g.lo, g.hi
	ax := f.axis
	u := (ax + 1) % 3
	v := (ax + 2) % 3
	plane := f.sign > 0 ? hi[ax] : lo[ax]
	corners: [4]Vec3
	uv := [4][2]f32{{lo[u], lo[v]}, {hi[u], lo[v]}, {hi[u], hi[v]}, {lo[u], hi[v]}}
	for k in 0 ..< 4 {
		p: Vec3
		p[ax] = plane
		p[u] = uv[k][0]
		p[v] = uv[k][1]
		corners[k] = (rp.world * [4]f32{p.x, p.y, p.z, 1}).xyz + f.world_dir * 0.3
	}
	fill := c
	fill.a = 60
	rl.DrawTriangle3D(corners[0], corners[1], corners[2], fill)
	rl.DrawTriangle3D(corners[0], corners[2], corners[1], fill)
	rl.DrawTriangle3D(corners[0], corners[2], corners[3], fill)
	rl.DrawTriangle3D(corners[0], corners[3], corners[2], fill)
	for k in 0 ..< 4 {rl.DrawLine3D(corners[k], corners[(k + 1) % 4], c)}
}

// ---------------------------------------------------------------------------
// Placement

@(private)
placement_at :: proc(a: ^App, mouse: Vec2) -> Place_Preview {
	ray := screen_ray(a, mouse)
	pk := render.pick(&a.r, &a.res, ray)
	pp: Place_Preview
	t: f32 = 18
	if len(a.doc.materials) > 0 {t = f32(a.doc.materials[0].thickness)}
	snap :: proc(v: f32) -> f32 {return math.round(v / 10) * 10}
	if pk.hit {
		n := pk.normal
		p := pk.point
		pp.valid = true
		if abs(n.y) >= max(abs(n.x), abs(n.z)) {
			pp.orient = 0
			pp.pos = {snap(p.x), n.y > 0 ? p.y : p.y - t, snap(p.z)}
		} else if abs(n.x) > abs(n.z) {
			pp.orient = 1
			pp.pos = {n.x > 0 ? p.x + t : p.x, snap(p.y), snap(p.z)}
		} else {
			pp.orient = 2
			pp.pos = {snap(p.x), snap(p.y), n.z > 0 ? p.z : p.z - t}
		}
	} else {
		p, ok := plane_hit(ray, 0)
		if !ok {return {}}
		pp = {valid = true, pos = {snap(p.x), 0, snap(p.z)}, orient = 0}
	}
	return pp
}

@(private)
place_part :: proc(a: ^App, pp: Place_Preview) {
	d := a.doc
	p: ^model.Part
	switch a.tool {
	case .Panel:
		p = model.new_panel(d, model.unique_name(d, "Panel"), "600", "300")
	case .Turned:
		p = model.new_turned(d, model.unique_name(d, "Leg"))
	case .Swept:
		p = model.new_swept(d, model.unique_name(d, "Rail"))
	case .Select, .Move, .Push_Pull:
		return
	}
	parent_id := a.context_group
	pw: Mat4 = 1
	if parent_id != 0 {
		if rg := resolved_group(a, parent_id); rg != nil {pw = rg.world}
	}
	local := (linalg.inverse(pw) * [4]f32{pp.pos.x, pp.pos.y, pp.pos.z, 1}).xyz
	for i in 0 ..< 3 {model.field_set_value(d, &p.xf.pos[i], f64(math.round(local[i] * 10) / 10))}
	if a.tool == .Panel {
		switch pp.orient {
		case 1: model.field_set_value(d, &p.xf.rot[2], 90)
		case 2: model.field_set_value(d, &p.xf.rot[0], 90)
		}
	}
	apply(a, Cmd_Add_Node{node = p, parent = parent_id, select = true})
	toast(a, fmt.tprintf("Placed %s", p.name))
	a.tool = .Select
}

// ---------------------------------------------------------------------------
// Typed distances

@(private)
typed_target :: proc(a: ^App) -> ^Drag {
	#partial switch a.drag.kind {
	case .Move_Axis, .Push_Pull: return &a.drag
	}
	#partial switch a.last_op.kind {
	case .Move_Axis, .Push_Pull: return &a.last_op
	}
	return nil
}

@(private)
handle_typed :: proc(a: ^App) -> bool {
	op := typed_target(a)
	if op == nil {
		clear(&a.typed)
		return false
	}
	for c in a.ui.chars {
		if (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '=' || c == '+' || c == '*' || c == '/' || c == '(' || c == ')' || c == ' ' || (len(a.typed) > 0 && ((c >= 'a' && c <= 'z') || c == '"')) {
			append(&a.typed, u8(c))
		}
	}
	if len(a.typed) == 0 {return false}
	if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) {pop(&a.typed)}
	if rl.IsKeyPressed(.ESCAPE) {
		clear(&a.typed)
		return true
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		text := string(a.typed[:])
		absolute := strings.has_prefix(text, "=")
		if absolute {text = text[1:]}
		v, ok := model.parse_number(text)
		if !ok {
			toast(a, "Not a number", .Error)
		} else {
			switch op.kind {
			case .Move_Axis:
				sign: f32 = op.delta[op.axis] < 0 ? -1 : 1
				delta: Vec3
				delta[op.axis] = f32(v) * (absolute ? 1 : sign)
				apply_move(a, op, delta)
			case .Push_Pull:
				amount := f32(v)
				if absolute {amount = f32(v - op.dim_start)}
				apply_push_pull(a, op, amount)
			case .None, .Pending, .Orbit, .Pan, .Move_Plane:
			}
			if op == &a.drag {finish_drag(a)}
		}
		clear(&a.typed)
	}
	return true
}

// ---------------------------------------------------------------------------
// Frame input

viewport_input :: proc(a: ^App) {
	mouse := a.ui.mouse
	over_ui := ui.wants_mouse(&a.ui) && a.drag.kind == .None
	sh := f32(rl.GetScreenHeight())

	// hover feedback
	clear(&a.hover_ids)
	a.pp_hover = {}
	a.gizmo_hover = -1
	a.place_preview = {}
	if !over_ui && a.drag.kind == .None {
		switch a.tool {
		case .Select, .Move:
			if a.tool == .Move {a.gizmo_hover = gizmo_pick(a, mouse)}
			if a.gizmo_hover < 0 {
				pk := render.pick(&a.r, &a.res, screen_ray(a, mouse))
				if pk.hit {
					target := click_target(a, pk.id)
					collect_parts(a, {target}, &a.hover_ids)
				}
			}
		case .Push_Pull:
			a.pp_hover = face_under(a, mouse)
		case .Panel, .Turned, .Swept:
			a.place_preview = placement_at(a, mouse)
		}
	}

	// scroll, pinch
	pinch := platform.take_pinch()
	if !over_ui {
		st := &a.settings
		wheel := a.ui.wheel_v
		if a.ui.wheel_used {wheel = {}}
		zoom_amount: f32 = 0
		pan := false
		if wheel != {} {
			// one modifier flips the configured scroll action
			pan = st.scroll == .Pan
			if ui.cmd_down() || (ui.shift_down() && st.scroll == .Zoom) {pan = !pan}
			if pan {
				// trackpad deltas arrive scaled by 0.1; content follows the fingers
				orbit_pan(&a.cam, wheel.x * 10 * st.pan_speed, wheel.y * 10 * st.pan_speed, sh)
			} else {
				zoom_amount += wheel.y
			}
		}
		if st.pinch_zoom && pinch != 0 {zoom_amount += pinch * 7}
		if zoom_amount != 0 {
			zoom_amount *= st.zoom_speed
			if st.invert_zoom {zoom_amount = -zoom_amount}
			focus: Vec3
			has := false
			if st.zoom_to_cursor {
				pk := render.pick(&a.r, &a.res, screen_ray(a, mouse))
				focus = pk.point
				has = pk.hit
				if !has {
					if p, ok := plane_hit(screen_ray(a, mouse), 0); ok && linalg.length(p - a.cam.target) < a.cam.dist * 4 {
						focus = p
						has = true
					}
				}
			}
			orbit_zoom(&a.cam, zoom_amount, focus, has)
		}
	}

	// presses
	if !over_ui && a.drag.kind == .None {
		if rl.IsMouseButtonPressed(.RIGHT) {
			reset_drag(a)
			a.drag = {kind = .Orbit, button = .RIGHT, start_mouse = mouse}
			if ui.shift_down() {a.drag.kind = .Pan}
		} else if rl.IsMouseButtonPressed(.MIDDLE) {
			reset_drag(a)
			a.drag = {kind = .Pan, button = .MIDDLE, start_mouse = mouse}
		} else if a.ui.pressed {
			started := false
			if ui.alt_down() {
				a.drag = {kind = .Orbit, button = .LEFT, start_mouse = mouse}
				started = true
			}
			if !started && a.tool == .Move && len(a.selection) > 0 {
				if axis := gizmo_pick(a, mouse); axis >= 0 {
					clear_last_op(a)
					started = start_move(a, .Move_Axis, axis, mouse)
				} else {
					pk := render.pick(&a.r, &a.res, screen_ray(a, mouse))
					parts := make([dynamic]Id, context.temp_allocator)
					collect_parts(a, a.selection[:], &parts)
					if pk.hit && in_list(parts[:], pk.id) {
						clear_last_op(a)
						a.drag.plane_start = pk.point
						y := pk.point.y
						started = start_move(a, .Move_Plane, -1, mouse)
						a.drag.plane_start.y = y
						if p, ok := plane_hit(screen_ray(a, mouse), y); ok {a.drag.plane_start = p}
					}
				}
			}
			if !started && a.tool == .Push_Pull {
				f := face_under(a, mouse)
				if f.valid {
					clear_last_op(a)
					start_push_pull(a, f, mouse)
					started = true
				} else if f.part != 0 {
					toast(a, "Push/Pull works on the flat faces of panels")
				}
			}
			if !started {
				// shift: a drag pans, a click still toggles the selection
				a.drag = {kind = .Pending, button = .LEFT, start_mouse = mouse, pan_on_drag = ui.shift_down()}
			}
		}
	}

	// drags
	switch a.drag.kind {
	case .None:
	case .Pending:
		if linalg.length(mouse - a.drag.start_mouse) > 4 {
			pan := a.settings.left_drag == .Pan
			if a.drag.pan_on_drag {pan = !pan}
			a.drag.kind = pan ? .Pan : .Orbit
		} else if a.ui.released {
			click(a, mouse)
			reset_drag(a)
		}
	case .Orbit:
		dlt := a.ui.mouse_delta * a.settings.orbit_speed
		orbit_rotate(&a.cam, dlt.x, dlt.y)
		if button_released(a, a.drag.button) {reset_drag(a)}
	case .Pan:
		dlt := a.ui.mouse_delta
		orbit_pan(&a.cam, dlt.x, dlt.y, sh)
		if button_released(a, a.drag.button) {reset_drag(a)}
	case .Move_Axis, .Move_Plane:
		if len(a.typed) == 0 {update_move(a, mouse)}
		if a.ui.released {finish_drag(a)}
	case .Push_Pull:
		if len(a.typed) == 0 {update_push_pull(a, mouse)}
		if a.ui.released {finish_drag(a)}
	}
}

@(private)
click :: proc(a: ^App, mouse: Vec2) {
	switch a.tool {
	case .Panel, .Turned, .Swept:
		pp := placement_at(a, mouse)
		if pp.valid {place_part(a, pp)}
		return
	case .Select, .Move, .Push_Pull:
	}
	pk := render.pick(&a.r, &a.res, screen_ray(a, mouse))
	shift := ui.shift_down()
	clear_last_op(a)
	if !pk.hit {
		if !shift {
			clear(&a.selection)
			a.context_group = 0
		}
		return
	}
	target := click_target(a, pk.id)
	if a.ui.double_click {
		// drill into the group: select the part itself
		target = pk.id
		ref, _ := model.find_node(a.doc, pk.id)
		if ref.parent != nil && ref.parent != a.doc.root {a.context_group = ref.parent.id}
	}
	if shift {
		toggle_selected(a, target)
	} else {
		set_selection(a, target)
	}
}

// ---------------------------------------------------------------------------
// Keyboard

key_pressed :: proc(k: rl.KeyboardKey) -> bool {return rl.IsKeyPressed(k)}

handle_keys :: proc(a: ^App) {
	if ui.wants_keyboard(&a.ui) || a.dialog.kind != .None || a.show_settings {return}
	if handle_typed(a) {return}
	cmd := ui.cmd_down()
	shift := ui.shift_down()

	if key_pressed(.ESCAPE) {
		switch {
		case a.show_help:
			a.show_help = false
		case a.show_cutlist:
			a.show_cutlist = false
		case a.drag.kind != .None:
			cancel_drag(a)
		case a.tool != .Select:
			a.tool = .Select
		case a.context_group != 0:
			a.context_group = 0
			clear(&a.selection)
		case:
			clear(&a.selection)
		}
		clear_last_op(a)
		return
	}
	if cmd {
		switch {
		case key_pressed(.Z) && shift: redo(a)
		case key_pressed(.Z): undo(a)
		case key_pressed(.Y): redo(a)
		case key_pressed(.S) && shift: open_dialog(a, .Save_As)
		case key_pressed(.S):
			if a.path != "" {save_to(a, a.path)} else {open_dialog(a, .Save_As)}
		case key_pressed(.O): open_dialog(a, .Open)
		case key_pressed(.N):
			if a.modified {open_dialog(a, .Confirm_New)} else {new_document(a)}
		case key_pressed(.D): duplicate_selection(a)
		case key_pressed(.A):
			set_selection(a)
			for c in a.doc.root.children {append(&a.selection, model.node_id(c))}
		case key_pressed(.G): if len(a.selection) > 0 {apply(a, Cmd_Group{ids = a.selection[:]})}
		case key_pressed(.E): open_dialog(a, .Export_Csv)
		case key_pressed(.COMMA): a.show_settings = true
		}
		return
	}
	switch {
	case key_pressed(.V): a.tool = .Select
	case key_pressed(.M): a.tool = .Move
	case key_pressed(.P): a.tool = .Push_Pull
	case key_pressed(.B): a.tool = .Panel
	case key_pressed(.T): a.tool = .Turned
	case key_pressed(.S): a.tool = .Swept
	case key_pressed(.G) && shift:
		for id in a.selection {
			if model.find_group(a.doc, id) != nil {
				apply(a, Cmd_Ungroup{id = id})
				break
			}
		}
	case key_pressed(.G):
		if len(a.selection) > 0 {apply(a, Cmd_Group{ids = a.selection[:]})}
	case key_pressed(.E): open_editor_for_selection(a)
	case key_pressed(.F): frame_selection(a)
	case key_pressed(.H): toggle_hidden(a)
	case key_pressed(.R): a.show_room = !a.show_room
	case key_pressed(.L): a.show_cutlist = !a.show_cutlist
	case key_pressed(.K) || key_pressed(.F1) || (key_pressed(.SLASH) && shift): a.show_help = !a.show_help
	case key_pressed(.ONE): orbit_view(&a.cam, .Front)
	case key_pressed(.TWO): orbit_view(&a.cam, .Right)
	case key_pressed(.THREE): orbit_view(&a.cam, .Top)
	case key_pressed(.FOUR) || key_pressed(.ZERO): orbit_view(&a.cam, .Iso)
	case key_pressed(.DELETE) || key_pressed(.BACKSPACE): delete_selection(a)
	}
}

delete_selection :: proc(a: ^App) {
	if len(a.selection) == 0 {return}
	n := len(a.selection)
	apply(a, Cmd_Delete{ids = a.selection[:]})
	toast(a, fmt.tprintf("Deleted %d item%s", n, n == 1 ? "" : "s"))
}

duplicate_selection :: proc(a: ^App) {
	if len(a.selection) == 0 {return}
	apply(a, Cmd_Duplicate{ids = a.selection[:]})
	// nudge copies so they do not overlap the originals
	refresh(a)
	lo, hi, ok := nodes_bounds(a, a.selection[:])
	if ok {
		key := new_coalesce_key(a)
		a.last_coalesce = key // same undo step as the duplicate
		w := hi.x - lo.x + 50
		for id in a.selection {
			ref, found := model.find_node(a.doc, id)
			if !found {continue}
			xf := model.node_xf(ref.node)
			pw_inv := linalg.inverse(parent_world(a, id))
			ld := (pw_inv * [4]f32{w, 0, 0, 0}).xyz
			for i in 0 ..< 3 {
				if abs(ld[i]) < 1e-4 || !model.field_is_literal(xf.pos[i]) {continue}
				apply(a, Cmd_Solve{owner = id, field = &xf.pos[i], value = xf.pos[i].value + f64(ld[i])}, key)
			}
		}
	}
}

toggle_hidden :: proc(a: ^App) {
	for id in a.selection {
		ref, ok := model.find_node(a.doc, id)
		if !ok {continue}
		switch v in ref.node {
		case ^model.Part:  apply(a, Cmd_Toggle{flag = &v.hidden})
		case ^model.Group: apply(a, Cmd_Toggle{flag = &v.hidden})
		}
	}
}

@(private)
button_released :: proc(a: ^App, b: rl.MouseButton) -> bool {
	if b == .LEFT {return a.ui.released}
	return rl.IsMouseButtonReleased(b)
}
