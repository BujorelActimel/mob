package app

import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Orbit camera with damped motion toward goal values.
Orbit :: struct {
	target, target_goal: Vec3,
	yaw, yaw_goal:       f32, // radians, 0 = looking from +Z
	pitch, pitch_goal:   f32,
	dist, dist_goal:     f32,
	fovy:                f32,
}

orbit_init :: proc(o: ^Orbit) {
	o.fovy = 32
	o.yaw = math.to_radians(f32(32))
	o.pitch = math.to_radians(f32(24))
	o.dist = 3000
	o.yaw_goal, o.pitch_goal, o.dist_goal = o.yaw, o.pitch, o.dist
}

// Returns true while still moving.
orbit_update :: proc(o: ^Orbit, dt: f32, smooth := true) -> bool {
	k := smooth ? 1 - math.exp(-min(dt, 0.05) * 16) : 1
	o.yaw += (o.yaw_goal - o.yaw) * k
	o.pitch += (o.pitch_goal - o.pitch) * k
	o.dist += (o.dist_goal - o.dist) * k
	o.target += (o.target_goal - o.target) * k
	moving := abs(o.yaw_goal - o.yaw) > 1e-4 || abs(o.pitch_goal - o.pitch) > 1e-4 || abs(o.dist_goal - o.dist) > o.dist * 1e-4 || linalg.length(o.target_goal - o.target) > o.dist * 1e-5
	if !moving {
		o.yaw, o.pitch, o.dist, o.target = o.yaw_goal, o.pitch_goal, o.dist_goal, o.target_goal
	}
	return moving
}

orbit_eye :: proc(o: ^Orbit) -> Vec3 {
	cp := math.cos(o.pitch)
	return o.target + o.dist * Vec3{cp * math.sin(o.yaw), math.sin(o.pitch), cp * math.cos(o.yaw)}
}

orbit_camera :: proc(o: ^Orbit) -> rl.Camera3D {
	return {position = orbit_eye(o), target = o.target, up = {0, 1, 0}, fovy = o.fovy, projection = .PERSPECTIVE}
}

orbit_rotate :: proc(o: ^Orbit, dx, dy: f32) {
	o.yaw_goal -= dx * 0.008
	o.pitch_goal = clamp(o.pitch_goal + dy * 0.008, math.to_radians(f32(-89.5)), math.to_radians(f32(89.5)))
	// keep yaw continuous but bounded
	if abs(o.yaw_goal) > 100 {
		off := math.round(o.yaw_goal / math.TAU) * math.TAU
		o.yaw_goal -= off
		o.yaw -= off
	}
}

// World units per screen point at the orbit target.
orbit_units_per_px :: proc(o: ^Orbit, screen_h: f32) -> f32 {
	return 2 * o.dist * math.tan(math.to_radians(o.fovy) * 0.5) / screen_h
}

orbit_pan :: proc(o: ^Orbit, dx, dy: f32, screen_h: f32) {
	s := orbit_units_per_px(o, screen_h)
	eye := orbit_eye(o)
	fwd := linalg.normalize(o.target - eye)
	right := linalg.normalize(linalg.cross(fwd, Vec3{0, 1, 0}))
	up := linalg.cross(right, fwd)
	delta := (-right * dx + up * dy) * s
	o.target_goal += delta
	o.target += delta
}

// Zoom toward a world point (the thing under the cursor).
orbit_zoom :: proc(o: ^Orbit, wheel: f32, focus: Vec3, has_focus: bool) {
	f := math.exp(-wheel * 0.14)
	nd := clamp(o.dist_goal * f, 60, 60000)
	f = nd / o.dist_goal
	if has_focus {
		o.target_goal = focus + (o.target_goal - focus) * f
	}
	o.dist_goal = nd
}

View :: enum u8 {
	Front,
	Right,
	Top,
	Iso,
}

orbit_view :: proc(o: ^Orbit, v: View) {
	yaw, pitch: f32
	switch v {
	case .Front: yaw, pitch = 0, 0
	case .Right: yaw, pitch = math.PI / 2, 0
	case .Top:   yaw, pitch = 0, math.to_radians(f32(89.5))
	case .Iso:   yaw, pitch = math.to_radians(f32(32)), math.to_radians(f32(24))
	}
	// shortest way around
	diff := yaw - o.yaw_goal
	diff = diff - math.round(diff / math.TAU) * math.TAU
	o.yaw_goal += diff
	o.pitch_goal = pitch
}

// Fits a bounding box in view.
orbit_frame :: proc(o: ^Orbit, lo, hi: Vec3, instant: bool) {
	c := (lo + hi) * 0.5
	r := max(linalg.length(hi - lo) * 0.5, 150)
	d := r / math.sin(math.to_radians(o.fovy) * 0.5) * 1.45
	o.target_goal = c
	o.dist_goal = d
	if instant {
		o.target = c
		o.dist = d
	}
}

frame_all :: proc(a: ^App, instant: bool) {
	if a.r.has_scene {
		orbit_frame(&a.cam, a.r.scene_lo, a.r.scene_hi, instant)
	} else {
		orbit_frame(&a.cam, {-500, 0, -500}, {500, 600, 500}, instant)
	}
}

frame_selection :: proc(a: ^App) {
	if len(a.selection) == 0 {
		frame_all(a, false)
		return
	}
	lo, hi, ok := nodes_bounds(a, a.selection[:])
	if ok {orbit_frame(&a.cam, lo, hi, false)}
}
