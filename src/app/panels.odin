package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import mobio "../io"
import "../model"
import "../render"
import "../ui"

MARGIN :: 12
LEFT_W :: 300
RIGHT_W :: 350
TOP_H :: 48

// ---------------------------------------------------------------------------
// Outliner

Tree_Drag :: struct {
	src:    Id,
	start:  Vec2,
	active: bool,
	parent: Id, // drop target group
	index:  int,
	line_y: f32,
	line_x: f32,
}

@(private)
node_sub :: proc(a: ^App, n: model.Node) -> string {
	switch v in n {
	case ^model.Group:
		return fmt.tprintf("%d", model.count_parts(v))
	case ^model.Part:
		rp := resolved_part(a, v.id)
		if rp == nil {return v.hidden ? "hidden" : ""}
		switch rp.kind {
		case .Panel:
			return fmt.tprintf("%s×%s×%s", model.format_number(math.round(pp_value(rp, 0))), model.format_number(math.round(pp_value(rp, 2))), model.format_number(f64(rp.thickness)))
		case .Turned:
			rmax, hmax: f32
			for p in rp.line {rmax = max(rmax, p.x); hmax = max(hmax, p.y)}
			return fmt.tprintf("Ø%s×%s", model.format_number(f64(math.round(2 * rmax))), model.format_number(f64(math.round(hmax))))
		case .Swept:
			return "swept"
		}
	}
	return ""
}

@(private)
tree_nodes :: proc(a: ^App, g: ^model.Group, depth: int) {
	td := &a.tree_drag
	for c, i in g.children {
		id := model.node_id(c)
		grp, is_group := c.(^model.Group)
		hidden := false
		switch v in c {
		case ^model.Part:  hidden = v.hidden
		case ^model.Group: hidden = v.hidden
		}
		y0 := a.ui.lay.y
		res := ui.tree_row(&a.ui, ui.id_n(ui.id("tree"), int(id)), depth, model.node_name(c), node_sub(a, c), is_selected(a, id), is_group && len(grp.children) > 0, is_group && grp.expanded, hidden)
		row := ui.Rect{a.ui.lay.x, y0 - (ui.GAP - 2), a.ui.lay.w, 28}
		if res.toggled && is_group {grp.expanded = !grp.expanded}
		if res.clicked {
			if ui.shift_down() {
				toggle_selected(a, id)
			} else if !is_selected(a, id) || len(a.selection) > 1 {
				set_selection(a, id)
			}
			if res.double {frame_selection(a)}
			td^ = {src = id, start = a.ui.mouse}
		}
		// drop target while dragging
		if td.active && res.hovered && td.src != id {
			rel := (a.ui.mouse.y - row.y) / row.height
			if is_group && rel > 0.25 && rel < 0.75 {
				td.parent = id
				td.index = -1
				td.line_y = -1
			} else {
				td.parent = g.id
				td.index = rel < 0.5 ? i : i + 1
				td.line_y = rel < 0.5 ? row.y : row.y + row.height
				td.line_x = row.x + 4 + f32(depth) * 14
			}
		}
		if is_group && grp.expanded {tree_nodes(a, grp, depth + 1)}
	}
}

outliner :: proc(a: ^App, r: rl.Rectangle) {
	td := &a.tree_drag
	pid := ui.id("outliner")
	ui.panel_begin(&a.ui, pid, r, "Scene")
	if td.active {
		td.parent = 0
		td.index = -1
		td.line_y = -1
	}
	if len(a.doc.root.children) == 0 {ui.label(&a.ui, "Nothing here yet.", .Regular, ui.THEME.text_faint)}
	tree_nodes(a, a.doc.root, 0)
	ui.panel_end(&a.ui)

	// drag and drop reparenting
	if td.src != 0 {
		if !td.active && a.ui.down && linalg.length(a.ui.mouse - td.start) > 5 {td.active = true}
		if td.active {
			a.ui.active = pid
			if td.line_y >= 0 && td.parent != 0 {
				rl.DrawRectangleRec({td.line_x, td.line_y - 1, r.x + r.width - MARGIN - td.line_x, 2}, ui.THEME.accent)
			}
			label := model.node_name(node_or_nil(a, td.src))
			w := ui.text_width(&a.ui, label) + 16
			ui.rounded({a.ui.mouse.x + 12, a.ui.mouse.y + 4, w, 22}, 5, {50, 53, 60, 235})
			ui.draw_text(&a.ui, label, a.ui.mouse.x + 20, a.ui.mouse.y + 7)
		}
		if a.ui.released || !a.ui.down {
			if td.active {
				target := td.parent
				if target == 0 && rl.CheckCollisionPointRec(a.ui.mouse, r) {target = a.doc.root.id}
				if target != 0 {
					parent := target == a.doc.root.id ? Id(0) : target
					apply(a, Cmd_Reparent{id = td.src, parent = parent, index = td.index})
				}
			}
			td^ = {}
		}
	}
}

@(private)
node_or_nil :: proc(a: ^App, id: Id) -> model.Node {
	ref, ok := model.find_node(a.doc, id)
	if !ok {return nil}
	return ref.node
}

// ---------------------------------------------------------------------------
// Library

place_template :: proc(a: ^App, t: model.Template) {
	d := a.doc
	g := t.build(d)
	g.name = model.unique_name(d, g.name)
	if a.r.has_scene && len(a.res.parts) > 0 {
		model.field_set_value(d, &g.xf.pos[0], f64(math.round(a.r.scene_hi.x + 300)))
	}
	apply(a, Cmd_Add_Node{node = g, parent = 0, select = true})
	refresh(a)
	frame_selection(a)
	toast(a, fmt.tprintf("Placed %s — edit its parameters on the right", g.name), .Good)
}

// ---------------------------------------------------------------------------
// Toolbar with drawn icons

// A button that opens a popup menu. Returns the chosen index, or -1.
menu_button :: proc(a: ^App, mid: ui.Id, r: rl.Rectangle, options: []string, align_right := false) -> int {
	if a.ui.pressed && ui.hovered(&a.ui, r) && a.ui.popup.id == 0 {
		a.ui.popup = {id = mid, anchor = r}
	}
	if a.ui.popup.id == mid {
		w: f32 = 0
		for o in options {w = max(w, ui.text_width(&a.ui, o) + 34)}
		x := align_right ? r.x + r.width - w : r.x
		a.ui.popup.anchor = {x, r.y, w, r.height}
		a.ui.popup.options = options
	}
	if a.ui.popup_choice_id == mid && a.ui.popup_choice >= 0 {
		c := a.ui.popup_choice
		a.ui.popup_choice = -1
		a.ui.popup_choice_id = 0
		return c
	}
	return -1
}

ADD_MENU := []string{"Panel   B", "Turned part   T", "Swept part   S", "Corner vinyl shelf", "Box", "Shelf unit", "Table"}

@(private)
tool_button :: proc(a: ^App, id: ui.Id, r: rl.Rectangle, ic: ui.Icon, on: bool, tip: string, enabled := true) -> bool {
	clicked := ui.button_rect(&a.ui, id, r, "", .Ghost, on, tip)
	col := on ? ui.THEME.accent : (enabled ? ui.THEME.text : ui.THEME.text_faint)
	ui.icon(ic, {r.x + r.width * 0.5, r.y + r.height * 0.5}, col)
	return clicked
}

toolbar :: proc(a: ^App, area: rl.Rectangle) {
	bw: f32 = 38
	gap: f32 = 4
	sep: f32 = 14
	add_w: f32 = 84
	w := 8 + add_w + sep + 3 * (bw + gap) + sep + 2 * (bw + gap) + sep + bw + 4
	r := rl.Rectangle{math.round(area.x + (area.width - w) * 0.5), area.y, w, 46}
	ui.shadowed_card(r, 8, ui.THEME.bg_panel)
	ui.block(&a.ui, r)
	x := r.x + 4
	y := r.y + 4
	separator :: proc(x: f32, y: f32) {rl.DrawRectangleRec({math.round(x), y + 9, 1, 20}, ui.THEME.border)}

	// add menu: parts and templates
	ar := rl.Rectangle{x, y, add_w, bw}
	add_id := ui.id("add-menu")
	open := a.ui.popup.id == add_id
	on := open || a.tool == .Panel || a.tool == .Turned || a.tool == .Swept
	ui.button_rect(&a.ui, add_id, ar, "", on ? .Primary : .Normal, false, "Add a part or a template")
	fg := on ? rl.Color{30, 20, 10, 255} : ui.THEME.text
	ui.icon(.Add, {ar.x + 18, ar.y + bw * 0.5}, fg)
	ui.text_in(&a.ui, "Add", {ar.x + 32, ar.y, add_w - 36, bw}, .Semibold, fg)
	switch c := menu_button(a, add_id, ar, ADD_MENU); c {
	case 0: a.tool = .Panel
	case 1: a.tool = .Turned
	case 2: a.tool = .Swept
	case 3 ..< 3 + len(model.TEMPLATES):
		place_template(a, model.TEMPLATES[c - 3])
	}
	x += add_w + sep * 0.5
	separator(x, y)
	x += sep * 0.5

	tools := [?]struct {
		tool: Tool,
		ic:   ui.Icon,
	}{{.Select, .Select}, {.Move, .Move}, {.Push_Pull, .Push_Pull}}
	for t, i in tools {
		if tool_button(a, ui.id_n(ui.id("tool"), i), {x, y, bw, bw}, t.ic, a.tool == t.tool, TOOL_INFO[t.tool].tip) {
			a.tool = t.tool
			clear_last_op(a)
		}
		x += bw + gap
	}
	x += sep * 0.5 - gap
	separator(x, y)
	x += sep * 0.5
	if tool_button(a, ui.id("undo"), {x, y, bw, bw}, .Undo, false, fmt.tprintf("Undo  Cmd+Z  (%d steps)", len(a.undo)), len(a.undo) > 0) {undo(a)}
	x += bw + gap
	if tool_button(a, ui.id("redo"), {x, y, bw, bw}, .Redo, false, "Redo  Cmd+Shift+Z", len(a.redo) > 0) {redo(a)}
	x += bw + gap
	x += sep * 0.5 - gap
	separator(x, y)
	x += sep * 0.5
	if tool_button(a, ui.id("settings-btn"), {x, y, bw, bw}, .Settings, a.show_settings, "Settings  Cmd+,") {a.show_settings = true}
}

view_buttons :: proc(a: ^App, area: rl.Rectangle) {
	labels := [?]string{"Front", "Side", "Top", "3D"}
	views := [?]View{.Front, .Right, .Top, .Iso}
	bw: f32 = 54
	w: f32 = 4 * bw + 8
	r := rl.Rectangle{area.x + area.width - w, area.y, w, 38}
	ui.shadowed_card(r, 8, ui.THEME.bg_panel)
	ui.block(&a.ui, r)
	for l, i in labels {
		br := rl.Rectangle{r.x + 4 + f32(i) * bw, r.y + 4, bw, 30}
		if ui.button_rect(&a.ui, ui.id_n(ui.id("view"), i), br, l, .Ghost, false, fmt.tprintf("%s view  (%d)", l, i + 1), .Regular) {
			orbit_view(&a.cam, views[i])
		}
	}
}

// ---------------------------------------------------------------------------
// File bar (top of the left column): name and one menu

FILE_MENU := []string{"New   Cmd+N", "Open...   Cmd+O", "Save   Cmd+S", "Save as...   Cmd+Shift+S", "Cut list   L", "Export cut list (CSV)...", "Export outlines (SVG)...", "Export model (OBJ)..."}

file_bar :: proc(a: ^App, r: rl.Rectangle) {
	ui.shadowed_card(r, 8, ui.THEME.bg_panel)
	ui.block(&a.ui, r)
	ui.text_in(&a.ui, "mob", {r.x + 14, r.y, 70, r.height}, .Big, ui.THEME.accent)
	name := a.doc.name
	if a.modified {name = fmt.tprintf("%s *", name)}
	ui.text_in(&a.ui, name, {r.x + 84, r.y, r.width - 84 - 48, r.height}, .Regular, ui.THEME.text_dim)
	mr := rl.Rectangle{r.x + r.width - 44, r.y + 5, 38, r.height - 10}
	mid := ui.id("file-menu")
	ui.button_rect(&a.ui, mid, mr, "", .Ghost, a.ui.popup.id == mid, "File")
	ui.icon(.Menu, {mr.x + mr.width * 0.5, mr.y + mr.height * 0.5}, ui.THEME.text)
	switch menu_button(a, mid, mr, FILE_MENU, true) {
	case 0: if a.modified {open_dialog(a, .Confirm_New)} else {new_document(a)}
	case 1: open_dialog(a, .Open)
	case 2: if a.path != "" {save_to(a, a.path)} else {open_dialog(a, .Save_As)}
	case 3: open_dialog(a, .Save_As)
	case 4: a.show_cutlist = true
	case 5: open_dialog(a, .Export_Csv)
	case 6: open_dialog(a, .Export_Svg)
	case 7: open_dialog(a, .Export_Obj)
	}
}

// ---------------------------------------------------------------------------
// Status bar, toasts

status_bar :: proc(a: ^App, area: rl.Rectangle) {
	hint := ""
	switch a.tool {
	case .Select:
		nav := a.settings.scroll == .Pan ? "pinch to zoom" : "scroll to zoom"
		drag := a.settings.left_drag == .Pan ? "drag to pan" : "drag to orbit"
		hint = fmt.tprintf("Click to select · double-click for a part · %s · %s", drag, nav)
	case .Move:      hint = "Drag an arrow or the piece · type a distance, then Enter"
	case .Push_Pull: hint = "Drag a face to resize · type a distance or =size, then Enter"
	case .Panel, .Turned, .Swept: hint = "Click the floor or a face to place · Esc cancels"
	}
	if a.context_group != 0 {
		if g := model.find_group(a.doc, a.context_group); g != nil {hint = fmt.tprintf("Inside %s (Esc to leave) · %s", g.name, hint)}
	}
	if len(a.typed) > 0 {hint = fmt.tprintf("Distance: %s  (Enter to apply, Esc to cancel)", string(a.typed[:]))}
	h: f32 = 26
	r := rl.Rectangle{area.x, area.y + area.height - h, area.width, h}
	w := ui.text_width(&a.ui, hint, .Small) + 24
	pill := rl.Rectangle{r.x, r.y, min(w, r.width - 170), h}
	ui.rounded(pill, 8, {24, 26, 30, 200})
	ui.text_in(&a.ui, hint, ui.inset(pill, 4) , .Small, len(a.typed) > 0 ? ui.THEME.accent : ui.THEME.text_dim)
	stats := fmt.tprintf("%d parts · %.1f ms", len(a.res.parts), a.frame_ms)
	if a.res.error_count > 0 {stats = fmt.tprintf("%d errors · %s", a.res.error_count, stats)}
	sw := ui.text_width(&a.ui, stats, .Small) + 20
	sp := rl.Rectangle{r.x + r.width - sw, r.y, sw, h}
	ui.rounded(sp, 8, {24, 26, 30, 200})
	ui.text_in(&a.ui, stats, sp, .Small, a.res.error_count > 0 ? ui.THEME.error : ui.THEME.text_faint, .Center)
}

toasts :: proc(a: ^App, area: rl.Rectangle) {
	y := area.y + area.height - 70
	#reverse for &t, i in a.toasts {
		t.age += a.ui.dt
		life: f32 = t.kind == .Error ? 4 : 2.6
		if t.age > life {
			delete(t.text)
			ordered_remove(&a.toasts, i)
			continue
		}
		alpha := min(1, t.age * 8, (life - t.age) * 3)
		w := ui.text_width(&a.ui, t.text) + 34
		r := rl.Rectangle{area.x + (area.width - w) * 0.5, y - (1 - min(1, t.age * 8)) * 8, w, 32}
		ui.shadowed_card(r, 9, ui.fade({36, 38, 43, 250}, alpha))
		dot := ui.THEME.text_dim
		switch t.kind {
		case .Info:
		case .Good:  dot = ui.THEME.good
		case .Error: dot = ui.THEME.error
		}
		rl.DrawCircleV({r.x + 14, r.y + 16}, 3.5, ui.fade(dot, alpha))
		ui.text_in(&a.ui, t.text, {r.x + 24, r.y, w - 30, 32}, .Regular, ui.fade(ui.THEME.text, alpha))
		y -= 40
		a.ui.animating = true
	}
}

// ---------------------------------------------------------------------------
// Dialogs (paths are typed; files can also be dropped on the window)

open_dialog :: proc(a: ^App, kind: Dialog_Kind) {
	a.dialog.kind = kind
	delete(a.dialog.path)
	p := ""
	switch kind {
	case .Open:       p = a.path != "" ? filepath.dir(a.path) : a.docs_dir
	case .Save_As:    p = default_path(a, ".mob")
	case .Export_Csv: p = default_path(a, " cut list.csv")
	case .Export_Svg: p = default_path(a, " panels.svg")
	case .Export_Obj: p = default_path(a, ".obj")
	case .None, .Confirm_New:
	}
	if kind == .Open && !strings.has_suffix(p, "/") {p = strings.concatenate({p, "/"}, context.temp_allocator)}
	a.dialog.path = strings.clone(p)
	a.dialog.focus = true
}

dialog :: proc(a: ^App, screen: rl.Rectangle) {
	dk := a.dialog.kind
	if dk == .None {return}
	rl.DrawRectangleRec(screen, {10, 11, 13, 110})
	ui.block(&a.ui, screen)
	w: f32 = 700
	titles := [Dialog_Kind]string {
		.None        = "",
		.Open        = "Open document",
		.Save_As     = "Save document",
		.Export_Csv  = "Export cut list",
		.Export_Svg  = "Export panel outlines (1:1 SVG)",
		.Export_Obj  = "Export 3D model",
		.Confirm_New = "Discard unsaved changes?",
	}
	files := make([dynamic]string, context.temp_allocator)
	if dk == .Open {
		dir := a.dialog.path
		if !os.is_dir(dir) {dir = filepath.dir(dir)}
		if entries, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
			for e in entries {
				if strings.has_suffix(e.name, ".mob") {append(&files, e.fullpath)}
			}
		}
		slice.sort(files[:])
	}
	h: f32 = dk == .Confirm_New ? 130 : 150 + f32(min(len(files), 8)) * 28
	r := rl.Rectangle{screen.x + (screen.width - w) * 0.5, screen.y + screen.height * 0.28, w, h}
	ui.shadowed_card(r, 12, {32, 34, 39, 252})
	a.ui.lay = {rect = ui.inset(r, 18), x = r.x + 18, y = r.y + 18, w = w - 36}
	a.ui.panel_id = ui.id("dialog")
	ui.label(&a.ui, titles[dk], .Title)
	done, cancel := false, false
	if dk == .Confirm_New {
		ui.label(&a.ui, "The current document has unsaved changes.", .Regular, ui.THEME.text_dim)
	} else {
		fr := ui.next_row(&a.ui, 30)
		did := ui.id("dialog-path")
		if a.dialog.focus {
			a.ui.focus = 0
			a.dialog.focus = false
			// focus the field this frame
			a.ui.tab_from = ui.id("dialog-anchor")
			a.ui.last_field = a.ui.tab_from
			a.ui.tab_pending = true
		}
		res := ui.text_field(&a.ui, did, fr, a.dialog.path, {})
		if res.committed {
			delete(a.dialog.path)
			a.dialog.path = strings.clone(res.text)
			if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {done = true}
		}
		if res.cancelled {cancel = true}
		if a.ui.focus == did {
			// keep the live text so the buttons use it
			delete(a.dialog.path)
			a.dialog.path = strings.clone(string(a.ui.edit.buf[:]))
		}
		for f, i in files {
			if i >= 8 {break}
			row := ui.next_row(&a.ui, 24)
			row.y -= 2
			if ui.button_rect(&a.ui, ui.id_n(ui.id("dlgfile"), i), row, "", .Ghost) {
				delete(a.dialog.path)
				a.dialog.path = strings.clone(f)
				done = true
			}
			ui.text_in(&a.ui, filepath.base(f), {row.x + 10, row.y, row.width - 20, row.height}, .Regular, ui.THEME.text)
		}
	}
	br := rl.Rectangle{r.x + r.width - 18 - 200, r.y + r.height - 18 - 30, 200, 30}
	cols := ui.columns(br, {1, 1})
	if ui.button_rect(&a.ui, ui.id("dlg-cancel"), cols[0], "Cancel") {cancel = true}
	ok_label := dk == .Open ? "Open" : (dk == .Save_As ? "Save" : (dk == .Confirm_New ? "Discard" : "Export"))
	if ui.button_rect(&a.ui, ui.id("dlg-ok"), cols[1], ok_label, .Primary) {done = true}
	if rl.IsKeyPressed(.ESCAPE) && a.ui.focus == 0 {cancel = true}
	if dk == .Confirm_New && (rl.IsKeyPressed(.ENTER)) {done = true}

	if done {
		path := strings.clone(a.dialog.path, context.temp_allocator)
		if strings.has_prefix(path, "~/") {
			home, _ := os.user_home_dir(context.temp_allocator)
			path = join_path({home, path[2:]})
		}
		a.dialog.kind = .None
		switch dk {
		case .Open:
			open_document(a, path)
		case .Save_As:
			if !strings.has_suffix(path, ".mob") {path = strings.concatenate({path, ".mob"}, context.temp_allocator)}
			save_to(a, path)
		case .Export_Csv, .Export_Svg, .Export_Obj:
			export_to(a, dk, path)
		case .Confirm_New:
			new_document(a)
		case .None:
		}
	} else if cancel {
		a.dialog.kind = .None
	}
}

// ---------------------------------------------------------------------------
// Help and cut list overlays

help_overlay :: proc(a: ^App, screen: rl.Rectangle) {
	rows := [?][2]string {
		{"V  M  P", "Select · Move · Push/Pull"},
		{"B  T  S", "Place a panel · turned · swept part"},
		{"G   Shift+G", "Group · ungroup"},
		{"E", "Edit outline / profile / path"},
		{"Cmd+Z   Cmd+Shift+Z", "Undo · redo"},
		{"Cmd+D   Delete", "Duplicate · delete"},
		{"Cmd+S   Cmd+O   Cmd+N", "Save · open · new"},
		{"1  2  3  4", "Front · side · top · 3D view"},
		{"F   H", "Frame selection · hide/show"},
		{"R   L", "Room backdrop · cut list"},
		{"Tab", "Next field"},
		{"Esc", "Cancel · leave group · deselect"},
		{"Cmd+,", "Settings: scroll, pinch, speeds, snapping"},
		{"Drag / Shift+drag", "Orbit / pan (swappable in settings)"},
		{"Drag a field label", "Change the number (Shift ×10, Opt ×0.1)"},
		{"Expressions", "W - 2*t,  1.8cm,  max(a, b),  round(x, 5)"},
	}
	w: f32 = 720
	h: f32 = 70 + f32(len(rows)) * 28
	r := rl.Rectangle{screen.x + (screen.width - w) * 0.5, screen.y + (screen.height - h) * 0.5, w, h}
	ui.shadowed_card(r, 14, {30, 32, 37, 248})
	ui.block(&a.ui, r)
	ui.text_in(&a.ui, "Keyboard", {r.x + 22, r.y + 14, 200, 26}, .Title)
	ui.text_in(&a.ui, "K or Esc to close", {r.x, r.y + 14, r.width - 22, 26}, .Small, ui.THEME.text_faint, .Right)
	for row, i in rows {
		y := r.y + 54 + f32(i) * 28
		ui.text_in(&a.ui, row[0], {r.x + 22, y, 250, 26}, .Semibold, ui.THEME.accent)
		ui.text_in(&a.ui, row[1], {r.x + 280, y, r.width - 300, 26}, .Regular, ui.THEME.text_dim)
	}
	if a.ui.pressed && !rl.CheckCollisionPointRec(a.ui.mouse, r) {a.show_help = false}
}

cut_list_overlay :: proc(a: ^App, area: rl.Rectangle) {
	rows := mobio.cut_list(&a.res, context.temp_allocator)
	w: f32 = min(760, area.width - 40)
	h: f32 = min(area.height - 120, 200 + f32(len(rows)) * 28)
	r := rl.Rectangle{area.x + (area.width - w) * 0.5, area.y + 60, w, h}
	ui.panel_begin(&a.ui, ui.id("cutlist"), r, "Cut list", {30, 32, 37, 248})
	cols := []f32{1.5, 2.2, 0.5, 0.8, 0.8, 0.6, 0.7}
	hdr := ui.next_row(&a.ui, 20)
	hc := ui.columns(hdr, cols, 8)
	heads := []string{"Material", "Parts", "Qty", "Length", "Width", "Thick", "Cost"}
	for hh, i in heads {ui.text_in(&a.ui, hh, hc[i], .Small, ui.THEME.text_faint, i >= 2 ? .Right : .Left)}
	total: f64
	area_total: f64
	for row in rows {
		rr := ui.next_row(&a.ui, 22)
		c := ui.columns(rr, cols, 8)
		name := row.names
		if row.shaped {name = fmt.tprintf("%s (shaped)", name)}
		if row.edge > 0 {
			sides := [model.Edge_Sides]string{.Both = "", .Top = " top", .Bottom = " bottom"}
			name = fmt.tprintf("%s (edges r%s%s)", name, model.format_number(row.edge), sides[row.edge_sides])
		}
		ui.text_in(&a.ui, row.material, c[0], .Regular, ui.THEME.text)
		ui.text_in(&a.ui, name, c[1], .Regular, ui.THEME.text_dim)
		ui.text_in(&a.ui, fmt.tprintf("%d", row.qty), c[2], .Semibold, ui.THEME.text, .Right)
		ui.text_in(&a.ui, model.format_number(row.length), c[3], .Regular, ui.THEME.text, .Right)
		ui.text_in(&a.ui, model.format_number(row.width), c[4], .Regular, ui.THEME.text, .Right)
		ui.text_in(&a.ui, model.format_number(row.thickness), c[5], .Regular, ui.THEME.text, .Right)
		ui.text_in(&a.ui, fmt.tprintf("%.2f", row.cost), c[6], .Regular, ui.THEME.text_dim, .Right)
		total += row.cost
		area_total += row.area_m2 * f64(row.qty)
	}
	ui.separator(&a.ui)
	tr := ui.next_row(&a.ui, 22)
	ui.text_in(&a.ui, fmt.tprintf("Sheet area %.2f m2 · estimated cost %.2f", area_total, total), tr, .Semibold, ui.THEME.text, .Right)
	br := ui.next_row(&a.ui, 28)
	bc := ui.columns(br, {3, 1, 1})
	if ui.button_rect(&a.ui, ui.id("cl-csv"), bc[1], "Export CSV", .Primary) {open_dialog(a, .Export_Csv)}
	if ui.button_rect(&a.ui, ui.id("cl-close"), bc[2], "Close") {a.show_cutlist = false}
	ui.panel_end(&a.ui)
}

// ---------------------------------------------------------------------------
// Dimension lines on the selection (2D overlay)

@(private)
dim_label :: proc(a: ^App, p: Vec2, text: string, accent := false) {
	w := ui.text_width(&a.ui, text, .Small) + 12
	r := rl.Rectangle{p.x - w * 0.5, p.y - 10, w, 20}
	ui.rounded(r, 6, accent ? ui.THEME.accent : {30, 32, 37, 225})
	ui.text_in(&a.ui, text, r, .Small, accent ? rl.Color{30, 20, 10, 255} : ui.THEME.text, .Center)
}

@(private)
dim_line :: proc(a: ^App, p0, p1: Vec3, offset_dir: Vec3, offset_px: f32, value: f32, cam: rl.Camera3D) {
	s0 := rl.GetWorldToScreen(p0, cam)
	s1 := rl.GetWorldToScreen(p1, cam)
	if linalg.length(s1 - s0) < 30 {return}
	// screen-space offset direction perpendicular to the line, pointing "outward"
	so := rl.GetWorldToScreen(p0 + offset_dir, cam) - s0
	d := linalg.normalize0(s1 - s0)
	n := Vec2{-d.y, d.x}
	if linalg.dot(n, so) < 0 {n = -n}
	o := n * offset_px
	c := rl.Color{40, 42, 48, 210}
	rl.DrawLineEx(s0 + n * 3, s0 + o + n * 4, 1, c)
	rl.DrawLineEx(s1 + n * 3, s1 + o + n * 4, 1, c)
	a0 := s0 + o
	a1 := s1 + o
	rl.DrawLineEx(a0, a1, 1.2, c)
	// arrow ticks
	for e, k in ([2]Vec2{a0, a1}) {
		dir := k == 0 ? d : -d
		rl.DrawTriangle(e, e + dir * 7 + n * 2.6, e + dir * 7 - n * 2.6, c)
		rl.DrawTriangle(e, e + dir * 7 - n * 2.6, e + dir * 7 + n * 2.6, c)
	}
	dim_label(a, (a0 + a1) * 0.5, model.format_number(f64(math.round(value * 10) / 10)))
}

// Clear vertical gaps between stacked flat panels (shelves): every gap inside a
// selected group, or the gaps above and below a selected shelf.
@(private)
draw_gaps :: proc(a: ^App, selected: Id, cam: rl.Camera3D) {
	scope := selected
	focus := Id(0)
	if model.find_part(a.doc, selected) != nil {
		ref, _ := model.find_node(a.doc, selected)
		if ref.parent == nil {return}
		scope = ref.parent.id
		focus = selected
	}
	ids := make([dynamic]Id, context.temp_allocator)
	collect_parts(a, {scope}, &ids)
	Flat :: struct {
		id:     Id,
		lo, hi: Vec3,
	}
	flats := make([dynamic]Flat, context.temp_allocator)
	for id in ids {
		rp := resolved_part(a, id)
		if rp == nil || rp.kind != .Panel {continue}
		size := rp.world_hi - rp.world_lo
		if size.y * 2 > min(size.x, size.z) {continue} // not lying flat
		append(&flats, Flat{id, rp.world_lo, rp.world_hi})
	}
	slice.sort_by(flats[:], proc(x, y: Flat) -> bool {return x.lo.y < y.lo.y})
	for f, i in flats {
		// nearest flat panel above that overlaps this one in plan
		for g in flats[i + 1:] {
			if g.lo.y < f.hi.y - 0.5 {continue}
			x0, x1 := max(f.lo.x, g.lo.x), min(f.hi.x, g.hi.x)
			z0, z1 := max(f.lo.z, g.lo.z), min(f.hi.z, g.hi.z)
			if x1 - x0 < 1 || z1 - z0 < 1 {continue}
			if focus == 0 || focus == f.id || focus == g.id {
				// down the middle of the open front
				x := (x0 + x1) * 0.5
				p0 := Vec3{x, f.hi.y, z1}
				p1 := Vec3{x, g.lo.y, z1}
				dim_line(a, p0, p1, {0, 0, 1}, 0, g.lo.y - f.hi.y, cam)
			}
			break
		}
	}
}

draw_dimensions :: proc(a: ^App) {
	if !a.show_dims || len(a.selection) != 1 || a.editor.open {return}
	id := a.selection[0]
	cam := orbit_camera(&a.cam)
	draw_gaps(a, id, cam)
	world: Mat4
	lo, hi: Vec3
	if rp := resolved_part(a, id); rp != nil {
		g := render.mesh_of(&a.r, rp^)
		if g == nil {return}
		world = rp.world
		lo, hi = g.lo, g.hi
	} else if rg := resolved_group(a, id); rg != nil {
		world = rg.world
		inv := linalg.inverse(world)
		parts := make([dynamic]Id, context.temp_allocator)
		collect_parts(a, {id}, &parts)
		lo = {max(f32), max(f32), max(f32)}
		hi = -lo
		for pid in parts {
			rp := resolved_part(a, pid)
			if rp == nil {continue}
			g := render.mesh_of(&a.r, rp^)
			if g == nil {continue}
			plo, phi := render.transform_aabb(inv * rp.world, g.lo, g.hi)
			lo = linalg.min(lo, plo)
			hi = linalg.max(hi, phi)
		}
		if lo.x > hi.x {return}
	} else {
		return
	}
	P :: proc(m: Mat4, p: Vec3) -> Vec3 {return (m * [4]f32{p.x, p.y, p.z, 1}).xyz}
	eye := cam.position
	center := P(world, (lo + hi) * 0.5)
	// for each axis choose the box edge nearest the viewer that is lowest on screen
	for axis in 0 ..< 3 {
		u := (axis + 1) % 3
		v := (axis + 2) % 3
		best_score: f32 = -max(f32)
		b0, b1, boff: Vec3
		for k in 0 ..< 4 {
			p0, p1: Vec3
			p0[axis], p1[axis] = lo[axis], hi[axis]
			cu := (k & 1) != 0 ? hi[u] : lo[u]
			cv := (k & 2) != 0 ? hi[v] : lo[v]
			p0[u], p1[u] = cu, cu
			p0[v], p1[v] = cv, cv
			w0 := P(world, p0)
			w1 := P(world, p1)
			mid := (w0 + w1) * 0.5
			s := rl.GetWorldToScreen(mid, cam)
			score := -linalg.length(mid - eye) * 0.002 + (axis == 1 ? -s.x : s.y) * 0.01
			if score > best_score {
				best_score = score
				b0, b1 = w0, w1
				boff = linalg.normalize0(mid - center)
			}
		}
		dim_line(a, b0, b1, boff * 10, 22, hi[axis] - lo[axis], cam)
	}
}

// Feedback drawn in 3D: snap guides, placement ghost, push/pull face.
draw_tool_feedback_3d :: proc(a: ^App) {
	if a.tool == .Push_Pull {
		f := a.drag.kind == .Push_Pull ? a.drag.face : a.pp_hover
		draw_face_highlight(a, f, a.drag.kind == .Push_Pull ? ui.THEME.accent : {255, 190, 120, 255})
	}
	if a.place_preview.valid {
		pp := a.place_preview
		size: Vec3
		center: Vec3
		t: f32 = 18
		switch a.tool {
		case .Panel:
			switch pp.orient {
			case 0: size = {600, t, 300}; center = pp.pos + {300, t * 0.5, -150}
			case 1: size = {t, 600, 300}; center = pp.pos + {-t * 0.5, 300, -150}
			case 2: size = {600, 300, t}; center = pp.pos + {300, 150, t * 0.5}
			}
		case .Turned:
			size = {50, 430, 50}
			center = pp.pos + {0, 215, 0}
		case .Swept:
			size = {600, 20, 400}
			center = pp.pos + {300, 10, -200}
		case .Select, .Move, .Push_Pull:
		}
		rl.DrawCubeV(center, size, {245, 142, 46, 50})
		rl.DrawCubeWiresV(center, size, ui.THEME.accent)
	}
	d := &a.drag
	if (d.kind == .Move_Axis || d.kind == .Move_Plane || d.kind == .Push_Pull) && d.snapped {
		rl.DrawLine3D(d.snap_from, d.snap_to, {220, 40, 160, 255})
		rl.DrawSphereEx(d.snap_to, units_per_px_at(a, d.snap_to) * 3.5, 6, 6, {220, 40, 160, 255})
	}
	if d.kind == .Move_Axis {
		o := d.origin + d.delta
		c := AXIS_COLORS[d.axis]
		c.a = 150
		rl.DrawLine3D(o - AXIS_DIRS[d.axis] * 50000, o + AXIS_DIRS[d.axis] * 50000, c)
	}
}

// Live readout next to the cursor while dragging.
draw_drag_readout :: proc(a: ^App) {
	d := &a.drag
	text := ""
	#partial switch d.kind {
	case .Move_Axis:
		text = fmt.tprintf("%s%s mm", d.delta[d.axis] >= 0 ? "+" : "", model.format_number(f64(d.delta[d.axis])))
	case .Move_Plane:
		text = fmt.tprintf("x %s · z %s", model.format_number(f64(d.delta.x)), model.format_number(f64(d.delta.z)))
	case .Push_Pull:
		text = fmt.tprintf("%s mm", model.format_number(d.dim_start + f64(d.pp_delta)))
	}
	if text == "" {return}
	dim_label(a, a.ui.mouse + {0, 30}, text, true)
}


