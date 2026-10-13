"""Go-exact strconv / fmt / encoding/json scalar formatting and parsing.

Ports of Go 1.23 strconv: the multiprecision `decimal` (decimal.go), bigFtoa +
roundShortest + fmtE/fmtF (ftoa.go), readFloat/atof64exact/decimal.floatBits/
atofHex (atof.go), ParseInt/Atoi (atoi.go) and Quote (quote.go, IsPrint tables
generated from Go by tools/gen_isprint). Go's optimized paths (Ryu, Eisel-Lemire)
are proven equal to these exact paths, so results are bit-identical.

API:
  go_format_float(x, fmt, prec)  strconv.FormatFloat(x, fmt, prec, 64), fmt in "efgEG"
  go_fmt_v_float(x)              fmt %v / %g of a float64
  go_fmt_e(x, prec), go_fmt_g(x, prec), go_fmt_f(x, prec)
  go_quote(s), go_quote_bytes(b) strconv.Quote / fmt %q
  json_float(x), json_quote(s)   encoding/json scalar encoding (HTML-escaped)
  JC                             compact json.Marshal builder (sorted keys are the caller's job:
                                 use go_sort_strings for map[string]T)
  go_parse_float(s) -> GoFloat   strconv.ParseFloat(s, 64): value, ok, range_err
  go_parse_int(s) -> GoInt       strconv.ParseInt(s, 10, 64) (== Atoi values)
"""

from p2.gomath import f64_bits, f64_from_bits, nan64
from p2.isprint_tables import ISPRINT_RANGES
from p2.eisel_lemire_tables import POW10_MIN_EXP10, POW10_MAX_EXP10, POW10_TABLE
from std.bit import count_leading_zeros

comptime DEC_CAP = 800
comptime MAX_SHIFT = 60
comptime LOWERHEX = "0123456789abcdef"

comptime CHEAT_DELTA: Array[Int, 61] = [
    0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10,
    10, 10, 10, 11, 11, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 15, 15, 15, 16, 16, 16, 16, 17,
    17, 17, 18, 18, 18, 19,
]


def _cheat_cutoff(k: Int) -> List[UInt8]:
    """Decimal digits of 5^k (Go leftcheats[k].cutoff), k <= 60."""
    var d = List[UInt8]()
    if k == 0:
        return d^
    d.append(1)
    for _ in range(k):
        var carry = 0
        for i in range(len(d) - 1, -1, -1):
            var v = Int(d[i]) * 5 + carry
            d[i] = UInt8(v % 10)
            carry = v // 10
        while carry > 0:
            d.insert(0, UInt8(carry % 10))
            carry //= 10
    for i in range(len(d)):
        d[i] += 48
    return d^


struct _Cheats(Movable):
    """Lazily built leftcheats cutoffs (5^k digits)."""

    var cut: List[List[UInt8]]
    var have: List[Bool]

    def __init__(out self):
        self.cut = List[List[UInt8]]()
        self.have = List[Bool](length=MAX_SHIFT + 1, fill=False)
        for _ in range(MAX_SHIFT + 1):
            self.cut.append(List[UInt8]())

    def get(mut self, k: Int):
        if not self.have[k]:
            self.cut[k] = _cheat_cutoff(k)
            self.have[k] = True


struct Decimal(Movable):
    """Go strconv.decimal: up to 800 ASCII digits, decimal point dp, trunc flag."""

    var d: List[UInt8]
    var nd: Int
    var dp: Int
    var neg: Bool
    var trunc: Bool

    def __init__(out self):
        self.d = List[UInt8](length=DEC_CAP, fill=48)
        self.nd = 0
        self.dp = 0
        self.neg = False
        self.trunc = False

    def trim(mut self):
        while self.nd > 0 and self.d[self.nd - 1] == 48:
            self.nd -= 1
        if self.nd == 0:
            self.dp = 0

    def assign(mut self, v_in: UInt64):
        var buf = List[UInt8]()
        var v = v_in
        while v > 0:
            var v1 = v // 10
            buf.append(UInt8(v - 10 * v1) + 48)
            v = v1
        self.nd = 0
        for i in range(len(buf) - 1, -1, -1):
            self.d[self.nd] = buf[i]
            self.nd += 1
        self.dp = self.nd
        self.trim()

    def _right_shift(mut self, k: Int):
        var r = 0
        var w = 0
        var n: UInt64 = 0
        var kk = UInt64(k)
        while (n >> kk) == 0:
            if r >= self.nd:
                if n == 0:
                    self.nd = 0
                    return
                while (n >> kk) == 0:
                    n = n * 10
                    r += 1
                break
            var c = UInt64(self.d[r])
            n = n * 10 + c - 48
            r += 1
        self.dp -= r - 1
        var mask: UInt64 = (UInt64(1) << kk) - 1
        while r < self.nd:
            var c = UInt64(self.d[r])
            var dig = n >> kk
            n &= mask
            self.d[w] = UInt8(dig + 48)
            w += 1
            n = n * 10 + c - 48
            r += 1
        while n > 0:
            var dig = n >> kk
            n &= mask
            if w < DEC_CAP:
                self.d[w] = UInt8(dig + 48)
                w += 1
            elif dig > 0:
                self.trunc = True
            n = n * 10
        self.nd = w
        self.trim()

    def _left_shift(mut self, k: Int, mut cheats: _Cheats):
        var delta = materialize[CHEAT_DELTA]()[k]
        cheats.get(k)
        ref cut = cheats.cut[k]
        var less = False
        for i in range(len(cut)):
            if i >= self.nd:
                less = True
                break
            if self.d[i] != cut[i]:
                less = self.d[i] < cut[i]
                break
        if less:
            delta -= 1
        var r = self.nd
        var w = self.nd + delta
        var n: UInt64 = 0
        var kk = UInt64(k)
        r -= 1
        while r >= 0:
            n += (UInt64(self.d[r]) - 48) << kk
            var quo = n // 10
            var rem = n - 10 * quo
            w -= 1
            if w < DEC_CAP:
                self.d[w] = UInt8(rem + 48)
            elif rem != 0:
                self.trunc = True
            n = quo
            r -= 1
        while n > 0:
            var quo = n // 10
            var rem = n - 10 * quo
            w -= 1
            if w < DEC_CAP:
                self.d[w] = UInt8(rem + 48)
            elif rem != 0:
                self.trunc = True
            n = quo
        self.nd += delta
        if self.nd >= DEC_CAP:
            self.nd = DEC_CAP
        self.dp += delta
        self.trim()

    def shift(mut self, k_in: Int, mut cheats: _Cheats):
        var k = k_in
        if self.nd == 0:
            return
        if k > 0:
            while k > MAX_SHIFT:
                self._left_shift(MAX_SHIFT, cheats)
                k -= MAX_SHIFT
            self._left_shift(k, cheats)
        elif k < 0:
            while k < -MAX_SHIFT:
                self._right_shift(MAX_SHIFT)
                k += MAX_SHIFT
            self._right_shift(-k)

    def should_round_up(self, nd: Int) -> Bool:
        if nd < 0 or nd >= self.nd:
            return False
        if self.d[nd] == 53 and nd + 1 == self.nd:
            if self.trunc:
                return True
            return nd > 0 and (Int(self.d[nd - 1]) - 48) % 2 != 0
        return self.d[nd] >= 53

    def round(mut self, nd: Int):
        if nd < 0 or nd >= self.nd:
            return
        if self.should_round_up(nd):
            self.round_up(nd)
        else:
            self.round_down(nd)

    def round_down(mut self, nd: Int):
        if nd < 0 or nd >= self.nd:
            return
        self.nd = nd
        self.trim()

    def round_up(mut self, nd: Int):
        if nd < 0 or nd >= self.nd:
            return
        for i in range(nd - 1, -1, -1):
            if self.d[i] < 57:
                self.d[i] += 1
                self.nd = i + 1
                return
        self.d[0] = 49
        self.nd = 1
        self.dp += 1

    def rounded_integer(self) -> UInt64:
        if self.dp > 20:
            return UInt64.MAX
        var i = 0
        var n: UInt64 = 0
        while i < self.dp and i < self.nd:
            n = n * 10 + UInt64(self.d[i] - 48)
            i += 1
        while i < self.dp:
            n *= 10
            i += 1
        if self.should_round_up(self.dp):
            n += 1
        return n


# ---------------------------------------------------------------- ftoa


def _round_shortest(mut d: Decimal, mant: UInt64, exp: Int, mut cheats: _Cheats):
    if mant == 0:
        d.nd = 0
        return
    var minexp = -1022
    if exp > minexp and 332 * (d.dp - d.nd) >= 100 * (exp - 52):
        return
    var upper = Decimal()
    upper.assign(mant * 2 + 1)
    upper.shift(exp - 52 - 1, cheats)
    var mantlo: UInt64
    var explo: Int
    if mant > (UInt64(1) << 52) or exp == minexp:
        mantlo = mant - 1
        explo = exp
    else:
        mantlo = mant * 2 - 1
        explo = exp - 1
    var lower = Decimal()
    lower.assign(mantlo * 2 + 1)
    lower.shift(explo - 52 - 1, cheats)
    var inclusive = mant % 2 == 0
    var upperdelta = 0
    var ui = 0
    while True:
        var mi = ui - upper.dp + d.dp
        if mi >= d.nd:
            break
        var li = ui - upper.dp + lower.dp
        var l = UInt8(48)
        if li >= 0 and li < lower.nd:
            l = lower.d[li]
        var m = UInt8(48)
        if mi >= 0:
            m = d.d[mi]
        var u = UInt8(48)
        if ui < upper.nd:
            u = upper.d[ui]
        var okdown = l != m or (inclusive and li + 1 == lower.nd)
        if upperdelta == 0 and m + 1 < u:
            upperdelta = 2
        elif upperdelta == 0 and m != u:
            upperdelta = 1
        elif upperdelta == 1 and (m != 57 or u != 48):
            upperdelta = 2
        var okup = upperdelta > 0 and (inclusive or upperdelta > 1 or ui + 1 < upper.nd)
        if okdown and okup:
            d.round(mi + 1)
            return
        elif okdown:
            d.round_down(mi + 1)
            return
        elif okup:
            d.round_up(mi + 1)
            return
        ui += 1


def _fmt_e(mut dst: List[UInt8], neg: Bool, d: Decimal, prec: Int, fmt: UInt8):
    if neg:
        dst.append(45)
    var ch = UInt8(48)
    if d.nd != 0:
        ch = d.d[0]
    dst.append(ch)
    if prec > 0:
        dst.append(46)
        var i = 1
        var m = min(d.nd, prec + 1)
        while i < m:
            dst.append(d.d[i])
            i += 1
        while i <= prec:
            dst.append(48)
            i += 1
    dst.append(fmt)
    var exp = d.dp - 1
    if d.nd == 0:
        exp = 0
    if exp < 0:
        dst.append(45)
        exp = -exp
    else:
        dst.append(43)
    if exp < 10:
        dst.append(48)
        dst.append(UInt8(exp) + 48)
    elif exp < 100:
        dst.append(UInt8(exp // 10) + 48)
        dst.append(UInt8(exp % 10) + 48)
    else:
        dst.append(UInt8(exp // 100) + 48)
        dst.append(UInt8((exp // 10) % 10) + 48)
        dst.append(UInt8(exp % 10) + 48)


def _fmt_f(mut dst: List[UInt8], neg: Bool, d: Decimal, prec: Int):
    if neg:
        dst.append(45)
    if d.dp > 0:
        var m = min(d.nd, d.dp)
        for i in range(m):
            dst.append(d.d[i])
        while m < d.dp:
            dst.append(48)
            m += 1
    else:
        dst.append(48)
    if prec > 0:
        dst.append(46)
        for i in range(prec):
            var ch = UInt8(48)
            var j = d.dp + i
            if 0 <= j and j < d.nd:
                ch = d.d[j]
            dst.append(ch)


def _bytes_str(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=b)


def go_format_float(x: Float64, fmt_s: String, prec_in: Int) -> String:
    """strconv.FormatFloat(x, fmt, prec, 64) for fmt in e, E, f, g, G."""
    var fmt = fmt_s.as_bytes()[0]
    var bits = f64_bits(x)
    var neg = (bits >> 63) != 0
    var exp = Int((bits >> 52) & 0x7FF)
    var mant = bits & ((UInt64(1) << 52) - 1)
    if exp == 0x7FF:
        if mant != 0:
            return "NaN"
        if neg:
            return "-Inf"
        return "+Inf"
    if exp == 0:
        exp += 1
    else:
        mant |= UInt64(1) << 52
    exp += -1023
    var cheats = _Cheats()
    var d = Decimal()
    d.assign(mant)
    d.shift(exp - 52, cheats)
    var prec = prec_in
    var shortest = prec < 0
    if shortest:
        _round_shortest(d, mant, exp, cheats)
        if fmt == 101 or fmt == 69:
            prec = d.nd - 1
        elif fmt == 102:
            prec = max(d.nd - d.dp, 0)
        else:
            prec = d.nd
    else:
        if fmt == 101 or fmt == 69:
            d.round(prec + 1)
        elif fmt == 102:
            d.round(d.dp + prec)
        else:
            if prec == 0:
                prec = 1
            d.round(prec)
    var out = List[UInt8](capacity=32)
    if fmt == 101 or fmt == 69:
        _fmt_e(out, neg, d, prec, fmt)
    elif fmt == 102:
        _fmt_f(out, neg, d, prec)
    else:
        var eprec = prec
        if eprec > d.nd and d.nd >= d.dp:
            eprec = d.nd
        if shortest:
            eprec = 6
        var e = d.dp - 1
        if e < -4 or e >= eprec:
            if prec > d.nd:
                prec = d.nd
            _fmt_e(out, neg, d, prec - 1, fmt + 101 - 103)
        else:
            if prec > d.dp:
                prec = d.nd
            _fmt_f(out, neg, d, max(prec - d.dp, 0))
    return _bytes_str(out)


def go_fmt_v_float(x: Float64) -> String:
    """fmt %v (== %g) of a float64."""
    return go_format_float(x, "g", -1)


def go_fmt_g(x: Float64, prec: Int) -> String:
    return go_format_float(x, "g", prec)


def go_fmt_e(x: Float64, prec: Int) -> String:
    return go_format_float(x, "e", prec)


def go_fmt_f(x: Float64, prec: Int) -> String:
    """fmt %.Nf (prec >= 0) or strconv 'f' -1 (prec < 0)."""
    return go_format_float(x, "f", prec)


# ---------------------------------------------------------------- utf8 / quote


@fieldwise_init
struct Rune(Copyable, ImplicitlyCopyable, Movable):
    var r: Int
    var width: Int


def decode_rune(b: Span[UInt8, _], i: Int) -> Rune:
    """utf8.DecodeRune on b[i:]: (0xFFFD, 1) for invalid encodings."""
    var n = len(b) - i
    var c0 = Int(b[i])
    if c0 < 0x80:
        return Rune(c0, 1)
    if c0 < 0xC2 or c0 > 0xF4:
        return Rune(0xFFFD, 1)
    if c0 < 0xE0:
        if n < 2:
            return Rune(0xFFFD, 1)
        var c1 = Int(b[i + 1])
        if c1 < 0x80 or c1 > 0xBF:
            return Rune(0xFFFD, 1)
        return Rune(((c0 & 0x1F) << 6) | (c1 & 0x3F), 2)
    var lo = 0x80
    var hi = 0xBF
    if c0 == 0xE0:
        lo = 0xA0
    elif c0 == 0xED:
        hi = 0x9F
    elif c0 == 0xF0:
        lo = 0x90
    elif c0 == 0xF4:
        hi = 0x8F
    if n < 2:
        return Rune(0xFFFD, 1)
    var c1 = Int(b[i + 1])
    if c1 < lo or c1 > hi:
        return Rune(0xFFFD, 1)
    if n < 3:
        return Rune(0xFFFD, 1)
    var c2 = Int(b[i + 2])
    if c2 < 0x80 or c2 > 0xBF:
        return Rune(0xFFFD, 1)
    if c0 < 0xF0:
        return Rune(((c0 & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F), 3)
    if n < 4:
        return Rune(0xFFFD, 1)
    var c3 = Int(b[i + 3])
    if c3 < 0x80 or c3 > 0xBF:
        return Rune(0xFFFD, 1)
    return Rune(((c0 & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F), 4)


def go_is_print(r: Int) -> Bool:
    """strconv.IsPrint (== unicode.IsPrint)."""
    if r < 0x80:
        return r >= 0x20 and r < 0x7F
    var t = materialize[ISPRINT_RANGES]()
    var lo = 0
    var hi = len(t) // 2
    while lo < hi:
        var mid = (lo + hi) // 2
        if Int(t[2 * mid + 1]) < r:
            lo = mid + 1
        else:
            hi = mid
    return lo < len(t) // 2 and Int(t[2 * lo]) <= r


def _append_hex(mut dst: List[UInt8], v: Int, digits: Int):
    var hx = LOWERHEX.as_bytes()
    for s in range((digits - 1) * 4, -1, -4):
        dst.append(hx[(v >> s) & 0xF])


def _append_rune(mut dst: List[UInt8], r: Int):
    if r < 0x80:
        dst.append(UInt8(r))
    elif r < 0x800:
        dst.append(UInt8(0xC0 | (r >> 6)))
        dst.append(UInt8(0x80 | (r & 0x3F)))
    elif r < 0x10000:
        dst.append(UInt8(0xE0 | (r >> 12)))
        dst.append(UInt8(0x80 | ((r >> 6) & 0x3F)))
        dst.append(UInt8(0x80 | (r & 0x3F)))
    else:
        dst.append(UInt8(0xF0 | (r >> 18)))
        dst.append(UInt8(0x80 | ((r >> 12) & 0x3F)))
        dst.append(UInt8(0x80 | ((r >> 6) & 0x3F)))
        dst.append(UInt8(0x80 | (r & 0x3F)))


def go_quote_bytes(b: Span[UInt8, _]) -> String:
    """strconv.Quote over raw bytes (invalid UTF-8 bytes become \\xNN)."""
    var out = List[UInt8](capacity=len(b) + 2)
    out.append(34)
    var i = 0
    var hx = LOWERHEX.as_bytes()
    while i < len(b):
        var ru = decode_rune(b, i)
        var r = ru.r
        if ru.width == 1 and r == 0xFFFD:
            out.append(92)
            out.append(120)
            out.append(hx[Int(b[i]) >> 4])
            out.append(hx[Int(b[i]) & 0xF])
            i += 1
            continue
        i += ru.width
        if r == 34 or r == 92:
            out.append(92)
            out.append(UInt8(r))
            continue
        if go_is_print(r):
            _append_rune(out, r)
            continue
        out.append(92)
        if r == 7:
            out.append(97)
        elif r == 8:
            out.append(98)
        elif r == 12:
            out.append(102)
        elif r == 10:
            out.append(110)
        elif r == 13:
            out.append(114)
        elif r == 9:
            out.append(116)
        elif r == 11:
            out.append(118)
        elif r < 0x20 or r == 0x7F:
            out.append(120)
            _append_hex(out, r, 2)
        elif r < 0x10000:
            out.append(117)
            _append_hex(out, r, 4)
        else:
            out.append(85)
            _append_hex(out, r, 8)
    out.append(34)
    return _bytes_str(out)


def go_quote(s: String) -> String:
    """strconv.Quote / fmt %q."""
    return go_quote_bytes(s.as_bytes())


# ---------------------------------------------------------------- encoding/json


def json_float(x: Float64) -> String:
    """encoding/json float64 encoding. Go errors on NaN/Inf; this returns "null" for them."""
    var bits = f64_bits(x)
    if ((bits >> 52) & 0x7FF) == 0x7FF:
        return "null"
    var a = abs(x)
    var use_e = a != 0 and (a < 1e-6 or a >= 1e21)
    var s = go_format_float(x, "e" if use_e else "f", -1)
    if use_e:
        var b = s.as_bytes()
        var n = len(b)
        if n >= 4 and b[n - 4] == 101 and b[n - 3] == 45 and b[n - 2] == 48:
            return String(s[byte = 0 : n - 2]) + String(s[byte = n - 1 :])
    return s


def json_quote_bytes(b: Span[UInt8, _]) -> String:
    """encoding/json string encoding with HTML escaping (json.Marshal default)."""
    var out = List[UInt8](capacity=len(b) + 2)
    out.append(34)
    var i = 0
    while i < len(b):
        var c = b[i]
        if c < 0x80:
            if c >= 0x20 and c != 34 and c != 92 and c != 60 and c != 62 and c != 38:
                out.append(c)
            elif c == 34 or c == 92:
                out.append(92)
                out.append(c)
            elif c == 8:
                out.append(92)
                out.append(98)
            elif c == 12:
                out.append(92)
                out.append(102)
            elif c == 10:
                out.append(92)
                out.append(110)
            elif c == 13:
                out.append(92)
                out.append(114)
            elif c == 9:
                out.append(92)
                out.append(116)
            else:
                out.append(92)
                out.append(117)
                _append_hex(out, Int(c), 4)
            i += 1
            continue
        var ru = decode_rune(b, i)
        if ru.r == 0xFFFD and ru.width == 1:
            out.append(92)
            out.append(117)
            _append_hex(out, 0xFFFD, 4)
            i += 1
            continue
        if ru.r == 0x2028 or ru.r == 0x2029:
            out.append(92)
            out.append(117)
            _append_hex(out, ru.r, 4)
            i += ru.width
            continue
        for k in range(ru.width):
            out.append(b[i + k])
        i += ru.width
    out.append(34)
    return _bytes_str(out)


def json_quote(s: String) -> String:
    return json_quote_bytes(s.as_bytes())


def go_sort_strings(mut v: List[String]):
    """sort.Strings (byte-wise order), as encoding/json uses for map keys."""
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x


struct JC(Movable):
    """Compact json.Marshal builder. Struct fields in declaration order; the *_omit
    helpers implement `omitempty` (skip "", false, 0, empty)."""

    var buf: String
    var first: List[Bool]
    var pending_key: Bool

    def __init__(out self):
        self.buf = String("")
        self.first = List[Bool]()
        self.pending_key = False

    def _item(mut self):
        if self.pending_key:
            self.pending_key = False
            return
        if len(self.first) > 0:
            if not self.first[len(self.first) - 1]:
                self.buf += ","
            self.first[len(self.first) - 1] = False

    def key(mut self, k: String):
        self._item()
        self.buf += json_quote(k) + ":"
        self.pending_key = True

    def begin_obj(mut self):
        self._item()
        self.buf += "{"
        self.first.append(True)

    def end_obj(mut self):
        _ = self.first.pop()
        self.buf += "}"

    def begin_arr(mut self):
        self._item()
        self.buf += "["
        self.first.append(True)

    def end_arr(mut self):
        _ = self.first.pop()
        self.buf += "]"

    def str(mut self, s: String):
        self._item()
        self.buf += json_quote(s)

    def num(mut self, x: Float64):
        self._item()
        self.buf += json_float(x)

    def int(mut self, x: Int):
        self._item()
        self.buf += String(x)

    def bool(mut self, b: Bool):
        self._item()
        self.buf += "true" if b else "false"

    def null(mut self):
        self._item()
        self.buf += "null"

    def raw(mut self, s: String):
        self._item()
        self.buf += s

    def kv_str(mut self, k: String, v: String):
        self.key(k)
        self.str(v)

    def kv_num(mut self, k: String, v: Float64):
        self.key(k)
        self.num(v)

    def kv_int(mut self, k: String, v: Int):
        self.key(k)
        self.int(v)

    def kv_bool(mut self, k: String, v: Bool):
        self.key(k)
        self.bool(v)

    def kv_str_omit(mut self, k: String, v: String):
        if v.byte_length() > 0:
            self.kv_str(k, v)

    def kv_num_omit(mut self, k: String, v: Float64):
        if v != 0:
            self.kv_num(k, v)

    def kv_int_omit(mut self, k: String, v: Int):
        if v != 0:
            self.kv_int(k, v)

    def kv_bool_omit(mut self, k: String, v: Bool):
        if v:
            self.kv_bool(k, v)

    def str_arr(mut self, xs: List[String]):
        """[]string; nil slices encode as null in Go — call null() for those."""
        self.begin_arr()
        for x in xs:
            self.str(x)
        self.end_arr()

    def num_arr(mut self, xs: List[Float64]):
        self.begin_arr()
        for x in xs:
            self.num(x)
        self.end_arr()


# ---------------------------------------------------------------- ParseFloat / ParseInt


@fieldwise_init
struct GoFloat(Copyable, ImplicitlyCopyable, Movable):
    var value: Float64
    var ok: Bool
    var range_err: Bool


@fieldwise_init
struct GoInt(Copyable, ImplicitlyCopyable, Movable):
    var value: Int
    var ok: Bool
    var range_err: Bool


@always_inline
def _lower(c: UInt8) -> UInt8:
    return c | 0x20


def _prefix_ic(b: Span[UInt8, _], start: Int, prefix: StaticString) -> Int:
    var p = prefix.as_bytes()
    var n = min(len(p), len(b) - start)
    for i in range(n):
        var c = b[start + i]
        if c >= 65 and c <= 90:
            c += 32
        if c != p[i]:
            return i
    return n


@fieldwise_init
struct _Special(Copyable, ImplicitlyCopyable, Movable):
    var f: Float64
    var n: Int
    var ok: Bool


def _special(b: Span[UInt8, _]) -> _Special:
    if len(b) == 0:
        return _Special(0, 0, False)
    var sign = 1.0
    var nsign = 0
    var c = b[0]
    if c == 43 or c == 45 or c == 105 or c == 73:
        if c == 43 or c == 45:
            if c == 45:
                sign = -1.0
            nsign = 1
        var n = _prefix_ic(b, nsign, "infinity")
        if 3 < n and n < 8:
            n = 3
        if n == 3 or n == 8:
            return _Special(sign * f64_from_bits(0x7FF0000000000000), nsign + n, True)
    elif c == 110 or c == 78:
        if _prefix_ic(b, 0, "nan") == 3:
            return _Special(nan64(), 3, True)
    return _Special(0, 0, False)


def _underscore_ok(b: Span[UInt8, _], end: Int) -> Bool:
    var saw = 94
    var i = 0
    var start = 0
    if end >= 1 and (b[0] == 45 or b[0] == 43):
        start = 1
    var hexp = False
    if end - start >= 2 and b[start] == 48 and (_lower(b[start + 1]) == 98 or _lower(b[start + 1]) == 111 or _lower(b[start + 1]) == 120):
        i = 2
        saw = 48
        hexp = _lower(b[start + 1]) == 120
    while start + i < end:
        var c = b[start + i]
        if (c >= 48 and c <= 57) or (hexp and _lower(c) >= 97 and _lower(c) <= 102):
            saw = 48
            i += 1
            continue
        if c == 95:
            if saw != 48:
                return False
            saw = 95
            i += 1
            continue
        if saw == 95:
            return False
        saw = 33
        i += 1
    return saw != 95


struct _Read(Copyable, Movable):
    var mantissa: UInt64
    var exp: Int
    var neg: Bool
    var trunc: Bool
    var hex: Bool
    var i: Int
    var ok: Bool

    def __init__(out self):
        self.mantissa = 0
        self.exp = 0
        self.neg = False
        self.trunc = False
        self.hex = False
        self.i = 0
        self.ok = False


def _read_float(b: Span[UInt8, _]) -> _Read:
    var r = _Read()
    var underscores = False
    var i = 0
    var n = len(b)
    if i >= n:
        return r^
    if b[i] == 43:
        i += 1
    elif b[i] == 45:
        r.neg = True
        i += 1
    var base: UInt64 = 10
    var max_mant = 19
    var exp_char = UInt8(101)
    if i + 2 < n and b[i] == 48 and _lower(b[i + 1]) == 120:
        base = 16
        max_mant = 16
        i += 2
        exp_char = 112
        r.hex = True
    var sawdot = False
    var sawdigits = False
    var nd = 0
    var nd_mant = 0
    var dp = 0
    while i < n:
        var c = b[i]
        if c == 95:
            underscores = True
            i += 1
            continue
        elif c == 46:
            if sawdot:
                break
            sawdot = True
            dp = nd
            i += 1
            continue
        elif c >= 48 and c <= 57:
            sawdigits = True
            if c == 48 and nd == 0:
                dp -= 1
                i += 1
                continue
            nd += 1
            if nd_mant < max_mant:
                r.mantissa = r.mantissa * base + UInt64(c - 48)
                nd_mant += 1
            elif c != 48:
                r.trunc = True
            i += 1
            continue
        elif base == 16 and _lower(c) >= 97 and _lower(c) <= 102:
            sawdigits = True
            nd += 1
            if nd_mant < max_mant:
                r.mantissa = r.mantissa * 16 + UInt64(_lower(c) - 97 + 10)
                nd_mant += 1
            else:
                r.trunc = True
            i += 1
            continue
        break
    r.i = i
    if not sawdigits:
        return r^
    if not sawdot:
        dp = nd
    if base == 16:
        dp *= 4
        nd_mant *= 4
    if i < n and _lower(b[i]) == exp_char:
        i += 1
        r.i = i
        if i >= n:
            return r^
        var esign = 1
        if b[i] == 43:
            i += 1
        elif b[i] == 45:
            i += 1
            esign = -1
        r.i = i
        if i >= n or b[i] < 48 or b[i] > 57:
            return r^
        var e = 0
        while i < n and ((b[i] >= 48 and b[i] <= 57) or b[i] == 95):
            if b[i] == 95:
                underscores = True
                i += 1
                continue
            if e < 10000:
                e = e * 10 + Int(b[i]) - 48
            i += 1
        dp += e * esign
    elif base == 16:
        return r^
    r.i = i
    if r.mantissa != 0:
        r.exp = dp - nd_mant
    if underscores and not _underscore_ok(b, i):
        return r^
    r.ok = True
    return r^


def _pow10(k: Int) -> Float64:
    var v = 1.0
    for _ in range(k):
        v *= 10.0
    return v


def _atof64exact(mantissa: UInt64, exp_in: Int, neg: Bool) -> GoFloat:
    if (mantissa >> 52) != 0:
        return GoFloat(0, False, False)
    var exp = exp_in
    var f = Float64(mantissa)
    if neg:
        f = -f
    if exp == 0:
        return GoFloat(f, True, False)
    if exp > 0 and exp <= 15 + 22:
        if exp > 22:
            f *= _pow10(exp - 22)
            exp = 22
        if f > 1e15 or f < -1e15:
            return GoFloat(0, False, False)
        return GoFloat(f * _pow10(exp), True, False)
    if exp < 0 and exp >= -22:
        return GoFloat(f / _pow10(-exp), True, False)
    return GoFloat(0, False, False)


def _eisel_lemire64(man_in: UInt64, exp10: Int, neg: Bool) -> GoFloat:
    """strconv.eiselLemire64; ok=False means "fall back"."""
    if man_in == 0:
        return GoFloat(f64_from_bits(UInt64(0x8000000000000000) if neg else 0), True, False)
    if exp10 < POW10_MIN_EXP10 or POW10_MAX_EXP10 < exp10:
        return GoFloat(0, False, False)
    var clz = Int(count_leading_zeros(man_in))
    var man = man_in << UInt64(clz)
    var ret_exp2 = UInt64(((217706 * exp10) >> 16) + 64 + 1023) - UInt64(clz)
    var tab = materialize[POW10_TABLE]()
    var idx = exp10 - POW10_MIN_EXP10
    var px = UInt128(man) * UInt128(tab[2 * idx + 1])
    var x_hi = UInt64(px >> 64)
    var x_lo = UInt64(px & UInt128(UInt64.MAX))
    if (x_hi & 0x1FF) == 0x1FF and x_lo + man < man:
        var py = UInt128(man) * UInt128(tab[2 * idx])
        var y_hi = UInt64(py >> 64)
        var y_lo = UInt64(py & UInt128(UInt64.MAX))
        var merged_hi = x_hi
        var merged_lo = x_lo + y_hi
        if merged_lo < x_lo:
            merged_hi += 1
        if (merged_hi & 0x1FF) == 0x1FF and merged_lo + 1 == 0 and y_lo + man < man:
            return GoFloat(0, False, False)
        x_hi = merged_hi
        x_lo = merged_lo
    var msb = x_hi >> 63
    var ret_mant = x_hi >> (msb + 9)
    ret_exp2 -= 1 ^ msb
    if x_lo == 0 and (x_hi & 0x1FF) == 0 and (ret_mant & 3) == 1:
        return GoFloat(0, False, False)
    ret_mant += ret_mant & 1
    ret_mant >>= 1
    if (ret_mant >> 53) > 0:
        ret_mant >>= 1
        ret_exp2 += 1
    if ret_exp2 - 1 >= 0x7FF - 1:
        return GoFloat(0, False, False)
    var ret_bits = (ret_exp2 << 52) | (ret_mant & 0x000FFFFFFFFFFFFF)
    if neg:
        ret_bits |= 0x8000000000000000
    return GoFloat(f64_from_bits(ret_bits), True, False)


def _decimal_set(mut d: Decimal, b: Span[UInt8, _], n: Int) -> Bool:
    var i = 0
    d.neg = False
    d.trunc = False
    if i >= n:
        return False
    if b[i] == 43:
        i += 1
    elif b[i] == 45:
        d.neg = True
        i += 1
    var sawdot = False
    var sawdigits = False
    while i < n:
        var c = b[i]
        if c == 95:
            i += 1
            continue
        elif c == 46:
            if sawdot:
                return False
            sawdot = True
            d.dp = d.nd
            i += 1
            continue
        elif c >= 48 and c <= 57:
            sawdigits = True
            if c == 48 and d.nd == 0:
                d.dp -= 1
                i += 1
                continue
            if d.nd < DEC_CAP:
                d.d[d.nd] = c
                d.nd += 1
            elif c != 48:
                d.trunc = True
            i += 1
            continue
        break
    if not sawdigits:
        return False
    if not sawdot:
        d.dp = d.nd
    if i < n and _lower(b[i]) == 101:
        i += 1
        if i >= n:
            return False
        var esign = 1
        if b[i] == 43:
            i += 1
        elif b[i] == 45:
            i += 1
            esign = -1
        if i >= n or b[i] < 48 or b[i] > 57:
            return False
        var e = 0
        while i < n and ((b[i] >= 48 and b[i] <= 57) or b[i] == 95):
            if b[i] == 95:
                i += 1
                continue
            if e < 10000:
                e = e * 10 + Int(b[i]) - 48
            i += 1
        d.dp += e * esign
    return i == n


comptime POWTAB: Array[Int, 9] = [1, 3, 6, 9, 13, 16, 19, 23, 26]


def _float_bits(mut d: Decimal) -> Tuple[UInt64, Bool]:
    var cheats = _Cheats()
    var powtab = materialize[POWTAB]()
    var bias = -1023
    var exp = 0
    var mant: UInt64 = 0
    var overflow = False
    var done = False
    if d.nd == 0:
        mant = 0
        exp = bias
        done = True
    elif d.dp > 310:
        overflow = True
    elif d.dp < -330:
        mant = 0
        exp = bias
        done = True
    if not done and not overflow:
        exp = 0
        while d.dp > 0:
            var n = 27 if d.dp >= 9 else powtab[d.dp]
            d.shift(-n, cheats)
            exp += n
        while d.dp < 0 or (d.dp == 0 and d.d[0] < 53):
            var n = 27 if -d.dp >= 9 else powtab[-d.dp]
            d.shift(n, cheats)
            exp -= n
        exp -= 1
        if exp < bias + 1:
            var n = bias + 1 - exp
            d.shift(-n, cheats)
            exp += n
        if exp - bias >= (1 << 11) - 1:
            overflow = True
        else:
            d.shift(1 + 52, cheats)
            mant = d.rounded_integer()
            if mant == (UInt64(2) << 52):
                mant >>= 1
                exp += 1
                if exp - bias >= (1 << 11) - 1:
                    overflow = True
            if not overflow and (mant & (UInt64(1) << 52)) == 0:
                exp = bias
    if overflow:
        mant = 0
        exp = (1 << 11) - 1 + bias
    var bits = mant & ((UInt64(1) << 52) - 1)
    bits |= UInt64((exp - bias) & ((1 << 11) - 1)) << 52
    if d.neg:
        bits |= UInt64(1) << 63
    return (bits, overflow)


def _atof_hex(mantissa_in: UInt64, exp_in: Int, neg: Bool, trunc: Bool) -> GoFloat:
    var bias = -1023
    var max_exp = (1 << 11) + bias - 2
    var min_exp = bias + 1
    var mantissa = mantissa_in
    var exp = exp_in + 52
    while mantissa != 0 and (mantissa >> (52 + 2)) == 0:
        mantissa <<= 1
        exp -= 1
    if trunc:
        mantissa |= 1
    while (mantissa >> (1 + 52 + 2)) != 0:
        mantissa = (mantissa >> 1) | (mantissa & 1)
        exp += 1
    while mantissa > 1 and exp < min_exp - 2:
        mantissa = (mantissa >> 1) | (mantissa & 1)
        exp += 1
    var round = mantissa & 3
    mantissa >>= 2
    round |= mantissa & 1
    exp += 2
    if round == 3:
        mantissa += 1
        if mantissa == (UInt64(1) << 53):
            mantissa >>= 1
            exp += 1
    if (mantissa >> 52) == 0:
        exp = bias
    var range_err = False
    if exp > max_exp:
        mantissa = UInt64(1) << 52
        exp = max_exp + 1
        range_err = True
    var bits = mantissa & ((UInt64(1) << 52) - 1)
    bits |= UInt64((exp - bias) & ((1 << 11) - 1)) << 52
    if neg:
        bits |= UInt64(1) << 63
    return GoFloat(f64_from_bits(bits), not range_err, range_err)


def go_parse_float_bytes(b: Span[UInt8, _]) -> GoFloat:
    """strconv.ParseFloat(s, 64). ok=False on syntax (value 0) or range (value +-Inf) errors."""
    var n = len(b)
    var sp = _special(b)
    if sp.ok:
        if sp.n != n:
            return GoFloat(0, False, False)
        return GoFloat(sp.f, True, False)
    var r = _read_float(b)
    if not r.ok:
        return GoFloat(0, False, False)
    var res: GoFloat
    if r.hex:
        res = _atof_hex(r.mantissa, r.exp, r.neg, r.trunc)
    else:
        var fast = GoFloat(0, False, False)
        if not r.trunc:
            fast = _atof64exact(r.mantissa, r.exp, r.neg)
        if not fast.ok:
            var el = _eisel_lemire64(r.mantissa, r.exp, r.neg)
            if el.ok:
                if not r.trunc:
                    fast = el
                else:
                    var up = _eisel_lemire64(r.mantissa + 1, r.exp, r.neg)
                    if up.ok and f64_bits(el.value) == f64_bits(up.value):
                        fast = el
        if fast.ok:
            res = fast
        else:
            var d = Decimal()
            if not _decimal_set(d, b, r.i):
                return GoFloat(0, False, False)
            var fb = _float_bits(d)
            res = GoFloat(f64_from_bits(fb[0]), not fb[1], fb[1])
    if r.i != n:
        return GoFloat(0, False, False)
    return res


def go_parse_float(s: String) -> GoFloat:
    return go_parse_float_bytes(s.as_bytes())


def go_parse_int_bytes(b: Span[UInt8, _]) -> GoInt:
    """strconv.ParseInt(s, 10, 64); Atoi yields the same values."""
    var n = len(b)
    if n == 0:
        return GoInt(0, False, False)
    var i = 0
    var neg = False
    if b[0] == 43:
        i = 1
    elif b[0] == 45:
        neg = True
        i = 1
    if i >= n:
        return GoInt(0, False, False)
    var cutoff10: UInt64 = UInt64.MAX // 10 + 1
    var un: UInt64 = 0
    var ranged = False
    while i < n:
        var c = b[i]
        if c < 48 or c > 57:
            return GoInt(0, False, False)
        var d = UInt64(c - 48)
        if un >= cutoff10:
            un = UInt64.MAX
            ranged = True
            break
        un *= 10
        var n1 = un + d
        if n1 < un:
            un = UInt64.MAX
            ranged = True
            break
        un = n1
        i += 1
    var cutoff: UInt64 = UInt64(1) << 63
    if not neg and un >= cutoff:
        return GoInt(Int(cutoff - 1), False, True)
    if neg and un > cutoff:
        return GoInt(Int(Int64.MIN), False, True)
    if ranged:
        return GoInt(0, False, True)
    var v = Int(Int64(un)) if un < cutoff else Int(Int64.MIN)
    if neg:
        v = -v if un < cutoff else Int(Int64.MIN)
    return GoInt(v, True, False)


def go_parse_int(s: String) -> GoInt:
    return go_parse_int_bytes(s.as_bytes())
