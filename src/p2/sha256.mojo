"""SHA-256 (FIPS 180-4), identical output to Go crypto/sha256 + hex.EncodeToString."""

from std.os.path import getsize

comptime K256: Array[UInt32, 64] = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
]


@always_inline
def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))


struct Sha256(Movable):
    var h: List[UInt32]
    var buf: List[UInt8]
    var total: UInt64
    var k: List[UInt32]

    def __init__(out self):
        self.h = [UInt32(0x6A09E667), 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
        self.buf = List[UInt8](capacity=64)
        self.total = 0
        self.k = List[UInt32](capacity=64)
        var kk = materialize[K256]()
        for i in range(64):
            self.k.append(kk[i])

    def _block(mut self, p: Span[UInt8, _], off: Int):
        var w = List[UInt32](length=64, fill=0)
        for i in range(16):
            var j = off + 4 * i
            w[i] = (UInt32(p[j]) << 24) | (UInt32(p[j + 1]) << 16) | (UInt32(p[j + 2]) << 8) | UInt32(p[j + 3])
        for i in range(16, 64):
            var v1 = w[i - 2]
            var t1 = _rotr(v1, 17) ^ _rotr(v1, 19) ^ (v1 >> 10)
            var v2 = w[i - 15]
            var t2 = _rotr(v2, 7) ^ _rotr(v2, 18) ^ (v2 >> 3)
            w[i] = t1 + w[i - 7] + t2 + w[i - 16]
        var a = self.h[0]
        var b = self.h[1]
        var c = self.h[2]
        var d = self.h[3]
        var e = self.h[4]
        var f = self.h[5]
        var g = self.h[6]
        var hh = self.h[7]
        for i in range(64):
            var t1 = hh + (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) + ((e & f) ^ (~e & g)) + self.k[i] + w[i]
            var t2 = (_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))
            hh = g
            g = f
            f = e
            e = d + t1
            d = c
            c = b
            b = a
            a = t1 + t2
        self.h[0] += a
        self.h[1] += b
        self.h[2] += c
        self.h[3] += d
        self.h[4] += e
        self.h[5] += f
        self.h[6] += g
        self.h[7] += hh

    def update(mut self, data: Span[UInt8, _]):
        self.total += UInt64(len(data))
        var i = 0
        var n = len(data)
        if len(self.buf) > 0:
            while i < n and len(self.buf) < 64:
                self.buf.append(data[i])
                i += 1
            if len(self.buf) == 64:
                var blk = self.buf.copy()
                self._block(blk, 0)
                self.buf.clear()
        while i + 64 <= n:
            self._block(data, i)
            i += 64
        while i < n:
            self.buf.append(data[i])
            i += 1

    def digest(mut self) -> List[UInt8]:
        var bitlen = self.total * 8
        var pad = List[UInt8]()
        pad.append(0x80)
        var rem = Int((self.total + 1) % 64)
        var zeros = 56 - rem if rem <= 56 else 120 - rem
        for _ in range(zeros):
            pad.append(0)
        for s in range(56, -1, -8):
            pad.append(UInt8((bitlen >> UInt64(s)) & 0xFF))
        var t = self.total
        self.update(pad)
        self.total = t
        var out = List[UInt8](capacity=32)
        for i in range(8):
            out.append(UInt8(self.h[i] >> 24))
            out.append(UInt8((self.h[i] >> 16) & 0xFF))
            out.append(UInt8((self.h[i] >> 8) & 0xFF))
            out.append(UInt8(self.h[i] & 0xFF))
        return out^


def hex_lower(b: Span[UInt8, _]) -> String:
    var hx = "0123456789abcdef".as_bytes()
    var out = List[UInt8](capacity=2 * len(b))
    for x in b:
        out.append(hx[Int(x) >> 4])
        out.append(hx[Int(x) & 0xF])
    return String(unsafe_from_utf8=out)


def sha256_hex(data: Span[UInt8, _]) -> String:
    var h = Sha256()
    h.update(data)
    var d = h.digest()
    return hex_lower(d)


def sha256_string_hex(s: String) -> String:
    return sha256_hex(s.as_bytes())


def sha256_file_hex(path: String) raises -> String:
    var f = open(path, "r")
    var h = Sha256()
    while True:
        var chunk = f.read_bytes(1 << 20)
        if len(chunk) == 0:
            break
        h.update(chunk)
    f.close()
    var d = h.digest()
    return hex_lower(d)
