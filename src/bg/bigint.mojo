"""Minimal arbitrary-precision unsigned integers (UInt32 limbs, little endian) for exact
rational statistics matching CPython (statistics.mean/pstdev, int/int true division)."""

from p2.gomath import f64_bits, f64_from_bits


struct Big(Copyable, Movable):
    var d: List[UInt32]

    def __init__(out self):
        self.d = List[UInt32]()

    @staticmethod
    def from_u64(v: UInt64) -> Big:
        var b = Big()
        if v != 0:
            b.d.append(UInt32(v & 0xFFFFFFFF))
            if (v >> 32) != 0:
                b.d.append(UInt32(v >> 32))
        return b^

    def trim(mut self):
        while len(self.d) > 0 and self.d[len(self.d) - 1] == 0:
            _ = self.d.pop()

    def is_zero(self) -> Bool:
        return len(self.d) == 0

    def bit_length(self) -> Int:
        if len(self.d) == 0:
            return 0
        var top = self.d[len(self.d) - 1]
        var n = 0
        while top != 0:
            top >>= 1
            n += 1
        return (len(self.d) - 1) * 32 + n

    def shl(self, s: Int) -> Big:
        var out = Big()
        if self.is_zero():
            return out^
        var limbs = s // 32
        var bits = s % 32
        for _ in range(limbs):
            out.d.append(0)
        var carry: UInt32 = 0
        for x in self.d:
            if bits == 0:
                out.d.append(x)
            else:
                out.d.append((x << UInt32(bits)) | carry)
                carry = x >> UInt32(32 - bits)
        if carry != 0:
            out.d.append(carry)
        out.trim()
        return out^

    def shr(self, s: Int) -> Big:
        var out = Big()
        var limbs = s // 32
        var bits = s % 32
        if limbs >= len(self.d):
            return out^
        for i in range(limbs, len(self.d)):
            var lo = self.d[i] >> UInt32(bits) if bits > 0 else self.d[i]
            var hi: UInt32 = 0
            if bits > 0 and i + 1 < len(self.d):
                hi = self.d[i + 1] << UInt32(32 - bits)
            out.d.append(lo | hi)
        out.trim()
        return out^

    def low_bits_nonzero(self, s: Int) -> Bool:
        """True when any of the lowest s bits are set."""
        var limbs = s // 32
        for i in range(min(limbs, len(self.d))):
            if self.d[i] != 0:
                return True
        var bits = s % 32
        if bits > 0 and limbs < len(self.d):
            if (self.d[limbs] & ((UInt32(1) << UInt32(bits)) - 1)) != 0:
                return True
        return False


def cmp(a: Big, b: Big) -> Int:
    if len(a.d) != len(b.d):
        return -1 if len(a.d) < len(b.d) else 1
    var i = len(a.d) - 1
    while i >= 0:
        if a.d[i] != b.d[i]:
            return -1 if a.d[i] < b.d[i] else 1
        i -= 1
    return 0


def add(a: Big, b: Big) -> Big:
    var out = Big()
    var n = max(len(a.d), len(b.d))
    var carry: UInt64 = 0
    for i in range(n):
        var x = UInt64(a.d[i]) if i < len(a.d) else 0
        var y = UInt64(b.d[i]) if i < len(b.d) else 0
        var s = x + y + carry
        out.d.append(UInt32(s & 0xFFFFFFFF))
        carry = s >> 32
    if carry != 0:
        out.d.append(UInt32(carry))
    out.trim()
    return out^


def sub(a: Big, b: Big) -> Big:
    """a - b, requires a >= b."""
    var out = Big()
    var borrow: Int64 = 0
    for i in range(len(a.d)):
        var x = Int64(a.d[i])
        var y = Int64(b.d[i]) if i < len(b.d) else 0
        var s = x - y - borrow
        if s < 0:
            s += Int64(1) << 32
            borrow = 1
        else:
            borrow = 0
        out.d.append(UInt32(s))
    out.trim()
    return out^


def mul(a: Big, b: Big) -> Big:
    var out = Big()
    if a.is_zero() or b.is_zero():
        return out^
    var r = List[UInt64](length=len(a.d) + len(b.d) + 1, fill=0)
    for i in range(len(a.d)):
        var carry: UInt64 = 0
        var x = UInt64(a.d[i])
        for j in range(len(b.d)):
            var t = r[i + j] + x * UInt64(b.d[j]) + carry
            r[i + j] = t & 0xFFFFFFFF
            carry = t >> 32
        var k = i + len(b.d)
        while carry != 0:
            var t = r[k] + carry
            r[k] = t & 0xFFFFFFFF
            carry = t >> 32
            k += 1
    for v in r:
        out.d.append(UInt32(v))
    out.trim()
    return out^


def mul_small(a: Big, m: UInt64) -> Big:
    return mul(a, Big.from_u64(m))


def divmod(a: Big, b: Big) -> Tuple[Big, Big]:
    """Binary long division (operands here are a few hundred bits)."""
    if cmp(a, b) < 0:
        return (Big(), a.copy())
    var q = Big()
    var r = Big()
    var n = a.bit_length()
    q.d = List[UInt32](length=(n + 31) // 32, fill=0)
    var i = n - 1
    while i >= 0:
        r = r.shl(1)
        if (a.d[i // 32] >> UInt32(i % 32)) & 1 == 1:
            if len(r.d) == 0:
                r.d.append(1)
            else:
                r.d[0] |= 1
        if cmp(r, b) >= 0:
            r = sub(r, b)
            q.d[i // 32] |= UInt32(1) << UInt32(i % 32)
        i -= 1
    q.trim()
    return (q^, r^)


def isqrt(n: Big) -> Big:
    """floor(sqrt(n)) by Newton iteration."""
    if n.is_zero():
        return Big()
    var x = Big.from_u64(1).shl((n.bit_length() + 1) // 2)
    while True:
        var qd = divmod(n, x)
        var y = add(x, qd[0]).shr(1)
        if cmp(y, x) >= 0:
            return x^
        x = y^


@fieldwise_init
struct SBig(Copyable, Movable):
    var neg: Bool
    var mag: Big


def sadd(a: SBig, b: SBig) -> SBig:
    if a.neg == b.neg:
        return SBig(a.neg, add(a.mag, b.mag))
    var c = cmp(a.mag, b.mag)
    if c == 0:
        return SBig(False, Big())
    if c > 0:
        return SBig(a.neg, sub(a.mag, b.mag))
    return SBig(b.neg, sub(b.mag, a.mag))


comptime SCALE = 1074


def exact_scaled(x: Float64) -> SBig:
    """x * 2^1074 as an exact signed integer (finite x)."""
    var bits = f64_bits(x)
    var neg = (bits >> 63) == 1
    var e = Int((bits >> 52) & 0x7FF)
    var m = bits & 0x000FFFFFFFFFFFFF
    var shift: Int
    if e == 0:
        shift = 0
    else:
        m |= UInt64(1) << 52
        shift = e - 1
    return SBig(neg and m != 0, Big.from_u64(m).shl(shift))


def ratio_to_f64(num: SBig, den: Big) -> Float64:
    """Correctly rounded (half-even) num/den, den > 0 (CPython int / int)."""
    if num.mag.is_zero():
        return 0.0
    var a = num.mag.copy()
    var diff = a.bit_length() - den.bit_length()
    # q = floor(a * 2^s / den) with 54..55 significant bits
    var s = 55 - diff
    var q: Big
    var rem_nonzero: Bool
    if s >= 0:
        var qr = divmod(a.shl(s), den)
        q = qr[0].copy()
        rem_nonzero = not qr[1].is_zero()
    else:
        var qr = divmod(a, den.shl(-s))
        q = qr[0].copy()
        rem_nonzero = not qr[1].is_zero()
    var qb = q.bit_length()
    # value = q * 2^-s ; unbiased exponent of the leading bit
    var lead_exp = qb - 1 - s
    var keep = 53
    if lead_exp < -1022:
        keep = 53 - (-1022 - lead_exp)
        if keep < 0:
            keep = 0
    var drop = qb - keep
    var mant = q.shr(drop)
    var half = False
    var sticky = rem_nonzero
    if drop > 0:
        half = (q.d[(drop - 1) // 32] >> UInt32((drop - 1) % 32)) & 1 == 1
        if q.low_bits_nonzero(drop - 1):
            sticky = True
    var mv: UInt64 = 0
    for i in range(len(mant.d)):
        mv |= UInt64(mant.d[i]) << UInt64(32 * i)
    if half and (sticky or (mv & 1) == 1):
        mv += 1
    # result = mv * 2^(drop - s)
    var e2 = drop - s
    var r = Float64(mv)
    # exact scaling by powers of two
    while e2 > 0:
        var st = min(e2, 1000)
        r *= _pow2(st)
        e2 -= st
    while e2 < 0:
        var st = min(-e2, 1000)
        r /= _pow2(st)
        e2 += st
    return -r if num.neg else r


def _pow2(k: Int) -> Float64:
    return f64_from_bits(UInt64(1023 + k) << 52)


def py_mean(v: List[Float64]) -> Float64:
    """statistics.mean of finite floats (exact rational, correctly rounded)."""
    var s = SBig(False, Big())
    for x in v:
        s = sadd(s, exact_scaled(x))
    var den = Big.from_u64(UInt64(len(v))).shl(SCALE)
    return ratio_to_f64(s, den)


def py_pstdev(v: List[Float64]) -> Float64:
    """statistics.pstdev of finite floats (exact ssd, correctly rounded sqrt)."""
    var n = len(v)
    var sx = SBig(False, Big())
    var sxx = Big()
    for x in v:
        var e = exact_scaled(x)
        sx = sadd(sx, e)
        sxx = add(sxx, mul(e.mag, e.mag))
    # mss = (n*sxx - sx^2) / (n^2 * 2^(2*SCALE))
    var num = sub(mul_small(sxx, UInt64(n)), mul(sx.mag, sx.mag))
    var den = mul_small(Big.from_u64(UInt64(n)), UInt64(n)).shl(2 * SCALE)
    if num.is_zero():
        return 0.0
    # _float_sqrt_of_frac(num, den)
    var q = (num.bit_length() - den.bit_length() - 109) // 2
    var numer: Big
    var denom: Big
    if q >= 0:
        numer = _isqrt_frac_rto(num, den.shl(2 * q)).shl(q)
        denom = Big.from_u64(1)
    else:
        numer = _isqrt_frac_rto(num.shl(-2 * q), den)
        denom = Big.from_u64(1).shl(-q)
    return ratio_to_f64(SBig(False, numer^), denom)


def _isqrt_frac_rto(n: Big, m: Big) -> Big:
    var qd = divmod(n, m)
    var a = isqrt(qd[0])
    var aa = mul(mul(a, a), m)
    if cmp(aa, n) != 0:
        if len(a.d) == 0:
            a.d.append(1)
        else:
            a.d[0] |= 1
    return a^
