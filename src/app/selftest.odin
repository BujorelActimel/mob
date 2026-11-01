package app

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:math/linalg"
import "core:os"
import "../geom"
import "../model"
import "../platform"
import "../ui"

// End-to-end checks of app-level editing, run inside a live window
// (`mob --selftest <dir>`). Exercises commands, undo, push/pull, move,
// grouping, files and exports against the default corner-shelf document.
@(private = "file")
check :: proc(all_ok: ^bool, cond: bool, msg: string, args: ..any) {
	fmt.println(cond ? "ok   " : "FAIL ", fmt.tprintf(msg, ..args))
	if !cond {all_ok^ = false}
}

selftest :: proc(a: ^App, out_dir: string) -> bool {
	all_ok := true
	part_named :: proc(a: ^App, name: string) -> ^model.Resolved_Part {
		for &rp in a.res.parts {if rp.part.name == name {return &rp}}
		return nil
	}
	origin :: proc(rp: ^model.Resolved_Part) -> Vec3 {return (rp.world * [4]f32{0, 0, 0, 1}).xyz}
	shelf_group :: proc(a: ^App) -> ^model.Group {
		g, _ := a.doc.root.children[0].(^model.Group)
		return g
	}

	refresh(a)
	check(&all_ok, len(a.res.parts) == 7 && a.res.error_count == 0, "default document: %d parts, %d errors", len(a.res.parts), a.res.error_count)

	// 1. resize through one group parameter
	g := shelf_group(a)
	hc := model.find_param(g.params[:], "H_comp")
	apply(a, Cmd_Set_Field{field = &hc.field, text = "350"})
	refresh(a)
	side := part_named(a, "Side")
	check(&all_ok, abs(pp_value(side, 0) - (4 * 350 + 5 * 18)) < 1e-3, "H_comp=350 resizes the side to %v", pp_value(side, 0))
	check(&all_ok, abs(origin(part_named(a, "Shelf 5")).y - 4 * 368) < 1e-3, "top shelf moves to %v", origin(part_named(a, "Shelf 5")).y)

	// 2. undo / redo
	undo(a)
	check(&all_ok, abs(pp_value(part_named(a, "Side"), 0) - 1410) < 1e-3, "undo restores side height")
	redo(a)
	check(&all_ok, abs(pp_value(part_named(a, "Side"), 0) - 1490) < 1e-3, "redo re-applies it")
	undo(a)

	// 3. push/pull on a shelf's right face: width is `W - t`, so W is edited
	{
		rp := part_named(a, "Shelf 1")
		op: Drag
		init_push_pull(a, &op, {valid = true, part = rp.id, axis = 0, sign = 1, world_dir = {1, 0, 0}})
		apply_push_pull(a, &op, 60)
		apply_push_pull(a, &op, 100) // same drag: one undo step
		refresh(a)
		g = shelf_group(a)
		w := model.find_param(g.params[:], "W")
		check(&all_ok, w.field.value == 520, "push/pull edits parameter W -> %v", w.field.value)
		check(&all_ok, abs(pp_value(part_named(a, "Shelf 3"), 0) - 502) < 1e-3, "other shelves follow (%v)", pp_value(part_named(a, "Shelf 3"), 0))
		check(&all_ok, abs(pp_value(part_named(a, "Back"), 0) - 520) < 1e-3, "back follows")
		drag_free(&op)
		undo(a)
		g = shelf_group(a)
		check(&all_ok, model.find_param(g.params[:], "W").field.value == 420, "one undo reverts the whole drag")
	}

	// 4. push/pull a loose panel's left face shifts its position
	{
		p := model.new_panel(a.doc, "Loose", "600", "300")
		model.field_set_value(a.doc, &p.xf.pos[0], 2000)
		apply(a, Cmd_Add_Node{node = p, parent = 0, select = true})
		refresh(a)
		rp := part_named(a, "Loose")
		op: Drag
		init_push_pull(a, &op, {valid = true, part = rp.id, axis = 0, sign = -1, world_dir = {-1, 0, 0}})
		apply_push_pull(a, &op, 50)
		refresh(a)
		rp = part_named(a, "Loose")
		check(&all_ok, abs(pp_value(rp, 0) - 650) < 1e-3 && abs(origin(rp).x - 1950) < 1e-3, "left-face pull grows to %v and shifts to x=%v", pp_value(rp, 0), origin(rp).x)
		drag_free(&op)
		// thickness face
		op2: Drag
		init_push_pull(a, &op2, {valid = true, part = rp.id, axis = 1, sign = 1, world_dir = {0, 1, 0}})
		apply_push_pull(a, &op2, 7)
		refresh(a)
		check(&all_ok, abs(part_named(a, "Loose").thickness - 25) < 1e-3, "top-face pull sets thickness 25")
		drag_free(&op2)
		apply(a, Cmd_Delete{ids = {part_named(a, "Loose").id}})
		refresh(a)
	}

	// 5. move the whole group
	{
		set_selection(a, shelf_group(a).id)
		op := Drag{kind = .Move_Axis, axis = 0, coalesce = new_coalesce_key(a)}
		m, _ := moving_of(a, shelf_group(a).id)
		append(&op.nodes, m)
		apply_move(a, &op, {250, 0, 0})
		refresh(a)
		check(&all_ok, abs(origin(part_named(a, "Back")).x - 250) < 1e-3, "move group +250 on X")
		// keep dragging the same way past zero into negative coordinates
		for dx in ([]f32{100, 0, -5, -150, -400}) {
			apply_move(a, &op, {dx, 0, 0})
			refresh(a)
		}
		x := origin(part_named(a, "Back")).x
		check(&all_ok, abs(x + 400) < 1e-3, "drag continues into negative X (x = %v)", x)
		apply_move(a, &op, {0, 0, -250})
		refresh(a)
		z := origin(part_named(a, "Side")).z
		check(&all_ok, abs(z + 250) < 1e-3, "and negative Z (z = %v)", z)
		delete(op.nodes)
		undo(a)
	}

	// 6. duplicate (copy + offset are one undo step)
	{
		set_selection(a, shelf_group(a).id)
		duplicate_selection(a)
		refresh(a)
		check(&all_ok, len(a.res.parts) == 14 && a.res.error_count == 0, "duplicate -> %d parts, %d errors", len(a.res.parts), a.res.error_count)
		lo, hi, _ := nodes_bounds(a, a.selection[:])
		check(&all_ok, lo.x > 400, "copy is placed beside the original (x %v..%v)", lo.x, hi.x)
		undo(a)
		check(&all_ok, len(a.res.parts) == 7, "undo removes the copy")
	}

	// 7. group two shelves inside the parametric group, then ungroup
	{
		s1 := part_named(a, "Shelf 1").id
		s2 := part_named(a, "Shelf 2").id
		before := origin(part_named(a, "Shelf 2"))
		apply(a, Cmd_Group{ids = {s1, s2}})
		refresh(a)
		check(&all_ok, a.res.error_count == 0 && len(a.res.parts) == 7, "nested group still sees outer params (%d errors)", a.res.error_count)
		check(&all_ok, linalg.length(origin(part_named(a, "Shelf 2")) - before) < 1e-3, "grouping keeps placement")
		gid := a.selection[0]
		apply(a, Cmd_Ungroup{id = gid})
		refresh(a)
		check(&all_ok, model.find_group(a.doc, gid) == nil && linalg.length(origin(part_named(a, "Shelf 2")) - before) < 1e-3, "ungroup restores")
	}

	// 8. converting a rectangle to a free outline keeps the shape and expressions
	{
		rp := part_named(a, "Shelf 1")
		b0 := geom.contour_bounds(rp.profile.outer)
		cv := Convert{rp.part}
		apply(a, Cmd_Custom{fn = convert_to_polygon, data = &cv})
		refresh(a)
		rp = part_named(a, "Shelf 1")
		b1 := geom.contour_bounds(rp.profile.outer)
		arcs := 0
		for s in rp.profile.outer.segs {if _, is_arc := s.(geom.Arc); is_arc {arcs += 1}}
		check(&all_ok, linalg.length(b0.max - b1.max) < 1e-2 && arcs == 1 && a.res.error_count == 0, "free outline matches the rectangle (arcs %d)", arcs)
	}

	// 9. renaming a parameter rewrites its uses
	{
		g = shelf_group(a)
		p := model.find_param(g.params[:], "H_comp")
		rename_param(a, p, "Hc")
		refresh(a)
		h := model.find_param(shelf_group(a).params[:], "H")
		check(&all_ok, a.res.error_count == 0 && h.field.src == "4*Hc + 5*t", "rename H_comp -> Hc rewrites '%s'", h.field.src)
	}

	// 10. templates
	{
		n := len(a.res.parts)
		place_template(a, model.TEMPLATES[3])
		check(&all_ok, len(a.res.parts) == n + 5 && a.res.error_count == 0, "table template adds 5 parts")
	}

	// 11. files
	{
		path := join_path({out_dir, "selftest.mob"})
		check(&all_ok, save_to(a, path), "save %s", path)
		check(&all_ok, strings.has_suffix(a.settings.last_file, "selftest.mob"), "saving remembers it as the last project")
		hashes := make([dynamic]u64, context.temp_allocator)
		for rp in a.res.parts {append(&hashes, rp.hash)}
		check(&all_ok, open_document(a, path), "reopen")
		same := len(hashes) == len(a.res.parts)
		for rp, i in a.res.parts {if same && rp.hash != hashes[i] {same = false}}
		check(&all_ok, same, "reopened geometry identical (%d parts)", len(a.res.parts))
		for k in ([]Dialog_Kind{.Export_Csv, .Export_Svg, .Export_Obj}) {
			ext := k == .Export_Csv ? "csv" : (k == .Export_Svg ? "svg" : "obj")
			out := join_path({out_dir, fmt.tprintf("selftest.%s", ext)})
			clear(&a.selection)
			export_to(a, k, out)
			check(&all_ok, os.exists(out), "export %s", ext)
		}
	}
	return all_ok
}

// Clicks real UI controls through simulated mouse input.
ui_selftest :: proc(a: ^App) -> bool {
	all_ok := true
	step :: proc(a: ^App, n := 1) {
		for _ in 0 ..< n {
			frame(a)
			free_all(context.temp_allocator)
		}
	}
	click_at :: proc(a: ^App, p: Vec2) {
		a.ui.sim_mouse = p
		step(a, 2) // hover
		a.ui.sim_down = true
		step(a)
		a.ui.sim_down = false
		step(a)
	}
	click_button :: proc(a: ^App, id: ui.Id) -> bool {
		r, ok := a.ui.rects[id]
		if !ok {return false}
		click_at(a, {r.x + r.width * 0.5, r.y + r.height * 0.5})
		return true
	}
	// run against default preferences, never touching the user's settings file
	a.settings_readonly = true
	reset_settings(a)
	a.ui.sim = true
	a.ui.sim_mouse = {-100, -100}
	step(a, 3)

	check(&all_ok, click_button(a, ui.id_n(ui.id("tool"), 1)) && a.tool == .Move, "toolbar: Move tool button")
	check(&all_ok, click_button(a, ui.id_n(ui.id("tool"), 0)) && a.tool == .Select, "toolbar: Select tool button")
	// menus: open, then click an entry
	add_id := ui.id("add-menu")
	check(&all_ok, click_button(a, add_id) && a.ui.popup.id == add_id, "toolbar: Add opens its menu")
	check(&all_ok, click_button(a, ui.id_n(add_id, 0)) && a.tool == .Panel && a.ui.popup.id == 0, "add menu: Panel picks the place tool")
	a.tool = .Select
	file_id := ui.id("file-menu")
	check(&all_ok, click_button(a, file_id) && click_button(a, ui.id_n(file_id, 4)) && a.show_cutlist, "file menu: Cut list")
	a.show_cutlist = false
	check(&all_ok, click_button(a, ui.id_n(ui.id("view"), 2)) && a.cam.pitch_goal > 1.5, "view buttons: Top")
	check(&all_ok, click_button(a, ui.id_n(ui.id("view"), 3)) && a.cam.pitch_goal < 0.5, "view buttons: 3D")
	step(a, 40) // let the camera settle

	// click the shelf in the viewport: selects its group
	lo, hi, _ := nodes_bounds(a, {model.node_id(a.doc.root.children[0])})
	sp := world_to_screen(a, (lo + hi) * 0.5 + {0, 0, 0})
	clear(&a.selection)
	click_at(a, sp)
	check(&all_ok, len(a.selection) == 1 && a.selection[0] == model.node_id(a.doc.root.children[0]), "viewport click selects the shelf group")

	g, _ := a.doc.root.children[0].(^model.Group)
	n := len(g.params)
	check(&all_ok, click_button(a, fid(g.id, "padd")) && len(g.params) == n + 1, "inspector: + Parameter")
	check(&all_ok, click_button(a, ui.id("undo")), "toolbar: undo button")
	g, _ = a.doc.root.children[0].(^model.Group)
	check(&all_ok, len(g.params) == n, "undo removed the parameter")

	parts := len(a.res.parts)
	check(&all_ok, click_button(a, add_id) && click_button(a, ui.id_n(add_id, 4)) && len(a.res.parts) == parts + 5, "add menu: Box template")
	check(&all_ok, click_button(a, ui.id("undo")) && len(a.res.parts) == parts, "undo the template")

	// shift + left drag pans, whether or not something is selected
	for with_sel in ([]bool{false, true}) {
		if with_sel {set_selection(a, model.node_id(a.doc.root.children[0]))} else {clear(&a.selection)}
		sel_before := len(a.selection)
		t0 := a.cam.target_goal
		yaw0 := a.cam.yaw_goal
		a.ui.sim_shift = true
		a.ui.sim_mouse = {a.viewport.x + 200, a.viewport.y + a.viewport.height - 120}
		step(a, 2)
		a.ui.sim_down = true
		step(a)
		for _ in 1 ..= 10 {
			a.ui.sim_mouse += {8, 3}
			step(a)
		}
		a.ui.sim_down = false
		step(a)
		a.ui.sim_shift = false
		moved := linalg.length(a.cam.target_goal - t0) > 1
		check(&all_ok, moved && a.cam.yaw_goal == yaw0 && len(a.selection) == sel_before, "shift-drag pans (selection: %v)", with_sel)
	}

	// ---- settings
	override := strings.clone(join_path({a.docs_dir_for_tests, "settings-selftest.json"}))
	defer delete(override)
	settings_path_override = override
	check(&all_ok, platform.gestures_ready(), "native pinch monitor installed")
	check(&all_ok, platform.has_file_chooser(), "native file chooser available")
	check(&all_ok, click_button(a, ui.id("settings-btn")) && a.show_settings, "toolbar: settings button opens settings")
	step(a, 2)
	check(&all_ok, click_button(a, ui.id_n(ui.id("set-preset"), 1)) && a.settings.scroll == .Pan && a.settings.pinch_zoom, "settings: Trackpad preset")
	check(&all_ok, click_button(a, ui.id("set-done")) && !a.show_settings, "settings: Done closes")
	{
		saved := Settings{}
		data, err := os.read_entire_file(settings_path(), context.temp_allocator)
		ok := err == nil && json.unmarshal(data, &saved, allocator = context.temp_allocator) == nil
		check(&all_ok, ok && saved.scroll == .Pan, "settings saved to disk")
	}
	viewport_mid := Vec2{a.viewport.x + a.viewport.width * 0.5, a.viewport.y + a.viewport.height * 0.6}
	a.ui.sim_mouse = viewport_mid
	step(a, 30)
	{
		// scroll pans (camera target moves, distance stays)
		d0 := a.cam.dist_goal
		t0 := a.cam.target_goal
		a.ui.sim_wheel = {0, 3}
		step(a)
		check(&all_ok, linalg.length(a.cam.target_goal - t0) > 1 && abs(a.cam.dist_goal - d0) < 1e-3, "trackpad: scroll pans")
		// pinch zooms in
		d0 = a.cam.dist_goal
		platform.inject_pinch(0.2)
		step(a)
		check(&all_ok, a.cam.dist_goal < d0 * 0.9, "trackpad: pinch zooms (%v -> %v)", d0, a.cam.dist_goal)
		// cmd + scroll zooms
		d0 = a.cam.dist_goal
		a.ui.sim_cmd = true
		a.ui.sim_wheel = {0, -2}
		step(a)
		a.ui.sim_cmd = false
		check(&all_ok, a.cam.dist_goal > d0 * 1.1, "trackpad: Cmd + scroll zooms")
		// pinch disabled -> ignored
		a.settings.pinch_zoom = false
		d0 = a.cam.dist_goal
		platform.inject_pinch(0.3)
		step(a)
		check(&all_ok, a.cam.dist_goal == d0, "pinch off: ignored")
		// mouse preset: scroll zooms again
		reset_settings(a)
		d0 = a.cam.dist_goal
		a.ui.sim_wheel = {0, 2}
		step(a)
		check(&all_ok, a.cam.dist_goal < d0 * 0.9, "mouse: scroll zooms")
		// left drag set to pan: a plain drag pans
		a.settings.left_drag = .Pan
		clear(&a.selection)
		t0 = a.cam.target_goal
		y0 := a.cam.yaw_goal
		a.ui.sim_mouse = {a.viewport.x + 220, a.viewport.y + a.viewport.height - 110}
		step(a, 2)
		a.ui.sim_down = true
		step(a)
		for _ in 0 ..< 8 {a.ui.sim_mouse += {9, 2}; step(a)}
		a.ui.sim_down = false
		step(a)
		check(&all_ok, linalg.length(a.cam.target_goal - t0) > 1 && a.cam.yaw_goal == y0, "left-drag setting: Pan")
		reset_settings(a)
	}
	settings_path_override = ""

	a.ui.sim = false
	return all_ok
}
