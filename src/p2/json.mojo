"""Minimal JSON reader (arena of nodes) for weights, margin and metadata files.

Numbers are converted with the stdlib's correctly-rounded parser so weights
round-trip to the same float64 bits as Go's encoding/json.
"""

from p2.gomath import is_finite

comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUM = 2
comptime J_STR = 3
comptime J_ARR = 4
comptime J_OBJ = 5


@fieldwise_init
struct JNode(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var num: Float64
    var str_start: Int
    var str_len: Int
    var first_child: Int
    var next_sibling: Int
    var key_start: Int
    var key_len: Int
    var count: Int


struct Json(Movable):
    var src: List[UInt8]
    var nodes: List[JNode]
    var strings: List[UInt8]

    def __init__(out self, var src: List[UInt8]) raises:
        self.src = src^
        self.nodes = List[JNode]()
        self.strings = List[UInt8]()
        var pos = 0
        _ = self._parse_value(pos)
        self._skip_ws(pos)
        if pos != len(self.src):
            raise Error("json: trailing data at byte " + String(pos))

    @staticmethod
    def from_file(path: String) raises -> Json:
        var f = open(path, "r")
        var data = f.read_bytes()
        f.close()
        return Json(data^)

    def _skip_ws(self, mut pos: Int):
        while pos < len(self.src):
            var c = self.src[pos]
            if c == 32 or c == 9 or c == 10 or c == 13:
                pos += 1
            else:
                break

    def _new(mut self, kind: Int) -> Int:
        self.nodes.append(JNode(kind, 0.0, 0, 0, -1, -1, 0, 0, 0))
        return len(self.nodes) - 1

    def _peek(self, pos: Int) raises -> UInt8:
        if pos < 0 or pos >= len(self.src):
            raise Error("json: unexpected end")
        return self.src[pos]

    def _hex4(self, pos: Int) raises -> Int:
        var cp = 0
        for k in range(4):
            var h = Int(self._peek(pos+k))
            var d: Int
            if h >= 48 and h <= 57:
                d = h-48
            elif h >= 97 and h <= 102:
                d = h-87
            elif h >= 65 and h <= 70:
                d = h-55
            else:
                raise Error("json: invalid unicode escape")
            cp = cp*16+d
        return cp

    def _parse_string_into(mut self, mut pos: Int) raises -> Tuple[Int, Int]:
        if self._peek(pos) != 34:
            raise Error("json: expected string at byte " + String(pos))
        pos += 1
        var start = len(self.strings)
        while True:
            if pos >= len(self.src):
                raise Error("json: unterminated string")
            var c = self.src[pos]
            if c == 34:
                pos += 1
                break
            if c == 92:
                pos += 1
                var e = self._peek(pos)
                if e == 110:
                    self.strings.append(10)
                elif e == 116:
                    self.strings.append(9)
                elif e == 114:
                    self.strings.append(13)
                elif e == 98:
                    self.strings.append(8)
                elif e == 102:
                    self.strings.append(12)
                elif e == 117:
                    var cp = self._hex4(pos+1)
                    pos += 4
                    if cp >= 0xD800 and cp <= 0xDBFF:
                        if self._peek(pos+1) != 92 or self._peek(pos+2) != 117:
                            raise Error("json: missing low surrogate")
                        var low = self._hex4(pos+3)
                        if low < 0xDC00 or low > 0xDFFF:
                            raise Error("json: invalid low surrogate")
                        cp = 0x10000 + ((cp-0xD800) << 10) + low-0xDC00
                        pos += 6
                    elif cp >= 0xDC00 and cp <= 0xDFFF:
                        raise Error("json: unpaired low surrogate")
                    if cp < 0x80:
                        self.strings.append(UInt8(cp))
                    elif cp < 0x800:
                        self.strings.append(UInt8(0xC0 | (cp >> 6)))
                        self.strings.append(UInt8(0x80 | (cp & 0x3F)))
                    elif cp < 0x10000:
                        self.strings.append(UInt8(0xE0 | (cp >> 12)))
                        self.strings.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
                        self.strings.append(UInt8(0x80 | (cp & 0x3F)))
                    else:
                        self.strings.append(UInt8(0xF0 | (cp >> 18)))
                        self.strings.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
                        self.strings.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
                        self.strings.append(UInt8(0x80 | (cp & 0x3F)))
                elif e == 34 or e == 92 or e == 47:
                    self.strings.append(e)
                else:
                    raise Error("json: invalid escape")
                pos += 1
                continue
            if c < 32:
                raise Error("json: unescaped control character")
            self.strings.append(c)
            pos += 1
        return (start, len(self.strings) - start)

    def _parse_value(mut self, mut pos: Int, depth: Int = 0) raises -> Int:
        if depth > 128:
            raise Error("json: nesting limit exceeded")
        self._skip_ws(pos)
        if pos >= len(self.src):
            raise Error("json: unexpected end")
        var c = self.src[pos]
        if c == 123:
            var idx = self._new(J_OBJ)
            pos += 1
            self._skip_ws(pos)
            if self._peek(pos) == 125:
                pos += 1
                return idx
            var last = -1
            while True:
                self._skip_ws(pos)
                var kk = self._parse_string_into(pos)
                var ks = kk[0]
                var kl = kk[1]
                var new_key = String(unsafe_from_utf8=Span(self.strings)[ks:ks+kl])
                for previous in self.children(idx):
                    if self.key(previous) == new_key:
                        raise Error("json: duplicate key: " + new_key)
                self._skip_ws(pos)
                if self._peek(pos) != 58:
                    raise Error("json: expected ':' at byte " + String(pos))
                pos += 1
                var child = self._parse_value(pos, depth+1)
                self.nodes[child].key_start = ks
                self.nodes[child].key_len = kl
                if last < 0:
                    self.nodes[idx].first_child = child
                else:
                    self.nodes[last].next_sibling = child
                last = child
                self.nodes[idx].count += 1
                self._skip_ws(pos)
                if self._peek(pos) == 44:
                    pos += 1
                    continue
                if self._peek(pos) == 125:
                    pos += 1
                    break
                raise Error("json: expected ',' or '}' at byte " + String(pos))
            return idx
        if c == 91:
            var idx = self._new(J_ARR)
            pos += 1
            self._skip_ws(pos)
            if self._peek(pos) == 93:
                pos += 1
                return idx
            var last = -1
            while True:
                var child = self._parse_value(pos, depth+1)
                if last < 0:
                    self.nodes[idx].first_child = child
                else:
                    self.nodes[last].next_sibling = child
                last = child
                self.nodes[idx].count += 1
                self._skip_ws(pos)
                if self._peek(pos) == 44:
                    pos += 1
                    continue
                if self._peek(pos) == 93:
                    pos += 1
                    break
                raise Error("json: expected ',' or ']' at byte " + String(pos))
            return idx
        if c == 34:
            var idx = self._new(J_STR)
            var sl = self._parse_string_into(pos)
            self.nodes[idx].str_start = sl[0]
            self.nodes[idx].str_len = sl[1]
            return idx
        if c == 116:
            if pos+4 > len(self.src) or String(unsafe_from_utf8=Span(self.src)[pos:pos+4]) != "true":
                raise Error("json: invalid literal")
            pos += 4
            var idx = self._new(J_BOOL)
            self.nodes[idx].num = 1.0
            return idx
        if c == 102:
            if pos+5 > len(self.src) or String(unsafe_from_utf8=Span(self.src)[pos:pos+5]) != "false":
                raise Error("json: invalid literal")
            pos += 5
            return self._new(J_BOOL)
        if c == 110:
            if pos+4 > len(self.src) or String(unsafe_from_utf8=Span(self.src)[pos:pos+4]) != "null":
                raise Error("json: invalid literal")
            pos += 4
            return self._new(J_NULL)
        var start = pos
        while pos < len(self.src):
            var d = self.src[pos]
            if (d >= 48 and d <= 57) or d == 45 or d == 43 or d == 46 or d == 101 or d == 69:
                pos += 1
            else:
                break
        if pos == start:
            raise Error("json: unexpected byte " + String(Int(c)) + " at " + String(start))
        var p = start
        if self.src[p] == 45:
            p += 1
        if p >= pos or self.src[p] < 48 or self.src[p] > 57:
            raise Error("json: invalid number")
        if self.src[p] == 48:
            p += 1
        else:
            while p < pos and self.src[p] >= 48 and self.src[p] <= 57:
                p += 1
        if p < pos and self.src[p] == 46:
            p += 1
            var begin = p
            while p < pos and self.src[p] >= 48 and self.src[p] <= 57:
                p += 1
            if p == begin:
                raise Error("json: invalid fraction")
        if p < pos and (self.src[p] == 101 or self.src[p] == 69):
            p += 1
            if p < pos and (self.src[p] == 43 or self.src[p] == 45):
                p += 1
            var begin = p
            while p < pos and self.src[p] >= 48 and self.src[p] <= 57:
                p += 1
            if p == begin:
                raise Error("json: invalid exponent")
        if p != pos:
            raise Error("json: invalid number syntax")
        var text = String(unsafe_from_utf8=Span(self.src)[start:pos])
        var idx = self._new(J_NUM)
        self.nodes[idx].num = atof(text)
        if not is_finite(self.nodes[idx].num):
            raise Error("json: number outside finite float64 range")
        return idx

    def root(self) -> Int:
        return 0

    def kind(self, n: Int) -> Int:
        return self.nodes[n].kind

    def text(self, n: Int) -> String:
        var nd = self.nodes[n]
        return String(unsafe_from_utf8=Span(self.strings)[nd.str_start : nd.str_start + nd.str_len])

    def key(self, n: Int) -> String:
        var nd = self.nodes[n]
        return String(unsafe_from_utf8=Span(self.strings)[nd.key_start : nd.key_start + nd.key_len])

    def num(self, n: Int) -> Float64:
        return self.nodes[n].num

    def children(self, n: Int) -> List[Int]:
        var out = List[Int]()
        if n < 0 or n >= len(self.nodes):
            return out^
        var c = self.nodes[n].first_child
        while c >= 0:
            out.append(c)
            c = self.nodes[c].next_sibling
        return out^

    def get(self, n: Int, key: String) -> Int:
        if n < 0 or n >= len(self.nodes) or self.nodes[n].kind != J_OBJ:
            return -1
        var c = self.nodes[n].first_child
        while c >= 0:
            if self.key(c) == key:
                return c
            c = self.nodes[c].next_sibling
        return -1

    def float_list(self, n: Int) raises -> List[Float64]:
        var out = List[Float64]()
        if n < 0 or self.nodes[n].kind != J_ARR:
            raise Error("json: expected numeric array")
        for c in self.children(n):
            if self.nodes[c].kind != J_NUM:
                raise Error("json: expected number in array")
            out.append(self.nodes[c].num)
        return out^

    def string_list(self, n: Int) raises -> List[String]:
        var out = List[String]()
        if n < 0 or self.nodes[n].kind != J_ARR:
            raise Error("json: expected string array")
        for c in self.children(n):
            if self.nodes[c].kind != J_STR:
                raise Error("json: expected string in array")
            out.append(self.text(c))
        return out^
