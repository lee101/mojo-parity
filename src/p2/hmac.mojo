"""SHA-1 / SHA-512 (FIPS 180-4), HMAC over SHA-1/256/512 (RFC 2104), base32 and
RFC 6238 TOTP — the node:crypto subset jobs/ibkr_relogin uses."""

from p2.sha256 import Sha256


@always_inline
def _rotl32(x: UInt32, n: UInt32) -> UInt32:
    return (x << n) | (x >> (32 - n))


def sha1(data: Span[UInt8, _]) -> List[UInt8]:
    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xEFCDAB89
    var h2: UInt32 = 0x98BADCFE
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xC3D2E1F0
    var msg = List[UInt8](capacity=len(data) + 72)
    for b in data:
        msg.append(b)
    var bitlen = UInt64(len(data)) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    for s in range(56, -1, -8):
        msg.append(UInt8((bitlen >> UInt64(s)) & 0xFF))
    var w = List[UInt32](length=80, fill=0)
    for off in range(0, len(msg), 64):
        for i in range(16):
            var j = off + 4 * i
            w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
        for i in range(16, 80):
            w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        for i in range(80):
            var f: UInt32
            var k: UInt32
            if i < 20:
                f = (b & c) | ((~b) & d)
                k = 0x5A827999
            elif i < 40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            elif i < 60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            else:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            var t = _rotl32(a, 5) + f + e + k + w[i]
            e = d
            d = c
            c = _rotl32(b, 30)
            b = a
            a = t
        h0 += a
        h1 += b
        h2 += c
        h3 += d
        h4 += e
    var out = List[UInt8](capacity=20)
    for hv in [h0, h1, h2, h3, h4]:
        out.append(UInt8(hv >> 24))
        out.append(UInt8((hv >> 16) & 0xFF))
        out.append(UInt8((hv >> 8) & 0xFF))
        out.append(UInt8(hv & 0xFF))
    return out^


comptime K512: Array[UInt64, 80] = [
    0x428A2F98D728AE22, 0x7137449123EF65CD, 0xB5C0FBCFEC4D3B2F, 0xE9B5DBA58189DBBC, 0x3956C25BF348B538, 0x59F111F1B605D019,
    0x923F82A4AF194F9B, 0xAB1C5ED5DA6D8118, 0xD807AA98A3030242, 0x12835B0145706FBE, 0x243185BE4EE4B28C, 0x550C7DC3D5FFB4E2,
    0x72BE5D74F27B896F, 0x80DEB1FE3B1696B1, 0x9BDC06A725C71235, 0xC19BF174CF692694, 0xE49B69C19EF14AD2, 0xEFBE4786384F25E3,
    0x0FC19DC68B8CD5B5, 0x240CA1CC77AC9C65, 0x2DE92C6F592B0275, 0x4A7484AA6EA6E483, 0x5CB0A9DCBD41FBD4, 0x76F988DA831153B5,
    0x983E5152EE66DFAB, 0xA831C66D2DB43210, 0xB00327C898FB213F, 0xBF597FC7BEEF0EE4, 0xC6E00BF33DA88FC2, 0xD5A79147930AA725,
    0x06CA6351E003826F, 0x142929670A0E6E70, 0x27B70A8546D22FFC, 0x2E1B21385C26C926, 0x4D2C6DFC5AC42AED, 0x53380D139D95B3DF,
    0x650A73548BAF63DE, 0x766A0ABB3C77B2A8, 0x81C2C92E47EDAEE6, 0x92722C851482353B, 0xA2BFE8A14CF10364, 0xA81A664BBC423001,
    0xC24B8B70D0F89791, 0xC76C51A30654BE30, 0xD192E819D6EF5218, 0xD69906245565A910, 0xF40E35855771202A, 0x106AA07032BBD1B8,
    0x19A4C116B8D2D0C8, 0x1E376C085141AB53, 0x2748774CDF8EEB99, 0x34B0BCB5E19B48A8, 0x391C0CB3C5C95A63, 0x4ED8AA4AE3418ACB,
    0x5B9CCA4F7763E373, 0x682E6FF3D6B2B8A3, 0x748F82EE5DEFB2FC, 0x78A5636F43172F60, 0x84C87814A1F0AB72, 0x8CC702081A6439EC,
    0x90BEFFFA23631E28, 0xA4506CEBDE82BDE9, 0xBEF9A3F7B2C67915, 0xC67178F2E372532B, 0xCA273ECEEA26619C, 0xD186B8C721C0C207,
    0xEADA7DD6CDE0EB1E, 0xF57D4F7FEE6ED178, 0x06F067AA72176FBA, 0x0A637DC5A2C898A6, 0x113F9804BEF90DAE, 0x1B710B35131C471B,
    0x28DB77F523047D84, 0x32CAAB7B40C72493, 0x3C9EBE0A15C9BEBC, 0x431D67C49C100D4C, 0x4CC5D4BECB3E42B6, 0x597F299CFC657E2A,
    0x5FCB6FAB3AD6FAEC, 0x6C44198C4A475817,
]


@always_inline
def _rotr64(x: UInt64, n: UInt64) -> UInt64:
    return (x >> n) | (x << (64 - n))


def sha512(data: Span[UInt8, _]) -> List[UInt8]:
    var h = [UInt64(0x6A09E667F3BCC908), 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1, 0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179]
    var kk = materialize[K512]()
    var msg = List[UInt8](capacity=len(data) + 144)
    for b in data:
        msg.append(b)
    var bitlen = UInt64(len(data)) * 8
    msg.append(0x80)
    while len(msg) % 128 != 112:
        msg.append(0)
    for _ in range(8):
        msg.append(0)
    for s in range(56, -1, -8):
        msg.append(UInt8((bitlen >> UInt64(s)) & 0xFF))
    var w = List[UInt64](length=80, fill=0)
    for off in range(0, len(msg), 128):
        for i in range(16):
            var v: UInt64 = 0
            for k in range(8):
                v = (v << 8) | UInt64(msg[off + 8 * i + k])
            w[i] = v
        for i in range(16, 80):
            var s0 = _rotr64(w[i - 15], 1) ^ _rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
            var s1 = _rotr64(w[i - 2], 19) ^ _rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
            w[i] = w[i - 16] + s0 + w[i - 7] + s1
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for i in range(80):
            var S1 = _rotr64(e, 14) ^ _rotr64(e, 18) ^ _rotr64(e, 41)
            var ch = (e & f) ^ ((~e) & g)
            var t1 = hh + S1 + ch + kk[i] + w[i]
            var S0 = _rotr64(a, 28) ^ _rotr64(a, 34) ^ _rotr64(a, 39)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var t2 = S0 + maj
            hh = g
            g = f
            f = e
            e = d + t1
            d = c
            c = b
            b = a
            a = t1 + t2
        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e
        h[5] += f
        h[6] += g
        h[7] += hh
    var out = List[UInt8](capacity=64)
    for i in range(8):
        for s in range(56, -1, -8):
            out.append(UInt8((h[i] >> UInt64(s)) & 0xFF))
    return out^


def _digest(algo: String, data: Span[UInt8, _]) raises -> List[UInt8]:
    if algo == "sha1":
        return sha1(data)
    if algo == "sha256":
        var h = Sha256()
        h.update(data)
        return h.digest()
    if algo == "sha512":
        return sha512(data)
    raise Error("Invalid digest: " + algo)


def hmac(algo: String, key_in: Span[UInt8, _], msg: Span[UInt8, _]) raises -> List[UInt8]:
    var block = 128 if algo == "sha512" else 64
    var key = List[UInt8]()
    if len(key_in) > block:
        key = _digest(algo, key_in)
    else:
        for b in key_in:
            key.append(b)
    while len(key) < block:
        key.append(0)
    var inner = List[UInt8]()
    var outer = List[UInt8]()
    for i in range(block):
        inner.append(key[i] ^ 0x36)
        outer.append(key[i] ^ 0x5C)
    for b in msg:
        inner.append(b)
    var ih = _digest(algo, Span(inner))
    for b in ih:
        outer.append(b)
    return _digest(algo, Span(outer))


def base32_decode(s: String) raises -> List[UInt8]:
    """relogin.mjs base32Decode: uppercase, strip whitespace - _ =, A-Z2-7 only, >= 16 chars."""
    var clean = List[UInt8]()
    for b0 in s.as_bytes():
        var b = b0
        if b >= 97 and b <= 122:
            b -= 32
        if b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12 or b == 45 or b == 95 or b == 61:
            continue
        clean.append(b)
    for b in clean:
        if not ((b >= 65 and b <= 90) or (b >= 50 and b <= 55)):
            raise Error("secret is not base32 (A-Z2-7, >=16 chars)")
    if len(clean) < 16:
        raise Error("secret is not base32 (A-Z2-7, >=16 chars)")
    var out = List[UInt8]()
    var bits = 0
    var val = 0
    for b in clean:
        var idx = Int(b) - 65 if b >= 65 else Int(b) - 50 + 26
        val = ((val << 5) | idx) & 0xFFFFFFFF
        bits += 5
        if bits >= 8:
            out.append(UInt8((val >> (bits - 8)) & 255))
            bits -= 8
    return out^


def totp(secret: String, at_ms: Int, period: Int, digits: Int, algo: String) raises -> String:
    var key = base32_decode(secret)
    var ctr = UInt64(at_ms // 1000 // period) if at_ms >= 0 else UInt64(0)
    var c = List[UInt8]()
    for s in range(56, -1, -8):
        c.append(UInt8((ctr >> UInt64(s)) & 0xFF))
    var mac = hmac(algo, Span(key), Span(c))
    var off = Int(mac[len(mac) - 1] & 0x0F)
    var code = ((Int(mac[off]) & 0x7F) << 24) | (Int(mac[off + 1]) << 16) | (Int(mac[off + 2]) << 8) | Int(mac[off + 3])
    var mod = 1
    for _ in range(digits):
        mod *= 10
    var s = String(code % mod)
    while s.byte_length() < digits:
        s = "0" + s
    return s
