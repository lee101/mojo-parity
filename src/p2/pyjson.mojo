"""Python json for ports of Python tools: json.loads (CPython scanner semantics and
JSONDecodeError texts), a Python value arena (dict keeps first-insertion order,
last value wins; int vs float kept apart) and json.dumps (indent, sort_keys,
ensure_ascii, allow_nan) with float.__repr__."""

from p2.gofmt import go_format_float, go_parse_float
from p2.gomath import is_finite, nan64, inf64

comptime P_NONE = 0
comptime P_BOOL = 1
comptime P_INT = 2
comptime P_FLOAT = 3
comptime P_STR = 4
comptime P_LIST = 5
comptime P_DICT = 6


@fieldwise_init
struct PNode(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var b: Bool
    var f: Float64
    var s: Int
    var first: Int
    var next: Int
    var last: Int
    var key: Int


def py_float_repr(x: Float64) -> String:
    """repr(float): shortest round-trip digits; exponent form when decpt <= -4 or > 16."""
    if x != x:
        return "nan"
    if not is_finite(x):
        return "inf" if x > 0 else "-inf"
    var e = go_format_float(x, "e", -1)
    var neg = e.startswith("-")
    var body = String(e[byte=1:]) if neg else e
    var epos = body.find("e")
    var mant = String(body[byte=0:epos])
    var exp = 0
    var es = String(body[byte = epos + 1 :])
    var eneg = es.startswith("-")
    for b in es.as_bytes():
        if b >= 48 and b <= 57:
            exp = exp * 10 + Int(b) - 48
    if eneg:
        exp = -exp
    var digits = mant.replace(".", "")
    var decpt = exp + 1
    var out = String("-") if neg else String("")
    if decpt <= -4 or decpt > 16:
        out += String(digits[byte=0:1])
        if digits.byte_length() > 1:
            out += "." + String(digits[byte=1:])
        out += "e" + ("-" if exp < 0 else "+")
        var a = -exp if exp < 0 else exp
        if a < 10:
            out += "0"
        out += String(a)
        return out
    if decpt <= 0:
        out += "0."
        for _ in range(-decpt):
            out += "0"
        out += digits
        return out
    if digits.byte_length() <= decpt:
        out += digits
        for _ in range(decpt - digits.byte_length()):
            out += "0"
        out += ".0"
        return out
    out += String(digits[byte=0:decpt]) + "." + String(digits[byte=decpt:])
    return out


struct PyVal(Movable):
    var nodes: List[PNode]
    var strs: List[String]

    def __init__(out self):
        self.nodes = List[PNode]()
        self.strs = List[String]()

    def _new(mut self, kind: Int) -> Int:
        self.nodes.append(PNode(kind, False, 0, -1, -1, -1, -1, -1))
        return len(self.nodes) - 1

    def none(mut self) -> Int:
        return self._new(P_NONE)

    def boolean(mut self, b: Bool) -> Int:
        var n = self._new(P_BOOL)
        self.nodes[n].b = b
        return n

    def integer(mut self, text: String) -> Int:
        var n = self._new(P_INT)
        self.strs.append(text)
        self.nodes[n].s = len(self.strs) - 1
        return n

    def float(mut self, x: Float64) -> Int:
        var n = self._new(P_FLOAT)
        self.nodes[n].f = x
        return n

    def string(mut self, s: String) -> Int:
        var n = self._new(P_STR)
        self.strs.append(s)
        self.nodes[n].s = len(self.strs) - 1
        return n

    def list(mut self) -> Int:
        return self._new(P_LIST)

    def dict(mut self) -> Int:
        return self._new(P_DICT)

    def append(mut self, lst: Int, v: Int):
        if self.nodes[lst].first < 0:
            self.nodes[lst].first = v
        else:
            self.nodes[self.nodes[lst].last].next = v
        self.nodes[lst].last = v
        self.nodes[v].next = -1

    def set(mut self, d: Int, k: String, v: Int):
        """d[k] = v: replace in place if present (keeps position), else append."""
        var c = self.nodes[d].first
        var prev = -1
        while c >= 0:
            if self.strs[self.nodes[c].key] == k:
                self.strs.append(k)
                self.nodes[v].key = len(self.strs) - 1
                self.nodes[v].next = self.nodes[c].next
                if prev < 0:
                    self.nodes[d].first = v
                else:
                    self.nodes[prev].next = v
                if self.nodes[d].last == c:
                    self.nodes[d].last = v
                return
            prev = c
            c = self.nodes[c].next
        self.strs.append(k)
        self.nodes[v].key = len(self.strs) - 1
        self.append(d, v)

    def pop(mut self, d: Int, k: String):
        var c = self.nodes[d].first
        var prev = -1
        while c >= 0:
            if self.strs[self.nodes[c].key] == k:
                var nx = self.nodes[c].next
                if prev < 0:
                    self.nodes[d].first = nx
                else:
                    self.nodes[prev].next = nx
                if self.nodes[d].last == c:
                    self.nodes[d].last = prev
                return
            prev = c
            c = self.nodes[c].next

    def kind(self, n: Int) -> Int:
        return self.nodes[n].kind

    def text(self, n: Int) -> String:
        return self.strs[self.nodes[n].s]

    def key(self, n: Int) -> String:
        return self.strs[self.nodes[n].key]

    def children(self, n: Int) -> List[Int]:
        var out = List[Int]()
        var c = self.nodes[n].first
        while c >= 0:
            out.append(c)
            c = self.nodes[c].next
        return out^

    def get(self, d: Int, k: String) -> Int:
        if d < 0 or self.nodes[d].kind != P_DICT:
            return -1
        var c = self.nodes[d].first
        while c >= 0:
            if self.strs[self.nodes[c].key] == k:
                return c
            c = self.nodes[c].next
        return -1

    def length(self, n: Int) -> Int:
        var k = 0
        var c = self.nodes[n].first
        while c >= 0:
            k += 1
            c = self.nodes[c].next
        return k

    def truthy(self, n: Int) -> Bool:
        """bool(value) in Python."""
        if n < 0:
            return False
        var k = self.nodes[n].kind
        if k == P_NONE:
            return False
        if k == P_BOOL:
            return self.nodes[n].b
        if k == P_INT:
            var t = self.text(n)
            return t != "0" and t != "-0"
        if k == P_FLOAT:
            return self.nodes[n].f != 0
        if k == P_STR:
            return self.text(n).byte_length() > 0
        return self.nodes[n].first >= 0

    def deep_copy(mut self, n: Int) -> Int:
        """Deep copy of node n within this arena."""
        var k = self.nodes[n].kind
        if k == P_NONE:
            return self.none()
        if k == P_BOOL:
            return self.boolean(self.nodes[n].b)
        if k == P_INT:
            return self.integer(self.text(n))
        if k == P_FLOAT:
            return self.float(self.nodes[n].f)
        if k == P_STR:
            return self.string(self.text(n))
        var kids = self.children(n)
        if k == P_LIST:
            var l = self.list()
            for c in kids:
                self.append(l, self.deep_copy(c))
            return l
        var d = self.dict()
        for c in kids:
            var key = self.key(c)
            self.set(d, key, self.deep_copy(c))
        return d

    def copy_from(mut self, src: PyVal, n: Int) -> Int:
        """Deep copy of src node n into this arena."""
        var k = src.nodes[n].kind
        if k == P_NONE:
            return self.none()
        if k == P_BOOL:
            return self.boolean(src.nodes[n].b)
        if k == P_INT:
            return self.integer(src.text(n))
        if k == P_FLOAT:
            return self.float(src.nodes[n].f)
        if k == P_STR:
            return self.string(src.text(n))
        if k == P_LIST:
            var l = self.list()
            for c in src.children(n):
                self.append(l, self.copy_from(src, c))
            return l
        var d = self.dict()
        for c in src.children(n):
            self.set(d, src.key(c), self.copy_from(src, c))
        return d


# ---- loads -------------------------------------------------------------------------------


struct _Dec:
    var b: List[UInt8]
    var chars: List[Int]

    def __init__(out self, var b: List[UInt8]):
        self.b = b^
        self.chars = List[Int]()


def _err(src: Span[UInt8, _], msg: String, pos_byte: Int) -> Error:
    """JSONDecodeError text; positions are str (code point) indices."""
    var pos = 0
    var line = 1
    var last_nl = -1
    var i = 0
    while i < pos_byte and i < len(src):
        var c = src[i]
        if (c & 0xC0) != 0x80:
            if c == 10:
                line += 1
                last_nl = pos
            pos += 1
        i += 1
    var col = pos - last_nl if last_nl >= 0 else pos + 1
    return Error(msg + ": line " + String(line) + " column " + String(col) + " (char " + String(pos) + ")")


def _ws(src: Span[UInt8, _], mut i: Int):
    while i < len(src) and (src[i] == 32 or src[i] == 9 or src[i] == 10 or src[i] == 13):
        i += 1


def _hex4(src: Span[UInt8, _], i: Int) -> Int:
    var v = 0
    for k in range(4):
        if i + k >= len(src):
            return -1
        var c = src[i + k]
        var d: Int
        if c >= 48 and c <= 57:
            d = Int(c) - 48
        elif c >= 97 and c <= 102:
            d = Int(c) - 87
        elif c >= 65 and c <= 70:
            d = Int(c) - 55
        else:
            return -1
        v = v * 16 + d
    return v


def _put(mut out: List[UInt8], r: Int):
    if r < 0x80:
        out.append(UInt8(r))
    elif r < 0x800:
        out.append(UInt8(0xC0 | (r >> 6)))
        out.append(UInt8(0x80 | (r & 0x3F)))
    elif r < 0x10000:
        out.append(UInt8(0xE0 | (r >> 12)))
        out.append(UInt8(0x80 | ((r >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (r & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (r >> 18)))
        out.append(UInt8(0x80 | ((r >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((r >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (r & 0x3F)))


def _string(src: Span[UInt8, _], mut i: Int) raises -> String:
    """i at the opening quote; leaves i after the closing quote."""
    var start = i
    i += 1
    var out = List[UInt8]()
    while True:
        if i >= len(src):
            raise _err(src, "Unterminated string starting at", start)
        var c = src[i]
        if c == 34:
            i += 1
            return String(unsafe_from_utf8=out)
        if c == 92:
            if i + 1 >= len(src):
                raise _err(src, "Unterminated string starting at", start)
            var e = src[i + 1]
            if e == 117:
                var r = _hex4(src, i + 2)
                if r < 0:
                    raise _err(src, "Invalid \\uXXXX escape", i + 1)
                i += 6
                if r >= 0xD800 and r <= 0xDBFF and i + 1 < len(src) and src[i] == 92 and src[i + 1] == 117:
                    var r2 = _hex4(src, i + 2)
                    if r2 >= 0xDC00 and r2 <= 0xDFFF:
                        r = 0x10000 + ((r - 0xD800) << 10) + (r2 - 0xDC00)
                        i += 6
                _put(out, r)
                continue
            var m: Int
            if e == 34:
                m = 34
            elif e == 92:
                m = 92
            elif e == 47:
                m = 47
            elif e == 98:
                m = 8
            elif e == 102:
                m = 12
            elif e == 110:
                m = 10
            elif e == 114:
                m = 13
            elif e == 116:
                m = 9
            else:
                raise _err(src, "Invalid \\escape: " + _py_repr_char(e), i)
            out.append(UInt8(m))
            i += 2
            continue
        if c < 32:
            raise _err(src, "Invalid control character at", i)
        out.append(c)
        i += 1


def _py_repr_char(c: UInt8) -> String:
    if c == 39:
        return "\"'\""
    if c >= 32 and c < 127:
        return "'" + chr(Int(c)) + "'"
    var h = "0123456789abcdef"
    return "'\\x" + String(h[byte = Int(c >> 4) : Int(c >> 4) + 1]) + String(h[byte = Int(c & 15) : Int(c & 15) + 1]) + "'"


def _match(src: Span[UInt8, _], i: Int, lit: String) -> Bool:
    var b = lit.as_bytes()
    if i + len(b) > len(src):
        return False
    for k in range(len(b)):
        if src[i + k] != b[k]:
            return False
    return True


def _value(src: Span[UInt8, _], mut i: Int, mut v: PyVal) raises -> Int:
    if i >= len(src):
        raise _err(src, "Expecting value", i)
    var c = src[i]
    if c == 34:
        return v.string(_string(src, i))
    if c == 123:
        var d = v.dict()
        i += 1
        _ws(src, i)
        if i < len(src) and src[i] == 125:
            i += 1
            return d
        if i >= len(src) or src[i] != 34:
            raise _err(src, "Expecting property name enclosed in double quotes", i)
        while True:
            var k = _string(src, i)
            _ws(src, i)
            if i >= len(src) or src[i] != 58:
                raise _err(src, "Expecting ':' delimiter", i)
            i += 1
            _ws(src, i)
            var val = _value(src, i, v)
            v.set(d, k, val)
            _ws(src, i)
            if i < len(src) and src[i] == 125:
                i += 1
                return d
            if i >= len(src) or src[i] != 44:
                raise _err(src, "Expecting ',' delimiter", i)
            i += 1
            _ws(src, i)
            if i >= len(src) or src[i] != 34:
                raise _err(src, "Expecting property name enclosed in double quotes", i)
    if c == 91:
        var l = v.list()
        i += 1
        _ws(src, i)
        if i < len(src) and src[i] == 93:
            i += 1
            return l
        while True:
            var val = _value(src, i, v)
            v.append(l, val)
            _ws(src, i)
            if i < len(src) and src[i] == 93:
                i += 1
                return l
            if i >= len(src) or src[i] != 44:
                raise _err(src, "Expecting ',' delimiter", i)
            i += 1
            _ws(src, i)
    if c == 110 and _match(src, i, "null"):
        i += 4
        return v.none()
    if c == 116 and _match(src, i, "true"):
        i += 4
        return v.boolean(True)
    if c == 102 and _match(src, i, "false"):
        i += 5
        return v.boolean(False)
    if c == 78 and _match(src, i, "NaN"):
        i += 3
        return v.float(nan64())
    if c == 73 and _match(src, i, "Infinity"):
        i += 8
        return v.float(inf64())
    if c == 45 and _match(src, i, "-Infinity"):
        i += 9
        return v.float(-inf64())
    var start = i
    var j = i
    if j < len(src) and src[j] == 45:
        j += 1
    if j < len(src) and src[j] == 48:
        j += 1
    elif j < len(src) and src[j] >= 49 and src[j] <= 57:
        while j < len(src) and src[j] >= 48 and src[j] <= 57:
            j += 1
    else:
        raise _err(src, "Expecting value", i)
    var is_float = False
    if j + 1 < len(src) and src[j] == 46 and src[j + 1] >= 48 and src[j + 1] <= 57:
        is_float = True
        j += 2
        while j < len(src) and src[j] >= 48 and src[j] <= 57:
            j += 1
    if j < len(src) and (src[j] == 101 or src[j] == 69):
        var k = j + 1
        if k < len(src) and (src[k] == 43 or src[k] == 45):
            k += 1
        if k < len(src) and src[k] >= 48 and src[k] <= 57:
            while k < len(src) and src[k] >= 48 and src[k] <= 57:
                k += 1
            j = k
            is_float = True
    var text = String(unsafe_from_utf8=src[start:j])
    i = j
    if is_float:
        var r = go_parse_float(text)
        return v.float(r.value)
    if text == "-0":
        text = "0"
    return v.integer(text)


@always_inline
def _zero() -> Float64:
    return 0.0


def py_loads(src: Span[UInt8, _], mut v: PyVal) raises -> Int:
    """json.loads: returns the root node in v."""
    var i = 0
    _ws(src, i)
    var root = _value(src, i, v)
    _ws(src, i)
    if i != len(src):
        raise _err(src, "Extra data", i)
    return root


# ---- dumps -------------------------------------------------------------------------------


def _esc(s: String) -> String:
    """ensure_ascii string encoding (py_encode_basestring_ascii)."""
    var out = List[UInt8]()
    out.append(34)
    var b = s.as_bytes()
    var i = 0
    comptime H = "0123456789abcdef"
    while i < len(b):
        var c = Int(b[i])
        var r = c
        var w = 1
        if c >= 0xF0:
            r = ((c & 0x07) << 18) | ((Int(b[i + 1]) & 0x3F) << 12) | ((Int(b[i + 2]) & 0x3F) << 6) | (Int(b[i + 3]) & 0x3F)
            w = 4
        elif c >= 0xE0:
            r = ((c & 0x0F) << 12) | ((Int(b[i + 1]) & 0x3F) << 6) | (Int(b[i + 2]) & 0x3F)
            w = 3
        elif c >= 0xC0:
            r = ((c & 0x1F) << 6) | (Int(b[i + 1]) & 0x3F)
            w = 2
        i += w
        var lit = String("")
        if r == 34:
            lit = '\\"'
        elif r == 92:
            lit = "\\\\"
        elif r == 10:
            lit = "\\n"
        elif r == 13:
            lit = "\\r"
        elif r == 9:
            lit = "\\t"
        elif r == 8:
            lit = "\\b"
        elif r == 12:
            lit = "\\f"
        if lit.byte_length() > 0:
            for x in lit.as_bytes():
                out.append(x)
            continue
        if r >= 32 and r < 127:
            out.append(UInt8(r))
            continue
        var units = List[Int]()
        if r >= 0x10000:
            var v = r - 0x10000
            units.append(0xD800 | (v >> 10))
            units.append(0xDC00 | (v & 0x3FF))
        else:
            units.append(r)
        for u in units:
            out.append(92)
            out.append(117)
            for sh in [12, 8, 4, 0]:
                var d = (u >> sh) & 15
                out.append(H.as_bytes()[d])
    out.append(34)
    return String(unsafe_from_utf8=out)


def py_float_json(x: Float64, allow_nan: Bool) raises -> String:
    if x != x:
        if not allow_nan:
            raise Error("Out of range float values are not JSON compliant")
        return "NaN"
    if not is_finite(x):
        if not allow_nan:
            raise Error("Out of range float values are not JSON compliant")
        return "Infinity" if x > 0 else "-Infinity"
    return py_float_repr(x)


def py_dumps(v: PyVal, n: Int, indent: Int = -1, sort_keys: Bool = False, allow_nan: Bool = True) raises -> String:
    var out = String("")
    _dump(v, n, indent, sort_keys, allow_nan, 0, out)
    return out


def _dump(v: PyVal, n: Int, indent: Int, sort_keys: Bool, allow_nan: Bool, level: Int, mut out: String) raises:
    var k = v.kind(n)
    if k == P_NONE:
        out += "null"
    elif k == P_BOOL:
        out += "true" if v.nodes[n].b else "false"
    elif k == P_INT:
        out += v.text(n)
    elif k == P_FLOAT:
        out += py_float_json(v.nodes[n].f, allow_nan)
    elif k == P_STR:
        out += _esc(v.text(n))
    else:
        var kids = v.children(n)
        var open = "[" if k == P_LIST else "{"
        var close = "]" if k == P_LIST else "}"
        if len(kids) == 0:
            out += open + close
            return
        if k == P_DICT and sort_keys:
            for i in range(1, len(kids)):
                var x = kids[i]
                var j = i - 1
                while j >= 0 and v.key(kids[j]) > v.key(x):
                    kids[j + 1] = kids[j]
                    j -= 1
                kids[j + 1] = x
        out += open
        var pad = String("")
        var sep = String(", ")
        if indent >= 0:
            pad = "\n"
            for _ in range(indent * (level + 1)):
                pad += " "
            sep = ","
        for i in range(len(kids)):
            if i > 0:
                out += sep
            out += pad
            if k == P_DICT:
                out += _esc(v.key(kids[i])) + ": "
            _dump(v, kids[i], indent, sort_keys, allow_nan, level + 1, out)
        if indent >= 0:
            out += "\n"
            for _ in range(indent * level):
                out += " "
        out += close
