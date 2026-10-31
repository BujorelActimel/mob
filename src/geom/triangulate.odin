package geom

import "core:math/linalg"
import "core:slice"

// Triangulates a polygon with holes by bridging holes into the outer ring and
// ear-clipping. `outer` may be either orientation; holes are re-oriented as needed.
// Returns the merged vertex list and triangle indices (CCW) into it.
triangulate :: proc(outer: []Vec2, holes: [][]Vec2, allocator := context.allocator) -> (verts: [dynamic]Vec2, tris: [dynamic]i32) {
	verts = make([dynamic]Vec2, allocator)
	tris = make([dynamic]i32, allocator)
	if len(outer) < 3 {return}

	ta := context.temp_allocator
	append(&verts, ..outer)
	if polygon_area(verts[:]) < 0 {reverse_points(verts[:])}
	poly := make([dynamic]i32, ta)
	for i in 0 ..< len(outer) {append(&poly, i32(i))}

	Hole :: struct {
		start, count: i32,
		max_x:        f32,
	}
	hole_list := make([dynamic]Hole, ta)
	for h in holes {
		if len(h) < 3 {continue}
		start := i32(len(verts))
		append(&verts, ..h)
		hv := verts[start:]
		if polygon_area(hv) > 0 {reverse_points(hv)}
		mx := f32(min(f32))
		for p in hv {mx = max(mx, p.x)}
		append(&hole_list, Hole{start, i32(len(h)), mx})
	}
	slice.sort_by(hole_list[:], proc(a, b: Hole) -> bool {return a.max_x > b.max_x})

	for h, hi in hole_list {
		// rightmost hole vertex
		m := h.start
		for k in h.start ..< h.start + h.count {
			if verts[k].x > verts[m].x {m = k}
		}
		mp := verts[m]
		// candidate bridge targets in the current polygon, closest first
		Cand :: struct {
			pos: int,
			d:   f32,
		}
		cands := make([dynamic]Cand, ta)
		for idx, pos in poly {
			p := verts[idx]
			d := linalg.length2(p - mp)
			if p.x < mp.x {d += 1e9 + d} // prefer vertices to the right
			append(&cands, Cand{pos, d})
		}
		slice.sort_by(cands[:], proc(a, b: Cand) -> bool {return a.d < b.d})
		chosen := -1
		for cd in cands {
			if bridge_visible(verts[:], poly[:], hole_list[hi:], mp, verts[poly[cd.pos]]) {
				chosen = cd.pos
				break
			}
		}
		if chosen < 0 {chosen = cands[0].pos} // degenerate input: best effort
		// splice: ... V, M, hole..., M, V, ...
		ins := make([dynamic]i32, ta)
		for k in 0 ..= h.count {
			append(&ins, h.start + (m - h.start + k) % h.count)
		}
		append(&ins, poly[chosen])
		inject_at(&poly, chosen + 1, ..ins[:])
	}

	ear_clip(verts[:], &poly, &tris)
	return
}

@(private)
segments_cross :: proc(p1, p2, q1, q2: Vec2) -> bool {
	d1 := cross2(q2 - q1, p1 - q1)
	d2 := cross2(q2 - q1, p2 - q1)
	d3 := cross2(p2 - p1, q1 - p1)
	d4 := cross2(p2 - p1, q2 - p1)
	return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

@(private)
same_pt :: proc(a, b: Vec2) -> bool {return linalg.length2(a - b) < 1e-10}

@(private)
point_in_ring :: proc(verts: []Vec2, ring: []i32, p: Vec2) -> bool {
	inside := false
	n := len(ring)
	j := n - 1
	for i in 0 ..< n {
		a := verts[ring[i]]
		b := verts[ring[j]]
		if (a.y > p.y) != (b.y > p.y) {
			x := (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
			if p.x < x {inside = !inside}
		}
		j = i
	}
	return inside
}

@(private)
bridge_visible :: proc(verts: []Vec2, poly: []i32, holes: []$H, a, b: Vec2) -> bool {
	edge_ok :: proc(a, b, p, q: Vec2) -> bool {
		if same_pt(p, a) || same_pt(p, b) || same_pt(q, a) || same_pt(q, b) {return true}
		return !segments_cross(a, b, p, q)
	}
	n := len(poly)
	for i in 0 ..< n {
		if !edge_ok(a, b, verts[poly[i]], verts[poly[(i + 1) % n]]) {return false}
	}
	for h in holes {
		for k in 0 ..< h.count {
			p := verts[h.start + k]
			q := verts[h.start + (k + 1) % h.count]
			if !edge_ok(a, b, p, q) {return false}
		}
	}
	mid := (a + b) * 0.5
	if !point_in_ring(verts, poly, mid) {return false}
	// must not run through the interior of the hole being bridged
	h := holes[0]
	ring := make([]i32, h.count, context.temp_allocator)
	for k in 0 ..< h.count {ring[k] = h.start + i32(k)}
	return !point_in_ring(verts, ring, mid)
}

@(private)
point_in_tri :: proc(p, a, b, c: Vec2) -> bool {
	d1 := cross2(b - a, p - a)
	d2 := cross2(c - b, p - b)
	d3 := cross2(a - c, p - c)
	return d1 >= 0 && d2 >= 0 && d3 >= 0
}

@(private)
ear_clip :: proc(verts: []Vec2, poly: ^[dynamic]i32, tris: ^[dynamic]i32) {
	guard := 0
	for len(poly) > 3 {
		n := len(poly)
		found := false
		best_i := -1
		best_area := f32(-max(f32))
		for i in 0 ..< n {
			ia := poly[(i + n - 1) % n]
			ib := poly[i]
			ic := poly[(i + 1) % n]
			a, b, c := verts[ia], verts[ib], verts[ic]
			area := cross2(b - a, c - b)
			if area > best_area {
				best_area = area
				best_i = i
			}
			if area <= 1e-9 {continue}
			ear := true
			for k in 0 ..< n {
				p := verts[poly[k]]
				if same_pt(p, a) || same_pt(p, b) || same_pt(p, c) {continue}
				if point_in_tri(p, a, b, c) {
					ear = false
					break
				}
			}
			if ear {
				append(tris, ia, ib, ic)
				ordered_remove(poly, i)
				found = true
				break
			}
		}
		if !found {
			// degenerate (collinear spikes or numerical trouble): drop the best vertex
			i := best_i
			if best_area > 1e-9 {
				append(tris, poly[(i + n - 1) % n], poly[i], poly[(i + 1) % n])
			}
			ordered_remove(poly, i)
		}
		guard += 1
		if guard > 100000 {break}
	}
	if len(poly) == 3 {
		a, b, c := verts[poly[0]], verts[poly[1]], verts[poly[2]]
		if cross2(b - a, c - b) > 1e-9 {append(tris, poly[0], poly[1], poly[2])}
	}
}
