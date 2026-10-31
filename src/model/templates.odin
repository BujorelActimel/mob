package model

// Built-in parametric templates. Each is an ordinary group with params; the
// library panel places a copy.

Template :: struct {
	name:  string,
	about: string,
	build: proc(d: ^Document) -> ^Group,
}

TEMPLATES := []Template {
	{"Corner vinyl shelf", "4 compartments, rounded front corner", template_vinyl_corner},
	{"Box", "Open-top carcass", template_box},
	{"Shelf unit", "Sides, back and 3 shelves", template_shelf_unit},
	{"Table", "Top with rounded corners, turned legs", template_table},
}

@(private)
set_xf :: proc(d: ^Document, xf: ^Transform_Def, x, y, z: string, rx := "0", ry := "0", rz := "0") {
	field_set(d, &xf.pos[0], x)
	field_set(d, &xf.pos[1], y)
	field_set(d, &xf.pos[2], z)
	field_set(d, &xf.rot[0], rx)
	field_set(d, &xf.rot[1], ry)
	field_set(d, &xf.rot[2], rz)
}

@(private)
panel_shape :: proc(p: ^Part) -> ^Panel {
	return &p.shape.(Panel)
}

// Room corner at the back-left: back wall at z = -D, side wall at x = 0.
template_vinyl_corner :: proc(d: ^Document) -> ^Group {
	g := new_group(d, "Corner vinyl shelf")
	add_param(d, &g.params, "W", "420")
	add_param(d, &g.params, "D", "380")
	add_param(d, &g.params, "H_comp", "330")
	add_param(d, &g.params, "t", "18")
	add_param(d, &g.params, "R", "120")
	add_param(d, &g.params, "H", "4*H_comp + 5*t")

	back := new_panel(d, "Back", "W", "H")
	set_xf(d, &back.xf, "0", "0", "-D", rx = "90")
	append(&g.children, back)

	side := new_panel(d, "Side", "H", "D - t")
	set_xf(d, &side.xf, "t", "0", "0", rz = "90")
	append(&g.children, side)

	ys := []string{"0", "H_comp + t", "2*(H_comp + t)", "3*(H_comp + t)", "4*(H_comp + t)"}
	names := []string{"Shelf 1", "Shelf 2", "Shelf 3", "Shelf 4", "Shelf 5"}
	for y, i in ys {
		s := new_panel(d, names[i], "W - t", "D - t")
		set_xf(d, &s.xf, "t", y, "0")
		field_set(d, &panel_shape(s).profile.radii[.Front_Right], "R")
		append(&g.children, s)
	}
	return g
}

template_box :: proc(d: ^Document) -> ^Group {
	g := new_group(d, "Box")
	add_param(d, &g.params, "W", "600")
	add_param(d, &g.params, "H", "400")
	add_param(d, &g.params, "D", "350")
	add_param(d, &g.params, "t", "18")

	bottom := new_panel(d, "Bottom", "W - 2*t", "D")
	set_xf(d, &bottom.xf, "t", "0", "0")
	append(&g.children, bottom)
	left := new_panel(d, "Left", "H", "D")
	set_xf(d, &left.xf, "t", "0", "0", rz = "90")
	append(&g.children, left)
	right := new_panel(d, "Right", "H", "D")
	set_xf(d, &right.xf, "W", "0", "0", rz = "90")
	append(&g.children, right)
	back := new_panel(d, "Back", "W - 2*t", "H - t")
	set_xf(d, &back.xf, "t", "t", "-D", rx = "90")
	append(&g.children, back)
	front := new_panel(d, "Front", "W - 2*t", "H - t")
	set_xf(d, &front.xf, "t", "t", "-t", rx = "90")
	append(&g.children, front)
	return g
}

template_shelf_unit :: proc(d: ^Document) -> ^Group {
	g := new_group(d, "Shelf unit")
	add_param(d, &g.params, "W", "800")
	add_param(d, &g.params, "H", "1200")
	add_param(d, &g.params, "D", "300")
	add_param(d, &g.params, "t", "18")
	add_param(d, &g.params, "gap", "(H - 2*t) / 3")

	left := new_panel(d, "Left side", "H", "D")
	set_xf(d, &left.xf, "t", "0", "0", rz = "90")
	append(&g.children, left)
	right := new_panel(d, "Right side", "H", "D")
	set_xf(d, &right.xf, "W", "0", "0", rz = "90")
	append(&g.children, right)
	ys := []string{"0", "gap", "2*gap", "H - t"}
	names := []string{"Bottom", "Shelf 1", "Shelf 2", "Top"}
	for y, i in ys {
		s := new_panel(d, names[i], "W - 2*t", "D - 6")
		set_xf(d, &s.xf, "t", y, "0")
		append(&g.children, s)
	}
	back := new_panel(d, "Back", "W - 2*t", "H", "6")
	set_xf(d, &back.xf, "t", "0", "-D", rx = "90")
	if len(d.materials) > 3 {back.material = d.materials[3].id}
	append(&g.children, back)
	return g
}

template_table :: proc(d: ^Document) -> ^Group {
	g := new_group(d, "Table")
	add_param(d, &g.params, "W", "1400")
	add_param(d, &g.params, "D", "800")
	add_param(d, &g.params, "H", "750")
	add_param(d, &g.params, "top_t", "28")
	add_param(d, &g.params, "R", "60")
	add_param(d, &g.params, "inset", "70")
	add_param(d, &g.params, "L", "H - top_t")

	top := new_panel(d, "Top", "W", "D", "top_t")
	set_xf(d, &top.xf, "0", "L", "0")
	if len(d.materials) > 1 {top.material = d.materials[1].id}
	for c in Corner {field_set(d, &panel_shape(top).profile.radii[c], "R")}
	append(&g.children, top)

	legs := [][2]string{{"inset", "-inset"}, {"W - inset", "-inset"}, {"W - inset", "-(D - inset)"}, {"inset", "-(D - inset)"}}
	for xz in legs {
		leg := new_part(d, "Leg")
		t := Turned{segments = 40, points = make([dynamic]Sketch_Point, d.allocator)}
		prof := [][3]string{{"16", "0", "3"}, {"18", "L*0.15", "0"}, {"24", "L*0.15 + 10", "0"}, {"24", "L*0.15 + 30", "0"}, {"20", "L*0.15 + 40", "0"}, {"26", "L - 60", "0"}, {"26", "L", "0"}}
		for q in prof {
			append(&t.points, Sketch_Point{field_make(d, q[0]), field_make(d, q[1]), field_make(d, q[2])})
		}
		leg.shape = t
		if len(d.materials) > 1 {leg.material = d.materials[1].id}
		set_xf(d, &leg.xf, xz[0], "0", xz[1])
		append(&g.children, leg)
	}
	return g
}
