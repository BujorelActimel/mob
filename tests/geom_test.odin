package tests

import "core:math"
import "core:math/linalg"
import "core:testing"
import "../src/geom"

@(private = "file")
tri_area_sum :: proc(verts: []geom.Vec2, tris: []i32) -> f32 {
	s: f32
	for k := 0; k + 2 < len(tris); k += 3 {
		a, b, c := verts[tris[k]], verts[tris[k + 1]], verts[tris[k + 2]]
		ar := geom.cross2(b - a, c - a) * 0.5
		s += ar
	}
	return s
}

@(private = "file")
all_ccw :: proc(verts: []geom.Vec2, tris: []i32) -> bool {
	for k := 0; k + 2 < len(tris); k += 3 {
		a, b, c := verts[tris[k]], verts[tris[k + 1]], verts[tris[k + 2]]
		if geom.cross2(b - a, c - a) <= 0 {return false}
	}
	return true
}

@(test)
test_triangulate_convex :: proc(t: ^testing.T) {
	sq := []geom.Vec2{{0, 0}, {100, 0}, {100, 50}, {0, 50}}
	v, tr := geom.triangulate(sq, nil, context.temp_allocator)
	testing.expect_value(t, len(tr), 6)
	testing.expect(t, abs(tri_area_sum(v[:], tr[:]) - 5000) < 1e-2)
	testing.expect(t, all_ccw(v[:], tr[:]))
	// clockwise input gets fixed
	cw := []geom.Vec2{{0, 0}, {0, 50}, {100, 50}, {100, 0}}
	v, tr = geom.triangulate(cw, nil, context.temp_allocator)
	testing.expect(t, abs(tri_area_sum(v[:], tr[:]) - 5000) < 1e-2)
}

@(test)
test_triangulate_concave :: proc(t: ^testing.T) {
	// L shape, area 100*100 - 60*60
	l := []geom.Vec2{{0, 0}, {100, 0}, {100, 40}, {40, 40}, {40, 100}, {0, 100}}
	v, tr := geom.triangulate(l, nil, context.temp_allocator)
	testing.expect_value(t, len(tr) / 3, 4)
	testing.expect(t, abs(tri_area_sum(v[:], tr[:]) - 6400) < 1e-2)
	testing.expect(t, all_ccw(v[:], tr[:]))
}

@(test)
test_triangulate_holes :: proc(t: ^testing.T) {
	outer := []geom.Vec2{{0, 0}, {200, 0}, {200, 100}, {0, 100}}
	h1 := []geom.Vec2{{20, 20}, {60, 20}, {60, 60}, {20, 60}}
	h2 := []geom.Vec2{{120, 30}, {180, 30}, {180, 70}, {120, 70}}
	holes := [][]geom.Vec2{h1, h2}
	v, tr := geom.triangulate(outer, holes, context.temp_allocator)
	want := f32(200 * 100 - 40 * 40 - 60 * 40)
	got := tri_area_sum(v[:], tr[:])
	testing.expectf(t, abs(got - want) < 1e-1, "area %v want %v", got, want)
	testing.expect(t, all_ccw(v[:], tr[:]))
}

@(test)
test_fillet_and_arcs :: proc(t: ^testing.T) {
	pts := []geom.Vec2{{0, 0}, {300, 0}, {300, 200}, {0, 200}}
	radii := []f32{0, 50, 0, 0}
	c := geom.contour_from_polygon(pts, radii, true, context.temp_allocator)
	arcs := 0
	for s in c.segs {
		if a, ok := s.(geom.Arc); ok {
			arcs += 1
			testing.expect(t, abs(a.r - 50) < 1e-4)
			testing.expect(t, abs(abs(a.sweep) - math.PI / 2) < 1e-4)
			testing.expect(t, linalg.length(a.c - geom.Vec2{250, 50}) < 1e-3)
		}
	}
	testing.expect_value(t, arcs, 1)
	testing.expect_value(t, len(c.segs), 5)
	// contour is closed and continuous
	for s, i in c.segs {
		nxt := c.segs[(i + 1) % len(c.segs)]
		testing.expect(t, linalg.length(geom.seg_end(s) - geom.seg_start(nxt)) < 1e-3)
	}
	// tessellated area: rect minus the corner cut (r^2 - pi r^2 / 4)
	poly := make([dynamic]geom.Vec2, context.temp_allocator)
	geom.tessellate_contour(c, 0.01, &poly)
	area := geom.polygon_area(poly[:])
	want := f32(300 * 200) - (50 * 50 - math.PI * 50 * 50 / 4)
	testing.expectf(t, abs(area - want) < 2, "area %v want %v", area, want)
	// radius larger than the edges allow gets clamped
	big := geom.contour_from_polygon(pts, []f32{500, 500, 500, 500}, true, context.temp_allocator)
	for s in big.segs {
		if a, ok := s.(geom.Arc); ok {testing.expect(t, a.r <= 100 + 1e-3)}
	}
}

@(test)
test_extrude :: proc(t: ^testing.T) {
	prof: geom.Profile2D
	prof.outer = geom.contour_from_polygon([]geom.Vec2{{0, 0}, {100, 0}, {100, 50}, {0, 50}}, nil, true, context.temp_allocator)
	m: geom.Mesh_Data
	geom.mesh_init(&m, context.temp_allocator)
	geom.extrude_profile(prof, 18, 0.1, &m)
	// box: 2 caps * 2 tris + 4 walls * 2 tris = 12 triangles
	testing.expect_value(t, len(m.positions), 36)
	testing.expect_value(t, len(m.normals), 36)
	lo, hi := geom.mesh_bounds(m)
	testing.expect(t, lo == geom.Vec3{0, 0, -50})
	testing.expect(t, hi == geom.Vec3{100, 18, 0})
	// every triangle faces along its normals, normals are unit length
	for k := 0; k < len(m.positions); k += 3 {
		f := linalg.cross(m.positions[k + 1] - m.positions[k], m.positions[k + 2] - m.positions[k])
		testing.expect(t, linalg.dot(f, m.normals[k]) > 0)
		testing.expect(t, abs(linalg.length(m.normals[k]) - 1) < 1e-4)
	}
	// 4 bottom + 4 top + 4 vertical feature edges
	testing.expect_value(t, len(m.edges) / 2, 12)
}

@(test)
test_extrude_with_hole :: proc(t: ^testing.T) {
	prof: geom.Profile2D
	prof.outer = geom.contour_from_polygon([]geom.Vec2{{0, 0}, {100, 0}, {100, 100}, {0, 100}}, nil, true, context.temp_allocator)
	prof.holes = make([dynamic]geom.Contour, context.temp_allocator)
	append(&prof.holes, geom.contour_circle({50, 50}, 20, false, context.temp_allocator))
	m: geom.Mesh_Data
	geom.mesh_init(&m, context.temp_allocator)
	geom.extrude_profile(prof, 18, 0.5, &m)
	// top cap area = square minus (polygonal) circle
	area: f32
	for k := 0; k < len(m.positions); k += 3 {
		if m.normals[k].y > 0.99 {
			f := linalg.cross(m.positions[k + 1] - m.positions[k], m.positions[k + 2] - m.positions[k])
			area += linalg.length(f) * 0.5
		}
	}
	want := f32(100 * 100) - math.PI * 20 * 20
	testing.expectf(t, abs(area - want) < 60, "cap area %v want ~%v", area, want)
}

@(test)
test_lathe :: proc(t: ^testing.T) {
	// cylinder r=20 h=100: side + two caps
	m: geom.Mesh_Data
	geom.mesh_init(&m, context.temp_allocator)
	geom.lathe([]geom.Vec2{{20, 0}, {20, 100}}, 16, &m)
	// bottom cap 16 tris (one degenerate per quad dropped), side 32, top 16
	testing.expect_value(t, len(m.positions) / 3, 16 + 32 + 16)
	testing.expect_value(t, len(m.normals), len(m.positions))
	side_ok := true
	for k in 0 ..< len(m.positions) {
		p := m.positions[k]
		n := m.normals[k]
		if p.y > 1 && p.y < 99 && abs(n.y) > 1e-3 {side_ok = false}
		if abs(n.y) < 1e-3 {
			// side normals point radially outward
			radial := linalg.normalize(geom.Vec3{p.x, 0, p.z})
			if linalg.dot(radial, n) < 0.99 {side_ok = false}
		}
	}
	testing.expect(t, side_ok)
	// two hard rings
	testing.expect_value(t, len(m.edges) / 2, 2 * 32)
}

@(test)
test_sweep :: proc(t: ^testing.T) {
	m: geom.Mesh_Data
	geom.mesh_init(&m, context.temp_allocator)
	section := []geom.Vec2{{-10, 0}, {10, 0}, {10, 20}, {-10, 20}}
	path := []geom.Vec2{{0, 0}, {100, 0}, {100, 100}}
	geom.sweep(section, path, &m)
	// 2 path segments * 4 sides * 2 tris + 2 caps * 2 tris
	testing.expect_value(t, len(m.positions) / 3, 2 * 4 * 2 + 4)
	for k := 0; k < len(m.positions); k += 3 {
		f := linalg.cross(m.positions[k + 1] - m.positions[k], m.positions[k + 2] - m.positions[k])
		testing.expect(t, linalg.dot(f, m.normals[k] + m.normals[k + 1] + m.normals[k + 2]) > 0)
	}
}

@(test)
test_raycast :: proc(t: ^testing.T) {
	r := geom.Ray{origin = {0, 100, 0}, dir = {0, -1, 0}}
	d, hit := geom.ray_triangle(r, {-10, 0, -10}, {10, 0, -10}, {0, 0, 10})
	testing.expect(t, hit)
	testing.expect(t, abs(d - 100) < 1e-4)
	_, hit = geom.ray_aabb(r, {50, -1, -1}, {60, 1, 1})
	testing.expect(t, !hit)
}
