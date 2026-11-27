"""
gpc_sim.py - a strict interpreter for the Cronus Zen GPC subset used by XERA.gpc.

It exists to test the script off-device:
  * parses GPC (define / const arrays / int globals / init / main / function),
  * enforces the documented rules: globals only (no locals), no recursion,
    no combos needed, every identifier declared, calls match arity,
  * runs with 32-bit integer semantics: C-style truncating division and an
    overflow trap (any intermediate outside int32 raises),
  * emulates the I/O built-ins (get_ival / set_val / event_press / get_rtime ...)
    and the 128x64 OLED (cls_oled / pixel_oled / line_oled / rect_oled),
  * counts executed operations and OLED calls per tick.

It is not the Zen firmware. It is a reference that makes the script's
arithmetic and drawing reproducible and checkable.
"""
import re

INT_MIN, INT_MAX = -2**31, 2**31 - 1


class GPCError(Exception):
    pass


class Overflow(GPCError):
    pass


# ----------------------------------------------------------------- lexer
TOKEN_RE = re.compile(r"""
    (?P<ws>\s+) |
    (?P<lc>//[^\n]*) |
    (?P<bc>/\*.*?\*/) |
    (?P<num>0[xX][0-9a-fA-F]+|\d+) |
    (?P<id>[A-Za-z_][A-Za-z0-9_]*) |
    (?P<str>"[^"\n]*") |
    (?P<op>\+\+|--|\+=|-=|\*=|/=|%=|==|!=|<=|>=|&&|\|\||\^\^|<<|>>|[-+*/%<>=!&|^~(){}\[\],;])
""", re.S | re.X)


def lex(src):
    toks, pos, line = [], 0, 1
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise GPCError(f'line {line}: unexpected character {src[pos]!r}')
        kind = m.lastgroup
        text = m.group(kind)
        if kind not in ('ws', 'lc', 'bc'):
            toks.append((kind, text, line))
        line += text.count('\n')
        pos = m.end()
    toks.append(('eof', '', line))
    return toks


# ----------------------------------------------------------------- parser
KEYWORDS = {'define', 'const', 'int', 'init', 'main', 'combo', 'function', 'if', 'else',
            'while', 'do', 'for', 'break', 'return', 'remap', 'unmap', 'data'}
CONST_TYPES = {'int8', 'uint8', 'int16', 'uint16', 'int32', 'string'}
TYPE_RANGE = {'int8': (-128, 127), 'uint8': (0, 255), 'int16': (-32768, 32767),
              'uint16': (0, 65535), 'int32': (INT_MIN, INT_MAX)}


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        return self.t[self.i + k]

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expect(self, text):
        tok = self.next()
        if tok[1] != text:
            raise GPCError(f'line {tok[2]}: expected {text!r}, got {tok[1]!r}')
        return tok

    def ident(self):
        tok = self.next()
        if tok[0] != 'id' or tok[1] in KEYWORDS:
            raise GPCError(f'line {tok[2]}: expected identifier, got {tok[1]!r}')
        return tok[1]

    # --- top level
    def program(self):
        prog = {'defines': {}, 'consts': {}, 'ints': {}, 'funcs': {}, 'init': None, 'main': None,
                'order': []}
        while self.peek()[0] != 'eof':
            kind, text, line = self.peek()
            if text == 'define':
                self.next()
                name = self.ident()
                self.expect('=')
                prog['defines'][name] = ('expr', self.expr(), line)
                self.expect(';')
            elif text == 'const':
                self.next()
                ctype = self.ident()
                if ctype not in CONST_TYPES:
                    raise GPCError(f'line {line}: unknown const type {ctype}')
                name = self.ident()
                dims = 0
                while self.peek()[1] == '[':
                    self.expect('[')
                    self.expect(']')
                    dims += 1
                self.expect('=')
                prog['consts'][name] = (ctype, dims, self.init_list(), line)
                self.expect(';')
            elif text == 'int':
                if prog['init'] or prog['main']:
                    raise GPCError(f'line {line}: global variables must be declared before init/main')
                self.next()
                while True:
                    name = self.ident()
                    if self.peek()[1] == '[':
                        raise GPCError(f'line {line}: runtime int arrays are not used by this script')
                    val = None
                    if self.peek()[1] == '=':
                        self.next()
                        val = self.expr()
                    if name in prog['ints']:
                        raise GPCError(f'line {line}: duplicate variable {name}')
                    prog['ints'][name] = val
                    if self.peek()[1] == ',':
                        self.next()
                        continue
                    break
                self.expect(';')
            elif text in ('init', 'main'):
                self.next()
                if prog[text] is not None:
                    raise GPCError(f'line {line}: duplicate {text}')
                prog[text] = self.block()
            elif text == 'function':
                self.next()
                name = self.ident()
                self.expect('(')
                params = []
                if self.peek()[1] != ')':
                    while True:
                        params.append(self.ident())
                        if self.peek()[1] == ',':
                            self.next()
                            continue
                        break
                self.expect(')')
                if name in prog['funcs']:
                    raise GPCError(f'line {line}: duplicate function {name}')
                prog['funcs'][name] = (params, self.block(), line)
            else:
                raise GPCError(f'line {line}: unexpected {text!r} at top level')
        if prog['main'] is None:
            raise GPCError('script has no main')
        return prog

    def init_list(self):
        self.expect('{')
        items = []
        if self.peek()[1] != '}':
            while True:
                if self.peek()[1] == '{':
                    items.append(self.init_list())
                else:
                    items.append(self.expr())
                if self.peek()[1] == ',':
                    self.next()
                    if self.peek()[1] == '}':
                        break
                    continue
                break
        self.expect('}')
        return items

    # --- statements
    def block(self):
        self.expect('{')
        stmts = []
        while self.peek()[1] != '}':
            stmts.append(self.stmt())
        self.expect('}')
        return ('block', stmts)

    def stmt(self):
        kind, text, line = self.peek()
        if text == '{':
            return self.block()
        if text == 'int':
            raise GPCError(f'line {line}: local variable declarations are not allowed in GPC blocks')
        if text == 'if':
            self.next()
            self.expect('(')
            cond = self.expr()
            self.expect(')')
            then = self.stmt()
            other = None
            if self.peek()[1] == 'else':
                self.next()
                other = self.stmt()
            return ('if', cond, then, other, line)
        if text == 'while':
            self.next()
            self.expect('(')
            cond = self.expr()
            self.expect(')')
            return ('while', cond, self.stmt(), line)
        if text == 'do':
            self.next()
            body = self.stmt()
            self.expect('while')
            self.expect('(')
            cond = self.expr()
            self.expect(')')
            self.expect(';')
            return ('dowhile', body, cond, line)
        if text == 'for':
            self.next()
            self.expect('(')
            a = None if self.peek()[1] == ';' else self.expr()
            self.expect(';')
            c = None if self.peek()[1] == ';' else self.expr()
            self.expect(';')
            s = None if self.peek()[1] == ')' else self.expr()
            self.expect(')')
            return ('for', a, c, s, self.stmt(), line)
        if text == 'break':
            self.next()
            self.expect(';')
            return ('break', line)
        if text == 'return':
            self.next()
            if self.peek()[1] == ';':
                raise GPCError(f'line {line}: bare return; (this script always returns a value)')
            e = self.expr()
            self.expect(';')
            return ('return', e, line)
        if text == ';':
            self.next()
            return ('nop',)
        e = self.expr()
        self.expect(';')
        return ('expr', e, line)

    # --- expressions (C precedence; the script parenthesises anyway)
    BIN = [['||', '^^'], ['&&'], ['|'], ['^'], ['&'], ['==', '!='], ['<', '>', '<=', '>='],
           ['<<', '>>'], ['+', '-'], ['*', '/', '%']]

    def expr(self):
        return self.assign()

    def assign(self):
        left = self.binary(0)
        op = self.peek()[1]
        if op in ('=', '+=', '-=', '*=', '/=', '%='):
            line = self.next()[2]
            if left[0] != 'var':
                raise GPCError(f'line {line}: left side of {op} is not a variable')
            return ('assign', op, left[1], self.assign(), line)
        return left

    def binary(self, level):
        if level == len(self.BIN):
            return self.unary()
        left = self.binary(level + 1)
        while self.peek()[1] in self.BIN[level]:
            op, line = self.next()[1:]
            right = self.binary(level + 1)
            left = ('bin', op, left, right, line)
        return left

    def unary(self):
        kind, text, line = self.peek()
        if text in ('-', '!', '~'):
            self.next()
            return ('un', text, self.unary(), line)
        if text in ('++', '--'):
            self.next()
            target = self.unary()
            if target[0] != 'var':
                raise GPCError(f'line {line}: {text} needs a variable')
            return ('incdec', text, target[1], True, line)
        return self.postfix()

    def postfix(self):
        node = self.primary()
        while True:
            text = self.peek()[1]
            if text == '(':
                if node[0] != 'var':
                    raise GPCError('call of non-identifier')
                line = self.next()[2]
                args = []
                if self.peek()[1] != ')':
                    while True:
                        args.append(self.expr())
                        if self.peek()[1] == ',':
                            self.next()
                            continue
                        break
                self.expect(')')
                node = ('call', node[1], args, line)
            elif text == '[':
                line = self.next()[2]
                idx = self.expr()
                self.expect(']')
                node = ('index', node, idx, line)
            elif text in ('++', '--'):
                line = self.next()[2]
                if node[0] != 'var':
                    raise GPCError(f'line {line}: {text} needs a variable')
                node = ('incdec', text, node[1], False, line)
            else:
                return node

    def primary(self):
        kind, text, line = self.next()
        if kind == 'num':
            return ('num', int(text, 0))
        if kind == 'id' and text not in KEYWORDS:
            return ('var', text, line)
        if text == '(':
            e = self.expr()
            self.expect(')')
            return e
        raise GPCError(f'line {line}: unexpected {text!r} in expression')


# ----------------------------------------------------------------- runtime
class BreakSig(Exception):
    pass


class ReturnSig(Exception):
    def __init__(self, v):
        self.v = v


# device identifiers (values only need to be distinct)
DEVICE_CONSTS = {
    'TRUE': 1, 'FALSE': 0, 'OLED_WHITE': 1, 'OLED_BLACK': 0,
    'PS4_PS': 0, 'PS4_SHARE': 1, 'PS4_OPTIONS': 2, 'PS4_R1': 3, 'PS4_R2': 4, 'PS4_R3': 5,
    'PS4_L1': 6, 'PS4_L2': 7, 'PS4_L3': 8, 'PS4_RX': 9, 'PS4_RY': 10, 'PS4_LX': 11, 'PS4_LY': 12,
    'PS4_UP': 13, 'PS4_DOWN': 14, 'PS4_LEFT': 15, 'PS4_RIGHT': 16, 'PS4_TRIANGLE': 17,
    'PS4_CIRCLE': 18, 'PS4_CROSS': 19, 'PS4_SQUARE': 20, 'PS4_TOUCH': 27,
    'XB1_XBOX': 0, 'XB1_VIEW': 1, 'XB1_MENU': 2, 'XB1_RB': 3, 'XB1_RT': 4, 'XB1_RS': 5,
    'XB1_LB': 6, 'XB1_LT': 7, 'XB1_LS': 8, 'XB1_RX': 9, 'XB1_RY': 10, 'XB1_LX': 11, 'XB1_LY': 12,
}

BUILTIN_ARITY = {
    'get_ival': 1, 'get_val': 1, 'set_val': 2, 'event_press': 1, 'event_release': 1, 'get_rtime': 0,
    'vm_tctrl': 1, 'isqrt': 1, 'abs': 1, 'inv': 1, 'random': 2, 'pow': 2,
    'set_bit': 2, 'clear_bit': 2, 'test_bit': 2, 'set_bits': 4, 'get_bits': 3,
    'cls_oled': 1, 'pixel_oled': 3, 'line_oled': 6, 'rect_oled': 6, 'circle_oled': 5,
}
LVALUE_FIRST = {'set_bit', 'clear_bit', 'set_bits'}


def i32(v, where=''):
    if v < INT_MIN or v > INT_MAX:
        raise Overflow(f'int32 overflow ({v}) {where}')
    return v


def cdiv(a, b, where=''):
    if b == 0:
        raise GPCError(f'division by zero {where}')
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def cmod(a, b, where=''):
    return a - cdiv(a, b, where) * b


class Machine:
    def __init__(self, src, rng_seed=1):
        self.prog = Parser(lex(src)).program()
        self.ops = 0
        self.oled_calls = 0
        self.fb = [[0] * 128 for _ in range(64)]
        self.inputs = {}
        self.prev_inputs = {}
        self.out = {}
        self.rtime = 1
        self.vm = None
        import random
        self.rng = random.Random(rng_seed)
        self._link()

    # ---------- static checks + constant evaluation
    def _link(self):
        p = self.prog
        self.defines = {}
        for name, (_, e, line) in p['defines'].items():
            self.defines[name] = self._const_eval(e, line)
        self.consts = {}
        for name, (ctype, dims, items, line) in p['consts'].items():
            lo, hi = TYPE_RANGE[ctype]

            def conv(x):
                v = self._const_eval(x, line)
                if not lo <= v <= hi:
                    raise GPCError(f'line {line}: value {v} out of range for {ctype} in {name}')
                return v
            if dims == 1:
                self.consts[name] = [conv(x) for x in items]
            elif dims == 2:
                rows = [[conv(x) for x in r] for r in items]
                if len({len(r) for r in rows}) != 1:
                    raise GPCError(f'line {line}: rows of {name} differ in length')
                self.consts[name] = rows
            else:
                raise GPCError(f'line {line}: unsupported const dims')
        self.vars = {}
        for name, init in p['ints'].items():
            self._check_name(name)
            self.vars[name] = 0 if init is None else self._const_eval(init, 0)
        self.funcs = p['funcs']
        for name in self.funcs:
            self._check_name(name)
        # resolve and check every identifier / call in code
        self.calls = {name: set() for name in self.funcs}
        for name, (params, body, line) in self.funcs.items():
            self._check(body, set(params), name)
        self._check(p['init'] or ('block', []), set(), None)
        self._check(p['main'], set(), None)
        self._check_recursion()
        # conservative: every function only calls functions defined above it
        order = list(self.funcs)
        for name in order:
            for callee in self.calls[name]:
                if order.index(callee) > order.index(name):
                    raise GPCError(f'{name} calls {callee}, which is defined later in the file')

    def _check_name(self, name):
        if name in DEVICE_CONSTS or name in BUILTIN_ARITY:
            raise GPCError(f'{name} collides with a built-in identifier')

    def _const_eval(self, e, line):
        if e[0] == 'num':
            return e[1]
        if e[0] == 'un' and e[1] == '-':
            return -self._const_eval(e[2], line)
        if e[0] == 'var':
            if e[1] in self.defines:
                return self.defines[e[1]]
            if e[1] in DEVICE_CONSTS:
                return DEVICE_CONSTS[e[1]]
        raise GPCError(f'line {line}: define/const values must be literals or known constants')

    def _check(self, node, params, fname):
        t = node[0]
        if t == 'block':
            for s in node[1]:
                self._check(s, params, fname)
        elif t == 'if':
            self._check(node[1], params, fname)
            self._check(node[2], params, fname)
            if node[3]:
                self._check(node[3], params, fname)
        elif t == 'while':
            self._check(node[1], params, fname)
            self._check(node[2], params, fname)
        elif t == 'dowhile':
            self._check(node[1], params, fname)
            self._check(node[2], params, fname)
        elif t == 'for':
            for k in (1, 2, 3, 4):
                if node[k]:
                    self._check(node[k], params, fname)
        elif t in ('return', 'expr'):
            self._check(node[1], params, fname)
        elif t in ('break', 'nop', 'num'):
            pass
        elif t == 'var':
            n = node[1]
            if not (n in params or n in self.vars or n in self.defines or n in DEVICE_CONSTS or n in self.consts):
                raise GPCError(f'line {node[2]}: undeclared identifier {n}')
        elif t == 'assign':
            n = node[2]
            if not (n in params or n in self.vars):
                raise GPCError(f'line {node[4]}: cannot assign to {n}')
            self._check(node[3], params, fname)
        elif t == 'incdec':
            if not (node[2] in params or node[2] in self.vars):
                raise GPCError(f'line {node[4]}: cannot modify {node[2]}')
        elif t == 'bin':
            self._check(node[2], params, fname)
            self._check(node[3], params, fname)
        elif t == 'un':
            self._check(node[2], params, fname)
        elif t == 'index':
            if node[1][0] != 'var' or node[1][1] not in self.consts:
                if node[1][0] != 'index':
                    raise GPCError(f'line {node[3]}: only const arrays can be indexed')
            self._check(node[2], params, fname)
            if node[1][0] == 'index':
                self._check(node[1], params, fname)
        elif t == 'call':
            n, args, line = node[1], node[2], node[3]
            if n in self.funcs:
                if len(args) != len(self.funcs[n][0]):
                    raise GPCError(f'line {line}: {n} expects {len(self.funcs[n][0])} args')
                if fname:
                    self.calls[fname].add(n)
            elif n in BUILTIN_ARITY:
                if len(args) != BUILTIN_ARITY[n]:
                    raise GPCError(f'line {line}: {n} expects {BUILTIN_ARITY[n]} args')
                if n in LVALUE_FIRST and args[0][0] != 'var':
                    raise GPCError(f'line {line}: first argument of {n} must be a variable')
            else:
                raise GPCError(f'line {line}: unknown function {n}')
            for a in args:
                self._check(a, params, fname)
        else:
            raise GPCError(f'unknown node {t}')

    def _check_recursion(self):
        def visit(n, stack):
            if n in stack:
                raise GPCError(f'recursive call chain: {" -> ".join(stack + [n])}')
            for m in self.calls.get(n, ()):
                visit(m, stack + [n])
        for n in self.funcs:
            visit(n, [])

    # ---------- execution
    def run_init(self):
        if self.prog['init']:
            self._exec(self.prog['init'], {})

    def tick(self, inputs, rtime=1):
        """one main iteration; inputs: {identifier_index: value}"""
        self.prev_inputs = self.inputs
        self.inputs = dict(inputs)
        self.out = dict(inputs)
        self.rtime = rtime
        self.ops = 0
        self.oled_calls = 0
        self._exec(self.prog['main'], {})
        return self.out

    def _exec(self, node, env):
        t = node[0]
        self.ops += 1
        if t == 'block':
            for s in node[1]:
                self._exec(s, env)
        elif t == 'expr':
            self._eval(node[1], env)
        elif t == 'if':
            if self._eval(node[1], env):
                self._exec(node[2], env)
            elif node[3]:
                self._exec(node[3], env)
        elif t == 'while':
            n = 0
            try:
                while self._eval(node[1], env):
                    self._exec(node[2], env)
                    n += 1
                    if n > 100000:
                        raise GPCError(f'line {node[3]}: runaway loop')
            except BreakSig:
                pass
        elif t == 'dowhile':
            try:
                while True:
                    self._exec(node[1], env)
                    if not self._eval(node[2], env):
                        break
            except BreakSig:
                pass
        elif t == 'for':
            if node[1]:
                self._eval(node[1], env)
            n = 0
            try:
                while node[2] is None or self._eval(node[2], env):
                    self._exec(node[4], env)
                    if node[3]:
                        self._eval(node[3], env)
                    n += 1
                    if n > 100000:
                        raise GPCError(f'line {node[5]}: runaway loop')
            except BreakSig:
                pass
        elif t == 'break':
            raise BreakSig()
        elif t == 'return':
            raise ReturnSig(self._eval(node[1], env))
        elif t == 'nop':
            pass
        else:
            raise GPCError(f'cannot execute {t}')

    def _get(self, name, env):
        if name in env:
            return env[name]
        if name in self.vars:
            return self.vars[name]
        if name in self.defines:
            return self.defines[name]
        if name in DEVICE_CONSTS:
            return DEVICE_CONSTS[name]
        raise GPCError(f'unknown {name}')

    def _set(self, name, v, env, line):
        v = i32(v, f'assigning {name} (line {line})')
        if name in env:
            env[name] = v
        else:
            self.vars[name] = v

    def _eval(self, e, env):
        self.ops += 1
        t = e[0]
        if t == 'num':
            return e[1]
        if t == 'var':
            return self._get(e[1], env)
        if t == 'bin':
            op, line = e[1], e[4]
            a = self._eval(e[2], env)
            b = self._eval(e[3], env)
            w = f'(line {line}, op {op})'
            if op == '+': return i32(a + b, w)
            if op == '-': return i32(a - b, w)
            if op == '*': return i32(a * b, w)
            if op == '/': return cdiv(a, b, w)
            if op == '%': return cmod(a, b, w)
            if op == '<': return int(a < b)
            if op == '>': return int(a > b)
            if op == '<=': return int(a <= b)
            if op == '>=': return int(a >= b)
            if op == '==': return int(a == b)
            if op == '!=': return int(a != b)
            if op == '&&': return int(bool(a) and bool(b))
            if op == '||': return int(bool(a) or bool(b))
            if op == '^^': return int(bool(a) != bool(b))
            if op == '&': return a & b
            if op == '|': return a | b
            if op == '^': return a ^ b
            if op == '<<':
                if a < 0 or b < 0 or b > 30: raise GPCError(f'unsafe shift {w}')
                return i32(a << b, w)
            if op == '>>':
                if a < 0 or b < 0: raise GPCError(f'unsafe shift {w}')
                return a >> b
            raise GPCError(f'op {op}')
        if t == 'un':
            v = self._eval(e[2], env)
            if e[1] == '-': return i32(-v)
            if e[1] == '!': return int(not v)
            if e[1] == '~': return ~v
        if t == 'assign':
            op, name, line = e[1], e[2], e[4]
            v = self._eval(e[3], env)
            if op != '=':
                cur = self._get(name, env)
                w = f'(line {line})'
                v = {'+=': lambda: cur + v, '-=': lambda: cur - v, '*=': lambda: cur * v,
                     '/=': lambda: cdiv(cur, v, w), '%=': lambda: cmod(cur, v, w)}[op]()
            self._set(name, v, env, line)
            return v
        if t == 'incdec':
            cur = self._get(e[2], env)
            nv = cur + (1 if e[1] == '++' else -1)
            self._set(e[2], nv, env, e[4])
            return nv if e[3] else cur
        if t == 'index':
            if e[1][0] == 'var':
                arr = self.consts[e[1][1]]
            else:
                arr = self._eval_index_base(e[1], env)
            i = self._eval(e[2], env)
            if not 0 <= i < len(arr):
                raise GPCError(f'line {e[3]}: index {i} out of range')
            return arr[i]
        if t == 'call':
            return self._call(e, env)
        raise GPCError(f'cannot evaluate {t}')

    def _eval_index_base(self, e, env):
        arr = self.consts[e[1][1]]
        i = self._eval(e[2], env)
        return arr[i]

    def _call(self, e, env):
        name, args, line = e[1], e[2], e[3]
        if name in self.funcs:
            params, body, _ = self.funcs[name]
            vals = [self._eval(a, env) for a in args]
            local = dict(zip(params, vals))
            try:
                self._exec(body, local)
            except ReturnSig as r:
                return r.v
            return 0
        if name in LVALUE_FIRST:
            var = args[0][1]
            cur = self._get(var, env)
            rest = [self._eval(a, env) for a in args[1:]]
            if name == 'set_bit':
                nv = cur | (1 << rest[0])
            elif name == 'clear_bit':
                nv = cur & ~(1 << rest[0])
            else:  # set_bits(var, value, index, mask)
                val, idx, mask = rest
                nv = (cur & ~(mask << idx)) | ((val & mask) << idx)
            self._set(var, nv, env, line)
            return 0
        a = [self._eval(x, env) for x in args]
        if name == 'get_ival': return self.inputs.get(a[0], 0)
        if name == 'get_val': return self.out.get(a[0], 0)
        if name == 'set_val':
            v = a[1]
            if not -100 <= v <= 100:
                raise GPCError(f'line {line}: set_val out of range ({v})')
            self.out[a[0]] = v
            return 0
        if name == 'event_press':
            return int(bool(self.inputs.get(a[0], 0)) and not self.prev_inputs.get(a[0], 0))
        if name == 'event_release':
            return int(not self.inputs.get(a[0], 0) and bool(self.prev_inputs.get(a[0], 0)))
        if name == 'get_rtime': return self.rtime
        if name == 'vm_tctrl':
            if not -9 <= a[0] <= 10: raise GPCError('vm_tctrl range')
            self.vm = a[0]
            return 0
        if name == 'isqrt':
            if a[0] < 0: raise GPCError(f'line {line}: isqrt of negative')
            import math
            return math.isqrt(a[0])
        if name == 'abs': return abs(a[0])
        if name == 'inv': return -a[0]
        if name == 'pow': return i32(a[0] ** a[1])
        if name == 'random': return self.rng.randint(a[0], a[1])
        if name == 'test_bit': return int(bool(a[0] & (1 << a[1])))
        if name == 'get_bits': return (a[0] >> a[1]) & a[2]
        if name in ('cls_oled', 'pixel_oled', 'line_oled', 'rect_oled', 'circle_oled'):
            self.oled_calls += 1
            return self._oled(name, a, line)
        raise GPCError(f'built-in {name} not emulated')

    # ---------- OLED
    def _px(self, x, y, c):
        if 0 <= x < 128 and 0 <= y < 64:
            self.fb[y][x] = 1 if c else 0
        else:
            raise GPCError(f'OLED draw outside the screen at ({x},{y})')

    def _oled(self, name, a, line):
        if name == 'cls_oled':
            for row in self.fb:
                for x in range(128):
                    row[x] = 1 if a[0] else 0
        elif name == 'pixel_oled':
            self._px(a[0], a[1], a[2])
        elif name == 'line_oled':
            x0, y0, x1, y1, th, c = a
            if th != 1:
                raise GPCError(f'line {line}: thickness {th} not emulated')
            dx, dy = abs(x1 - x0), -abs(y1 - y0)
            sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
            err = dx + dy
            while True:
                self._px(x0, y0, c)
                if x0 == x1 and y0 == y1:
                    break
                e2 = 2 * err
                if e2 >= dy:
                    err += dy
                    x0 += sx
                if e2 <= dx:
                    err += dx
                    y0 += sy
        elif name == 'rect_oled':
            x, y, w, h, fill, c = a
            for yy in range(y, y + h):
                for xx in range(x, x + w):
                    if fill or yy in (y, y + h - 1) or xx in (x, x + w - 1):
                        self._px(xx, yy, c)
        else:
            raise GPCError(f'{name} not emulated')
        return 0
