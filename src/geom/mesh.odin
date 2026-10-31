package geom

import "core:math"
import "core:math/linalg"

// Non-indexed triangle soup plus feature edges (line pairs) for outlines.
Mesh_Data :: struct {
	positions: [dynamic]Vec3,
	normals:   [dynamic]Vec3,
	uvs:       [dynamic]Vec2,
	edges:     [dynamic]Vec3,
}

mesh_init :: proc(m: ^Mesh_Data, allocator := context.allocator) {
	m.positions = make([dynamic]Vec3, allocator)
	m.normals = make([dynamic]Vec3, allocator)
	m.uvs = make([dynamic]Vec2, allocator)
	m.edges = make([dynamic]Vec3, allocator)
}

mesh_destroy :: proc(m: ^Mesh_Data) {
	delete(m.positions)
	delete(m.normals)
	delete(m.uvs)
	delete(m.edges)
	m^ = {}
}

mesh_bounds :: proc(m: Mesh_Data) -> (lo, hi: Vec3) {
	if len(m.positions) == 0 {return}
	lo = m.positions[0]
	hi = lo
	for p in m.positions {
		lo = linalg.min(lo, p)
		hi = linalg.max(hi, p)
	}
	return
}

// Smooth vertices get averaged normals; corners sharper than this stay hard.
SMOOTH_ANGLE_COS :: 0.82 // ~35 degrees

@(private)
vert :: proc(m: ^Mesh_Data, p, n: Vec3, uv: Vec2) {
	append(&m.positions, p)
	append(&m.normals, n)
	append(&m.uvs, uv)
}

// Emits a triangle, fixing its winding so that it faces along the given normals.
@(private)
tri :: proc(m: ^Mesh_Data, a, b, c: Vec3, na, nb, nc: Vec3, ua, ub, uc: Vec2) {
	f := linalg.cross(b - a, c - a)
	if linalg.length2(f) < 1e-12 {return}
	if linalg.dot(f, na + nb + nc) < 0 {
		vert(m, a, na, ua)
		vert(m, c, nc, uc)
		vert(m, b, nb, ub)
	} else {
		vert(m, a, na, ua)
		vert(m, b, nb, ub)
		vert(m, c, nc, uc)
	}
}

@(private)
edge :: proc(m: ^Mesh_Data, a, b: Vec3) {
	append(&m.edges, a, b)
}

// Per-vertex data for a 2D ring: edge normals (right-hand side) and whether
// the vertex is smooth.
@(private)
Ring_Info :: struct {
	edge_n: []Vec2, // normal of edge i -> i+1
	smooth: []bool,
}

@(private)
ring_info :: proc(pts: []Vec2, closed: bool) -> Ring_Info {
	n := len(pts)
	ri := Ring_Info {
		edge_n = make([]Vec2, n, context.temp_allocator),
		smooth = make([]bool, n, context.temp_allocator),
	}
	ecount := closed ? n : n - 1
	for i in 0 ..< ecount {
		d := pts[(i + 1) % n] - pts[i]
		l := linalg.length(d)
		ri.edge_n[i] = l > 0 ? Vec2{d.y, -d.x} / l : {}
	}
	for i in 0 ..< n {
		if !closed && (i == 0 || i == n - 1) {continue}
		a := ri.edge_n[(i + n - 1) % n]
		b := ri.edge_n[i]
		ri.smooth[i] = linalg.dot(a, b) > SMOOTH_ANGLE_COS
	}
	return ri
}

@(private)
vertex_normal :: proc(ri: Ring_Info, i: int, edge_idx: int, n: int) -> Vec2 {
	if ri.smooth[i] {
		return linalg.normalize(ri.edge_n[(i + n - 1) % n] + ri.edge_n[i])
	}
	return ri.edge_n[edge_idx]
}

// Profile (u, v) maps to local 3D (u, y, -v): the profile is seen from above
// and extruded upward along +Y by `thickness`.
@(private)
to3 :: proc(p: Vec2, y: f32) -> Vec3 {return {p.x, y, -p.y}}

UV_SCALE :: 1.0 / 600.0 // one texture repeat per 600 mm

// A horizontal slice of an extruded wall: height, inward inset, and how the
// normal blends between the outline normal (h) and straight up/down (v).
@(private)
Wall_Ring :: struct {
	y, inset: f32,
	nh, nv:   f32,
}

ROUND_STEPS :: 6 // segments per quarter-circle edge rounding

// Moves every point of a closed ring inward (into the material) by `d`.
// Holes are clockwise, so the same formula grows them.
@(private)
inset_ring :: proc(pts: []Vec2, ri: Ring_Info, d: f32, allocator := context.temp_allocator) -> []Vec2 {
	n := len(pts)
	out := make([]Vec2, n, allocator)
	for i in 0 ..< n {
		if d == 0 {
			out[i] = pts[i]
			continue
		}
		a := ri.edge_n[(i + n - 1) % n]
		b := ri.edge_n[i]
		avg := linalg.normalize0(a + b)
		out[i] = pts[i] - avg * d / max(linalg.dot(avg, b), 0.25)
	}
	return out
}

// Extrudes along +Y by `thickness`. With `edge_r` > 0 the top and bottom
// perimeter edges are rounded with that radius (the outline should already
// have corner radii >= edge_r so the vertical corners blend in).
extrude_profile :: proc(prof: Profile2D, thickness: f32, tol: f32, m: ^Mesh_Data, edge_r: f32 = 0) {
	ta := context.temp_allocator
	outer := make([dynamic]Vec2, ta)
	tessellate_contour(prof.outer, tol, &outer)
	if len(outer) < 3 {return}
	if polygon_area(outer[:]) < 0 {reverse_points(outer[:])}
	holes := make([dynamic][]Vec2, ta)
	for h in prof.holes {
		hp := make([dynamic]Vec2, ta)
		tessellate_contour(h, tol, &hp)
		if len(hp) < 3 {continue}
		if polygon_area(hp[:]) > 0 {reverse_points(hp[:])}
		append(&holes, hp[:])
	}
	e := clamp(edge_r, 0, thickness * 0.5 - 0.01)

	rings := make([dynamic]Wall_Ring, ta)
	if e <= 0 {
		append(&rings, Wall_Ring{0, 0, 1, 0}, Wall_Ring{thickness, 0, 1, 0})
	} else {
		for k in 0 ..= ROUND_STEPS {
			phi := f32(k) / ROUND_STEPS * math.PI * 0.5
			append(&rings, Wall_Ring{e * (1 - math.cos(phi)), e * (1 - math.sin(phi)), math.sin(phi), -math.cos(phi)})
		}
		for k := ROUND_STEPS; k >= 0; k -= 1 {
			phi := f32(k) / ROUND_STEPS * math.PI * 0.5
			append(&rings, Wall_Ring{thickness - e * (1 - math.cos(phi)), e * (1 - math.sin(phi)), math.sin(phi), math.cos(phi)})
		}
	}

	// caps, inset by the rounding so they meet the curved band
	cap_outer := inset_ring(outer[:], ring_info(outer[:], true), e)
	cap_holes := make([dynamic][]Vec2, ta)
	for h in holes {append(&cap_holes, inset_ring(h, ring_info(h, true), e))}
	verts, tris := triangulate(cap_outer, cap_holes[:], ta)
	up := Vec3{0, 1, 0}
	for k := 0; k + 2 < len(tris); k += 3 {
		a, b, c := verts[tris[k]], verts[tris[k + 1]], verts[tris[k + 2]]
		tri(m, to3(a, thickness), to3(b, thickness), to3(c, thickness), up, up, up, a * UV_SCALE, b * UV_SCALE, c * UV_SCALE)
		tri(m, to3(a, 0), to3(b, 0), to3(c, 0), -up, -up, -up, a * UV_SCALE, b * UV_SCALE, c * UV_SCALE)
	}

	walls :: proc(m: ^Mesh_Data, pts: []Vec2, rings: []Wall_Ring, rounded: bool) {
		n := len(pts)
		ri := ring_info(pts, true)
		insets := make([][]Vec2, len(rings), context.temp_allocator)
		for r, k in rings {insets[k] = inset_ring(pts, ri, r.inset)}
		s: f32 = 0
		for i in 0 ..< n {
			j := (i + 1) % n
			len_e := linalg.length(pts[j] - pts[i])
			n0 := vertex_normal(ri, i, i, n)
			n1 := vertex_normal(ri, j, i, n)
			for k in 0 ..< len(rings) - 1 {
				r0, r1 := rings[k], rings[k + 1]
				N :: proc(n2: Vec2, r: Wall_Ring) -> Vec3 {return linalg.normalize(Vec3{n2.x * r.nh, r.nv, -n2.y * r.nh})}
				a := to3(insets[k][i], r0.y)
				b := to3(insets[k][j], r0.y)
				c := to3(insets[k + 1][j], r1.y)
				d := to3(insets[k + 1][i], r1.y)
				ua := Vec2{s, r0.y} * UV_SCALE
				ub := Vec2{s + len_e, r0.y} * UV_SCALE
				uc := Vec2{s + len_e, r1.y} * UV_SCALE
				ud := Vec2{s, r1.y} * UV_SCALE
				tri(m, a, b, c, N(n0, r0), N(n1, r0), N(n1, r1), ua, ub, uc)
				tri(m, a, c, d, N(n0, r0), N(n1, r1), N(n0, r1), ua, uc, ud)
			}
			s += len_e
			// feature edges: where the caps meet the sides, plus sharp verticals
			last := len(rings) - 1
			edge(m, to3(insets[0][i], rings[0].y), to3(insets[0][j], rings[0].y))
			edge(m, to3(insets[last][i], rings[last].y), to3(insets[last][j], rings[last].y))
			if !rounded && !ri.smooth[i] {edge(m, to3(pts[i], 0), to3(pts[i], rings[last].y))}
		}
	}
	walls(m, outer[:], rings[:], e > 0)
	for h in holes {walls(m, h, rings[:], e > 0)}
}

// Revolves a half profile of (radius, height) points around the local Y axis.
lathe :: proc(profile: []Vec2, segments: int, m: ^Mesh_Data) {
	if len(profile) < 2 {return}
	ta := context.temp_allocator
	pts := make([dynamic]Vec2, ta)
	// close the profile onto the axis so ends get flat caps
	if profile[0].x > 1e-4 {append(&pts, Vec2{0, profile[0].y})}
	append(&pts, ..profile)
	last := profile[len(profile) - 1]
	if last.x > 1e-4 {append(&pts, Vec2{0, last.y})}
	for &p in pts {p.x = max(p.x, 0)}
	// orient so that the right-hand normal points away from the axis
	closed_area := polygon_area(pts[:])
	if closed_area < 0 {reverse_points(pts[:])}

	n := len(pts)
	ri := ring_info(pts[:], false)
	seg := max(segments, 8)
	s: f32 = 0
	for i in 0 ..< n - 1 {
		p, q := pts[i], pts[i + 1]
		e := linalg.length(q - p)
		n0 := ri.smooth[i] ? linalg.normalize(ri.edge_n[i - 1] + ri.edge_n[i]) : ri.edge_n[i]
		n1 := ri.smooth[i + 1] ? linalg.normalize(ri.edge_n[i] + ri.edge_n[i + 1]) : ri.edge_n[i]
		for k in 0 ..< seg {
			a0 := f32(k) / f32(seg) * math.TAU
			a1 := f32(k + 1) / f32(seg) * math.TAU
			c0, s0 := math.cos(a0), math.sin(a0)
			c1, s1 := math.cos(a1), math.sin(a1)
			P0 := Vec3{p.x * c0, p.y, p.x * s0}
			P1 := Vec3{p.x * c1, p.y, p.x * s1}
			Q0 := Vec3{q.x * c0, q.y, q.x * s0}
			Q1 := Vec3{q.x * c1, q.y, q.x * s1}
			NP0 := Vec3{n0.x * c0, n0.y, n0.x * s0}
			NP1 := Vec3{n0.x * c1, n0.y, n0.x * s1}
			NQ0 := Vec3{n1.x * c0, n1.y, n1.x * s0}
			NQ1 := Vec3{n1.x * c1, n1.y, n1.x * s1}
			u0 := f32(k) / f32(seg)
			u1 := f32(k + 1) / f32(seg)
			tri(m, P0, P1, Q1, NP0, NP1, NQ1, {u0, s * UV_SCALE}, {u1, s * UV_SCALE}, {u1, (s + e) * UV_SCALE})
			tri(m, P0, Q1, Q0, NP0, NQ1, NQ0, {u0, s * UV_SCALE}, {u1, (s + e) * UV_SCALE}, {u0, (s + e) * UV_SCALE})
		}
		s += e
	}
	// rings at hard profile vertices
	for i in 0 ..< n {
		p := pts[i]
		if ri.smooth[i] || p.x < 1e-3 {continue}
		ring_seg := max(seg, 32)
		for k in 0 ..< ring_seg {
			a0 := f32(k) / f32(ring_seg) * math.TAU
			a1 := f32(k + 1) / f32(ring_seg) * math.TAU
			edge(m, {p.x * math.cos(a0), p.y, p.x * math.sin(a0)}, {p.x * math.cos(a1), p.y, p.x * math.sin(a1)})
		}
	}
}

// Sweeps a closed cross-section (s along the path's side vector, t along +Y)
// along an open planar path in the profile plane (mapped like panels: (u, v) -> (u, 0, -v)).
sweep :: proc(section: []Vec2, path: []Vec2, m: ^Mesh_Data) {
	if len(section) < 3 || len(path) < 2 {return}
	ta := context.temp_allocator
	sec := make([]Vec2, len(section), ta)
	copy(sec, section)
	if polygon_area(sec) < 0 {reverse_points(sec)}
	ns := len(sec)
	sri := ring_info(sec, true)

	np := len(path)
	P := make([]Vec3, np, ta)
	for p, i in path {P[i] = to3(p, 0)}
	up := Vec3{0, 1, 0}
	// per path segment direction and side
	nseg := np - 1
	T := make([]Vec3, nseg, ta)
	S := make([]Vec3, nseg, ta)
	for i in 0 ..< nseg {
		T[i] = linalg.normalize0(P[i + 1] - P[i])
		S[i] = linalg.normalize0(linalg.cross(T[i], up))
	}
	// miter side vectors at path vertices
	miter := make([]Vec3, np, ta)
	smooth := make([]bool, np, ta)
	for i in 0 ..< np {
		if i == 0 {miter[i] = S[0]; continue}
		if i == np - 1 {miter[i] = S[nseg - 1]; continue}
		mdir := linalg.normalize0(S[i - 1] + S[i])
		d := linalg.dot(mdir, S[i])
		miter[i] = d > 0.2 ? mdir / d : S[i]
		smooth[i] = linalg.dot(T[i - 1], T[i]) > SMOOTH_ANGLE_COS
	}
	place :: proc(P: Vec3, side: Vec3, q: Vec2) -> Vec3 {return P + side * q.x + Vec3{0, q.y, 0}}

	along: f32 = 0
	for i in 0 ..< nseg {
		seg_len := linalg.length(P[i + 1] - P[i])
		side_a := smooth[i] ? linalg.normalize(miter[i]) : S[i]
		side_b := smooth[i + 1] ? linalg.normalize(miter[i + 1]) : S[i]
		perim: f32 = 0
		for k in 0 ..< ns {
			k1 := (k + 1) % ns
			qa, qb := sec[k], sec[k1]
			na := vertex_normal(sri, k, k, ns)
			nb := vertex_normal(sri, k1, k, ns)
			A0 := place(P[i], miter[i], qa)
			B0 := place(P[i], miter[i], qb)
			A1 := place(P[i + 1], miter[i + 1], qa)
			B1 := place(P[i + 1], miter[i + 1], qb)
			NA0 := side_a * na.x + up * na.y
			NB0 := side_a * nb.x + up * nb.y
			NA1 := side_b * na.x + up * na.y
			NB1 := side_b * nb.x + up * nb.y
			el := linalg.length(qb - qa)
			u0 := along * UV_SCALE
			u1 := (along + seg_len) * UV_SCALE
			v0 := perim * UV_SCALE
			v1 := (perim + el) * UV_SCALE
			tri(m, A0, B0, B1, NA0, NB0, NB1, {u0, v0}, {u0, v1}, {u1, v1})
			tri(m, A0, B1, A1, NA0, NB1, NA1, {u0, v0}, {u1, v1}, {u1, v0})
			if !sri.smooth[k] {edge(m, A0, A1)}
			perim += el
		}
		along += seg_len
	}
	// section outlines at ends and hard path corners
	for i in 0 ..< np {
		if smooth[i] {continue}
		for k in 0 ..< ns {
			edge(m, place(P[i], miter[i], sec[k]), place(P[i], miter[i], sec[(k + 1) % ns]))
		}
	}
	// end caps
	verts, tris := triangulate(sec, nil, ta)
	for end in 0 ..< 2 {
		idx := end == 0 ? 0 : np - 1
		nrm := end == 0 ? -T[0] : T[nseg - 1]
		for k := 0; k + 2 < len(tris); k += 3 {
			a, b, c := verts[tris[k]], verts[tris[k + 1]], verts[tris[k + 2]]
			tri(m, place(P[idx], miter[idx], a), place(P[idx], miter[idx], b), place(P[idx], miter[idx], c), nrm, nrm, nrm, a * UV_SCALE, b * UV_SCALE, c * UV_SCALE)
		}
	}
}
