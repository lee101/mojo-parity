"""Go-compatible float formatting.

fmt_fixed reproduces Go's %.Nf / strconv.FormatFloat(x, 'f', N, 64): the exact
binary value rounded half-to-even at N decimals. fmt_short reproduces
strconv.FormatFloat(x, 'f', -1, 64) (shortest round-trip digits, no exponent).
"""

from p2.gomath import f64_bits, is_finite


def _u128_str(v_in: UInt128) -> String:
    if v_in == 0:
        return "0"
    var v = v_in
    var digits = List[UInt8]()
    while v > 0:
        digits.append(UInt8(Int(v % 10)) + 48)
        v = v // 10
    var out = String("")
    for i in range(len(digits) - 1, -1, -1):
        out += chr(Int(digits[i]))
    return out


def fmt_fixed(x: Float64, decimals: Int, plus: Bool = False) -> String:
    if x != x:
        return "NaN"
    if not is_finite(x):
        if x > 0:
            return "+Inf"
        return "-Inf"
    var bits = f64_bits(x)
    var neg = (bits >> 63) == 1
    var exp_bits = Int((bits >> 52) & 0x7FF)
    var frac = bits & 0x000FFFFFFFFFFFFF
    var m: UInt128
    var e: Int
    if exp_bits == 0:
        m = UInt128(frac)
        e = -1074
    else:
        m = UInt128(frac | 0x0010000000000000)
        e = exp_bits - 1075
    var pow10 = UInt128(1)
    for _ in range(decimals):
        pow10 *= 10
    var n: UInt128
    if e >= 0:
        if e > 60:
            return String(x)
        n = (m << UInt128(e)) * pow10
    else:
        var sh = -e
        var num = m * pow10
        if sh >= 127:
            n = 0
        else:
            n = num >> UInt128(sh)
            var rem = num - (n << UInt128(sh))
            var half = UInt128(1) << UInt128(sh - 1)
            if rem > half or (rem == half and (n & 1) == 1):
                n += 1
    var s = _u128_str(n)
    if decimals > 0:
        while s.byte_length() <= decimals:
            s = "0" + s
        var cut = s.byte_length() - decimals
        var _a1_s = String(s[byte=0:cut]) + "." + String(s[byte=cut:])
        s = _a1_s
    var is_zero = n == 0
    if neg and not is_zero:
        return "-" + s
    if neg and is_zero:
        return "-" + s
    if plus:
        return "+" + s
    return s


def fmt_short(x: Float64) -> String:
    """strconv.FormatFloat(x, 'f', -1, 64): shortest digits rendered without exponent."""
    var r = String(x)
    if r.find("e") < 0:
        if r.endswith(".0"):
            return String(r[byte=0 : r.byte_length() - 2])
        return r
    var neg = r.startswith("-")
    if neg:
        var r2 = String(r[byte=1:])
        r = r2
    var epos = r.find("e")
    var mant = String(r[byte=0:epos])
    var ex = _int_noraise(String(r[byte = epos + 1 :]))
    var dot = mant.find(".")
    var digits: String
    var int_len: Int
    if dot >= 0:
        digits = String(mant[byte=0:dot]) + String(mant[byte = dot + 1 :])
        int_len = dot
    else:
        digits = mant
        int_len = mant.byte_length()
    var point = int_len + ex
    var out: String
    if point <= 0:
        out = "0."
        for _ in range(-point):
            out += "0"
        out += digits
    elif point >= digits.byte_length():
        out = digits
        for _ in range(point - digits.byte_length()):
            out += "0"
    else:
        out = String(digits[byte=0:point]) + "." + String(digits[byte=point:])
    if neg:
        return "-" + out
    return out


def fmt_float_list(values: List[Float64]) -> String:
    var out = String("")
    for i in range(len(values)):
        if i > 0:
            out += ","
        out += fmt_short(values[i])
    return out


def fmt_int_list(values: List[Int]) -> String:
    var out = String("")
    for i in range(len(values)):
        if i > 0:
            out += ","
        out += String(values[i])
    return out


def fmt_repr(x: Float64) -> String:
    return String(x)


def _int_noraise(s: String) -> Int:
    var v = 0
    var neg = False
    for b in s.as_bytes():
        if b == 45:
            neg = True
        elif b >= 48 and b <= 57:
            v = v * 10 + Int(b - 48)
    return -v if neg else v
