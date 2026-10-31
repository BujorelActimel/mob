// Exact 2D profiles (lines + arcs), tessellation and fillet construction.
package geom

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32

Line :: struct {
	a, b: Vec2,
}

// Arc around `c` with radius `r`, from angle `start` sweeping `sweep` radians (+ = CCW).
Arc :: struct {
	c:     Vec2,
	r:     f32,
	start: f32,
	sweep: f32,
}

Segment :: union {
	Line,
	Arc,
}

Contour :: struct {
	segs:   [dynamic]Segment,
	closed: bool,
}

Profile2D :: struct {
	outer: Contour,
	holes: [dynamic]Contour,
}

arc_point :: proc(a: Arc, t: f32) -> Vec2 {
	ang := a.start + a.sweep * t
	return a.c + a.r * Vec2{math.cos(ang), math.sin(ang)}
}

seg_start :: proc(s: Segment) -> Vec2 {
	switch v in s {
	case Line: return v.a
	case Arc:  return arc_point(v, 0)
	}
	return {}
}

seg_end :: proc(s: Segment) -> Vec2 {
	switch v in s {
	case Line: return v.b
	case Arc:  return arc_point(v, 1)
	}
	return {}
}

contour_destroy :: proc(c: ^Contour) {
	delete(c.segs)
	c^ = {}
}

profile_destroy :: proc(p: ^Profile2D) {
	contour_destroy(&p.outer)
	for &h in p.holes {contour_destroy(&h)}
	delete(p.holes)
	p^ = {}
}

cross2 :: proc(a, b: Vec2) -> f32 {return a.x * b.y - a.y * b.x}

// Builds a contour from polygon vertices, rounding vertex i with radius radii[i].
// Radii are clamped so that neighbouring fillets never overlap.
contour_from_polygon :: proc(pts: []Vec2, radii: []f32, closed: bool, allocator := context.allocator) -> Contour {
	c := Contour{segs = make([dynamic]Segment, allocator), closed = closed}
	n := len(pts)
	if n < 2 {return c}

	// Per vertex: entry tangent point, exit tangent point, optional arc.
	Corner :: struct {
		pin, pout: Vec2,
		arc:       Arc,
		has_arc:   bool,
	}
	corners := make([]Corner, n, context.temp_allocator)
	for i in 0 ..< n {
		corners[i] = {pin = pts[i], pout = pts[i]}
		r := i < len(radii) ? radii[i] : 0
		if r <= 1e-4 {continue}
		if !closed && (i == 0 || i == n - 1) {continue}
		prev := pts[(i + n - 1) % n]
		next := pts[(i + 1) % n]
		cur := pts[i]
		e0 := cur - prev
		e1 := next - cur
		l0 := linalg.length(e0)
		l1 := linalg.length(e1)
		if l0 < 1e-5 || l1 < 1e-5 {continue}
		d0 := e0 / l0
		d1 := e1 / l1
		cos_t := clamp(linalg.dot(-d0, d1), -1, 1)
		theta := math.acos(cos_t) // interior angle at the corner
		if theta < 1e-3 || theta > math.PI - 1e-3 {continue}
		t := r / math.tan(theta * 0.5)
		// a neighbour that is an open end gets the full edge, otherwise half
		lim0 := (!closed && i - 1 == 0) ? l0 : l0 * 0.5
		lim1 := (!closed && i + 1 == n - 1) ? l1 : l1 * 0.5
		tmax := min(lim0, lim1)
		if t > tmax {
			t = tmax
			r = t * math.tan(theta * 0.5)
		}
		t0 := cur - d0 * t
		t1 := cur + d1 * t
		bis := linalg.normalize(-d0 + d1)
		center := cur + bis * (r / math.sin(theta * 0.5))
		a0 := math.atan2(t0.y - center.y, t0.x - center.x)
		turn := cross2(d0, d1)
		sweep := f32(math.PI) - theta
		if turn < 0 {sweep = -sweep}
		corners[i] = {pin = t0, pout = t1, arc = {c = center, r = r, start = a0, sweep = sweep}, has_arc = true}
	}

	add_line :: proc(c: ^Contour, a, b: Vec2) {
		if linalg.length(b - a) > 1e-5 {append(&c.segs, Line{a, b})}
	}
	if closed {
		for i in 0 ..< n {
			k := corners[i]
			if k.has_arc {append(&c.segs, k.arc)}
			add_line(&c, k.pout, corners[(i + 1) % n].pin)
		}
	} else {
		for i in 0 ..< n - 1 {
			k := corners[i]
			if k.has_arc {append(&c.segs, k.arc)}
			add_line(&c, k.pout, corners[i + 1].pin)
		}
	}
	return c
}

contour_circle :: proc(center: Vec2, r: f32, ccw: bool, allocator := context.allocator) -> Contour {
	c := Contour{segs = make([dynamic]Segment, allocator), closed = true}
	append(&c.segs, Arc{c = center, r = r, start = 0, sweep = ccw ? math.TAU : -math.TAU})
	return c
}

contour_reverse :: proc(c: ^Contour) {
	n := len(c.segs)
	for i in 0 ..< n / 2 {
		c.segs[i], c.segs[n - 1 - i] = c.segs[n - 1 - i], c.segs[i]
	}
	for &s in c.segs {
		switch &v in s {
		case Line: v.a, v.b = v.b, v.a
		case Arc:
			v.start = v.start + v.sweep
			v.sweep = -v.sweep
		}
	}
}

arc_steps :: proc(r, sweep, tol: f32) -> int {
	if r <= 0 {return 1}
	step: f32
	if tol >= r {
		step = math.PI / 2
	} else {
		step = 2 * math.acos(1 - tol / r)
	}
	step = max(step, 0.01)
	n := int(math.ceil(abs(sweep) / step))
	return clamp(n, 1, 256)
}

// Appends the polyline approximation. Closed contours do not repeat the first point.
tessellate_contour :: proc(c: Contour, tol: f32, out: ^[dynamic]Vec2) {
	for s, si in c.segs {
		switch v in s {
		case Line:
			append(out, v.a)
		case Arc:
			n := arc_steps(v.r, v.sweep, tol)
			if abs(v.sweep) > math.PI * 1.9 {n = max(n, 12)}
			for k in 0 ..< n {
				append(out, arc_point(v, f32(k) / f32(n)))
			}
		}
		if !c.closed && si == len(c.segs) - 1 {
			append(out, seg_end(s))
		}
	}
}

polygon_area :: proc(pts: []Vec2) -> f32 {
	a: f32
	n := len(pts)
	for i in 0 ..< n {
		p := pts[i]
		q := pts[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	}
	return a * 0.5
}

reverse_points :: proc(pts: []Vec2) {
	n := len(pts)
	for i in 0 ..< n / 2 {pts[i], pts[n - 1 - i] = pts[n - 1 - i], pts[i]}
}

Bounds2 :: struct {
	min, max: Vec2,
}

contour_bounds :: proc(c: Contour, tol: f32 = 0.05) -> Bounds2 {
	pts := make([dynamic]Vec2, context.temp_allocator)
	tessellate_contour(c, tol, &pts)
	b := Bounds2{{max(f32), max(f32)}, {min(f32), min(f32)}}
	for p in pts {
		b.min = linalg.min(b.min, p)
		b.max = linalg.max(b.max, p)
	}
	if len(pts) == 0 {b = {}}
	return b
}

// True if a contour consists of exactly four axis-aligned lines (a plain rectangle).
contour_is_rect :: proc(c: Contour) -> bool {
	if len(c.segs) != 4 {return false}
	for s in c.segs {
		l, ok := s.(Line)
		if !ok {return false}
		if abs(l.a.x - l.b.x) > 1e-4 && abs(l.a.y - l.b.y) > 1e-4 {return false}
	}
	return true
}
