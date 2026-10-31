package tests

import "core:testing"
import "../src/expr"

@(private = "file")
Vars :: struct {
	names:  []string,
	values: []f64,
}

@(private = "file")
vars_lookup :: proc(data: rawptr, name: string) -> (f64, expr.Error) {
	v := (^Vars)(data)
	for n, i in v.names {
		if n == name {return v.values[i], {}}
	}
	return 0, {kind = .Unknown_Name, name = name}
}

@(private = "file")
eval_str :: proc(t: ^testing.T, src: string, vars: ^Vars = nil) -> (f64, expr.Error) {
	e, perr := expr.parse(src, context.temp_allocator)
	if perr.kind != .None {return 0, perr}
	r := expr.Resolver{}
	if vars != nil {r = {data = vars, lookup = vars_lookup}}
	return expr.eval(e, r)
}

@(test)
test_precedence :: proc(t: ^testing.T) {
	cases := []struct {
		src: string,
		v:   f64,
	} {
		{"1 + 2 * 3", 7},
		{"(1 + 2) * 3", 9},
		{"10 - 4 - 3", 3},
		{"24 / 4 / 2", 3},
		{"-2 * 3", -6},
		{"-(2 + 3)", -5},
		{"2 * -3", -6},
		{"1.5e2", 150},
		{"+4", 4},
	}
	for c in cases {
		v, err := eval_str(t, c.src)
		testing.expectf(t, err.kind == .None, "%s: error %v", c.src, err)
		testing.expectf(t, v == c.v, "%s = %v, want %v", c.src, v, c.v)
	}
}

@(test)
test_units :: proc(t: ^testing.T) {
	cases := []struct {
		src: string,
		v:   f64,
	} {{"18", 18}, {"1.8cm", 18}, {"2m", 2000}, {"1in", 25.4}, {"1ft + 1mm", 305.8}, {"3cm*2", 60}}
	for c in cases {
		v, err := eval_str(t, c.src)
		testing.expectf(t, err.kind == .None, "%s: error %v", c.src, err)
		testing.expectf(t, abs(v - c.v) < 1e-9, "%s = %v, want %v", c.src, v, c.v)
	}
	_, err := eval_str(t, "3qq")
	testing.expect_value(t, err.kind, expr.Error_Kind.Unknown_Unit)
}

@(test)
test_functions_and_names :: proc(t: ^testing.T) {
	vars := Vars{names = {"W", "t"}, values = {800, 18}}
	v, err := eval_str(t, "W - 2*t", &vars)
	testing.expect_value(t, err.kind, expr.Error_Kind.None)
	testing.expect_value(t, v, 764)
	v, err = eval_str(t, "max(W/2, 500, t)", &vars)
	testing.expect_value(t, v, 500)
	v, err = eval_str(t, "round(333, 10)", &vars)
	testing.expect_value(t, v, 330)
	v, err = eval_str(t, "min(1, 2)", &vars)
	testing.expect_value(t, v, 1)

	_, err = eval_str(t, "W + depth", &vars)
	testing.expect_value(t, err.kind, expr.Error_Kind.Unknown_Name)
	testing.expect_value(t, err.name, "depth")
	_, err = eval_str(t, "foo(1)", &vars)
	testing.expect_value(t, err.kind, expr.Error_Kind.Unknown_Function)
	_, err = eval_str(t, "W / 0", &vars)
	testing.expect_value(t, err.kind, expr.Error_Kind.Div_Zero)
}

@(test)
test_syntax_errors :: proc(t: ^testing.T) {
	for src in ([]string{"1 +", "(1 + 2", "1 2", "*3", "min(1,", "a $ b"}) {
		_, err := expr.parse(src, context.temp_allocator)
		testing.expectf(t, err.kind == .Syntax, "%q should be a syntax error, got %v", src, err.kind)
	}
	_, err := expr.parse("   ", context.temp_allocator)
	testing.expect_value(t, err.kind, expr.Error_Kind.Empty)
}

@(test)
test_literal :: proc(t: ^testing.T) {
	e, _ := expr.parse("42", context.temp_allocator)
	testing.expect(t, expr.is_literal(e))
	e, _ = expr.parse("4 + 2", context.temp_allocator)
	testing.expect(t, !expr.is_literal(e))
}

@(test)
test_negative_literal :: proc(t: ^testing.T) {
	for src in ([]string{"-100", "-2.5", "- 7", "-1.8cm", "+4"}) {
		e, err := expr.parse(src, context.temp_allocator)
		testing.expect_value(t, err.kind, expr.Error_Kind.None)
		testing.expectf(t, expr.is_literal(e), "%q should be a plain number", src)
	}
	e, _ := expr.parse("-(2)", context.temp_allocator)
	v, _ := expr.literal_value(e)
	testing.expect_value(t, v, -2)
	e, _ = expr.parse("--3", context.temp_allocator)
	v, _ = expr.literal_value(e)
	testing.expect_value(t, v, 3)
}
