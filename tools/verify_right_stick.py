#!/usr/bin/env python3
"""
Verifies gpc/adaptive_right_stick_curve.gpc by running the script itself.

A small GPC interpreter (the subset this script uses) compiles the .gpc file
to Python with Cronus Zen integer semantics:
  * 32-bit signed ints - any result outside that range is a hard error,
    so a clean run proves the script never overflows;
  * C-style integer division (truncates toward zero) - divide by zero is a
    hard error;
  * get_val / set_val / get_rtime / abs / inv built-ins.
It also enforces "int variables + functions only": combos, defines,
data/const tables, loops and local variables are rejected at parse time.

Usage:  python3 tools/verify_right_stick.py [path/to/script.gpc]
"""
import math
import random
import re
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCRIPT = ROOT / "gpc" / "adaptive_right_stick_curve.gpc"

INT_MIN, INT_MAX = -2**31, 2**31 - 1
RX, RY = 9, 10
CONSTS = {"PS4_RX": RX, "PS4_RY": RY, "XB1_RX": RX, "XB1_RY": RY,
          "TRUE": 1, "FALSE": 0}
BUILTINS = {"get_val": 1, "set_val": 2, "get_rtime": 0, "abs": 1, "inv": 1}
RESERVED = set(BUILTINS) | set(CONSTS) | {
    "pow", "isqrt", "random", "min", "max", "clamp", "sqrt", "sin", "cos",
    "get_ival", "get_lval", "get_ptime", "event_press", "event_release",
    "combo_run", "combo_stop", "combo_running", "block", "swap",
    "sensitivity", "deadzone", "stickize", "vm_tctrl", "wait", "call",
    "get_console", "get_controller", "get_slot", "load_slot", "set_bit",
    "clear_bit", "test_bit", "set_bits", "get_bits", "get_pvar", "set_pvar",
    "set_rgb", "set_led", "print", "main", "init", "combo", "function",
    "data", "define", "const", "int", "if", "else", "return", "while", "for",
    "do", "break", "continue",
}
FORBIDDEN_TOP = {"combo", "define", "data", "const", "remap", "unmap", "enum",
                 "int8", "int16", "int32", "uint8", "uint16", "uint32",
                 "fix32", "image"}
FORBIDDEN_STMT = {"while", "for", "do", "break", "continue", "int", "wait",
                  "call", "fix32"}

# --------------------------------------------------------------------------
# Tokenizer / parser
# --------------------------------------------------------------------------
TOKEN = re.compile(r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<cmt>//[^\n]*|/\*.*?\*/)
  | (?P<num>\d+)
  | (?P<id>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>==|!=|<=|>=|&&|\|\||[-+*/%<>=!(){},;])
""", re.S | re.X)


def tokenize(src):
    toks, pos, line = [], 0, 1
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            raise SyntaxError(f"line {line}: unexpected character {src[pos]!r}")
        kind, text = m.lastgroup, m.group()
        if kind == "num":
            toks.append(("num", int(text), line))
        elif kind in ("id", "op"):
            toks.append((kind, text, line))
        line += text.count("\n")
        pos = m.end()
    toks.append(("eof", None, line))
    return toks


class Program:
    def __init__(self):
        self.globals = {}   # name -> initial value
        self.funcs = {}     # name -> (params, body, line)
        self.init = None
        self.main = None


class Parser:
    PREC = [("||",), ("&&",), ("==", "!="), ("<", "<=", ">", ">="),
            ("+", "-"), ("*", "/", "%")]

    def __init__(self, toks):
        self.toks, self.i = toks, 0

    def peek(self, k=0):
        return self.toks[min(self.i + k, len(self.toks) - 1)]

    def take(self):
        tok = self.toks[self.i]
        self.i += 1
        return tok

    def accept(self, kind, text=None):
        tok = self.peek()
        if tok[0] == kind and (text is None or tok[1] == text):
            self.i += 1
            return tok
        return None

    def expect(self, kind, text=None):
        tok = self.take()
        if tok[0] != kind or (text is not None and tok[1] != text):
            raise SyntaxError(f"line {tok[2]}: expected {text or kind!r}, "
                              f"got {tok[1]!r}")
        return tok

    @staticmethod
    def check_name(name, line):
        if name in RESERVED:
            raise SyntaxError(f"line {line}: '{name}' clashes with a GPC built-in")

    def program(self):
        prog = Program()
        stage = 0  # 0 = variables, 1 = init seen, 2 = main seen
        while self.peek()[0] != "eof":
            tok = self.peek()
            if tok[0] != "id":
                raise SyntaxError(f"line {tok[2]}: unexpected {tok[1]!r}")
            word = tok[1]
            if word in FORBIDDEN_TOP:
                raise SyntaxError(f"line {tok[2]}: '{word}' not allowed "
                                  "(int variables + functions only)")
            if word == "int":
                if stage:
                    raise SyntaxError(f"line {tok[2]}: variables must come "
                                      "before init/main")
                self.take()
                while True:
                    name_tok = self.expect("id")
                    name = name_tok[1]
                    self.check_name(name, name_tok[2])
                    if name in prog.globals:
                        raise SyntaxError(f"line {name_tok[2]}: '{name}' "
                                          "declared twice")
                    value = 0
                    if self.accept("op", "="):
                        neg = bool(self.accept("op", "-"))
                        value = self.expect("num")[1]
                        value = -value if neg else value
                    prog.globals[name] = value
                    if self.accept("op", ","):
                        continue
                    self.expect("op", ";")
                    break
            elif word == "init":
                if stage:
                    raise SyntaxError(f"line {tok[2]}: init must come once, "
                                      "before main")
                self.take()
                prog.init = self.block()
                stage = 1
            elif word == "main":
                if stage == 2:
                    raise SyntaxError(f"line {tok[2]}: second main")
                self.take()
                prog.main = self.block()
                stage = 2
            elif word == "function":
                if stage != 2:
                    raise SyntaxError(f"line {tok[2]}: functions go after main")
                self.take()
                name_tok = self.expect("id")
                name = name_tok[1]
                self.check_name(name, name_tok[2])
                if name in prog.funcs or name in prog.globals:
                    raise SyntaxError(f"line {name_tok[2]}: '{name}' redefined")
                self.expect("op", "(")
                params = []
                if not self.accept("op", ")"):
                    while True:
                        p = self.expect("id")
                        self.check_name(p[1], p[2])
                        if p[1] in prog.globals or p[1] in params:
                            raise SyntaxError(f"line {p[2]}: parameter "
                                              f"'{p[1]}' shadows a name")
                        params.append(p[1])
                        if self.accept("op", ")"):
                            break
                        self.expect("op", ",")
                prog.funcs[name] = (params, self.block(), name_tok[2])
            else:
                raise SyntaxError(f"line {tok[2]}: unexpected '{word}'")
        if prog.main is None:
            raise SyntaxError("missing main section")
        return prog

    def block(self):
        self.expect("op", "{")
        body = []
        while not self.accept("op", "}"):
            if self.peek()[0] == "eof":
                raise SyntaxError("unterminated block")
            body.append(self.statement())
        return ("block", body)

    def statement(self):
        tok = self.peek()
        if tok[0] == "op" and tok[1] == "{":
            return self.block()
        if tok[0] == "id":
            word = tok[1]
            if word in FORBIDDEN_STMT:
                raise SyntaxError(f"line {tok[2]}: '{word}' not allowed here")
            if word == "if":
                self.take()
                self.expect("op", "(")
                cond = self.expr()
                self.expect("op", ")")
                then = self.statement()
                other = self.statement() if self.accept("id", "else") else None
                return ("if", cond, then, other)
            if word == "return":
                self.take()
                if self.accept("op", ";"):
                    return ("return", None)
                value = self.expr()
                self.expect("op", ";")
                return ("return", value)
            nxt = self.peek(1)
            if nxt[0] == "op" and nxt[1] == "=":
                self.take()
                self.take()
                value = self.expr()
                self.expect("op", ";")
                return ("assign", word, value, tok[2])
        value = self.expr()
        self.expect("op", ";")
        return ("expr", value)

    def expr(self, level=0):
        if level == len(self.PREC):
            return self.unary()
        left = self.expr(level + 1)
        while True:
            tok = self.peek()
            if tok[0] == "op" and tok[1] in self.PREC[level]:
                self.take()
                left = ("bin", tok[1], left, self.expr(level + 1))
            else:
                return left

    def unary(self):
        tok = self.peek()
        if tok[0] == "op" and tok[1] in ("-", "!"):
            self.take()
            return ("un", tok[1], self.unary())
        return self.primary()

    def primary(self):
        tok = self.take()
        if tok[0] == "num":
            if tok[1] > INT_MAX:
                raise SyntaxError(f"line {tok[2]}: literal too large")
            return ("num", tok[1])
        if tok[0] == "op" and tok[1] == "(":
            inner = self.expr()
            self.expect("op", ")")
            return inner
        if tok[0] == "id":
            if self.accept("op", "("):
                args = []
                if not self.accept("op", ")"):
                    while True:
                        args.append(self.expr())
                        if self.accept("op", ")"):
                            break
                        self.expect("op", ",")
                return ("call", tok[1], args, tok[2])
            return ("var", tok[1], tok[2])
        raise SyntaxError(f"line {tok[2]}: unexpected {tok[1]!r}")


# --------------------------------------------------------------------------
# Compiler: GPC AST -> Python source
# --------------------------------------------------------------------------
class Compiler:
    def __init__(self, prog):
        self.prog = prog
        self.calls = {}

    def e(self, node, params, cur):
        kind = node[0]
        if kind == "num":
            return str(node[1])
        if kind == "var":
            name = node[1]
            if name in params:
                return "p_" + name
            if name in self.prog.globals:
                return f"G[{name!r}]"
            if name in CONSTS:
                return str(CONSTS[name])
            raise NameError(f"line {node[2]}: '{name}' is not declared")
        if kind == "un":
            inner = self.e(node[2], params, cur)
            if node[1] == "-":
                return f"W(-({inner}))"
            return f"(0 if ({inner}) else 1)"
        if kind == "bin":
            op = node[1]
            a = self.e(node[2], params, cur)
            b = self.e(node[3], params, cur)
            if op in ("+", "-", "*"):
                return f"W(({a}) {op} ({b}))"
            if op == "/":
                return f"DIV({a}, {b})"
            if op == "%":
                return f"MOD({a}, {b})"
            if op == "&&":
                return f"(1 if (({a}) and ({b})) else 0)"
            if op == "||":
                return f"(1 if (({a}) or ({b})) else 0)"
            return f"(1 if ({a}) {op} ({b}) else 0)"
        if kind == "call":
            name, args, line = node[1], node[2], node[3]
            src = ", ".join(self.e(a, params, cur) for a in args)
            if name in BUILTINS:
                if len(args) != BUILTINS[name]:
                    raise TypeError(f"line {line}: {name} takes "
                                    f"{BUILTINS[name]} argument(s)")
                return f"B_{name}({src})"
            if name in self.prog.funcs:
                if len(args) != len(self.prog.funcs[name][0]):
                    raise TypeError(f"line {line}: wrong argument count "
                                    f"for {name}")
                self.calls.setdefault(cur, set()).add(name)
                return f"F_{name}({src})"
            raise NameError(f"line {line}: unknown function '{name}'")
        raise ValueError(node)

    def s(self, node, params, cur, depth, out):
        pad = "    " * depth
        kind = node[0]
        if kind == "block":
            for child in node[1]:
                self.s(child, params, cur, depth, out)
            if not node[1]:
                out.append(pad + "pass")
        elif kind == "if":
            out.append(f"{pad}if {self.e(node[1], params, cur)}:")
            self.body(node[2], params, cur, depth + 1, out)
            if node[3] is not None:
                out.append(f"{pad}else:")
                self.body(node[3], params, cur, depth + 1, out)
        elif kind == "assign":
            name = node[1]
            if name in params:
                target = "p_" + name
            elif name in self.prog.globals:
                target = f"G[{name!r}]"
            else:
                raise NameError(f"line {node[3]}: '{name}' is not declared")
            out.append(f"{pad}{target} = {self.e(node[2], params, cur)}")
        elif kind == "return":
            value = "0" if node[1] is None else self.e(node[1], params, cur)
            out.append(f"{pad}return {value}")
        elif kind == "expr":
            out.append(pad + self.e(node[1], params, cur))

    def body(self, node, params, cur, depth, out):
        start = len(out)
        self.s(node, params, cur, depth, out)
        if len(out) == start:
            out.append("    " * depth + "pass")

    def compile(self):
        out = []
        for name, (params, body, _line) in self.prog.funcs.items():
            out.append(f"def F_{name}({', '.join('p_' + p for p in params)}):")
            self.body(body, set(params), name, 1, out)
            out.append("    return 0")
        for section in ("init", "main"):
            node = getattr(self.prog, section)
            out.append(f"def S_{section}():")
            if node is None:
                out.append("    pass")
            else:
                self.body(node, set(), section, 1, out)
        self.check_recursion()
        return "\n".join(out) + "\n"

    def check_recursion(self):
        state = {}

        def visit(f, path):
            if state.get(f) == 1:
                raise RecursionError("recursive call chain: "
                                     + " -> ".join(path + [f]))
            if state.get(f) == 2:
                return
            state[f] = 1
            for g in self.calls.get(f, ()):
                visit(g, path + [f])
            state[f] = 2

        for f in list(self.calls):
            visit(f, [])


def load(path):
    prog = Parser(tokenize(Path(path).read_text())).program()
    return prog, Compiler(prog).compile()


class Zen:
    """One Cronus Zen running the compiled script."""

    def __init__(self, prog, source, bits=32, overrides=None):
        self.bits = bits
        self.G = dict(prog.globals)
        for k, v in (overrides or {}).items():
            if k not in self.G:
                raise KeyError(k)
            self.G[k] = v
        if bits == 16:
            for k in self.G:
                self.G[k] = self.wrap(self.G[k])
        self.vals = {}
        self.rtime = 10
        ns = {
            "G": self.G, "W": self.wrap, "DIV": self.div, "MOD": self.mod,
            "B_get_val": lambda i: self.vals.get(i, 0),
            "B_set_val": self.set_val,
            "B_get_rtime": lambda: self.rtime,
            "B_abs": lambda v: self.wrap(abs(v)),
            "B_inv": lambda v: self.wrap(-v),
        }
        exec(compile(source, "<gpc>", "exec"), ns)
        self.ns = ns
        ns["S_init"]()

    def wrap(self, v):
        if self.bits == 32:
            if v < INT_MIN or v > INT_MAX:
                raise OverflowError(f"32-bit overflow: {v}")
            return v
        v &= 0xFFFF
        return v - 0x10000 if v & 0x8000 else v

    def div(self, a, b):
        if b == 0:
            raise ZeroDivisionError("division by zero in script")
        q = abs(a) // abs(b)
        return self.wrap(-q if (a < 0) != (b < 0) else q)

    def mod(self, a, b):
        return self.wrap(a - self.div(a, b) * b)

    def set_val(self, idx, value):
        self.vals[idx] = value

    def frame(self, x, y, dt=10):
        self.vals = {RX: x, RY: y}
        self.rtime = dt
        self.ns["S_main"]()
        return self.vals[RX], self.vals[RY]

    def frame_at_adapt(self, x, y, adapt):
        """Static evaluation with the adapt factor pinned (no window close)."""
        g = self.G
        g["rs_adapt"] = adapt
        g["rs_goal"] = adapt
        g["rs_win"] = 0
        out = self.frame(x, y, dt=1)
        assert g["rs_adapt"] == adapt
        return out


# --------------------------------------------------------------------------
# Real-number reference of the same maths
# --------------------------------------------------------------------------
def reference(x, y, cfg, adapt):
    dz_units = cfg["rs_deadzone"]
    r_units = round(100 * math.hypot(x, y))     # same inside/outside decision
    if r_units <= dz_units or (x == 0 and y == 0):
        return 0.0, 0.0
    dz = dz_units / 10000
    outer = cfg["rs_outer"] / 10000
    r = math.hypot(x, y) / 100
    n = 1.0 if r >= outer else (r - dz) / (outer - dz)
    a = adapt / 10000
    e = (cfg["rs_expo_fine"] * (1 - a) + cfg["rs_expo_fast"] * a) / 10000
    c = (1 - e) * n + e * n ** 3
    f = cfg["rs_forward"] / 10000
    fade = cfg["rs_forward_fade"] / 10000
    p = f if n >= fade else f * n / fade
    m = p + (1 - p) * c
    return x * m / r, y * m / r


def round_half_away(v):
    return int(math.floor(abs(v) + 0.5)) * (1 if v >= 0 else -1)


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------
RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(ok)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))


def test_language(prog):
    print("Language / structure")
    n_vars = len(prog.globals)
    n_funcs = len(prog.funcs)
    check("only int globals + functions + init/main (no combos, defines, "
          "data, loops, locals)", True, f"{n_vars} int variables, "
          f"{n_funcs} functions")
    check("no recursion, every name declared, no clash with GPC built-ins",
          True)


def test_sqrt_rdiv(prog, source):
    print("Exact helpers")
    zen = Zen(prog, source)
    f_sqrt = zen.ns["F_rs_sqrt"]
    f_rdiv = zen.ns["F_rs_rdiv"]

    def want_sqrt(v):
        s = math.isqrt(v)
        return s + 1 if v - s * s > s else s

    values = {(x * x + y * y) * 10000 for x in range(101) for y in range(101)}
    values.update(range(0, 70000))
    for k in list(range(0, 32768, 7)) + [32767]:
        for d in (-1, 0, 1, k, k + 1):
            v = k * k + d
            if 0 <= v < 2**30:
                values.add(v)
    rng = random.Random(1)
    values.update(rng.randrange(0, 2**30) for _ in range(100000))
    values.add(2**30 - 1)
    bad = [v for v in sorted(values) if f_sqrt(v) != want_sqrt(v)]
    check("rs_sqrt == exact sqrt rounded to nearest", not bad,
          f"{len(values)} values incl. every stick input" +
          (f", first bad {bad[:3]}" if bad else ""))

    bad = 0
    for _ in range(200000):
        a = rng.randint(-3_000_000, 3_000_000)
        b = rng.randint(1, 20000)
        q = Fraction(abs(a), b)
        want = math.floor(q + Fraction(1, 2)) * (1 if a >= 0 else -1)
        if f_rdiv(a, b) != want:
            bad += 1
    check("rs_rdiv == exact round-half-away division", bad == 0,
          f"200000 random pairs, {bad} wrong")


def all_inputs():
    for x in range(-100, 101):
        for y in range(-100, 101):
            yield x, y


def test_static(prog, source):
    print("Static curve, every one of the 40,401 stick positions")
    zen = Zen(prog, source)
    cfg = dict(zen.G)
    for adapt in (0, 2500, 5000, 7500, 10000):
        max_err = 0.0
        exact = total = 0
        range_ok = dz_ok = True
        worst_angle = 0.0
        for x, y in all_inputs():
            ox, oy = zen.frame_at_adapt(x, y, adapt)
            rx, ry = reference(x, y, cfg, adapt)
            for got, ref in ((ox, rx), (oy, ry)):
                max_err = max(max_err, abs(got - ref))
                exact += got == round_half_away(ref)
                total += 1
            # each axis rounds by <= 0.5, so the vector may exceed 100 by
            # at most sqrt(0.5^2 + 0.5^2) = 0.7071
            if (abs(ox) > 100 or abs(oy) > 100
                    or math.hypot(ox, oy) > 100 + math.sqrt(0.5)):
                range_ok = False
            inside = round(100 * math.hypot(x, y)) <= cfg["rs_deadzone"]
            if inside and (ox, oy) != (0, 0):
                dz_ok = False
            mag = math.hypot(ox, oy)
            if mag >= 20:
                d = abs(math.atan2(oy, ox) - math.atan2(y, x))
                d = min(d, 2 * math.pi - d)
                worst_angle = max(worst_angle, math.degrees(d))
        label = f"adapt {adapt / 100:.0f}%"
        check(f"{label}: matches real-number maths", max_err <= 0.52,
              f"max error {max_err:.4f} units, {100 * exact / total:.2f}% "
              "identical to ideal rounding")
        check(f"{label}: every axis in -100..100, vector on/inside the "
              "circle (+ rounding)", range_ok)
        check(f"{label}: deadzone outputs exactly 0", dz_ok)
        check(f"{label}: direction kept (output >= 20)", worst_angle < 2.1,
              f"worst angle error {worst_angle:.3f} deg, integer rounding only")


def test_shape(prog, source):
    print("Curve shape")
    zen = Zen(prog, source)
    rays = [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (2, 1),
            (1, 2), (3, 1), (1, 3), (-3, 2), (4, -3)]
    mono = True
    for adapt in (0, 10000):
        for dx, dy in rays:
            prev = -1.0
            k = 0
            while abs(k * dx) <= 100 and abs(k * dy) <= 100:
                ox, oy = zen.frame_at_adapt(k * dx, k * dy, adapt)
                mag = math.hypot(ox, oy)
                if mag + 1e-9 < prev:
                    mono = False
                prev = mag
                k += 1
    check("output never decreases as the stick moves outward (12 rays)", mono)

    jump = 0
    for adapt in (0, 10000):
        grid = {}
        for x, y in all_inputs():
            grid[(x, y)] = zen.frame_at_adapt(x, y, adapt)
        for (x, y), (ox, oy) in grid.items():
            for nx, ny in ((x + 1, y), (x, y + 1)):
                if (nx, ny) in grid:
                    px, py = grid[(nx, ny)]
                    jump = max(jump, abs(px - ox), abs(py - oy))
    check("no jumps: 1-unit stick change moves output <= 3 units", jump <= 3,
          f"largest change {jump}")

    full = [zen.frame_at_adapt(x, y, 0) for x, y in
            ((100, 0), (-100, 0), (0, 100), (0, -100))]
    check("full tilt on each axis = 100", all(max(abs(a), abs(b)) == 100
                                               for a, b in full))
    ident = Zen(prog, source, overrides={
        "rs_deadzone": 0, "rs_outer": 10000, "rs_expo_fine": 0,
        "rs_expo_fast": 0, "rs_forward": 0})
    same = all(ident.frame(x, y) == (x, y) for x, y in all_inputs()
               if x * x + y * y <= 10000)
    check("with curve/deadzone/forward off the output equals the input "
          "exactly", same)


def run_seq(zen, seq, dt):
    log = []
    for x, y in seq:
        out = zen.frame(x, y, dt)
        log.append((zen.G["rs_adapt"], out))
    return log


def flick_seq(dt, angle_deg=20.0, peak=90, hold_ms=1500):
    seq = []
    ca, sa = math.cos(math.radians(angle_deg)), math.sin(math.radians(angle_deg))
    t = 0
    while t < 200:
        seq.append((0, 0))
        t += dt
    t0 = t
    while t < t0 + 100:
        k = peak * (t - t0 + dt) / 100
        seq.append((round(k * ca), round(k * sa)))
        t += dt
    t1 = t
    while t < t1 + hold_ms:
        seq.append((round(peak * ca), round(peak * sa)))
        t += dt
    return seq


def test_dynamic(prog, source):
    print("Auto adjust over time")
    rng = random.Random(7)
    for amp in (1, 2):
        worst = 0
        for dt in (1, 4, 10):
            zen = Zen(prog, source)
            run_seq(zen, [(35, 0)] * (2000 // dt), dt)      # settle first
            seq = [(35 + rng.randint(-amp, amp), rng.randint(-amp, amp))
                   for _ in range(5000 // dt)]
            worst = max(worst, max(a for a, _ in run_seq(zen, seq, dt)))
        limit = 0 if amp == 1 else 500
        check(f"stick noise +/-{amp} (held stick) does not trigger the fast "
              "curve", worst <= limit, f"max adapt {worst / 100:.1f}%")

    curves = {}
    for dt in (1, 4, 10):
        zen = Zen(prog, source)
        log = run_seq(zen, flick_seq(dt, hold_ms=3000), dt)
        times = [i * dt for i in range(len(log))]
        curves[dt] = (times, [a for a, _ in log], [o for _, o in log])
    t_end_flick = 300

    def adapt_at(dt, t):
        times, adapts, _ = curves[dt]
        i = min(range(len(times)), key=lambda j: abs(times[j] - t))
        return adapts[i]

    peaks = {dt: max(curves[dt][1]) for dt in curves}
    check("fast flick engages the fast curve", min(peaks.values()) >= 7000,
          "peak adapt " + ", ".join(f"{dt}ms loop {p / 100:.0f}%"
                                    for dt, p in peaks.items()))
    spread = max(abs(adapt_at(a, t) - adapt_at(b, t))
                 for t in range(t_end_flick, 1800, 50)
                 for a in curves for b in curves)
    check("same behaviour at 1 / 4 / 10 ms loop times", spread <= 1200,
          f"max difference {spread / 100:.1f}% of adapt")
    settled = {dt: next((t for t, a in zip(curves[dt][0], curves[dt][1])
                         if t > t_end_flick and a == 0), 10**9)
               for dt in curves}
    check("settles back to exactly the fine curve while held",
          max(settled.values()) <= 3000,
          "exactly 0 after " + ", ".join(f"{(t - t_end_flick) / 1000:.2f}s"
                                         for t in settled.values()))
    _, adapts, outs = curves[10]
    held = [(a, o) for t, a, o in zip(*curves[10]) if t >= t_end_flick + 20]
    step = max(max(abs(o2[0] - o1[0]), abs(o2[1] - o1[1]))
               for (_, o1), (_, o2) in zip(held, held[1:]))
    check("holding still after a flick: output glides, never jumps",
          step <= 1, f"largest frame-to-frame change {step} unit")

    zen = Zen(prog, source)
    seq = [(90, 0)] * 200 + [(round(90 - 90 * i / 2), 0) for i in range(1, 3)]
    seq += [(0, 0)] * 10
    log = run_seq(zen, seq, 10)
    check("snapping back to centre is not treated as a flick",
          max(a for a, _ in log[200:]) == 0)
    zen = Zen(prog, source)
    seq = [(round(60 * i / 60), 0) for i in range(61)]
    log = run_seq(zen, seq, 10)
    check("slow 100 %/s movement stays on the fine curve",
          max(a for a, _ in log) == 0)
    zen = Zen(prog, source)
    log = run_seq(zen, [(-70, 40)] * 100, 10)
    check("script loaded while the stick is already held: no false flick",
          max(a for a, _ in log) == 0)


def test_fuzz(prog, source):
    print("Robustness")
    rng = random.Random(99)
    keys = ["rs_deadzone", "rs_outer", "rs_expo_fine", "rs_expo_fast",
            "rs_speed_fine", "rs_speed_fast", "rs_attack_ms", "rs_release_ms",
            "rs_forward", "rs_forward_fade", "rs_window_ms"]
    frames = 0
    errors = []
    for case in range(400):
        cfg = {}
        for k in keys:
            if rng.random() < 0.15:
                cfg[k] = rng.choice([-50000, -1, 0, 1, 99999, 10**6])
            else:
                cfg[k] = rng.randint(0, 12000)
        try:
            zen = Zen(prog, source, overrides=cfg)
            x = y = 0
            for _ in range(400):
                if rng.random() < 0.2:
                    x, y = rng.randint(-100, 100), rng.randint(-100, 100)
                else:
                    x = max(-100, min(100, x + rng.randint(-15, 15)))
                    y = max(-100, min(100, y + rng.randint(-15, 15)))
                dt = rng.choice([0, 1, 2, 4, 5, 8, 10, 16, 20, 33, 250])
                ox, oy = zen.frame(x, y, dt)
                frames += 1
                if abs(ox) > 100 or abs(oy) > 100:
                    errors.append(("range", cfg, x, y, ox, oy))
                if (x, y) == (0, 0) and (ox, oy) != (0, 0):
                    errors.append(("centre", cfg))
                if not 0 <= zen.G["rs_adapt"] <= 10000:
                    errors.append(("adapt", cfg, zen.G["rs_adapt"]))
        except (OverflowError, ZeroDivisionError) as exc:
            errors.append((type(exc).__name__, cfg, str(exc)))
    check("400 random/extreme settings x 400 frames: no overflow, no /0, "
          "output always valid", not errors,
          f"{frames} frames" + (f", first problem {errors[0]}" if errors else ""))

    old = Zen(prog, source, bits=16)
    passthru = all(old.frame(x, y) == (x, y) for x, y in
                   ((0, 0), (37, -12), (-100, 100), (5, 5)))
    check("16-bit firmware: script switches itself off (stick untouched)",
          old.G["rs_on"] == 0 and passthru)


def print_table(prog, source):
    zen = Zen(prog, source)
    print("\nStick -> output along one axis (fine curve / fast curve):")
    print("  stick  " + "  ".join(f"{v:>4}" for v in
                                  (5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100)))
    for adapt, label in ((0, "fine "), (10000, "fast ")):
        row = [zen.frame_at_adapt(v, 0, adapt)[0] for v in
               (5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100)]
        print(f"  {label}  " + "  ".join(f"{v:>4}" for v in row))


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SCRIPT
    print(f"Verifying {path}\n")
    prog, source = load(path)
    test_language(prog)
    test_sqrt_rdiv(prog, source)
    test_static(prog, source)
    test_shape(prog, source)
    test_dynamic(prog, source)
    test_fuzz(prog, source)
    print_table(prog, source)
    failed = RESULTS.count(False)
    print(f"\n{len(RESULTS) - failed}/{len(RESULTS)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
