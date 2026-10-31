package app

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"
import "../platform"
import "../ui"

Scroll_Action :: enum u8 {
	Zoom,
	Pan,
}

Drag_Action :: enum u8 {
	Orbit,
	Pan,
}

// User preferences, stored as JSON next to other app data.
Settings :: struct {
	scroll:         Scroll_Action, // what the wheel / two-finger scroll does
	pinch_zoom:     bool,
	zoom_to_cursor: bool,
	invert_zoom:    bool,
	smooth_camera:  bool,
	zoom_speed:     f32,
	orbit_speed:    f32,
	pan_speed:      f32,
	left_drag:      Drag_Action, // left drag on empty space
	fov:            f32,
	object_snap:    bool,
	grid_step:      f32, // mm; ⌘ multiplies by 10
	snap_distance:  f32, // px
	show_edges:     bool,
	show_grid:      bool,
	show_dims:      bool,
	show_room:      bool,
	documents_dir:  string,
	reopen_last:    bool, // open the last project at launch
	last_file:      string,
}

DEFAULT_SETTINGS :: Settings {
	scroll         = .Zoom,
	pinch_zoom     = true,
	zoom_to_cursor = true,
	invert_zoom    = false,
	smooth_camera  = true,
	zoom_speed     = 1,
	orbit_speed    = 1,
	pan_speed      = 1,
	left_drag      = .Orbit,
	fov            = 32,
	object_snap    = true,
	grid_step      = 1,
	snap_distance  = 9,
	show_edges     = true,
	show_grid      = true,
	show_dims      = true,
	reopen_last    = true,
}

settings_path_override: string // tests write elsewhere

settings_path :: proc() -> string {
	if settings_path_override != "" {return settings_path_override}
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil || dir == "" {
		home, _ := os.user_home_dir(context.temp_allocator)
		dir = join_path({home, ".config"})
	}
	return join_path({dir, "mob", "settings.json"})
}

load_settings :: proc(a: ^App) {
	a.settings = DEFAULT_SETTINGS
	if data, err := os.read_entire_file(settings_path(), context.temp_allocator); err == nil {
		loaded := DEFAULT_SETTINGS // keys missing from the file keep their defaults
		if json.unmarshal(data, &loaded, allocator = context.temp_allocator) == nil {
			loaded.documents_dir = strings.clone(loaded.documents_dir)
			loaded.last_file = strings.clone(loaded.last_file)
			a.settings = loaded
		}
	}
	sanitize_settings(&a.settings)
	apply_settings(a)
}

@(private)
sanitize_settings :: proc(s: ^Settings) {
	s.zoom_speed = clamp(s.zoom_speed, 0.2, 4)
	s.orbit_speed = clamp(s.orbit_speed, 0.2, 4)
	s.pan_speed = clamp(s.pan_speed, 0.2, 4)
	s.fov = clamp(s.fov, 15, 70)
	s.snap_distance = clamp(s.snap_distance, 2, 30)
	if s.grid_step <= 0 {s.grid_step = 1}
}

apply_settings :: proc(a: ^App) {
	s := &a.settings
	a.cam.fovy = s.fov
	a.show_edges = s.show_edges
	a.show_grid = s.show_grid
	a.show_dims = s.show_dims
	a.show_room = s.show_room
	if s.documents_dir != "" && s.documents_dir != a.docs_dir {
		delete(a.docs_dir)
		a.docs_dir = strings.clone(s.documents_dir)
	}
}

save_settings :: proc(a: ^App) -> bool {
	if a.settings_readonly && settings_path_override == "" {return true}
	s := a.settings
	s.show_edges = a.show_edges
	s.show_grid = a.show_grid
	s.show_dims = a.show_dims
	s.show_room = a.show_room
	if s.documents_dir == "" {s.documents_dir = a.docs_dir}
	data, err := json.marshal(s, {pretty = true, use_spaces = true, spaces = 2, use_enum_names = true}, context.temp_allocator)
	if err != nil {return false}
	path := settings_path()
	ensure_dir(path)
	return os.write_entire_file(path, data) == nil
}

settings_shutdown :: proc(a: ^App) {
	delete(a.settings.documents_dir)
	delete(a.settings.last_file)
}

// ---------------------------------------------------------------------------
// Panel

Input_Preset :: enum u8 {
	Mouse,
	Trackpad,
	Custom,
}

@(private)
current_preset :: proc(s: ^Settings) -> Input_Preset {
	if s.scroll == .Zoom && s.left_drag == .Orbit {return .Mouse}
	if s.scroll == .Pan && s.pinch_zoom && s.left_drag == .Orbit {return .Trackpad}
	return .Custom
}

close_settings :: proc(a: ^App) {
	a.show_settings = false
	if !save_settings(a) {toast(a, "Could not save settings", .Error)}
}

settings_panel :: proc(a: ^App, screen: rl.Rectangle) {
	s := &a.settings
	rl.DrawRectangleRec(screen, {10, 11, 13, 110})
	ui.block(&a.ui, screen)
	w: f32 = 700
	h := min(screen.height - 80, 820)
	r := rl.Rectangle{screen.x + (screen.width - w) * 0.5, screen.y + (screen.height - h) * 0.5, w, h}
	body := rl.Rectangle{r.x, r.y, r.width, r.height - 56}
	ui.panel_begin(&a.ui, ui.id("settings"), body, "Settings", {30, 32, 37, 252})
	ui.block(&a.ui, r)

	row_label :: proc(a: ^App, text: string, label_w: f32 = 270) -> rl.Rectangle {
		row := ui.next_row(&a.ui, 30)
		ui.text_in(&a.ui, text, {row.x, row.y, label_w - 10, row.height}, .Regular, ui.THEME.text_dim)
		return {row.x + label_w, row.y, row.width - label_w, row.height}
	}

	ui.heading(&a.ui, "Navigation")
	{
		cur := current_preset(s)
		r2 := row_label(a, "Input device")
		sel := ui.segmented(&a.ui, ui.id("set-preset"), r2, {"Mouse", "Trackpad", "Custom"}, int(cur))
		if sel != int(cur) {
			switch Input_Preset(sel) {
			case .Mouse:
				s.scroll = .Zoom
				s.left_drag = .Orbit
			case .Trackpad:
				s.scroll = .Pan
				s.pinch_zoom = true
				s.left_drag = .Orbit
			case .Custom:
			}
		}
	}
	{
		r2 := row_label(a, "Scroll / two-finger swipe")
		v := ui.segmented(&a.ui, ui.id("set-scroll"), r2, {"Zoom", "Pan"}, int(s.scroll))
		if v != int(s.scroll) {s.scroll = Scroll_Action(v)}
	}
	hint := s.scroll == .Pan ? "Cmd + scroll zooms." : "Shift + scroll pans."
	ui.label(&a.ui, hint, .Small, ui.THEME.text_faint, 14)
	if platform.has_pinch() {
		ui.checkbox(&a.ui, "Pinch to zoom (trackpad)", &s.pinch_zoom)
	}
	{
		r2 := row_label(a, "Left-drag on empty space")
		v := ui.segmented(&a.ui, ui.id("set-ldrag"), r2, {"Orbit", "Pan"}, int(s.left_drag))
		if v != int(s.left_drag) {s.left_drag = Drag_Action(v)}
	}
	ui.label(&a.ui, "Shift + drag does the other one. Right-drag always orbits.", .Small, ui.THEME.text_faint, 14)
	ui.checkbox(&a.ui, "Zoom toward the cursor", &s.zoom_to_cursor)
	ui.checkbox(&a.ui, "Invert zoom direction", &s.invert_zoom)
	ui.checkbox(&a.ui, "Smooth camera motion", &s.smooth_camera)
	if v, ok := ui.slider(&a.ui, ui.id("set-zs"), row_label(a, "Zoom speed"), s.zoom_speed, 0.2, 4, "%.1f×"); ok {s.zoom_speed = v}
	if v, ok := ui.slider(&a.ui, ui.id("set-os"), row_label(a, "Orbit speed"), s.orbit_speed, 0.2, 4, "%.1f×"); ok {s.orbit_speed = v}
	if v, ok := ui.slider(&a.ui, ui.id("set-ps"), row_label(a, "Pan speed"), s.pan_speed, 0.2, 4, "%.1f×"); ok {s.pan_speed = v}
	if v, ok := ui.slider(&a.ui, ui.id("set-fov"), row_label(a, "Field of view"), s.fov, 15, 70, "%.0f°"); ok {
		s.fov = v
		a.cam.fovy = v
	}

	ui.heading(&a.ui, "Snapping")
	ui.checkbox(&a.ui, "Snap to other parts (Opt flips it while dragging)", &s.object_snap)
	{
		r2 := row_label(a, "Grid step (Cmd = ×10)")
		steps := []f32{1, 5, 10}
		cur := 0
		for st, i in steps {if st == s.grid_step {cur = i}}
		v := ui.segmented(&a.ui, ui.id("set-grid"), r2, {"1 mm", "5 mm", "10 mm"}, cur)
		if v != cur {s.grid_step = steps[v]}
	}
	if v, ok := ui.slider(&a.ui, ui.id("set-snap"), row_label(a, "Snap distance"), s.snap_distance, 2, 30, "%.0f px"); ok {s.snap_distance = v}

	ui.heading(&a.ui, "Display")
	ui.checkbox(&a.ui, "Outline edges", &a.show_edges)
	ui.checkbox(&a.ui, "Floor grid", &a.show_grid)
	ui.checkbox(&a.ui, "Dimension lines on the selection", &a.show_dims)
	ui.checkbox(&a.ui, "Room backdrop (R)", &a.show_room)

	ui.heading(&a.ui, "Files")
	{
		r2 := row_label(a, "Documents folder", 200)
		res := ui.text_field(&a.ui, ui.id("set-dir"), r2, a.docs_dir, {})
		if res.committed && res.text != a.docs_dir {
			delete(s.documents_dir)
			s.documents_dir = strings.clone(strings.trim_space(res.text))
			apply_settings(a)
		}
	}
	ui.checkbox(&a.ui, "Reopen the last project on start", &s.reopen_last)
	ui.space(&a.ui, 4)
	if ui.button(&a.ui, "Keyboard shortcuts   K", .Normal) {
		close_settings(a)
		a.show_help = true
	}
	ui.label(&a.ui, fmt.tprintf("Saved to %s", settings_path()), .Small, ui.THEME.text_faint, 20)
	ui.panel_end(&a.ui)

	// footer: continues the card below the scrolling body
	bg := rl.Color{30, 32, 37, 252}
	rl.DrawRectangleRec({r.x, body.y + body.height - 12, r.width, 20}, bg)
	ui.rounded({r.x, body.y + body.height, r.width, r.height - body.height}, 10, bg)
	rl.DrawRectangleRec({r.x + 16, body.y + body.height - 2, r.width - 32, 1}, {255, 255, 255, 14})
	fr := rl.Rectangle{r.x + 18, r.y + r.height - 46, r.width - 36, 30}
	cols := ui.columns(fr, {1.2, 1.8, 1})
	if ui.button_rect(&a.ui, ui.id("set-reset"), cols[0], "Reset to defaults", .Ghost) {
		dir := s.documents_dir
		s^ = DEFAULT_SETTINGS
		s.documents_dir = dir
		apply_settings(a)
	}
	if ui.button_rect(&a.ui, ui.id("set-done"), cols[2], "Done", .Primary) {close_settings(a)}
	if rl.IsKeyPressed(.ESCAPE) && a.ui.focus == 0 {close_settings(a)}
	if a.ui.pressed && !rl.CheckCollisionPointRec(a.ui.mouse, r) && a.ui.popup.id == 0 {close_settings(a)}
}
