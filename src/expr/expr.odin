// Parametric expressions: numbers with units, + - * / ( ), function calls and
// identifiers resolved against a caller-supplied scope chain. All lengths are mm.
package expr

import "core:fmt"
import "core:math"
import "core:strconv"

Node_Kind :: enum u8 {
	Number,
	Ident,
	Neg,
	Add,
	Sub,
	Mul,
	Div,
	Call,
}

Node :: struct {
	kind:      Node_Kind,
	value:     f64,
	name:      string, // Ident / Call: slice of the source text
	a, b:      i32, // operands (Neg uses a)
	arg_start: i32, // Call: range into Expr.args
	arg_count: i32,
	pos:       i32, // byte offset in source, for errors
}

Expr :: struct {
	nodes: []Node,
	args:  []i32,
	root:  i32,
}

Error_Kind :: enum u8 {
	None,
	Syntax,
	Unknown_Unit,
	Unknown_Name,
	Unknown_Function,
	Bad_Arg_Count,
	Cycle,
	Bad_Ref,
	Div_Zero,
	Not_Finite,
	Empty,
}

Error :: struct {
	kind: Error_Kind,
	name: string, // offending identifier/unit, when relevant
	pos:  int,
	msg:  string, // static detail for syntax errors
}

Resolver :: struct {
	data:   rawptr,
	lookup: proc(data: rawptr, name: string) -> (f64, Error),
}

is_literal :: proc(e: Expr) -> bool {
	return len(e.nodes) == 1 && e.nodes[0].kind == .Number
}

// Literal value if the expression is a plain number, else ok=false.
literal_value :: proc(e: Expr) -> (f64, bool) {
	if is_literal(e) {return e.nodes[0].value, true}
	return 0, false
}

destroy :: proc(e: ^Expr, allocator := context.allocator) {
	delete(e.nodes, allocator)
	delete(e.args, allocator)
	e^ = {}
}

format_error :: proc(err: Error, allocator := context.temp_allocator) -> string {
	switch err.kind {
	case .None:             return ""
	case .Syntax:           return fmt.aprintf("syntax: %s", err.msg, allocator = allocator)
	case .Unknown_Unit:     return fmt.aprintf("unknown unit '%s'", err.name, allocator = allocator)
	case .Unknown_Name:     return fmt.aprintf("unknown name '%s'", err.name, allocator = allocator)
	case .Unknown_Function: return fmt.aprintf("unknown function '%s'", err.name, allocator = allocator)
	case .Bad_Arg_Count:    return fmt.aprintf("wrong argument count for '%s'", err.name, allocator = allocator)
	case .Cycle:            return fmt.aprintf("cycle through '%s'", err.name, allocator = allocator)
	case .Bad_Ref:          return fmt.aprintf("'%s' has an error", err.name, allocator = allocator)
	case .Div_Zero:         return "division by zero"
	case .Not_Finite:       return "result is not a finite number"
	case .Empty:            return "empty expression"
	}
	return "error"
}

// ---------------------------------------------------------------------------
// Tokenizer

Token_Kind :: enum u8 {
	EOF,
	Number,
	Ident,
	Plus,
	Minus,
	Star,
	Slash,
	LParen,
	RParen,
	Comma,
	Invalid,
}

Token :: struct {
	kind:  Token_Kind,
	value: f64,
	text:  string,
	pos:   int,
}

Lexer :: struct {
	src: string,
	pos: int,
	tok: Token,
	err: Error,
}

@(private)
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private)
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}

unit_scale :: proc(u: string) -> (f64, bool) {
	switch u {
	case "mm": return 1, true
	case "cm": return 10, true
	case "m":  return 1000, true
	case "in", "\"": return 25.4, true
	case "ft": return 304.8, true
	}
	return 0, false
}

@(private)
next :: proc(l: ^Lexer) {
	s := l.src
	for l.pos < len(s) && (s[l.pos] == ' ' || s[l.pos] == '\t' || s[l.pos] == '\n' || s[l.pos] == '\r') {
		l.pos += 1
	}
	start := l.pos
	if l.pos >= len(s) {
		l.tok = {kind = .EOF, pos = start}
		return
	}
	c := s[l.pos]
	switch {
	case is_digit(c) || (c == '.' && l.pos + 1 < len(s) && is_digit(s[l.pos + 1])):
		for l.pos < len(s) && (is_digit(s[l.pos]) || s[l.pos] == '.') {l.pos += 1}
		// exponent
		if l.pos < len(s) && (s[l.pos] == 'e' || s[l.pos] == 'E') {
			p := l.pos + 1
			if p < len(s) && (s[p] == '+' || s[p] == '-') {p += 1}
			if p < len(s) && is_digit(s[p]) {
				l.pos = p
				for l.pos < len(s) && is_digit(s[l.pos]) {l.pos += 1}
			}
		}
		v, ok := strconv.parse_f64(s[start:l.pos])
		if !ok {
			l.tok = {kind = .Invalid, pos = start}
			if l.err.kind == .None {l.err = {kind = .Syntax, pos = start, msg = "bad number"}}
			return
		}
		// optional unit suffix, directly attached
		if l.pos < len(s) && (is_alpha(s[l.pos]) || s[l.pos] == '"') {
			us := l.pos
			if s[l.pos] == '"' {
				l.pos += 1
			} else {
				for l.pos < len(s) && is_alpha(s[l.pos]) {l.pos += 1}
			}
			unit := s[us:l.pos]
			scale, uok := unit_scale(unit)
			if !uok {
				l.tok = {kind = .Invalid, pos = us}
				if l.err.kind == .None {l.err = {kind = .Unknown_Unit, name = unit, pos = us}}
				return
			}
			v *= scale
		}
		l.tok = {kind = .Number, value = v, text = s[start:l.pos], pos = start}
	case is_alpha(c):
		for l.pos < len(s) && (is_alpha(s[l.pos]) || is_digit(s[l.pos])) {l.pos += 1}
		l.tok = {kind = .Ident, text = s[start:l.pos], pos = start}
	case:
		l.pos += 1
		k: Token_Kind
		switch c {
		case '+': k = .Plus
		case '-': k = .Minus
		case '*': k = .Star
		case '/': k = .Slash
		case '(': k = .LParen
		case ')': k = .RParen
		case ',': k = .Comma
		case:
			k = .Invalid
			if l.err.kind == .None {l.err = {kind = .Syntax, pos = start, msg = "unexpected character"}}
		}
		l.tok = {kind = k, text = s[start:l.pos], pos = start}
	}
}

// ---------------------------------------------------------------------------
// Pratt parser

@(private)
Parser :: struct {
	lex:   Lexer,
	nodes: [dynamic]Node,
	args:  [dynamic]i32,
	err:   Error,
}

@(private)
fail :: proc(p: ^Parser, msg: string, pos: int) {
	if p.err.kind == .None {
		if p.lex.err.kind != .None {
			p.err = p.lex.err
		} else {
			p.err = {kind = .Syntax, msg = msg, pos = pos}
		}
	}
}

@(private)
push :: proc(p: ^Parser, n: Node) -> i32 {
	append(&p.nodes, n)
	return i32(len(p.nodes) - 1)
}

@(private)
infix_power :: proc(k: Token_Kind) -> int {
	#partial switch k {
	case .Plus, .Minus: return 10
	case .Star, .Slash: return 20
	}
	return 0
}

@(private)
parse_expr :: proc(p: ^Parser, min_power: int) -> i32 {
	if p.err.kind != .None {return -1}
	t := p.lex.tok
	lhs: i32 = -1
	#partial switch t.kind {
	case .Number:
		next(&p.lex)
		lhs = push(p, {kind = .Number, value = t.value, pos = i32(t.pos)})
	case .Ident:
		next(&p.lex)
		if p.lex.tok.kind == .LParen {
			next(&p.lex)
			call_args := make([dynamic]i32, context.temp_allocator)
			if p.lex.tok.kind != .RParen {
				for {
					a := parse_expr(p, 0)
					if p.err.kind != .None {return -1}
					append(&call_args, a)
					if p.lex.tok.kind == .Comma {
						next(&p.lex)
						continue
					}
					break
				}
			}
			if p.lex.tok.kind != .RParen {
				fail(p, "expected ')'", p.lex.tok.pos)
				return -1
			}
			next(&p.lex)
			start := i32(len(p.args))
			append(&p.args, ..call_args[:])
			lhs = push(p, {kind = .Call, name = t.text, arg_start = start, arg_count = i32(len(call_args)), pos = i32(t.pos)})
		} else {
			lhs = push(p, {kind = .Ident, name = t.text, pos = i32(t.pos)})
		}
	case .Minus:
		next(&p.lex)
		a := parse_expr(p, 30)
		if p.err.kind != .None {return -1}
		if p.nodes[a].kind == .Number {
			// fold "-<number>" so negative values stay plain literals
			p.nodes[a].value = -p.nodes[a].value
			lhs = a
		} else {
			lhs = push(p, {kind = .Neg, a = a, pos = i32(t.pos)})
		}
	case .Plus:
		next(&p.lex)
		lhs = parse_expr(p, 30)
	case .LParen:
		next(&p.lex)
		lhs = parse_expr(p, 0)
		if p.err.kind != .None {return -1}
		if p.lex.tok.kind != .RParen {
			fail(p, "expected ')'", p.lex.tok.pos)
			return -1
		}
		next(&p.lex)
	case .EOF:
		fail(p, "unexpected end", t.pos)
		return -1
	case:
		fail(p, "unexpected token", t.pos)
		return -1
	}
	for p.err.kind == .None {
		op := p.lex.tok
		power := infix_power(op.kind)
		if power == 0 || power <= min_power {break}
		next(&p.lex)
		rhs := parse_expr(p, power)
		k: Node_Kind
		#partial switch op.kind {
		case .Plus:  k = .Add
		case .Minus: k = .Sub
		case .Star:  k = .Mul
		case .Slash: k = .Div
		}
		lhs = push(p, {kind = k, a = lhs, b = rhs, pos = i32(op.pos)})
	}
	return lhs
}

// Parses `src`. Node names are slices of `src`, so `src` must outlive the Expr.
parse :: proc(src: string, allocator := context.allocator) -> (e: Expr, err: Error) {
	p: Parser
	p.lex.src = src
	p.nodes = make([dynamic]Node, context.temp_allocator)
	p.args = make([dynamic]i32, context.temp_allocator)
	next(&p.lex)
	if p.lex.tok.kind == .EOF {
		return {}, {kind = .Empty}
	}
	root := parse_expr(&p, 0)
	if p.err.kind == .None && p.lex.tok.kind != .EOF {
		fail(&p, "unexpected trailing input", p.lex.tok.pos)
	}
	if p.err.kind != .None {
		return {}, p.err
	}
	e.nodes = make([]Node, len(p.nodes), allocator)
	copy(e.nodes, p.nodes[:])
	e.args = make([]i32, len(p.args), allocator)
	copy(e.args, p.args[:])
	e.root = root
	return e, {}
}

// ---------------------------------------------------------------------------
// Evaluation

eval :: proc(e: Expr, r: Resolver) -> (f64, Error) {
	if len(e.nodes) == 0 {return 0, {kind = .Empty}}
	v, err := eval_node(e, e.root, r)
	if err.kind == .None && (math.is_nan(v) || math.is_inf(v)) {
		return 0, {kind = .Not_Finite}
	}
	return v, err
}

@(private)
eval_node :: proc(e: Expr, i: i32, r: Resolver) -> (f64, Error) {
	n := e.nodes[i]
	switch n.kind {
	case .Number:
		return n.value, {}
	case .Ident:
		switch n.name {
		case "pi", "PI": return math.PI, {}
		}
		if r.lookup == nil {return 0, {kind = .Unknown_Name, name = n.name, pos = int(n.pos)}}
		v, err := r.lookup(r.data, n.name)
		if err.kind != .None && err.pos == 0 {err.pos = int(n.pos)}
		return v, err
	case .Neg:
		v, err := eval_node(e, n.a, r)
		return -v, err
	case .Add, .Sub, .Mul, .Div:
		a, ea := eval_node(e, n.a, r)
		if ea.kind != .None {return 0, ea}
		b, eb := eval_node(e, n.b, r)
		if eb.kind != .None {return 0, eb}
		#partial switch n.kind {
		case .Add: return a + b, {}
		case .Sub: return a - b, {}
		case .Mul: return a * b, {}
		case .Div:
			if b == 0 {return 0, {kind = .Div_Zero, pos = int(n.pos)}}
			return a / b, {}
		}
	case .Call:
		vals: [8]f64
		if n.arg_count > len(vals) {return 0, {kind = .Bad_Arg_Count, name = n.name, pos = int(n.pos)}}
		for k in 0 ..< n.arg_count {
			v, err := eval_node(e, e.args[n.arg_start + k], r)
			if err.kind != .None {return 0, err}
			vals[k] = v
		}
		return call(n.name, vals[:n.arg_count], int(n.pos))
	}
	return 0, {kind = .Syntax, msg = "bad node"}
}

@(private)
call :: proc(name: string, a: []f64, pos: int) -> (f64, Error) {
	bad := Error{kind = .Bad_Arg_Count, name = name, pos = pos}
	switch name {
	case "min", "max":
		if len(a) < 1 {return 0, bad}
		v := a[0]
		for x in a[1:] {v = name == "min" ? min(v, x) : max(v, x)}
		return v, {}
	case "round", "floor", "ceil":
		if len(a) != 1 && len(a) != 2 {return 0, bad}
		step := len(a) == 2 ? a[1] : 1
		if step == 0 {return 0, {kind = .Div_Zero, pos = pos}}
		x := a[0] / step
		switch name {
		case "round": x = math.round(x)
		case "floor": x = math.floor(x)
		case "ceil":  x = math.ceil(x)
		}
		return x * step, {}
	case "abs":
		if len(a) != 1 {return 0, bad}
		return abs(a[0]), {}
	case "sqrt":
		if len(a) != 1 {return 0, bad}
		return math.sqrt(a[0]), {}
	case "sin", "cos", "tan":
		// degrees, since furniture angles are written in degrees
		if len(a) != 1 {return 0, bad}
		rad := a[0] * math.PI / 180
		switch name {
		case "sin": return math.sin(rad), {}
		case "cos": return math.cos(rad), {}
		case "tan": return math.tan(rad), {}
		}
	}
	return 0, {kind = .Unknown_Function, name = name, pos = pos}
}

// Calls `f` for each identifier referenced by the expression (excluding constants).
visit_idents :: proc(e: Expr, data: rawptr, f: proc(data: rawptr, name: string)) {
	for n in e.nodes {
		if n.kind == .Ident && n.name != "pi" && n.name != "PI" {
			f(data, n.name)
		}
	}
}

is_valid_name :: proc(s: string) -> bool {
	if len(s) == 0 || !is_alpha(s[0]) {return false}
	for i in 1 ..< len(s) {
		if !is_alpha(s[i]) && !is_digit(s[i]) {return false}
	}
	_, is_unit := unit_scale(s)
	return s != "pi" && s != "PI" && !is_unit
}
