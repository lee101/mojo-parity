"""Cross-process request pacing for a shared broker API key.

When P2M_HTTP_MIN_INTERVAL_MS > 0, every request to a host containing
P2M_HTTP_RATE_HOST (default "alpaca.markets") first takes an exclusive flock on
P2M_HTTP_RATE_FILE (default /tmp/p2m-alpaca-rate), reads the last request time,
sleeps out the remaining interval and records its own start. All p2m processes
and threads sharing the key (trader, refresh, capture, shadow) are paced together.
"""

from std.ffi import external_call
from std.os import getenv
from p2.sysio import c_open, c_write
from p2.ptr import keep


def _now_ns() -> Int:
    var ts = List[Int](length=2, fill=0)
    _ = external_call["clock_gettime", Int32](Int32(0), ts.unsafe_ptr())
    return ts[0] * 1_000_000_000 + ts[1]


def pace(host: String):
    var ms_s = getenv("P2M_HTTP_MIN_INTERVAL_MS", "")
    if ms_s.byte_length() == 0:
        return
    var ms: Int
    try:
        ms = atol(ms_s)
    except:
        return
    if ms <= 0 or host.find(getenv("P2M_HTTP_RATE_HOST", "alpaca.markets")) < 0:
        return
    var path = getenv("P2M_HTTP_RATE_FILE", "/tmp/p2m-alpaca-rate")
    var c = List[UInt8]()
    for b in path.as_bytes():
        c.append(b)
    c.append(0)
    var fd = c_open(c.unsafe_ptr(), Int32(0o102), UInt32(0o666))
    keep(c)
    if fd < 0:
        return
    _ = external_call["flock", Int32](fd, Int32(2))
    var buf = List[UInt8](length=32, fill=0)
    var n = external_call["pread", Int](fd, buf.unsafe_ptr(), Int(31), Int(0))
    var last = 0
    for i in range(max(0, n)):
        var b = buf[i]
        if b >= 48 and b <= 57:
            last = last * 10 + Int(b - 48)
    var now = _now_ns()
    var wait = last + ms * 1_000_000 - now
    if wait > 0 and wait < 60_000_000_000:
        var ts = List[Int](length=2, fill=0)
        ts[0] = wait // 1_000_000_000
        ts[1] = wait % 1_000_000_000
        _ = external_call["nanosleep", Int32](ts.unsafe_ptr(), Int(0))
        keep(ts)
        now = _now_ns()
    var s = String(now)
    _ = external_call["ftruncate", Int32](fd, Int(0))
    _ = external_call["pwrite", Int](fd, s.unsafe_ptr(), s.byte_length(), Int(0))
    keep(s)
    keep(buf)
    _ = external_call["flock", Int32](fd, Int32(8))
    _ = external_call["close", Int32](fd)
