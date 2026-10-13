"""JSON tree that keeps each value's raw byte span, for ports that must echo
tokens verbatim (Go json.RawMessage / LooseString, Python's int-vs-float).

Validate with gojsonscan.json_check_valid first; the parser assumes valid input.
"""

from p2.gojsonscan import json_check_valid

comptime R_NULL = 0
comptime R_BOOL = 1
comptime R_NUM = 2
comptime R_STR = 3
comptime R_ARR = 4
comptime R_OBJ = 5


@fieldwise_init
struct RNode(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var start: Int
    var end: Int
    var key_start: Int
    var key_end: Int
    var first: Int
    var next: Int
    var count: Int


struct JRaw(Movable):
    var src: List[UInt8]
    var nodes: List[RNode]

    def __init__(out self, var src: List[UInt8]):
        """src must already be valid JSON (see parse)."""
        self.src = src^
        self.nodes = List[RNode]()
        var pos = 0
        _ = self._value(pos)

    @staticmethod
    def parse(var src: List[UInt8]) raises -> JRaw:
        var bad = json_check_valid(Span(src))
        if bad.byte_length() > 0:
            raise Error(bad)
        return JRaw(src^)

    @staticmethod
    def from_string(s: String) raises -> JRaw:
        var b = List[UInt8](capacity=s.byte_length())
        for x in s.as_bytes():
            b.append(x)
        return JRaw.parse(b^)

    def _ws(self, mut pos: Int):
        while pos < len(self.src):
            var c = self.src[pos]
            if c == 32 or c == 9 or c == 10 or c == 13:
                pos += 1
            else:
                return

    def _str_end(self, pos: Int) -> Int:
        var i = pos + 1
        while True:
            var c = self.src[i]
            if c == 92:
                i += 2
                continue
            if c == 34:
                return i + 1
            i += 1

    def _value(mut self, mut pos: Int) -> Int:
        self._ws(pos)
        var c = self.src[pos]
        var idx = len(self.nodes)
        self.nodes.append(RNode(R_NULL, pos, pos, -1, -1, -1, -1, 0))
        if c == 123 or c == 91:
            var obj = c == 123
            self.nodes[idx].kind = R_OBJ if obj else R_ARR
            pos += 1
            self._ws(pos)
            var close = UInt8(125) if obj else UInt8(93)
            var last = -1
            if self.src[pos] == close:
                pos += 1
            else:
                while True:
                    var ks = -1
                    var ke = -1
                    if obj:
                        self._ws(pos)
                        ks = pos
                        ke = self._str_end(pos)
                        pos = ke
                        self._ws(pos)
                        pos += 1
                    var child = self._value(pos)
                    self.nodes[child].key_start = ks
                    self.nodes[child].key_end = ke
                    if last < 0:
                        self.nodes[idx].first = child
                    else:
                        self.nodes[last].next = child
                    last = child
                    self.nodes[idx].count += 1
                    self._ws(pos)
                    if self.src[pos] == 44:
                        pos += 1
                        continue
                    pos += 1
                    break
        elif c == 34:
            self.nodes[idx].kind = R_STR
            pos = self._str_end(pos)
        elif c == 116:
            self.nodes[idx].kind = R_BOOL
            pos += 4
        elif c == 102:
            self.nodes[idx].kind = R_BOOL
            pos += 5
        elif c == 110:
            pos += 4
        else:
            self.nodes[idx].kind = R_NUM
            while pos < len(self.src):
                var d = self.src[pos]
                if (d >= 48 and d <= 57) or d == 45 or d == 43 or d == 46 or d == 101 or d == 69:
                    pos += 1
                else:
                    break
        self.nodes[idx].end = pos
        return idx

    def root(self) -> Int:
        return 0

    def kind(self, n: Int) -> Int:
        return self.nodes[n].kind

    def raw(self, n: Int) -> String:
        var nd = self.nodes[n]
        return String(unsafe_from_utf8=Span(self.src)[nd.start : nd.end])

    def is_true(self, n: Int) -> Bool:
        return self.nodes[n].kind == R_BOOL and self.src[self.nodes[n].start] == 116

    def text(self, n: Int) -> String:
        """Decoded string value (encoding/json unquote: invalid UTF-8 / lone surrogates -> U+FFFD)."""
        var nd = self.nodes[n]
        return _unquote(Span(self.src)[nd.start : nd.end])

    def key(self, n: Int) -> String:
        var nd = self.nodes[n]
        if nd.key_start < 0:
            return ""
        return _unquote(Span(self.src)[nd.key_start : nd.key_end])

    def children(self, n: Int) -> List[Int]:
        var out = List[Int]()
        var c = self.nodes[n].first
        while c >= 0:
            out.append(c)
            c = self.nodes[c].next
        return out^

    def field(self, obj: Int, name: String) -> Int:
        """encoding/json field match: last key equal to name exactly or ASCII-case-folded."""
        if obj < 0 or self.nodes[obj].kind != R_OBJ:
            return -1
        var lname = name.lower()
        var found = -1
        var c = self.nodes[obj].first
        while c >= 0:
            var k = self.key(c)
            if k == name or k.lower() == lname:
                found = c
            c = self.nodes[c].next
        return found

    def get(self, obj: Int, name: String) -> Int:
        """Exact-key lookup, last occurrence wins (Python dict / Go map semantics)."""
        if obj < 0 or self.nodes[obj].kind != R_OBJ:
            return -1
        var found = -1
        var c = self.nodes[obj].first
        while c >= 0:
            if self.key(c) == name:
                found = c
            c = self.nodes[c].next
        return found


def _hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    return Int(c) - 55


def _append_utf8(mut out: List[UInt8], r: Int):
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


def _utf8_len(b: Span[UInt8, _], i: Int) -> Int:
    """Length of a valid UTF-8 sequence at i, or 0 when invalid."""
    var c = b[i]
    var n = len(b)
    if c < 0x80:
        return 1
    if c >= 0xC2 and c <= 0xDF:
        if i + 1 < n and (b[i + 1] & 0xC0) == 0x80:
            return 2
        return 0
    if c >= 0xE0 and c <= 0xEF:
        if i + 2 < n and (b[i + 1] & 0xC0) == 0x80 and (b[i + 2] & 0xC0) == 0x80:
            if c == 0xE0 and b[i + 1] < 0xA0:
                return 0
            if c == 0xED and b[i + 1] > 0x9F:
                return 0
            return 3
        return 0
    if c >= 0xF0 and c <= 0xF4:
        if i + 3 < n and (b[i + 1] & 0xC0) == 0x80 and (b[i + 2] & 0xC0) == 0x80 and (b[i + 3] & 0xC0) == 0x80:
            if c == 0xF0 and b[i + 1] < 0x90:
                return 0
            if c == 0xF4 and b[i + 1] > 0x8F:
                return 0
            return 4
        return 0
    return 0


def _unquote(b: Span[UInt8, _]) -> String:
    var out = List[UInt8]()
    var i = 1
    var end = len(b) - 1
    while i < end:
        var c = b[i]
        if c == 92:
            var e = b[i + 1]
            if e == 117:
                var r = (_hexval(b[i + 2]) << 12) | (_hexval(b[i + 3]) << 8) | (_hexval(b[i + 4]) << 4) | _hexval(b[i + 5])
                i += 6
                if r >= 0xD800 and r < 0xDC00:
                    if i + 5 < end + 1 and b[i] == 92 and b[i + 1] == 117:
                        var r2 = (_hexval(b[i + 2]) << 12) | (_hexval(b[i + 3]) << 8) | (_hexval(b[i + 4]) << 4) | _hexval(b[i + 5])
                        if r2 >= 0xDC00 and r2 < 0xE000:
                            _append_utf8(out, 0x10000 + ((r - 0xD800) << 10) + (r2 - 0xDC00))
                            i += 6
                            continue
                    _append_utf8(out, 0xFFFD)
                    continue
                if r >= 0xDC00 and r < 0xE000:
                    _append_utf8(out, 0xFFFD)
                    continue
                _append_utf8(out, r)
                continue
            if e == 98:
                out.append(8)
            elif e == 102:
                out.append(12)
            elif e == 110:
                out.append(10)
            elif e == 114:
                out.append(13)
            elif e == 116:
                out.append(9)
            else:
                out.append(e)
            i += 2
            continue
        var w = _utf8_len(b, i)
        if w == 0:
            _append_utf8(out, 0xFFFD)
            i += 1
            continue
        for k in range(w):
            out.append(b[i + k])
        i += w
    return String(unsafe_from_utf8=out)
