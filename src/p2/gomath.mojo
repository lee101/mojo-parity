"""Bit-exact ports of the Go amd64 math routines the simulator depends on.

Go's math.Exp and math.Log are hand-written amd64 assembly (exp_amd64.s with
the AVX/FMA branch, log_amd64.s); math.Tanh is pure Go on top of Exp. Mojo's
libm-backed versions differ in the last ulp, which can flip a score tie, so
these mirror the Go instruction sequences operation for operation.
"""

from std.math import fma, sqrt
from std.memory import bitcast

comptime LOG2E = 1.4426950408889634073599246810018920
comptime LN2U = 0.69314718055966295651160180568695068359375
comptime LN2L = 0.28235290563031577122588448175013436025525412068e-12
comptime EXP_OVERFLOW = 7.09782712893384e02
comptime POS_INF_BITS: UInt64 = 0x7FF0000000000000
comptime NEG_INF_BITS: UInt64 = 0xFFF0000000000000


@always_inline
def f64_bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


@always_inline
def f64_from_bits(b: UInt64) -> Float64:
    return bitcast[DType.float64](b)


@always_inline
def is_finite(x: Float64) -> Bool:
    return (f64_bits(x) & 0x7FF0000000000000) != 0x7FF0000000000000


@always_inline
def is_nan(x: Float64) -> Bool:
    return x != x


@always_inline
def nan64() -> Float64:
    return f64_from_bits(0x7FF8000000000001)


@always_inline
def inf64() -> Float64:
    return f64_from_bits(POS_INF_BITS)


@always_inline
def neg_inf64() -> Float64:
    return f64_from_bits(NEG_INF_BITS)


@always_inline
def round_half_even_to_i32(x: Float64) -> Int32:
    """CVTSD2SL under the default MXCSR (round to nearest, ties to even)."""
    var r = x.__round__()
    if abs(x - x.__floor__()) == 0.5:
        var f = x.__floor__()
        if Int64(f) % 2 == 0:
            r = f
        else:
            r = f + 1.0
    return Int32(Int64(r))


def go_exp(x: Float64) -> Float64:
    var bx = f64_bits(x)
    if (bx & 0x7FFFFFFFFFFFFFFF) >= POS_INF_BITS:
        if bx == NEG_INF_BITS:
            return 0.0
        return x
    if x > EXP_OVERFLOW:
        return inf64()
    var e = round_half_even_to_i32(LOG2E * x)
    var k = Float64(e)
    var r = fma(-LN2U, k, x)
    r = fma(-LN2L, k, r)
    r = r * 0.0625
    var p: Float64 = 2.4801587301587301587e-5
    p = fma(p, r, 1.9841269841269841270e-4)
    p = fma(p, r, 1.3888888888888888889e-3)
    p = fma(p, r, 8.3333333333333333333e-3)
    p = fma(p, r, 4.1666666666666666667e-2)
    p = fma(p, r, 1.6666666666666666667e-1)
    p = fma(p, r, 0.5)
    p = fma(p, r, 1.0)
    r = r * p
    p = r + 2.0
    r = r * p
    p = r + 2.0
    r = r * p
    p = r + 2.0
    r = r * p
    p = r + 2.0
    r = fma(r, p, 1.0)
    var biased = Int64(e) + 0x3FF
    if biased <= 0:
        if biased < -52:
            return 0.0
        r = r * f64_from_bits(UInt64(biased + 0x3FE) << 52)
        biased = 1
    if biased >= 0x7FF:
        return inf64()
    return r * f64_from_bits(UInt64(biased) << 52)


comptime TANH_P0 = -9.64399179425052238628e-1
comptime TANH_P1 = -9.92877231001918586564e1
comptime TANH_P2 = -1.61468768441708447952e3
comptime TANH_Q0 = 1.12811678491632931402e2
comptime TANH_Q1 = 2.23548839060100448583e3
comptime TANH_Q2 = 4.84406305325125486048e3


def go_tanh(x: Float64) -> Float64:
    comptime MAXLOG = 8.8029691931113054295988e01
    var z = abs(x)
    if z > 0.5 * MAXLOG:
        if x < 0:
            return -1.0
        return 1.0
    if z >= 0.625:
        var s = go_exp(2.0 * z)
        z = 1.0 - 2.0 / (s + 1.0)
        if x < 0:
            z = -z
        return z
    if x == 0:
        return x
    var s = x * x
    return x + x * s * ((TANH_P0 * s + TANH_P1) * s + TANH_P2) / (
        ((s + TANH_Q0) * s + TANH_Q1) * s + TANH_Q2
    )


comptime LN2HI = 6.93147180369123816490e-01
comptime LN2LO = 1.90821492927058770002e-10
comptime LG1 = 6.666666666666735130e-01
comptime LG2 = 3.999999999940941908e-01
comptime LG3 = 2.857142874366239149e-01
comptime LG4 = 2.222219843214978396e-01
comptime LG5 = 1.818357216161805012e-01
comptime LG6 = 1.531383769920937332e-01
comptime LG7 = 1.479819860511658591e-01
comptime HSQRT2 = 7.07106781186547524401e-01


def go_log(x: Float64) -> Float64:
    var bx = f64_bits(x)
    if (bx & 0x7FFFFFFFFFFFFFFF) == 0:
        return neg_inf64()
    if Int64(bx) < 0:
        return f64_from_bits(0x7FF8000000000001)
    if bx >= POS_INF_BITS:
        return x
    var f1 = f64_from_bits((bx & 0x000FFFFFFFFFFFFF) | 0x3FE0000000000000)
    var k = Float64(Int64((bx >> 52) & 0x7FF) - 0x3FE)
    var adj: Float64 = 0.0
    if not (HSQRT2 < f1):
        adj = 1.0
    k = k - adj
    f1 = f1 * (adj + 1.0)
    var f = f1 - 1.0
    var s = f / (2.0 + f)
    var s2 = s * s
    var s4 = s2 * s2
    var t1 = LG7 * s4
    t1 = t1 + LG5
    t1 = t1 * s4
    t1 = t1 + LG3
    t1 = t1 * s4
    t1 = t1 + LG1
    t1 = s2 * t1
    var t2 = LG6 * s4
    t2 = t2 + LG4
    t2 = t2 * s4
    t2 = t2 + LG2
    t2 = s4 * t2
    var r = t1 + t2
    var hfsq = 0.5 * f
    hfsq = hfsq * f
    var a = s * (hfsq + r)
    a = a + k * LN2LO
    var b = hfsq - a
    b = b - f
    return k * LN2HI - b


comptime LP1 = 6.666666666666735130e-01
comptime LP2 = 3.999999999940941908e-01
comptime LP3 = 2.857142874366239149e-01
comptime LP4 = 2.222219843214978396e-01
comptime LP5 = 1.818357216161805012e-01
comptime LP6 = 1.531383769920937332e-01
comptime LP7 = 1.479819860511658591e-01


def go_log1p(x: Float64) -> Float64:
    """Port of Go's pure-Go math.Log1p (log1p.go)."""
    comptime SQRT2M1 = 4.142135623730950488017e-01
    comptime SQRT2HALFM1 = -2.928932188134524755992e-01
    comptime SMALL = 1.0 / Float64(1 << 29)
    comptime TINY = 1.0 / Float64(1 << 54)
    comptime TWO53 = Float64(1 << 53)
    comptime LN2HI_ = 6.93147180369123816490e-01
    comptime LN2LO_ = 1.90821492927058770002e-10
    if x < -1 or is_nan(x):
        return nan64()
    if x == -1:
        return neg_inf64()
    if x == inf64():
        return inf64()
    var absx = abs(x)
    var f: Float64 = 0
    var iu: UInt64 = 0
    var k = 1
    if absx < SQRT2M1:
        if absx < SMALL:
            if absx < TINY:
                return x
            return x - x * x * 0.5
        if x > SQRT2HALFM1:
            k = 0
            f = x
            iu = 1
    var c: Float64 = 0
    if k != 0:
        var u: Float64
        if absx < TWO53:
            u = 1.0 + x
            iu = f64_bits(u)
            k = Int((iu >> 52) - 1023)
            if k > 0:
                c = 1.0 - (u - x)
            else:
                c = x - (u - 1.0)
            c = c / u
        else:
            u = x
            iu = f64_bits(u)
            k = Int((iu >> 52) - 1023)
            c = 0
        iu &= 0x000FFFFFFFFFFFFF
        if iu < 0x0006A09E667F3BCD:
            u = f64_from_bits(iu | 0x3FF0000000000000)
        else:
            k += 1
            u = f64_from_bits(iu | 0x3FE0000000000000)
            iu = (0x0010000000000000 - iu) >> 2
        f = u - 1.0
    var hfsq = 0.5 * f * f
    var s: Float64
    var r: Float64
    var z: Float64
    if iu == 0:
        if f == 0:
            if k == 0:
                return 0
            c += Float64(k) * LN2LO_
            return Float64(k) * LN2HI_ + c
        r = hfsq * (1.0 - 0.66666666666666666 * f)
        if k == 0:
            return f - r
        return Float64(k) * LN2HI_ - ((r - (Float64(k) * LN2LO_ + c)) - f)
    s = f / (2.0 + f)
    z = s * s
    r = z * (LP1 + z * (LP2 + z * (LP3 + z * (LP4 + z * (LP5 + z * (LP6 + z * LP7))))))
    if k == 0:
        return f - (hfsq - s * (hfsq + r))
    return Float64(k) * LN2HI_ - ((hfsq - (s * (hfsq + r) + (Float64(k) * LN2LO_ + c))) - f)


@always_inline
def go_sqrt(x: Float64) -> Float64:
    return sqrt(x)


def _normalize(x: Float64) -> Tuple[Float64, Int]:
    comptime SMALLEST_NORMAL = 2.2250738585072014e-308
    if abs(x) < SMALLEST_NORMAL:
        return (x * Float64(1 << 52), -52)
    return (x, 0)


def go_frexp(f_in: Float64) -> Tuple[Float64, Int]:
    if f_in == 0 or not is_finite(f_in):
        return (f_in, 0)
    var n = _normalize(f_in)
    var x = f64_bits(n[0])
    var e = n[1] + Int((x >> 52) & 0x7FF) - 1023 + 1
    x &= ~(UInt64(0x7FF) << 52)
    x |= UInt64(1023 - 1) << 52
    return (f64_from_bits(x), e)


def go_ldexp(frac_in: Float64, exp_in: Int) -> Float64:
    if frac_in == 0 or not is_finite(frac_in):
        return frac_in
    var n = _normalize(frac_in)
    var frac = n[0]
    var e = exp_in + n[1]
    var x = f64_bits(frac)
    e += Int((x >> 52) & 0x7FF) - 1023
    if e < -1075:
        if frac < 0:
            return -0.0
        return 0.0
    if e > 1023:
        if frac < 0:
            return neg_inf64()
        return inf64()
    var m: Float64 = 1.0
    if e < -1022:
        e += 53
        m = 1.0 / Float64(1 << 53)
    x &= ~(UInt64(0x7FF) << 52)
    x |= UInt64(e + 1023) << 52
    return m * f64_from_bits(x)


def go_modf(f: Float64) -> Tuple[Float64, Float64]:
    if f < 1:
        if f < 0:
            var r = go_modf(-f)
            return (-r[0], -r[1])
        if f == 0:
            return (f, f)
        return (0.0, f)
    var x = f64_bits(f)
    var e = Int((x >> 52) & 0x7FF) - 1023
    if e < 64 - 12:
        x &= ~((UInt64(1) << UInt64(64 - 12 - e)) - 1)
    var ip = f64_from_bits(x)
    return (ip, f - ip)


def go_pow(x: Float64, y: Float64) -> Float64:
    """Port of Go math.Pow (pure Go) for finite, positive x (the metrics domain)."""
    if y == 0 or x == 1:
        return 1.0
    if y == 1:
        return x
    if is_nan(x) or is_nan(y):
        return nan64()
    if x == 0:
        if y < 0:
            return inf64()
        return 0.0
    if not is_finite(y):
        if (abs(x) < 1) == (y > 0):
            return 0.0
        return inf64()
    if not is_finite(x):
        if y < 0:
            return 0.0
        return inf64()
    if y == 0.5:
        return sqrt(x)
    if y == -0.5:
        return 1.0 / sqrt(x)
    var mf = go_modf(abs(y))
    var yi = mf[0]
    var yf = mf[1]
    if yf != 0 and x < 0:
        return nan64()
    if yi >= 9.223372036854775808e18:
        if (abs(x) < 1) == (y > 0):
            return 0.0
        return inf64()
    var a1: Float64 = 1.0
    var ae = 0
    if yf != 0:
        if yf > 0.5:
            yf -= 1.0
            yi += 1.0
        a1 = go_exp(yf * go_log(x))
    var fr = go_frexp(x)
    var x1 = fr[0]
    var xe = fr[1]
    var i = Int64(yi)
    while i != 0:
        if xe < -(1 << 12) or (1 << 12) < xe:
            ae += xe
            break
        if (i & 1) == 1:
            a1 *= x1
            ae += xe
        x1 *= x1
        xe <<= 1
        if x1 < 0.5:
            x1 += x1
            xe -= 1
        i >>= 1
    if y < 0:
        a1 = 1.0 / a1
        ae = -ae
    return go_ldexp(a1, ae)
