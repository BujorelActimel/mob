package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import "app"
import "model"

find_assets :: proc() -> string {
	exe_dir := filepath.dir(os.args[0])
	candidates := []string{
		filepath.join({exe_dir, "..", "assets"}, context.temp_allocator) or_else "",
		filepath.join({exe_dir, "assets"}, context.temp_allocator) or_else "",
		filepath.join({exe_dir, "..", "Resources", "assets"}, context.temp_allocator) or_else "",
		"assets",
	}
	for c in candidates {
		if c != "" && os.exists(filepath.join({c, "fonts", "PixelOperator-Bold.ttf"}, context.temp_allocator) or_else "") {
			return c
		}
	}
	return "assets"
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, leak in track.allocation_map {
				fmt.eprintf("leak: %v bytes at %v\n", leak.size, leak.location)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	open_path := ""
	shot_path := ""
	bench := 0
	select_first := false
	start_tool := ""
	open_editor := false
	view := ""
	show_cuts := false
	room := false
	show_settings := false
	demo := false
	empty := false
	selftest_dir := ""
	orbit_dir := ""
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		switch arg {
		case "--bench":
			bench = 72
			if i + 1 < len(os.args) {
				if n, ok := strconv.parse_int(os.args[i + 1]); ok {bench = n; i += 1}
			}
		case "--shot":
			if i + 1 < len(os.args) {shot_path = os.args[i + 1]; i += 1}
		case "--select-first":
			select_first = true
		case "--tool":
			if i + 1 < len(os.args) {start_tool = os.args[i + 1]; i += 1}
		case "--editor":
			open_editor = true
		case "--view":
			if i + 1 < len(os.args) {view = os.args[i + 1]; i += 1}
		case "--selftest":
			if i + 1 < len(os.args) {selftest_dir = os.args[i + 1]; i += 1}
		case "--orbit-shots":
			if i + 1 < len(os.args) {orbit_dir = os.args[i + 1]; i += 1}
		case "--settings":
			show_settings = true
		case "--demo":
			demo = true
		case "--settings-file":
			if i + 1 < len(os.args) {app.settings_path_override = os.args[i + 1]; i += 1}
		case "--empty":
			empty = true
		case "--cuts":
			show_cuts = true
		case "--room":
			room = true
		case:
			if !strings.has_prefix(arg, "--") {open_path = arg}
		}
	}

	rl.SetTraceLogLevel(.ERROR)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(1480, 920, "mob")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(1080, 680)
	rl.SetExitKey(.KEY_NULL)

	a := new(app.App)
	defer free(a)
	// dev runs (bench, screenshots, self-test) start from the demo shelf and
	// never write the user's settings
	dev := bench > 0 || shot_path != "" || selftest_dir != "" || orbit_dir != ""
	a.settings_readonly = dev || show_settings
	app.app_init(a, find_assets(), open_path, (demo || dev) && !empty)
	defer app.app_shutdown(a)
	a.show_room = room
	a.show_cutlist = show_cuts
	if show_settings {
		a.settings_readonly = true
		a.show_settings = true
	}

	if selftest_dir != "" {
		a.docs_dir_for_tests = selftest_dir
		ok := app.ui_selftest(a)
		ok = app.selftest(a, selftest_dir) && ok
		fmt.println(ok ? "selftest: all passed" : "selftest: FAILURES")
		if !ok {os.exit(1)}
		return
	}
	if bench > 0 {
		run_bench(a, bench)
		return
	}
	if select_first && len(a.doc.root.children) > 0 {
		app.set_selection(a, model.node_id(a.doc.root.children[0]))
	}
	switch start_tool {
	case "move": a.tool = .Move
	case "push": a.tool = .Push_Pull
	}
	if open_editor && len(a.doc.root.children) > 0 {
		if g, ok := a.doc.root.children[0].(^model.Group); ok && len(g.children) > 2 {
			id := model.node_id(g.children[2])
			app.set_selection(a, id)
			app.open_editor(a, id)
		}
	}
	switch view {
	case "front": app.orbit_view(&a.cam, .Front)
	case "top":   app.orbit_view(&a.cam, .Top)
	case "side":  app.orbit_view(&a.cam, .Right)
	}

	if orbit_dir != "" {
		// settle, then orbit continuously and grab frames mid-motion
		for _ in 0 ..< 30 {app.frame(a); free_all(context.temp_allocator)}
		for k in 0 ..< 12 {
			a.cam.yaw_goal += 0.55
			a.cam.pitch_goal = f32(k % 4) * 0.25 - 0.1
			for _ in 0 ..< 4 {app.frame(a); free_all(context.temp_allocator)}
			img := rl.LoadImageFromScreen()
			rl.ImageResize(&img, img.width / 4, img.height / 4)
			rl.ExportImage(img, fmt.ctprintf("%s/orbit_%02d.png", orbit_dir, k))
			rl.UnloadImage(img)
		}
		return
	}
	if shot_path != "" {
		for _ in 0 ..< 90 {
			app.frame(a)
			free_all(context.temp_allocator)
		}
		img := rl.LoadImageFromScreen()
		rl.ExportImage(img, strings.clone_to_cstring(shot_path, context.temp_allocator))
		rl.UnloadImage(img)
		return
	}

	for !rl.WindowShouldClose() && !a.quit {
		busy := app.frame(a)
		free_all(context.temp_allocator)
		// sleep until input arrives unless something is moving
		if busy {rl.DisableEventWaiting()} else {rl.EnableEventWaiting()}
	}
}

// Fills the scene with copies of the corner shelf and reports frame times.
run_bench :: proc(a: ^app.App, copies: int) {
	d := a.doc
	for i in 1 ..< copies {
		g := model.template_vinyl_corner(d)
		model.field_set_value(d, &g.xf.pos[0], f64((i % 12) * 600))
		model.field_set_value(d, &g.xf.pos[2], f64(-(i / 12) * 600))
		append(&d.root.children, g)
	}
	a.need_eval = true
	app.refresh(a)
	app.frame_all(a, true)
	parts := len(a.res.parts)
	// warm up, then select one group so the outline pass runs
	app.set_selection(a, model.node_id(d.root.children[0]))
	for _ in 0 ..< 30 {
		app.frame(a)
		free_all(context.temp_allocator)
	}
	N :: 240
	cpu_total: f64
	cpu_max: f64
	parts_t: [4]f32
	t0 := rl.GetTime()
	for i in 0 ..< N {
		// orbit a little so every frame redraws for real
		a.cam.yaw_goal += 0.01
		app.frame(a)
		cpu_total += f64(a.frame_ms)
		cpu_max = max(cpu_max, f64(a.frame_ms))
		parts_t += a.timings
		free_all(context.temp_allocator)
		_ = i
	}
	wall := (rl.GetTime() - t0) * 1000 / N
	// time a full re-evaluation + mesh sync (what an edit costs)
	t1 := rl.GetTime()
	hc := model.find_param((^model.Group)(d.root.children[0].(^model.Group)).params[:], "H_comp")
	model.field_set(d, &hc.field, "340")
	a.need_eval = true
	app.refresh(a)
	edit_ms := (rl.GetTime() - t1) * 1000
	fmt.printf("bench: %d parts, cpu frame avg %.2f ms (max %.2f), wall %.2f ms/frame (vsync bound), edit re-eval %.2f ms (eval %.2f ms)\n",
		parts, cpu_total / N, cpu_max, wall, edit_ms, a.eval_ms)
	fmt.printf("  breakdown ms: input %.2f, mask %.2f, scene %.2f, ui %.2f\n", parts_t[0] / N, parts_t[1] / N, parts_t[2] / N, parts_t[3] / N)
}
