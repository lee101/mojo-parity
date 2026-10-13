"""numpy-exact float64 kernels used by the rotation features (baseline SSE2/AVX2 builds, no AVX512 SVML):
add.reduce over a contiguous axis = pairwise_sum (8 accumulators, blocks of 128) added to the 0 identity;
reductions over the outer axis of a C-contiguous array are sequential; log/log1p are libm."""

from std.ffi import external_call
from std.math import sqrt


@always_inline
def clog(x: Float64) -> Float64:
    return external_call["log", Float64](x)


@always_inline
def clog1p(x: Float64) -> Float64:
    return external_call["log1p", Float64](x)


@no_inline
def mul_rn(a: Float64, b: Float64) -> Float64:
    return a * b


def pw_sum(a: List[Float64], lo: Int, n: Int) -> Float64:
    if n < 8:
        var r = Float64(-0.0)
        for i in range(n):
            r += a[lo + i]
        return r
    if n <= 128:
        var r0 = a[lo]
        var r1 = a[lo + 1]
        var r2 = a[lo + 2]
        var r3 = a[lo + 3]
        var r4 = a[lo + 4]
        var r5 = a[lo + 5]
        var r6 = a[lo + 6]
        var r7 = a[lo + 7]
        var i = 8
        while i < n - (n % 8):
            r0 += a[lo + i]
            r1 += a[lo + i + 1]
            r2 += a[lo + i + 2]
            r3 += a[lo + i + 3]
            r4 += a[lo + i + 4]
            r5 += a[lo + i + 5]
            r6 += a[lo + i + 6]
            r7 += a[lo + i + 7]
            i += 8
        var res = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7))
        while i < n:
            res += a[lo + i]
            i += 1
        return res
    var n2 = n // 2
    n2 -= n2 % 8
    return pw_sum(a, lo, n2) + pw_sum(a, lo + n2, n - n2)


def vsum(a: List[Float64]) -> Float64:
    """np.add.reduce of a contiguous 1-D array."""
    return 0.0 + pw_sum(a, 0, len(a))


def vmean(a: List[Float64]) -> Float64:
    return vsum(a) / Float64(len(a))


def vvar(a: List[Float64]) -> Float64:
    """ndarray.var(): mean, squared deviations, mean."""
    var n = len(a)
    var m = vsum(a) / Float64(n)
    var d = List[Float64](capacity=n)
    for i in range(n):
        var e = a[i] - m
        d.append(mul_rn(e, e))
    return vsum(d) / Float64(n)


def vstd(a: List[Float64]) -> Float64:
    return sqrt(vvar(a))


struct Mat(Copyable, Movable):
    """C-contiguous rows x cols float64."""
    var r: Int
    var c: Int
    var d: List[Float64]

    def __init__(out self, r: Int, c: Int):
        self.r = r
        self.c = c
        self.d = List[Float64](length=r * c, fill=0)

    @always_inline
    def at(self, i: Int, j: Int) -> Float64:
        return self.d[i * self.c + j]

    @always_inline
    def set(mut self, i: Int, j: Int, v: Float64):
        self.d[i * self.c + j] = v

    def rows(self, lo: Int, hi: Int) -> Mat:
        var m = Mat(hi - lo, self.c)
        for i in range(lo, hi):
            for j in range(self.c):
                m.set(i - lo, j, self.at(i, j))
        return m^

    def sum0(self) -> List[Float64]:
        """add.reduce(axis=0): identity 0 then rows in order."""
        var out = List[Float64](length=self.c, fill=0.0)
        for i in range(self.r):
            for j in range(self.c):
                out[j] = out[j] + self.at(i, j)
        return out^

    def mean0(self) -> List[Float64]:
        var s = self.sum0()
        for j in range(self.c):
            s[j] = s[j] / Float64(self.r)
        return s^

    def std0(self) -> List[Float64]:
        var m = self.mean0()
        var sq = Mat(self.r, self.c)
        for i in range(self.r):
            for j in range(self.c):
                var e = self.at(i, j) - m[j]
                sq.set(i, j, mul_rn(e, e))
        var s = sq.sum0()
        for j in range(self.c):
            s[j] = sqrt(s[j] / Float64(self.r))
        return s^

    def mean1(self) -> List[Float64]:
        """mean(axis=1) of a contiguous matrix: pairwise per row."""
        var out = List[Float64](capacity=self.r)
        for i in range(self.r):
            out.append((0.0 + pw_sum(self.d, i * self.c, self.c)) / Float64(self.c))
        return out^


def np_max(a: Float64, b: Float64) -> Float64:
    """np.maximum: NaN propagates."""
    if a != a:
        return a
    if b != b:
        return b
    return a if a >= b else b


def np_min(a: Float64, b: Float64) -> Float64:
    if a != a:
        return a
    if b != b:
        return b
    return a if a <= b else b


def np_clip(x: Float64, lo: Float64, hi: Float64) -> Float64:
    return np_min(np_max(x, lo), hi)


def py_max(a: Float64, b: Float64) -> Float64:
    """builtin max(a, b): first unless b > a."""
    return b if b > a else a


def pct_rank(v: List[Float64]) -> List[Float64]:
    """pandas Series.rank(method='average', pct=True) for finite values."""
    var n = len(v)
    var idx = List[Int](capacity=n)
    for i in range(n):
        idx.append(i)
    for i in range(1, n):
        var x = idx[i]
        var k = i - 1
        while k >= 0 and v[idx[k]] > v[x]:
            idx[k + 1] = idx[k]
            k -= 1
        idx[k + 1] = x
    var out = List[Float64](length=n, fill=0)
    var i = 0
    while i < n:
        var j = i
        while j + 1 < n and v[idx[j + 1]] == v[idx[i]]:
            j += 1
        var s: Float64 = 0
        for k in range(i, j + 1):
            s += Float64(k + 1)
        var avg = s / Float64(j - i + 1)
        for k in range(i, j + 1):
            out[idx[k]] = avg / Float64(n)
        i = j + 1
    return out^
