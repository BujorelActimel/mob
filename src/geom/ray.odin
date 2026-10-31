package geom

import "core:math/linalg"

Ray :: struct {
	origin, dir: Vec3,
}

// Slab test. Returns entry distance (clamped at 0) when the ray hits the box.
ray_aabb :: proc(r: Ray, lo, hi: Vec3) -> (t: f32, hit: bool) {
	tmin: f32 = 0
	tmax := max(f32)
	for i in 0 ..< 3 {
		if abs(r.dir[i]) < 1e-12 {
			if r.origin[i] < lo[i] || r.origin[i] > hi[i] {return 0, false}
			continue
		}
		inv := 1 / r.dir[i]
		t0 := (lo[i] - r.origin[i]) * inv
		t1 := (hi[i] - r.origin[i]) * inv
		if t0 > t1 {t0, t1 = t1, t0}
		tmin = max(tmin, t0)
		tmax = min(tmax, t1)
		if tmin > tmax {return 0, false}
	}
	return tmin, true
}

// Möller–Trumbore, double-sided.
ray_triangle :: proc(r: Ray, a, b, c: Vec3) -> (t: f32, hit: bool) {
	e1 := b - a
	e2 := c - a
	p := linalg.cross(r.dir, e2)
	det := linalg.dot(e1, p)
	if abs(det) < 1e-12 {return 0, false}
	inv := 1 / det
	s := r.origin - a
	u := linalg.dot(s, p) * inv
	if u < 0 || u > 1 {return 0, false}
	q := linalg.cross(s, e1)
	v := linalg.dot(r.dir, q) * inv
	if v < 0 || u + v > 1 {return 0, false}
	t = linalg.dot(e2, q) * inv
	return t, t > 0
}

// Closest hit against a triangle soup. Returns distance and triangle index.
ray_mesh :: proc(r: Ray, positions: []Vec3) -> (t: f32, tri_index: int, hit: bool) {
	best := max(f32)
	tri_index = -1
	for k := 0; k + 2 < len(positions); k += 3 {
		if d, ok := ray_triangle(r, positions[k], positions[k + 1], positions[k + 2]); ok && d < best {
			best = d
			tri_index = k / 3
		}
	}
	return best, tri_index, tri_index >= 0
}

ray_plane :: proc(r: Ray, p0, n: Vec3) -> (t: f32, hit: bool) {
	d := linalg.dot(n, r.dir)
	if abs(d) < 1e-9 {return 0, false}
	t = linalg.dot(p0 - r.origin, n) / d
	return t, t > 0
}

// Parameter along line (p0 + s*dir) closest to the ray; used for axis dragging.
closest_on_line_to_ray :: proc(p0, dir: Vec3, r: Ray) -> f32 {
	w0 := p0 - r.origin
	a := linalg.dot(dir, dir)
	b := linalg.dot(dir, r.dir)
	c := linalg.dot(r.dir, r.dir)
	d := linalg.dot(dir, w0)
	e := linalg.dot(r.dir, w0)
	denom := a * c - b * b
	if abs(denom) < 1e-9 {return 0}
	return (b * e - c * d) / denom
}
