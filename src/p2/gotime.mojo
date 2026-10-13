"""Go `time` semantics: Time (Unix sec + nsec + zone offset/abbr), Location (TZif
zoneinfo with POSIX TZ footer), Date normalization, layouts (Format/Parse), and
Duration (String/ParseDuration/Hours...). Integer arithmetic follows Go's
truncating division; parse/format error text matches Go's time package.

"Local" for parsing is UTC unless parse_in(..., local=...) is given; Go's Local
only changes the zone abbreviation of a parsed time whose offset matches it.
"""

from std.os import getenv
from std.os.path import exists

comptime ALPHA = -9223372036854775807 - 1
comptime OMEGA = 9223372036854775807
comptime UNIX_TO_INTERNAL = 62135596800
comptime NANOSECOND = 1
comptime MICROSECOND = 1000
comptime MILLISECOND = 1000000
comptime SECOND = 1000000000
comptime MINUTE = 60000000000
comptime HOUR = 3600000000000
comptime MIN_DURATION = -9223372036854775807 - 1
comptime MAX_DURATION = 9223372036854775807


@always_inline
def tdiv(a: Int, b: Int) -> Int:
    """Go integer division (truncates toward zero)."""
    var q = a // b
    if q < 0 and q * b != a:
        q += 1
    return q


@always_inline
def tmod(a: Int, b: Int) -> Int:
    """Go remainder (sign of the dividend)."""
    return a - tdiv(a, b) * b


@always_inline
def _fdiv(a: Int, b: Int) -> Int:
    var q = tdiv(a, b)
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q -= 1
    return q


def is_leap(y: Int) -> Bool:
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def days_in(m: Int, y: Int) -> Int:
    if m == 2:
        return 29 if is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


comptime _DAYS_BEFORE: Array[Int, 13] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]


def _days_before(m: Int) -> Int:
    var v = materialize[_DAYS_BEFORE]()
    return v[m - 1]


def days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    var y = y0 - 1 if m <= 2 else y0
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_from_days(days: Int) -> Tuple[Int, Int, Int]:
    var z = days + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


def month_name(m: Int) -> String:
    if m >= 1 and m <= 12:
        return String(
            "January,February,March,April,May,June,July,August,September,October,November,December".split(",")[m - 1]
        )
    return "%!Month(" + String(m) + ")"


def weekday_name(d: Int) -> String:
    if d >= 0 and d <= 6:
        return String("Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday".split(",")[d])
    return "%!Weekday(" + String(d) + ")"


# ---------------------------------------------------------------- Location


@fieldwise_init
struct Zone(Copyable, ImplicitlyCopyable, Movable):
    var name: String
    var offset: Int
    var is_dst: Bool


@fieldwise_init
struct ZoneTrans(Copyable, ImplicitlyCopyable, Movable):
    var when: Int
    var index: Int


@fieldwise_init
struct Lookup(Copyable, ImplicitlyCopyable, Movable):
    var name: String
    var offset: Int
    var start: Int
    var end: Int
    var is_dst: Bool


struct Location(Copyable, Movable):
    var name: String
    var zones: List[Zone]
    var tx: List[ZoneTrans]
    var extend: String

    def __init__(out self, name: String):
        """Empty zone list = UTC."""
        self.name = name
        self.zones = List[Zone]()
        self.tx = List[ZoneTrans]()
        self.extend = String("")

    @staticmethod
    def utc() -> Location:
        return Location("UTC")

    @staticmethod
    def fixed(name: String, offset: Int) -> Location:
        var l = Location(name)
        l.zones.append(Zone(name, offset, False))
        l.tx.append(ZoneTrans(ALPHA, 0))
        return l^

    def _first_zone(self) -> Int:
        var used = False
        for t in self.tx:
            if t.index == 0:
                used = True
        if not used:
            return 0
        if len(self.tx) > 0 and self.zones[self.tx[0].index].is_dst:
            var zi = self.tx[0].index - 1
            while zi >= 0:
                if not self.zones[zi].is_dst:
                    return zi
                zi -= 1
        for zi in range(len(self.zones)):
            if not self.zones[zi].is_dst:
                return zi
        return 0

    def lookup(self, sec: Int) -> Lookup:
        if len(self.zones) == 0:
            return Lookup("UTC", 0, ALPHA, OMEGA, False)
        if len(self.tx) == 0 or sec < self.tx[0].when:
            var z = self.zones[self._first_zone()]
            var end = self.tx[0].when if len(self.tx) > 0 else OMEGA
            return Lookup(z.name, z.offset, ALPHA, end, z.is_dst)
        var end = OMEGA
        var lo = 0
        var hi = len(self.tx)
        while hi - lo > 1:
            var m = (lo + hi) >> 1
            var lim = self.tx[m].when
            if sec < lim:
                end = lim
                hi = m
            else:
                lo = m
        var z = self.zones[self.tx[lo].index]
        var out = Lookup(z.name, z.offset, self.tx[lo].when, end, z.is_dst)
        if lo == len(self.tx) - 1 and self.extend.byte_length() > 0:
            var r = _tzset(self.extend, out.start, sec)
            if r[1]:
                return r[0]
        return out


def _be(b: List[UInt8], off: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v = (v << 8) | Int(b[off + i])
    if n == 4 and v >= 0x80000000:
        v -= 0x100000000
    return v


def load_tzdata(name: String, b: List[UInt8]) raises -> Location:
    """LoadLocationFromTZData: v1 header, then the 64-bit v2+ block and footer."""
    var bad = Error("malformed time zone information")
    if len(b) < 44 or b[0] != 84 or b[1] != 90 or b[2] != 105 or b[3] != 102:
        raise bad
    var version = Int(b[4])
    var is64 = False
    var cnt = List[Int](length=6, fill=0)
    for i in range(6):
        cnt[i] = _be(b, 20 + 4 * i, 4)
    var p = 44
    if version >= 50:
        var skip = cnt[3] * 4 + cnt[3] + cnt[4] * 6 + cnt[5] + cnt[2] * 8 + cnt[1] + cnt[0]
        p += skip
        if len(b) < p + 44 or b[p] != 84:
            raise bad
        for i in range(6):
            cnt[i] = _be(b, p + 20 + 4 * i, 4)
        p += 44
        is64 = True
    var tsz = 8 if is64 else 4
    var nutc = cnt[0]
    var nstd = cnt[1]
    var nleap = cnt[2]
    var ntime = cnt[3]
    var nzone = cnt[4]
    var nchar = cnt[5]
    var need = ntime * tsz + ntime + nzone * 6 + nchar + nleap * (tsz + 4) + nstd + nutc
    if len(b) < p + need or nzone == 0:
        raise bad
    var ttimes = p
    var tzones = ttimes + ntime * tsz
    var zdata = tzones + ntime
    var abbr = zdata + nzone * 6
    var rest = abbr + nchar + nleap * (tsz + 4) + nstd + nutc
    var loc = Location(name)
    for i in range(nzone):
        var o = zdata + 6 * i
        var off = _be(b, o, 4)
        var ai = Int(b[o + 5])
        if ai >= nchar:
            raise bad
        var e = abbr + ai
        var nm = List[UInt8]()
        while e < abbr + nchar and b[e] != 0:
            nm.append(b[e])
            e += 1
        loc.zones.append(Zone(String(unsafe_from_utf8=nm), off, b[o + 4] != 0))
    for i in range(ntime):
        var w: Int
        if is64:
            w = 0
            for k in range(8):
                w = (w << 8) | Int(b[ttimes + 8 * i + k])
        else:
            w = _be(b, ttimes + 4 * i, 4)
        var zi = Int(b[tzones + i])
        if zi >= nzone:
            raise bad
        loc.tx.append(ZoneTrans(w, zi))
    if len(loc.tx) == 0:
        loc.tx.append(ZoneTrans(ALPHA, 0))
    if is64:
        var n = len(b) - rest
        if n > 2 and b[rest] == 10 and b[len(b) - 1] == 10:
            var ext = List[UInt8]()
            for i in range(rest + 1, len(b) - 1):
                ext.append(b[i])
            loc.extend = String(unsafe_from_utf8=ext)
    return loc^


def load_location(name: String) raises -> Location:
    """time.LoadLocation (ZONEINFO dir, then the platform zoneinfo directories)."""
    if name.byte_length() == 0 or name == "UTC":
        return Location.utc()
    if name == "Local":
        return local_location()
    if name.find("..") >= 0 or name.startswith("/") or name.startswith("\\"):
        raise Error("time: invalid location name")
    var dirs = List[String]()
    var zi = getenv("ZONEINFO", "")
    if zi.byte_length() > 0:
        dirs.append(zi + "/")
    dirs.append("/usr/share/zoneinfo/")
    dirs.append("/usr/share/lib/zoneinfo/")
    dirs.append("/usr/lib/locale/TZ/")
    dirs.append("/etc/zoneinfo/")
    for d in dirs:
        var path = d + name
        if exists(path):
            try:
                return load_tzdata(name, _read_file(path))
            except:
                pass
    raise Error("unknown time zone " + name)


def local_location() -> Location:
    """Go initLocal: unset TZ -> /etc/localtime, TZ="" or unknown -> UTC."""
    var tz = getenv("TZ", "\x00")
    try:
        if tz == "\x00":
            var l = load_tzdata("Local", _read_file("/etc/localtime"))
            return l^
        var t = String(tz[byte=1:]) if tz.startswith(":") else tz
        if t.startswith("/"):
            var l = load_tzdata("Local" if t == "/etc/localtime" else t, _read_file(t))
            return l^
        if t.byte_length() > 0 and t != "UTC":
            return load_location(t)
    except:
        pass
    return Location.utc()


def _read_file(path: String) raises -> List[UInt8]:
    var f = open(path, "r")
    var b = f.read_bytes()
    f.close()
    return b^


# POSIX TZ footer rules (Go tzset).


def _tz_num(s: List[UInt8], mut i: Int, lo: Int, hi: Int) -> Int:
    """Returns -1 on failure; advances i."""
    if i >= len(s):
        return -1
    var num = 0
    var start = i
    while i < len(s):
        var c = s[i]
        if c < 48 or c > 57:
            if i == start or num < lo:
                return -1
            return num
        num = num * 10 + Int(c) - 48
        if num > hi:
            return -1
        i += 1
    if num < lo:
        return -1
    return num


def _tz_offset(s: List[UInt8], mut i: Int, mut ok: Bool) -> Int:
    if i >= len(s):
        ok = False
        return 0
    var neg = False
    if s[i] == 43:
        i += 1
    elif s[i] == 45:
        i += 1
        neg = True
    var h = _tz_num(s, i, 0, 24 * 7)
    if h < 0:
        ok = False
        return 0
    var off = h * 3600
    if i < len(s) and s[i] == 58:
        i += 1
        var m = _tz_num(s, i, 0, 59)
        if m < 0:
            ok = False
            return 0
        off += m * 60
        if i < len(s) and s[i] == 58:
            i += 1
            var sec = _tz_num(s, i, 0, 59)
            if sec < 0:
                ok = False
                return 0
            off += sec
    ok = True
    return -off if neg else off


def _tz_name(s: List[UInt8], mut i: Int) -> String:
    """Returns "" on failure."""
    if i >= len(s):
        return ""
    var out = List[UInt8]()
    if s[i] != 60:
        var start = i
        while i < len(s):
            var c = s[i]
            if (c >= 48 and c <= 57) or c == 44 or c == 45 or c == 43:
                if i - start < 3:
                    return ""
                return String(unsafe_from_utf8=out)
            out.append(c)
            i += 1
        if len(out) < 3:
            return ""
        return String(unsafe_from_utf8=out)
    var j = i + 1
    while j < len(s):
        if s[j] == 62:
            i = j + 1
            return String(unsafe_from_utf8=out)
        out.append(s[j])
        j += 1
    return ""


@fieldwise_init
struct _Rule(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var day: Int
    var week: Int
    var mon: Int
    var time: Int


def _tz_rule(s: List[UInt8], mut i: Int, mut ok: Bool) -> _Rule:
    var r = _Rule(0, 0, 0, 0, 0)
    ok = False
    if i >= len(s):
        return r
    if s[i] == 74:
        i += 1
        var jd = _tz_num(s, i, 1, 365)
        if jd < 0:
            return r
        r.kind = 0
        r.day = jd
    elif s[i] == 77:
        i += 1
        var mon = _tz_num(s, i, 1, 12)
        if mon < 0 or i >= len(s) or s[i] != 46:
            return r
        i += 1
        var week = _tz_num(s, i, 1, 5)
        if week < 0 or i >= len(s) or s[i] != 46:
            return r
        i += 1
        var day = _tz_num(s, i, 0, 6)
        if day < 0:
            return r
        r.kind = 2
        r.day = day
        r.week = week
        r.mon = mon
    else:
        var day = _tz_num(s, i, 0, 365)
        if day < 0:
            return r
        r.kind = 1
        r.day = day
    if i >= len(s) or s[i] != 47:
        r.time = 2 * 3600
        ok = True
        return r
    i += 1
    var ok2 = False
    r.time = _tz_offset(s, i, ok2)
    ok = ok2
    return r


def _tzrule_time(year: Int, r: _Rule, off: Int) -> Int:
    var s: Int
    if r.kind == 0:
        s = (r.day - 1) * 86400
        if is_leap(year) and r.day >= 60:
            s += 86400
    elif r.kind == 1:
        s = r.day * 86400
    else:
        var m1 = tmod(r.mon + 9, 12) + 1
        var yy0 = year
        if r.mon <= 2:
            yy0 -= 1
        var yy1 = tdiv(yy0, 100)
        var yy2 = tmod(yy0, 100)
        var dow = tmod(tdiv(26 * m1 - 2, 10) + 1 + yy2 + tdiv(yy2, 4) + tdiv(yy1, 4) - 2 * yy1, 7)
        if dow < 0:
            dow += 7
        var d = r.day - dow
        if d < 0:
            d += 7
        for _ in range(1, r.week):
            if d + 7 >= days_in(r.mon, year):
                break
            d += 7
        d += _days_before(r.mon)
        if is_leap(year) and r.mon > 2:
            d += 1
        s = d * 86400
    return s + r.time - off


def _tzset(ext: String, last_tx: Int, sec: Int) -> Tuple[Lookup, Bool]:
    var fail = (Lookup("", 0, 0, 0, False), False)
    var s = List[UInt8]()
    for c in ext.as_bytes():
        s.append(c)
    var i = 0
    var std_name = _tz_name(s, i)
    if std_name.byte_length() == 0:
        return fail
    var ok = False
    var std_off = -_tz_offset(s, i, ok)
    if not ok:
        return fail
    if i >= len(s) or s[i] == 44:
        return (Lookup(std_name, std_off, last_tx, OMEGA, False), True)
    var dst_name = _tz_name(s, i)
    if dst_name.byte_length() == 0:
        return fail
    var dst_off: Int
    if i >= len(s) or s[i] == 44:
        dst_off = std_off + 3600
    else:
        dst_off = -_tz_offset(s, i, ok)
        if not ok:
            return fail
    if i >= len(s):
        for c in ",M3.2.0,M11.1.0".as_bytes():
            s.append(c)
    if s[i] != 44 and s[i] != 59:
        return fail
    i += 1
    var r1 = _tz_rule(s, i, ok)
    if not ok or i >= len(s) or s[i] != 44:
        return fail
    i += 1
    var r2 = _tz_rule(s, i, ok)
    if not ok or i < len(s):
        return fail
    var days = _fdiv(sec, 86400)
    var ymd = civil_from_days(days)
    var year = ymd[0]
    var yday = days - days_from_civil(year, 1, 1) + 1
    var ysec = (yday - 1) * 86400 + tmod(sec, 86400)
    var ystart = sec - ysec
    var start_sec = _tzrule_time(year, r1, std_off)
    var end_sec = _tzrule_time(year, r2, dst_off)
    var dst_is = True
    var std_is = False
    if end_sec < start_sec:
        var t0 = start_sec
        start_sec = end_sec
        end_sec = t0
        var n0 = std_name
        std_name = dst_name
        dst_name = n0
        var o0 = std_off
        std_off = dst_off
        dst_off = o0
        std_is = True
        dst_is = False
    if ysec < start_sec:
        return (Lookup(std_name, std_off, ystart, start_sec + ystart, std_is), True)
    if ysec >= end_sec:
        return (Lookup(std_name, std_off, end_sec + ystart, ystart + 365 * 86400, std_is), True)
    return (Lookup(dst_name, dst_off, start_sec + ystart, end_sec + ystart, dst_is), True)


# ---------------------------------------------------------------- Time


@fieldwise_init
struct GoTime(Copyable, ImplicitlyCopyable, Movable):
    """Instant (Unix sec + nsec in [0,1e9)) plus the zone it is displayed in."""

    var sec: Int
    var nsec: Int
    var off: Int
    var abbr: String

    @staticmethod
    def zero() -> GoTime:
        return GoTime(-UNIX_TO_INTERNAL, 0, 0, "UTC")

    @staticmethod
    def unix_utc(sec: Int, nsec: Int = 0) -> GoTime:
        var s = sec
        var n = nsec
        if n < 0 or n >= SECOND:
            var q = tdiv(n, SECOND)
            s += q
            n -= q * SECOND
            if n < 0:
                n += SECOND
                s -= 1
        return GoTime(s, n, 0, "UTC")

    def is_zero(self) -> Bool:
        return self.sec == -UNIX_TO_INTERNAL and self.nsec == 0

    def utc(self) -> GoTime:
        return GoTime(self.sec, self.nsec, 0, "UTC")

    def in_loc(self, loc: Location) -> GoTime:
        var z = loc.lookup(self.sec)
        return GoTime(self.sec, self.nsec, z.offset, z.name)

    def unix(self) -> Int:
        return self.sec

    def unix_nano(self) -> Int:
        return self.sec * SECOND + self.nsec

    def unix_milli(self) -> Int:
        return self.sec * 1000 + self.nsec // MILLISECOND

    def equal(self, u: GoTime) -> Bool:
        return self.sec == u.sec and self.nsec == u.nsec

    def before(self, u: GoTime) -> Bool:
        return self.sec < u.sec or (self.sec == u.sec and self.nsec < u.nsec)

    def after(self, u: GoTime) -> Bool:
        return self.sec > u.sec or (self.sec == u.sec and self.nsec > u.nsec)

    def compare(self, u: GoTime) -> Int:
        if self.before(u):
            return -1
        if self.after(u):
            return 1
        return 0

    def add(self, d: Int) -> GoTime:
        var dsec = tdiv(d, SECOND)
        var nsec = self.nsec + tmod(d, SECOND)
        if nsec >= SECOND:
            dsec += 1
            nsec -= SECOND
        elif nsec < 0:
            dsec -= 1
            nsec += SECOND
        return GoTime(self.sec + dsec, nsec, self.off, self.abbr)

    def add_date(self, years: Int, months: Int, days: Int, loc: Location) -> GoTime:
        var ymd = self.date()
        var hms = self.clock()
        return go_date(ymd[0] + years, ymd[1] + months, ymd[2] + days, hms[0], hms[1], hms[2], self.nsec, loc)

    def sub(self, u: GoTime) -> Int:
        """Duration t-u, saturated to [MIN_DURATION, MAX_DURATION] like Go."""
        var d = SIMD[DType.int128, 1](self.sec - u.sec) * 1000000000 + SIMD[DType.int128, 1](self.nsec - u.nsec)
        if d > SIMD[DType.int128, 1](MAX_DURATION):
            return MAX_DURATION
        if d < SIMD[DType.int128, 1](MIN_DURATION):
            return MIN_DURATION
        return Int(d)

    def _wall(self) -> Int:
        return self.sec + self.off

    def date(self) -> Tuple[Int, Int, Int]:
        return civil_from_days(_fdiv(self._wall(), 86400))

    def year(self) -> Int:
        return self.date()[0]

    def month(self) -> Int:
        return self.date()[1]

    def day(self) -> Int:
        return self.date()[2]

    def clock(self) -> Tuple[Int, Int, Int]:
        var w = self._wall()
        var s = w - _fdiv(w, 86400) * 86400
        return (s // 3600, (s % 3600) // 60, s % 60)

    def hour(self) -> Int:
        return self.clock()[0]

    def minute(self) -> Int:
        return self.clock()[1]

    def second(self) -> Int:
        return self.clock()[2]

    def nanosecond(self) -> Int:
        return self.nsec

    def weekday(self) -> Int:
        """0 = Sunday."""
        var d = _fdiv(self._wall(), 86400)
        return (d + 4) % 7

    def year_day(self) -> Int:
        var days = _fdiv(self._wall(), 86400)
        var y = civil_from_days(days)[0]
        return days - days_from_civil(y, 1, 1) + 1

    def _rem(self, d: Int) -> Int:
        """Go div(t, d) remainder on seconds since year 1."""
        var neg = False
        var nsec = self.nsec
        var sec = self.sec + UNIX_TO_INTERNAL
        if sec < 0:
            neg = True
            sec = -sec
            nsec = -nsec
            if nsec < 0:
                nsec += SECOND
                sec -= 1
        var r: Int
        if d < SECOND and SECOND % (d + d) == 0:
            r = nsec % d
        elif d % SECOND == 0:
            var d1 = d // SECOND
            r = (sec % d1) * SECOND + nsec
        else:
            var big = SIMD[DType.int128, 1](sec) * 1000000000 + SIMD[DType.int128, 1](nsec)
            r = Int(big % SIMD[DType.int128, 1](d))
        if neg and r != 0:
            r = d - r
        return r

    def truncate(self, d: Int) -> GoTime:
        if d <= 0:
            return self
        return self.add(-self._rem(d))

    def round(self, d: Int) -> GoTime:
        if d <= 0:
            return self
        var r = self._rem(d)
        if r + r < d:
            return self.add(-r)
        return self.add(d - r)

    def format(self, layout: String) -> String:
        return go_format(self, layout)

    def string(self) -> String:
        return go_format(self, "2006-01-02 15:04:05.999999999 -0700 MST")


def go_date(year: Int, month: Int, day: Int, hour: Int, minute: Int, sec: Int, nsec: Int, loc: Location) -> GoTime:
    """time.Date with Go's normalization and DST gap/overlap resolution."""
    var m = month - 1
    var y = year
    var t = _norm(y, m, 12)
    y = t[0]
    m = t[1] + 1
    var s = sec
    var ns = nsec
    t = _norm(s, ns, 1000000000)
    s = t[0]
    ns = t[1]
    var mi = minute
    t = _norm(mi, s, 60)
    mi = t[0]
    s = t[1]
    var h = hour
    t = _norm(h, mi, 60)
    h = t[0]
    mi = t[1]
    var d = day
    t = _norm(d, h, 24)
    d = t[0]
    h = t[1]
    var unix = (days_from_civil(y, m, 1) + d - 1) * 86400 + h * 3600 + mi * 60 + s
    var z = loc.lookup(unix)
    var off = z.offset
    if off != 0:
        var utc = unix - off
        if utc < z.start or utc >= z.end:
            off = loc.lookup(utc).offset
        unix -= off
    var fz = loc.lookup(unix)
    return GoTime(unix, ns, fz.offset, fz.name)


def _norm(hi0: Int, lo0: Int, base: Int) -> Tuple[Int, Int]:
    var hi = hi0
    var lo = lo0
    if lo < 0:
        var n = tdiv(-lo - 1, base) + 1
        hi -= n
        lo += n * base
    if lo >= base:
        var n = tdiv(lo, base)
        hi += n
        lo -= n * base
    return (hi, lo)


# ---------------------------------------------------------------- layouts

comptime S_NONE = 0
comptime S_LONG_MONTH = 1
comptime S_MONTH = 2
comptime S_NUM_MONTH = 3
comptime S_ZERO_MONTH = 4
comptime S_LONG_WEEKDAY = 5
comptime S_WEEKDAY = 6
comptime S_DAY = 7
comptime S_UNDER_DAY = 8
comptime S_ZERO_DAY = 9
comptime S_UNDER_YEARDAY = 10
comptime S_ZERO_YEARDAY = 11
comptime S_HOUR = 12
comptime S_HOUR12 = 13
comptime S_ZERO_HOUR12 = 14
comptime S_MINUTE = 15
comptime S_ZERO_MINUTE = 16
comptime S_SECOND = 17
comptime S_ZERO_SECOND = 18
comptime S_LONG_YEAR = 19
comptime S_YEAR = 20
comptime S_PM = 21
comptime S_pm = 22
comptime S_TZ = 23
comptime S_ISO_TZ = 24
comptime S_ISO_SECONDS_TZ = 25
comptime S_ISO_SHORT_TZ = 26
comptime S_ISO_COLON_TZ = 27
comptime S_ISO_COLON_SECONDS_TZ = 28
comptime S_NUM_TZ = 29
comptime S_NUM_SECONDS_TZ = 30
comptime S_NUM_SHORT_TZ = 31
comptime S_NUM_COLON_TZ = 32
comptime S_NUM_COLON_SECONDS_TZ = 33
comptime S_FRAC0 = 34
comptime S_FRAC9 = 35

comptime RFC3339 = "2006-01-02T15:04:05Z07:00"
comptime RFC3339NANO = "2006-01-02T15:04:05.999999999Z07:00"
comptime DATE_ONLY = "2006-01-02"
comptime DATETIME = "2006-01-02 15:04:05"


@fieldwise_init
struct _Chunk(Copyable, ImplicitlyCopyable, Movable):
    var prefix_end: Int
    var std: Int
    var suffix: Int
    var ndigits: Int
    var sep: UInt8


@always_inline
def _at(b: List[UInt8], i: Int) -> Int:
    return Int(b[i]) if i < len(b) else -1


def _has(b: List[UInt8], i: Int, lit: StaticString) -> Bool:
    var lb = lit.as_bytes()
    if i + len(lb) > len(b):
        return False
    for k in range(len(lb)):
        if b[i + k] != lb[k]:
            return False
    return True


@always_inline
def _is_digit(b: List[UInt8], i: Int) -> Bool:
    return i < len(b) and b[i] >= 48 and b[i] <= 57


def _starts_lower(b: List[UInt8], i: Int) -> Bool:
    return i < len(b) and b[i] >= 97 and b[i] <= 122


def _next_chunk(l: List[UInt8], start: Int) -> _Chunk:
    """nextStdChunk over l[start:]; indices are absolute."""
    var i = start
    var n = len(l)
    while i < n:
        var c = Int(l[i])
        if c == 74:
            if _has(l, i, "Jan"):
                if _has(l, i, "January"):
                    return _Chunk(i, S_LONG_MONTH, i + 7, 0, 0)
                if not _starts_lower(l, i + 3):
                    return _Chunk(i, S_MONTH, i + 3, 0, 0)
        elif c == 77:
            if _has(l, i, "Mon"):
                if _has(l, i, "Monday"):
                    return _Chunk(i, S_LONG_WEEKDAY, i + 6, 0, 0)
                if not _starts_lower(l, i + 3):
                    return _Chunk(i, S_WEEKDAY, i + 3, 0, 0)
            if _has(l, i, "MST"):
                return _Chunk(i, S_TZ, i + 3, 0, 0)
        elif c == 48:
            var d = _at(l, i + 1)
            if d >= 49 and d <= 54:
                var code = S_YEAR
                if d == 49:
                    code = S_ZERO_MONTH
                elif d == 50:
                    code = S_ZERO_DAY
                elif d == 51:
                    code = S_ZERO_HOUR12
                elif d == 52:
                    code = S_ZERO_MINUTE
                elif d == 53:
                    code = S_ZERO_SECOND
                return _Chunk(i, code, i + 2, 0, 0)
            if d == 48 and _at(l, i + 2) == 50:
                return _Chunk(i, S_ZERO_YEARDAY, i + 3, 0, 0)
        elif c == 49:
            if _at(l, i + 1) == 53:
                return _Chunk(i, S_HOUR, i + 2, 0, 0)
            return _Chunk(i, S_NUM_MONTH, i + 1, 0, 0)
        elif c == 50:
            if _has(l, i, "2006"):
                return _Chunk(i, S_LONG_YEAR, i + 4, 0, 0)
            return _Chunk(i, S_DAY, i + 1, 0, 0)
        elif c == 95:
            if _at(l, i + 1) == 50:
                if _has(l, i + 1, "2006"):
                    return _Chunk(i + 1, S_LONG_YEAR, i + 5, 0, 0)
                return _Chunk(i, S_UNDER_DAY, i + 2, 0, 0)
            if _at(l, i + 1) == 95 and _at(l, i + 2) == 50:
                return _Chunk(i, S_UNDER_YEARDAY, i + 3, 0, 0)
        elif c == 51:
            return _Chunk(i, S_HOUR12, i + 1, 0, 0)
        elif c == 52:
            return _Chunk(i, S_MINUTE, i + 1, 0, 0)
        elif c == 53:
            return _Chunk(i, S_SECOND, i + 1, 0, 0)
        elif c == 80:
            if _at(l, i + 1) == 77:
                return _Chunk(i, S_PM, i + 2, 0, 0)
        elif c == 112:
            if _at(l, i + 1) == 109:
                return _Chunk(i, S_pm, i + 2, 0, 0)
        elif c == 45:
            if _has(l, i, "-070000"):
                return _Chunk(i, S_NUM_SECONDS_TZ, i + 7, 0, 0)
            if _has(l, i, "-07:00:00"):
                return _Chunk(i, S_NUM_COLON_SECONDS_TZ, i + 9, 0, 0)
            if _has(l, i, "-0700"):
                return _Chunk(i, S_NUM_TZ, i + 5, 0, 0)
            if _has(l, i, "-07:00"):
                return _Chunk(i, S_NUM_COLON_TZ, i + 6, 0, 0)
            if _has(l, i, "-07"):
                return _Chunk(i, S_NUM_SHORT_TZ, i + 3, 0, 0)
        elif c == 90:
            if _has(l, i, "Z070000"):
                return _Chunk(i, S_ISO_SECONDS_TZ, i + 7, 0, 0)
            if _has(l, i, "Z07:00:00"):
                return _Chunk(i, S_ISO_COLON_SECONDS_TZ, i + 9, 0, 0)
            if _has(l, i, "Z0700"):
                return _Chunk(i, S_ISO_TZ, i + 5, 0, 0)
            if _has(l, i, "Z07:00"):
                return _Chunk(i, S_ISO_COLON_TZ, i + 6, 0, 0)
            if _has(l, i, "Z07"):
                return _Chunk(i, S_ISO_SHORT_TZ, i + 3, 0, 0)
        elif c == 46 or c == 44:
            var d = _at(l, i + 1)
            if d == 48 or d == 57:
                var j = i + 1
                while j < n and Int(l[j]) == d:
                    j += 1
                if not _is_digit(l, j):
                    return _Chunk(i, S_FRAC0 if d == 48 else S_FRAC9, j, j - (i + 1), UInt8(c))
        i += 1
    return _Chunk(n, S_NONE, n, 0, 0)


def _append_int(mut b: String, x: Int, width: Int):
    var u = x
    if x < 0:
        b += "-"
        u = -x
    var s = String(u)
    for _ in range(width - s.byte_length()):
        b += "0"
    b += s


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=s.byte_length())
    for c in s.as_bytes():
        out.append(c)
    return out^


def _str(b: List[UInt8], a: Int, e: Int) -> String:
    var out = List[UInt8](capacity=max(0, e - a))
    for i in range(a, e):
        out.append(b[i])
    return String(unsafe_from_utf8=out)


def go_format(t: GoTime, layout: String) -> String:
    var l = _bytes(layout)
    var ymd = t.date()
    var hms = t.clock()
    var year = ymd[0]
    var month = ymd[1]
    var day = ymd[2]
    var hour = hms[0]
    var minute = hms[1]
    var second = hms[2]
    var off = t.off
    var b = String("")
    var pos = 0
    while True:
        var c = _next_chunk(l, pos)
        b += _str(l, pos, c.prefix_end)
        if c.std == S_NONE:
            break
        pos = c.suffix
        var std = c.std
        if std == S_YEAR:
            var y = -year if year < 0 else year
            _append_int(b, y % 100, 2)
        elif std == S_LONG_YEAR:
            _append_int(b, year, 4)
        elif std == S_MONTH:
            b += String(month_name(month)[byte=0:3])
        elif std == S_LONG_MONTH:
            b += month_name(month)
        elif std == S_NUM_MONTH:
            _append_int(b, month, 0)
        elif std == S_ZERO_MONTH:
            _append_int(b, month, 2)
        elif std == S_WEEKDAY:
            b += String(weekday_name(t.weekday())[byte=0:3])
        elif std == S_LONG_WEEKDAY:
            b += weekday_name(t.weekday())
        elif std == S_DAY:
            _append_int(b, day, 0)
        elif std == S_UNDER_DAY:
            if day < 10:
                b += " "
            _append_int(b, day, 0)
        elif std == S_ZERO_DAY:
            _append_int(b, day, 2)
        elif std == S_UNDER_YEARDAY:
            var yd = t.year_day()
            if yd < 100:
                b += " "
                if yd < 10:
                    b += " "
            _append_int(b, yd, 0)
        elif std == S_ZERO_YEARDAY:
            _append_int(b, t.year_day(), 3)
        elif std == S_HOUR:
            _append_int(b, hour, 2)
        elif std == S_HOUR12 or std == S_ZERO_HOUR12:
            var hr = hour % 12
            if hr == 0:
                hr = 12
            _append_int(b, hr, 2 if std == S_ZERO_HOUR12 else 0)
        elif std == S_MINUTE:
            _append_int(b, minute, 0)
        elif std == S_ZERO_MINUTE:
            _append_int(b, minute, 2)
        elif std == S_SECOND:
            _append_int(b, second, 0)
        elif std == S_ZERO_SECOND:
            _append_int(b, second, 2)
        elif std == S_PM:
            b += "PM" if hour >= 12 else "AM"
        elif std == S_pm:
            b += "pm" if hour >= 12 else "am"
        elif std >= S_ISO_TZ and std <= S_NUM_COLON_SECONDS_TZ:
            var iso = std >= S_ISO_TZ and std <= S_ISO_COLON_SECONDS_TZ
            if off == 0 and iso:
                b += "Z"
                continue
            var zone = tdiv(off, 60)
            var absoff = off
            if zone < 0:
                b += "-"
                zone = -zone
                absoff = -absoff
            else:
                b += "+"
            _append_int(b, zone // 60, 2)
            if std == S_ISO_COLON_TZ or std == S_NUM_COLON_TZ or std == S_ISO_COLON_SECONDS_TZ or std == S_NUM_COLON_SECONDS_TZ:
                b += ":"
            if std != S_NUM_SHORT_TZ and std != S_ISO_SHORT_TZ:
                _append_int(b, zone % 60, 2)
            if std == S_ISO_SECONDS_TZ or std == S_NUM_SECONDS_TZ or std == S_NUM_COLON_SECONDS_TZ or std == S_ISO_COLON_SECONDS_TZ:
                if std == S_NUM_COLON_SECONDS_TZ or std == S_ISO_COLON_SECONDS_TZ:
                    b += ":"
                _append_int(b, absoff % 60, 2)
        elif std == S_TZ:
            if t.abbr.byte_length() > 0:
                b += t.abbr
                continue
            var zone = tdiv(off, 60)
            if zone < 0:
                b += "-"
                zone = -zone
            else:
                b += "+"
            _append_int(b, zone // 60, 2)
            _append_int(b, zone % 60, 2)
        elif std == S_FRAC0 or std == S_FRAC9:
            var trim = std == S_FRAC9
            var nd = c.ndigits
            if trim and (nd == 0 or t.nsec == 0):
                continue
            var digits = String("")
            _append_int(digits, t.nsec, 9)
            var db = _bytes(digits)
            var keep = nd if nd < 9 else 9
            if trim:
                while keep > 0 and db[keep - 1] == 48:
                    keep -= 1
                if keep == 0:
                    continue
            b += chr(Int(c.sep))
            b += _str(db, 0, keep)
    return b


def go_quote(s: String) -> String:
    """time.quote: ASCII printable kept ("/\\ escaped), other bytes as \\xHH."""
    comptime hexd = "0123456789abcdef"
    var hb = hexd.as_bytes()
    var out = String('"')
    for c in s.as_bytes():
        if c >= 128 or c < 32:
            out += "\\x" + chr(Int(hb[Int(c >> 4)])) + chr(Int(hb[Int(c & 15)]))
        else:
            if c == 34 or c == 92:
                out += "\\"
            out += chr(Int(c))
    return out + '"'


def _parse_err(layout: String, value: String, lelem: String, velem: String, msg: String) -> Error:
    if msg.byte_length() == 0:
        return Error(
            "parsing time " + go_quote(value) + " as " + go_quote(layout) + ": cannot parse " + go_quote(velem)
            + " as " + go_quote(lelem)
        )
    return Error("parsing time " + go_quote(value) + msg)


def _getnum(v: List[UInt8], mut i: Int, fixed: Bool, mut ok: Bool) -> Int:
    if not _is_digit(v, i):
        ok = False
        return 0
    if not _is_digit(v, i + 1):
        if fixed:
            ok = False
            return 0
        i += 1
        return Int(v[i - 1]) - 48
    i += 2
    return (Int(v[i - 2]) - 48) * 10 + Int(v[i - 1]) - 48


def _getnum3(v: List[UInt8], mut i: Int, fixed: Bool, mut ok: Bool) -> Int:
    var n = 0
    var k = 0
    while k < 3 and _is_digit(v, i):
        n = n * 10 + Int(v[i]) - 48
        i += 1
        k += 1
    if k == 0 or (fixed and k != 3):
        ok = False
        return 0
    return n


def _atoi(v: List[UInt8], a: Int, e: Int, mut ok: Bool) -> Int:
    var i = a
    var neg = False
    if i < e and (v[i] == 45 or v[i] == 43):
        neg = v[i] == 45
        i += 1
    var x = 0
    while i < e:
        var c = v[i]
        if c < 48 or c > 57:
            ok = False
            return 0
        x = x * 10 + Int(c) - 48
        i += 1
    return -x if neg else x


def _parse_nanos(v: List[UInt8], i: Int, nbytes0: Int, mut ok: Bool, mut rng: String) -> Int:
    if v[i] != 46 and v[i] != 44:
        ok = False
        return 0
    var nbytes = min(nbytes0, 10)
    var ns = _atoi(v, i + 1, i + nbytes, ok)
    if not ok:
        return 0
    if ns < 0:
        rng = "fractional second"
        return 0
    for _ in range(10 - nbytes):
        ns *= 10
    return ns


def _lookup_name(v: List[UInt8], i: Int, table: String, mut ok: Bool) -> Int:
    """Case-insensitive prefix match against comma-separated names: index * 100 + matched length."""
    var names = table.split(",")
    for k in range(len(names)):
        var nm = _bytes(String(names[k]))
        if i + len(nm) <= len(v):
            var m = True
            for j in range(len(nm)):
                var a = Int(v[i + j])
                var c = Int(nm[j])
                if a >= 65 and a <= 90:
                    a += 32
                if c >= 65 and c <= 90:
                    c += 32
                if a != c:
                    m = False
                    break
            if m:
                return k * 100 + len(nm)
    ok = False
    return 0


def go_parse(layout: String, value: String) raises -> GoTime:
    """time.Parse (default and local location UTC)."""
    var utc = Location.utc()
    return parse_in(layout, value, utc, utc)


def parse_in(layout: String, value: String, default_loc: Location, local: Location) raises -> GoTime:
    """time.ParseInLocation semantics with an explicit Local."""
    var l = _bytes(layout)
    var v = _bytes(value)
    var vi = 0
    var pos = 0
    var range_err = String("")
    var am_set = False
    var pm_set = False
    var year = 0
    var month = -1
    var day = -1
    var yday = -1
    var hour = 0
    var minute = 0
    var sec = 0
    var nsec = 0
    var z_utc = False
    var zone_offset = -1
    while True:
        var c = _next_chunk(l, pos)
        var stdstr = _str(l, c.prefix_end, c.suffix)
        var p = pos
        var pe = c.prefix_end
        while p < pe:
            if l[p] == 32:
                if vi < len(v) and v[vi] != 32:
                    raise _parse_err(layout, value, _str(l, pos, pe), _str(v, vi, len(v)), "")
                while p < pe and l[p] == 32:
                    p += 1
                while vi < len(v) and v[vi] == 32:
                    vi += 1
                continue
            if vi >= len(v) or v[vi] != l[p]:
                raise _parse_err(layout, value, _str(l, pos, pe), _str(v, vi, len(v)), "")
            p += 1
            vi += 1
        if c.std == S_NONE:
            if vi < len(v):
                raise _parse_err(layout, value, "", _str(v, vi, len(v)), ": extra text: " + go_quote(_str(v, vi, len(v))))
            break
        pos = c.suffix
        var hold = vi
        var ok = True
        var std = c.std
        if std == S_YEAR:
            if len(v) - vi < 2:
                ok = False
            else:
                year = _atoi(v, vi, vi + 2, ok)
                if ok:
                    vi += 2
                    year += 1900 if year >= 69 else 2000
        elif std == S_LONG_YEAR:
            if len(v) - vi < 4 or not _is_digit(v, vi):
                ok = False
            else:
                year = _atoi(v, vi, vi + 4, ok)
                vi += 4
        elif std == S_MONTH or std == S_LONG_MONTH:
            var r = _lookup_name(
                v, vi,
                "Jan,Feb,Mar,Apr,May,Jun,Jul,Aug,Sep,Oct,Nov,Dec" if std == S_MONTH else "January,February,March,April,May,June,July,August,September,October,November,December",
                ok,
            )
            if ok:
                month = r // 100 + 1
                vi += r % 100
        elif std == S_NUM_MONTH or std == S_ZERO_MONTH:
            month = _getnum(v, vi, std == S_ZERO_MONTH, ok)
            if ok and (month <= 0 or 12 < month):
                range_err = "month"
        elif std == S_WEEKDAY or std == S_LONG_WEEKDAY:
            var r = _lookup_name(
                v, vi,
                "Sun,Mon,Tue,Wed,Thu,Fri,Sat" if std == S_WEEKDAY else "Sunday,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday",
                ok,
            )
            if ok:
                vi += r % 100
        elif std == S_DAY or std == S_UNDER_DAY or std == S_ZERO_DAY:
            if std == S_UNDER_DAY and vi < len(v) and v[vi] == 32:
                vi += 1
            day = _getnum(v, vi, std == S_ZERO_DAY, ok)
        elif std == S_UNDER_YEARDAY or std == S_ZERO_YEARDAY:
            for _ in range(2):
                if std == S_UNDER_YEARDAY and vi < len(v) and v[vi] == 32:
                    vi += 1
            yday = _getnum3(v, vi, std == S_ZERO_YEARDAY, ok)
        elif std == S_HOUR:
            hour = _getnum(v, vi, False, ok)
            if hour < 0 or 24 <= hour:
                range_err = "hour"
        elif std == S_HOUR12 or std == S_ZERO_HOUR12:
            hour = _getnum(v, vi, std == S_ZERO_HOUR12, ok)
            if hour < 0 or 12 < hour:
                range_err = "hour"
        elif std == S_MINUTE or std == S_ZERO_MINUTE:
            minute = _getnum(v, vi, std == S_ZERO_MINUTE, ok)
            if minute < 0 or 60 <= minute:
                range_err = "minute"
        elif std == S_SECOND or std == S_ZERO_SECOND:
            sec = _getnum(v, vi, std == S_ZERO_SECOND, ok)
            if ok:
                if sec < 0 or 60 <= sec:
                    range_err = "second"
                elif len(v) - vi >= 2 and (v[vi] == 46 or v[vi] == 44) and _is_digit(v, vi + 1):
                    var nx = _next_chunk(l, pos)
                    if nx.std != S_FRAC0 and nx.std != S_FRAC9:
                        var n = 2
                        while vi + n < len(v) and _is_digit(v, vi + n):
                            n += 1
                        nsec = _parse_nanos(v, vi, n, ok, range_err)
                        vi += n
        elif std == S_PM or std == S_pm:
            if len(v) - vi < 2:
                ok = False
            else:
                var a = _str(v, vi, vi + 2)
                vi += 2
                if (std == S_PM and a == "PM") or (std == S_pm and a == "pm"):
                    pm_set = True
                elif (std == S_PM and a == "AM") or (std == S_pm and a == "am"):
                    am_set = True
                else:
                    ok = False
        elif std >= S_ISO_TZ and std <= S_NUM_COLON_SECONDS_TZ:
            var iso = std >= S_ISO_TZ and std <= S_ISO_COLON_SECONDS_TZ
            if iso and vi < len(v) and v[vi] == 90:
                vi += 1
                z_utc = True
            else:
                var n = len(v) - vi
                var hs = 0
                var ms = 0
                var ss = -1
                var nxt = 0
                if std == S_ISO_COLON_TZ or std == S_NUM_COLON_TZ:
                    if n < 6 or v[vi + 3] != 58:
                        ok = False
                    else:
                        hs = vi + 1
                        ms = vi + 4
                        nxt = vi + 6
                elif std == S_NUM_SHORT_TZ or std == S_ISO_SHORT_TZ:
                    if n < 3:
                        ok = False
                    else:
                        hs = vi + 1
                        ms = -1
                        nxt = vi + 3
                elif std == S_ISO_COLON_SECONDS_TZ or std == S_NUM_COLON_SECONDS_TZ:
                    if n < 9 or v[vi + 3] != 58 or v[vi + 6] != 58:
                        ok = False
                    else:
                        hs = vi + 1
                        ms = vi + 4
                        ss = vi + 7
                        nxt = vi + 9
                elif std == S_ISO_SECONDS_TZ or std == S_NUM_SECONDS_TZ:
                    if n < 7:
                        ok = False
                    else:
                        hs = vi + 1
                        ms = vi + 3
                        ss = vi + 5
                        nxt = vi + 7
                else:
                    if n < 5:
                        ok = False
                    else:
                        hs = vi + 1
                        ms = vi + 3
                        nxt = vi + 5
                if ok:
                    var sign = v[vi]
                    var k = hs
                    var hr = _getnum(v, k, True, ok)
                    var mm = 0
                    var sv = 0
                    if ok and ms >= 0:
                        k = ms
                        mm = _getnum(v, k, True, ok)
                    if ok and ss >= 0:
                        k = ss
                        sv = _getnum(v, k, True, ok)
                    if hr > 24:
                        range_err = "time zone offset hour"
                    if mm > 60:
                        range_err = "time zone offset minute"
                    if sv > 60:
                        range_err = "time zone offset second"
                    zone_offset = (hr * 60 + mm) * 60 + sv
                    if sign == 45:
                        zone_offset = -zone_offset
                    elif sign != 43:
                        ok = False
                    vi = nxt
        elif std == S_TZ:
            if len(v) - vi >= 3 and _str(v, vi, vi + 3) == "UTC":
                z_utc = True
                vi += 3
            else:
                ok = False
        elif std == S_FRAC0:
            var nd = 1 + c.ndigits
            if len(v) - vi < nd:
                ok = False
            else:
                nsec = _parse_nanos(v, vi, nd, ok, range_err)
                vi += nd
        elif std == S_FRAC9:
            if len(v) - vi >= 2 and (v[vi] == 46 or v[vi] == 44) and _is_digit(v, vi + 1):
                var i = 0
                while vi + i + 1 < len(v) and _is_digit(v, vi + i + 1):
                    i += 1
                nsec = _parse_nanos(v, vi, 1 + i, ok, range_err)
                vi += 1 + i
        if range_err.byte_length() > 0:
            raise _parse_err(layout, value, stdstr, _str(v, vi, len(v)), ": " + range_err + " out of range")
        if not ok:
            raise _parse_err(layout, value, stdstr, _str(v, hold, len(v)), "")
    if pm_set and hour < 12:
        hour += 12
    elif am_set and hour == 12:
        hour = 0
    if yday >= 0:
        var d = 0
        var m = 0
        if is_leap(year):
            if yday == 31 + 29:
                m = 2
                d = 29
            elif yday > 31 + 29:
                yday -= 1
        if yday < 1 or yday > 365:
            raise _parse_err(layout, value, "", _str(v, vi, len(v)), ": day-of-year out of range")
        if m == 0:
            m = (yday - 1) // 31 + 1
            if _days_before(m + 1) < yday:
                m += 1
            d = yday - _days_before(m)
        if month >= 0 and month != m:
            raise _parse_err(layout, value, "", _str(v, vi, len(v)), ": day-of-year does not match month")
        month = m
        if day >= 0 and day != d:
            raise _parse_err(layout, value, "", _str(v, vi, len(v)), ": day-of-year does not match day")
        day = d
    else:
        if month < 0:
            month = 1
        if day < 0:
            day = 1
    if day < 1 or day > days_in(month, year):
        raise _parse_err(layout, value, "", _str(v, vi, len(v)), ": day out of range")
    if z_utc:
        return go_date(year, month, day, hour, minute, sec, nsec, Location.utc())
    if zone_offset != -1:
        var t = go_date(year, month, day, hour, minute, sec, nsec, Location.utc())
        t.sec -= zone_offset
        var z = local.lookup(t.sec)
        if z.offset == zone_offset:
            t.off = z.offset
            t.abbr = z.name
        else:
            t.off = zone_offset
            t.abbr = ""
        return t
    return go_date(year, month, day, hour, minute, sec, nsec, default_loc)


def parse_rfc3339(s: String) raises -> GoTime:
    """time.Parse(time.RFC3339, s); fractional seconds are accepted as in Go."""
    return go_parse(RFC3339, s)


def parse_rfc3339_nano(s: String) raises -> GoTime:
    return go_parse(RFC3339NANO, s)


# ---------------------------------------------------------------- Duration


def duration_string(d: Int) -> String:
    """time.Duration.String."""
    var u = UInt64(d)
    var neg = d < 0
    if neg:
        u = UInt64(0) - u
    var out = List[UInt8]()
    if u < UInt64(SECOND):
        if u == 0:
            return "0s"
        out.append(115)
        var prec: Int
        if u < UInt64(MICROSECOND):
            prec = 0
            out.append(110)
        elif u < UInt64(MILLISECOND):
            prec = 3
            out.append(0xB5)
            out.append(0xC2)
        else:
            prec = 6
            out.append(109)
        u = _fmt_frac(out, u, prec)
        _fmt_int(out, u)
    else:
        out.append(115)
        u = _fmt_frac(out, u, 9)
        _fmt_int(out, u % 60)
        u //= 60
        if u > 0:
            out.append(109)
            _fmt_int(out, u % 60)
            u //= 60
            if u > 0:
                out.append(104)
                _fmt_int(out, u)
    if neg:
        out.append(45)
    out.reverse()
    return String(unsafe_from_utf8=out)


def _fmt_frac(mut out: List[UInt8], v0: UInt64, prec: Int) -> UInt64:
    var v = v0
    var printed = False
    for _ in range(prec):
        var digit = v % 10
        printed = printed or digit != 0
        if printed:
            out.append(UInt8(digit) + 48)
        v //= 10
    if printed:
        out.append(46)
    return v


def _fmt_int(mut out: List[UInt8], v0: UInt64):
    var v = v0
    if v == 0:
        out.append(48)
        return
    while v > 0:
        out.append(UInt8(v % 10) + 48)
        v //= 10


def d_hours(d: Int) -> Float64:
    var h = tdiv(d, HOUR)
    var ns = tmod(d, HOUR)
    return Float64(h) + Float64(ns) / (60 * 60 * 1e9)


def d_minutes(d: Int) -> Float64:
    var m = tdiv(d, MINUTE)
    var ns = tmod(d, MINUTE)
    return Float64(m) + Float64(ns) / (60 * 1e9)


def d_seconds(d: Int) -> Float64:
    var s = tdiv(d, SECOND)
    var ns = tmod(d, SECOND)
    return Float64(s) + Float64(ns) / 1e9


def d_milliseconds(d: Int) -> Int:
    return tdiv(d, MILLISECOND)


def d_truncate(d: Int, m: Int) -> Int:
    if m <= 0:
        return d
    return d - tmod(d, m)


def d_round(d: Int, m: Int) -> Int:
    if m <= 0:
        return d
    var r = tmod(d, m)
    if d < 0:
        r = -r
        if UInt64(r) + UInt64(r) < UInt64(m):
            return d + r
        var d1 = d - m + r
        if d1 < d:
            return d1
        return MIN_DURATION
    if UInt64(r) + UInt64(r) < UInt64(m):
        return d - r
    var d1 = d + m - r
    if d1 > d:
        return d1
    return MAX_DURATION


def _unit(u: String) -> UInt64:
    if u == "ns":
        return 1
    if u == "us" or u == "µs" or u == "μs":
        return 1000
    if u == "ms":
        return 1000000
    if u == "s":
        return 1000000000
    if u == "m":
        return 60000000000
    if u == "h":
        return 3600000000000
    return 0


def parse_duration(s0: String) raises -> Int:
    """time.ParseDuration."""
    var orig = s0
    var s = _bytes(s0)
    var i = 0
    var d = UInt64(0)
    var neg = False
    comptime LIM = UInt64(1) << 63
    var invalid = Error("time: invalid duration " + go_quote(orig))
    if len(s) > 0 and (s[0] == 45 or s[0] == 43):
        neg = s[0] == 45
        i = 1
    if len(s) - i == 1 and s[i] == 48:
        return 0
    if i == len(s):
        raise invalid
    while i < len(s):
        var c = s[i]
        if not (c == 46 or (c >= 48 and c <= 57)):
            raise invalid
        var pl = i
        var v = UInt64(0)
        while i < len(s) and s[i] >= 48 and s[i] <= 57:
            if v > LIM // 10:
                raise invalid
            v = v * 10 + UInt64(s[i] - 48)
            if v > LIM:
                raise invalid
            i += 1
        var pre = pl != i
        var post = False
        var f = UInt64(0)
        var scale = 1.0
        if i < len(s) and s[i] == 46:
            i += 1
            var pl2 = i
            var overflow = False
            while i < len(s) and s[i] >= 48 and s[i] <= 57:
                if not overflow:
                    if f > (LIM - 1) // 10:
                        overflow = True
                    else:
                        var y = f * 10 + UInt64(s[i] - 48)
                        if y > LIM:
                            overflow = True
                        else:
                            f = y
                            scale *= 10
                i += 1
            post = pl2 != i
        if not pre and not post:
            raise invalid
        var us = i
        while i < len(s) and not (s[i] == 46 or (s[i] >= 48 and s[i] <= 57)):
            i += 1
        if i == us:
            raise Error("time: missing unit in duration " + go_quote(orig))
        var u = _str(s, us, i)
        var unit = _unit(u)
        if unit == 0:
            raise Error("time: unknown unit " + go_quote(u) + " in duration " + go_quote(orig))
        if v > LIM // unit:
            raise invalid
        v *= unit
        if f > 0:
            v += UInt64(Float64(f) * (Float64(unit) / scale))
            if v > LIM:
                raise invalid
        d += v
        if d > LIM:
            raise invalid
    if neg:
        return -Int(d) if d < LIM else MIN_DURATION
    if d > LIM - 1:
        raise invalid
    return Int(d)
