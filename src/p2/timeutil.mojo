"""RFC3339 timestamps as Unix seconds, plus UTC civil-date helpers."""


def days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    var y = y0 - 1 if m <= 2 else y0
    var era = (y if y >= 0 else y - 399) // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_year_month(unix_seconds: Int) -> Tuple[Int, Int]:
    var z = unix_seconds // 86400 + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y, m)


@always_inline
def _digits(b: Span[UInt8, _], start: Int, n: Int) raises -> Int:
    var v = 0
    for i in range(start, start + n):
        var c = Int(b[i])
        if c < 48 or c > 57:
            raise Error("timestamp: expected digit")
        v = v * 10 + (c - 48)
    return v


def parse_rfc3339(s: String) raises -> Int:
    """Returns Unix seconds; fractional seconds are truncated (bars are on whole seconds)."""
    var b = s.as_bytes()
    if len(b) < 20:
        raise Error("timestamp too short: " + s)
    var y = _digits(b, 0, 4)
    var mo = _digits(b, 5, 2)
    var d = _digits(b, 8, 2)
    var h = _digits(b, 11, 2)
    var mi = _digits(b, 14, 2)
    var se = _digits(b, 17, 2)
    var i = 19
    if i < len(b) and b[i] == 46:
        i += 1
        while i < len(b) and b[i] >= 48 and b[i] <= 57:
            i += 1
    var offset = 0
    if i < len(b) and (b[i] == 90 or b[i] == 122):
        i += 1
    elif i + 6 <= len(b) and (b[i] == 43 or b[i] == 45):
        var sign = 1 if b[i] == 43 else -1
        offset = sign * (_digits(b, i + 1, 2) * 3600 + _digits(b, i + 4, 2) * 60)
        i += 6
    else:
        raise Error("timestamp missing zone: " + s)
    return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset
