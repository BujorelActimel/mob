package app

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../render"
import "../ui"

// One frame: input, evaluation, rendering, UI. Returns true while something
// is animating (so the main loop keeps polling instead of waiting for events).
frame :: proc(a: ^App) -> bool {
	t0 := rl.GetTime()
	ui.begin_frame(&a.ui)
	refresh(a)

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	screen := rl.Rectangle{0, 0, sw, sh}
	left := rl.Rectangle{MARGIN, MARGIN, LEFT_W, sh - 2 * MARGIN}
	right := rl.Rectangle{sw - RIGHT_W - MARGIN, MARGIN, RIGHT_W, sh - 2 * MARGIN}
	center := rl.Rectangle{left.x + left.width + MARGIN, MARGIN, right.x - (left.x + left.width) - 2 * MARGIN, sh - 2 * MARGIN}
	a.viewport = center

	// file drops
	if rl.IsFileDropped() {
		files := rl.LoadDroppedFiles()
		if files.count > 0 {
			path := string(files.paths[0])
			open_document(a, path)
		}
		rl.UnloadDroppedFiles(files)
	}

	modal := a.dialog.kind != .None || a.show_help || a.show_settings
	if !modal && !a.editor.open {
		viewport_input(a)
	} else {
		clear(&a.hover_ids)
		a.place_preview = {}
		a.pp_hover = {}
		a.gizmo_hover = -1
	}
	handle_keys(a)
	refresh(a)
	animating := orbit_update(&a.cam, a.ui.dt, a.settings.smooth_camera)

	// ---- 3D
	t_in := rl.GetTime()
	render.update_shadows(&a.r, &a.res)
	cam := orbit_camera(&a.cam)
	near, far := render.clip_planes(&a.r, cam.position)
	sel_parts := make([dynamic]Id, context.temp_allocator)
	collect_parts(a, a.selection[:], &sel_parts)
	flags := make([]render.Part_Flags, len(a.res.parts), context.temp_allocator)
	mark :: proc(a: ^App, flags: []render.Part_Flags, ids: []Id, flag: render.Part_Flag) {
		for id in ids {
			if i, ok := a.res.part_index[id]; ok {flags[i] += {flag}}
		}
	}
	mark(a, flags, sel_parts[:], .Selected)
	mark(a, flags, a.hover_ids[:], .Hovered)
	if a.editor.open {mark(a, flags, {a.editor.part}, .Ghost)}
	f := render.Frame {
		camera      = cam,
		near        = near,
		far         = far,
		flags       = flags,
		highlighted = len(sel_parts) > 0 || len(a.hover_ids) > 0,
		show_edges  = a.show_edges,
		show_grid   = a.show_grid,
		show_room   = a.show_room,
	}
	render.draw_mask(&a.r, &a.res, f)
	t_mask := rl.GetTime()

	rl.BeginDrawing()
	render.draw_background()
	render.draw_scene(&a.r, &a.res, f)
	if len(sel_parts) > 0 || len(a.hover_ids) > 0 {
		render.draw_outline(&a.r, a.ui.dpi, outline_area(a, sel_parts[:], cam))
	}
	t_3d := rl.GetTime()
	rlgl.SetClipPlanes(f64(near), f64(far))
	rl.BeginMode3D(cam)
	draw_tool_feedback_3d(a)
	draw_gizmo(a)
	rl.EndMode3D()
	draw_dimensions(a)
	draw_drag_readout(a)

	// ---- UI
	a.ui.input_enabled = !modal
	if len(a.res.parts) == 0 && !a.editor.open {empty_hint(a, center)}
	file_bar(a, {left.x, left.y, LEFT_W, TOP_H})
	tree_top := left.y + TOP_H + 10
	outliner(a, {left.x, tree_top, LEFT_W, left.height - TOP_H - 10})
	view_w: f32 = 4 * 54 + 8
	toolbar(a, {center.x, center.y, center.width - view_w - 12, 46})
	view_buttons(a, center)
	inspector(a, right)
	status_bar(a, {center.x, center.y, center.width, center.height})
	if a.show_cutlist && !a.editor.open {cut_list_overlay(a, center)}
	if a.editor.open {
		editor_frame(a, {center.x, center.y + 56, center.width, center.height - 56 - 36})
	}
	toasts(a, center)
	a.ui.input_enabled = true
	if a.show_help {help_overlay(a, screen)}
	if a.show_settings {settings_panel(a, screen)}
	dialog(a, screen)
	ui.end_frame(&a.ui)

	a.frame_ms = f32((rl.GetTime() - t0) * 1000)
	a.timings = {f32((t_in - t0) * 1000), f32((t_mask - t_in) * 1000), f32((t_3d - t_mask) * 1000), f32((rl.GetTime() - t_3d) * 1000)}
	update_title(a)
	rl.EndDrawing()

	busy := a.drag.kind != .None || a.ui.active != 0 || a.ui.scrub_id != 0 || a.editor.drag_point >= 0 || a.editor.panning
	return animating || a.ui.animating || busy || len(a.toasts) > 0 || a.need_eval
}



// Screen rectangle covering the selected and hovered parts, plus room for the outline.
@(private)
outline_area :: proc(a: ^App, sel: []Id, cam: rl.Camera3D) -> rl.Rectangle {
	full := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	lo := Vec2{max(f32), max(f32)}
	hi := -lo
	fwd := cam.target - cam.position
	any := false
	for list in ([2][]Id{sel, a.hover_ids[:]}) {
		for id in list {
			rp := resolved_part(a, id)
			if rp == nil {continue}
			blo, bhi := render.part_world_bounds(&a.r, rp^)
			for k in 0 ..< 8 {
				p := Vec3{(k & 1) != 0 ? bhi.x : blo.x, (k & 2) != 0 ? bhi.y : blo.y, (k & 4) != 0 ? bhi.z : blo.z}
				// a corner behind the camera projects nonsense: fall back to the full screen
				if (p.x - cam.position.x) * fwd.x + (p.y - cam.position.y) * fwd.y + (p.z - cam.position.z) * fwd.z <= 0 {return full}
				s := rl.GetWorldToScreen(p, cam)
				lo = {min(lo.x, s.x), min(lo.y, s.y)}
				hi = {max(hi.x, s.x), max(hi.y, s.y)}
				any = true
			}
		}
	}
	if !any {return {}}
	m: f32 = 8
	return {lo.x - m, lo.y - m, hi.x - lo.x + 2 * m, hi.y - lo.y + 2 * m}
}

@(private)
empty_hint :: proc(a: ^App, area: rl.Rectangle) {
	lines := [?]string{"Empty scene", "Use Add in the toolbar for a part or a template,", "or press B and click to place a panel."}
	y := area.y + area.height * 0.42
	for l, i in lines {
		ui.text_in(&a.ui, l, {area.x, y + f32(i) * 26, area.width, 24}, i == 0 ? .Big : .Regular, i == 0 ? rl.Color{90, 86, 100, 255} : rl.Color{110, 106, 120, 255}, .Center)
		if i == 0 {y += 14}
	}
}
