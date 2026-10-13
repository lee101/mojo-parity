"""shopspring/decimal v1.4.0 value semantics on a normalized sign-magnitude UInt256.

Every Go operation the bot uses (Add, Sub, Mul, Div=DivRound(16), RoundFloor/Ceil, Cmp,
String, NewFromString, NewFromFloat, InexactFloat64) depends only on the exact value, so
values are kept with trailing zeros stripped. Magnitudes are capped at 2^255; overflow
aborts the process rather than trading on a wrong number.
"""

from std.os import abort
from p2.gofmt import go_format_float, go_parse_float, go_parse_int
from bg.bigint import Big, divmod as bdivmod, mul as bmul, cmp as bcmp

comptime MAXMAG: UInt256 = UInt256(1) << 255
comptime DIV_PREC = 16


def _pow10(k: Int) -> UInt256:
    var r: UInt256 = 1
    for _ in range(k):
        r *= 10
    return r


def _digits(m: UInt256) -> String:
    if m == 0:
        return "0"
    var b = List[UInt8]()
    var v = m
    while v != 0:
        b.append(UInt8(Int(v % 10)) + 48)
        v /= 10
    var out = List[UInt8](capacity=len(b))
    var i = len(b) - 1
    while i >= 0:
        out.append(b[i])
        i -= 1
    return String(unsafe_from_utf8=out)


def _to_big(m: UInt256) -> Big:
    var b = Big()
    var v = m
    while v != 0:
        b.d.append(UInt32(Int(v & 0xFFFFFFFF)))
        v >>= 32
    return b^


def _from_big(b: Big) -> UInt256:
    if len(b.d) > 8:
        abort("decimal magnitude overflow")
    var v: UInt256 = 0
    var i = len(b.d) - 1
    while i >= 0:
        v = (v << 32) | UInt256(Int(b.d[i]))
        i -= 1
    if v >= MAXMAG:
        abort("decimal magnitude overflow")
    return v


def _big_pow10(k: Int) -> Big:
    var r = Big.from_u64(1)
    var ten = Big.from_u64(10)
    for _ in range(k):
        r = bmul(r, ten)
    return r^


@fieldwise_init
struct Dec(Copyable, ImplicitlyCopyable, Movable, Writable):
    var neg: Bool
    var mag: UInt256
    var exp: Int

    @staticmethod
    def zero() -> Dec:
        return Dec(False, 0, 0)

    @staticmethod
    def mk(neg: Bool, mag: UInt256, exp: Int) -> Dec:
        if mag == 0:
            return Dec(False, 0, 0)
        if mag >= MAXMAG:
            abort("decimal magnitude overflow")
        var m = mag
        var e = exp
        while m % 10 == 0:
            m /= 10
            e += 1
        return Dec(neg, m, e)

    @staticmethod
    def int(v: Int) -> Dec:
        if v < 0:
            return Dec.mk(True, UInt256(-v), 0)
        return Dec.mk(False, UInt256(v), 0)

    @staticmethod
    def new(v: Int, exp: Int) -> Dec:
        if v < 0:
            return Dec.mk(True, UInt256(-v), exp)
        return Dec.mk(False, UInt256(v), exp)

    def sign(self) -> Int:
        if self.mag == 0:
            return 0
        return -1 if self.neg else 1

    def is_pos(self) -> Bool:
        return self.mag != 0 and not self.neg

    def is_neg(self) -> Bool:
        return self.mag != 0 and self.neg

    def is_zero(self) -> Bool:
        return self.mag == 0

    def negate(self) -> Dec:
        return Dec.mk(not self.neg, self.mag, self.exp)

    def abs(self) -> Dec:
        return Dec(False, self.mag, self.exp)

    def add(self, o: Dec) -> Dec:
        if self.mag == 0:
            return o
        if o.mag == 0:
            return self
        var e = min(self.exp, o.exp)
        var a = _scale(self.mag, self.exp - e)
        var b = _scale(o.mag, o.exp - e)
        if self.neg == o.neg:
            return Dec.mk(self.neg, a + b, e)
        if a >= b:
            return Dec.mk(self.neg, a - b, e)
        return Dec.mk(o.neg, b - a, e)

    def sub(self, o: Dec) -> Dec:
        return self.add(o.negate())

    def mul(self, o: Dec) -> Dec:
        if self.mag == 0 or o.mag == 0:
            return Dec.zero()
        var p = self.mag * o.mag
        if p / o.mag != self.mag or p >= MAXMAG:
            abort("decimal magnitude overflow")
        return Dec.mk(self.neg != o.neg, p, self.exp + o.exp)

    def div(self, o: Dec) -> Dec:
        return self.div_round(o, DIV_PREC)

    def div_round(self, o: Dec, prec: Int) -> Dec:
        if o.mag == 0:
            abort("decimal division by 0")
        if self.mag == 0:
            return Dec.zero()
        var k = self.exp - o.exp + prec
        var num = _to_big(self.mag)
        var den = _to_big(o.mag)
        if k >= 0:
            num = bmul(num, _big_pow10(k))
        else:
            den = bmul(den, _big_pow10(-k))
        var qr = bdivmod(num, den)
        var q = _from_big(qr[0])
        var r2 = bmul(qr[1], Big.from_u64(2))
        if bcmp(r2, den) >= 0:
            q += 1
        return Dec.mk(self.neg != o.neg, q, -prec)

    def cmp(self, o: Dec) -> Int:
        var sa = self.sign()
        var sb = o.sign()
        if sa != sb:
            return -1 if sa < sb else 1
        if sa == 0:
            return 0
        var c = _cmp_mag(self, o)
        return -c if self.neg else c

    def eq(self, o: Dec) -> Bool:
        return self.cmp(o) == 0

    def gt(self, o: Dec) -> Bool:
        return self.cmp(o) == 1

    def ge(self, o: Dec) -> Bool:
        return self.cmp(o) >= 0

    def lt(self, o: Dec) -> Bool:
        return self.cmp(o) == -1

    def le(self, o: Dec) -> Bool:
        return self.cmp(o) <= 0

    def _round_dir(self, places: Int, up_if_pos: Bool) -> Dec:
        if self.exp >= -places:
            return self
        var sh = -places - self.exp
        if sh > 76:
            var q0: UInt256 = 0
            if (up_if_pos and not self.neg) or (not up_if_pos and self.neg):
                q0 = 1
            return Dec.mk(self.neg, q0, -places)
        var p = _pow10(sh)
        var q = self.mag / p
        if self.mag % p == 0:
            return self
        if (up_if_pos and not self.neg) or (not up_if_pos and self.neg):
            q += 1
        return Dec.mk(self.neg, q, -places)

    def round_floor(self, places: Int) -> Dec:
        return self._round_dir(places, False)

    def round_ceil(self, places: Int) -> Dec:
        return self._round_dir(places, True)

    def string(self) -> String:
        if self.mag == 0:
            return "0"
        var s: String
        if self.exp >= 0:
            s = _digits(self.mag) + String("0") * self.exp
        else:
            var d = _digits(self.mag)
            var n = d.byte_length()
            var fe = -self.exp
            if n > fe:
                s = String(d[byte = 0 : n - fe]) + "." + String(d[byte = n - fe :])
            else:
                s = "0." + String("0") * (fe - n) + d
        if self.neg:
            return "-" + s
        return s

    def write_to(self, mut w: Some[Writer]):
        w.write(self.string())

    def f64(self) -> Float64:
        var s = _digits(self.mag) + "e" + String(self.exp)
        if self.neg:
            s = "-" + s
        return go_parse_float(s).value

    @staticmethod
    def from_f64(x: Float64) -> Dec:
        if x == 0:
            return Dec.zero()
        try:
            return dec_parse(go_format_float(x, "e", -1))
        except:
            abort("decimal from float")
            return Dec.zero()


def _scale(m: UInt256, k: Int) -> UInt256:
    if k == 0:
        return m
    if k > 76:
        abort("decimal magnitude overflow")
    var r = m * _pow10(k)
    if r / _pow10(k) != m or r >= MAXMAG:
        abort("decimal magnitude overflow")
    return r


def _cmp_mag(a: Dec, b: Dec) -> Int:
    var da = _digits(a.mag).byte_length() + a.exp
    var db = _digits(b.mag).byte_length() + b.exp
    if da != db:
        return -1 if da < db else 1
    var e = min(a.exp, b.exp)
    var x = _scale(a.mag, a.exp - e)
    var y = _scale(b.mag, b.exp - e)
    if x == y:
        return 0
    return -1 if x < y else 1


def dmin(a: Dec, b: Dec) -> Dec:
    return b if b.cmp(a) < 0 else a


def dmax(a: Dec, b: Dec) -> Dec:
    return b if b.cmp(a) > 0 else a


def _is_int_str(s: String) -> Bool:
    var b = s.as_bytes()
    var i = 0
    if len(b) > 0 and (b[0] == 43 or b[0] == 45):
        i = 1
    if i >= len(b):
        return False
    for j in range(i, len(b)):
        if b[j] < 48 or b[j] > 57:
            return False
    return True


def dec_parse(value: String) raises -> Dec:
    """decimal.NewFromString."""
    var v = value
    var exp = 0
    var bs = v.as_bytes()
    var ei = -1
    for i in range(len(bs)):
        if bs[i] == 69 or bs[i] == 101:
            ei = i
            break
    if ei >= 0:
        var es = String(v[byte = ei + 1 :])
        var r = go_parse_int(es)
        if not r.ok or r.value < -2147483648 or r.value > 2147483647:
            if r.range_err or (r.ok and (r.value < -2147483648 or r.value > 2147483647)):
                raise Error("can't convert " + value + " to decimal: fractional part too long")
            raise Error("can't convert " + value + " to decimal: exponent is not numeric")
        exp = r.value
        var vt = String(v[byte=0:ei])
        v = vt
    var b = v.as_bytes()
    var p = -1
    for i in range(len(b)):
        if b[i] == 46:
            if p > -1:
                raise Error("can't convert " + value + " to decimal: too many .s")
            p = i
    var ints: String
    if p == -1:
        ints = v
    else:
        if p + 1 < len(b):
            ints = String(v[byte=0:p]) + String(v[byte = p + 1 :])
        else:
            ints = String(v[byte=0:p])
        exp -= len(b) - p - 1
    if not _is_int_str(ints):
        raise Error("can't convert " + v + " to decimal")
    var ib = ints.as_bytes()
    var neg = ib[0] == 45
    var start = 1 if (ib[0] == 45 or ib[0] == 43) else 0
    var mag: UInt256 = 0
    var nd = 0
    for j in range(start, len(ib)):
        if nd == 0 and ib[j] == 48:
            continue
        nd += 1
        if nd > 76:
            raise Error("can't convert " + v + " to decimal: too many digits")
        mag = mag * 10 + UInt256(Int(ib[j] - 48))
    if exp < -2147483648 or exp > 2147483647:
        raise Error("can't convert " + value + " to decimal: fractional part too long")
    return Dec.mk(neg, mag, exp)


def dec_ok(value: String) -> Bool:
    try:
        _ = dec_parse(value)
        return True
    except:
        return False


def dparse0(value: String) -> Dec:
    """decimal.NewFromString with the error ignored (Go's `x, _ :=` yields zero)."""
    try:
        return dec_parse(value)
    except:
        return Dec.zero()
