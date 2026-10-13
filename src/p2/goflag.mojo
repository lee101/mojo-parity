"""Go flag.FlagSet (ContinueOnError) with prediction2's parseCommandFlags wrapper.

Flags are declared with typed defaults before parsing, exactly like Go; parse()
reproduces flag.(*FlagSet).parseOne: "-" or "--" prefixes, "--" terminator,
name=value, bool flags without values, and Go's error strings ("flag provided
but not defined: -x", "invalid value \"v\" for flag -x: parse error", ...).
"""

from p2.gofmt import go_parse_float, go_parse_int, go_quote
from p2.gotime import parse_duration

comptime K_BOOL = 0
comptime K_STRING = 1
comptime K_INT = 2
comptime K_FLOAT = 3
comptime K_DURATION = 4


@fieldwise_init
struct _Flag(Copyable, Movable):
    var name: String
    var kind: Int
    var s: String
    var f: Float64
    var i: Int
    var b: Bool
    var set: Bool


struct FlagSet(Movable):
    var command: String
    var flags: List[_Flag]
    var defaults: List[_Flag]
    var rest: List[String]

    def __init__(out self, command: String):
        self.command = command
        self.flags = List[_Flag]()
        self.defaults = List[_Flag]()
        self.rest = List[String]()

    def _idx(self, name: String) -> Int:
        for k in range(len(self.flags)):
            if self.flags[k].name == name:
                return k
        return -1

    def bool(mut self, name: String, default: Bool):
        self.flags.append(_Flag(name, K_BOOL, "", 0, 0, default, False))
        self.defaults.append(self.flags[len(self.flags) - 1].copy())

    def string(mut self, name: String, default: String):
        self.flags.append(_Flag(name, K_STRING, default, 0, 0, False, False))
        self.defaults.append(self.flags[len(self.flags) - 1].copy())

    def int(mut self, name: String, default: Int):
        self.flags.append(_Flag(name, K_INT, "", 0, default, False, False))
        self.defaults.append(self.flags[len(self.flags) - 1].copy())

    def float(mut self, name: String, default: Float64):
        self.flags.append(_Flag(name, K_FLOAT, "", default, 0, False, False))
        self.defaults.append(self.flags[len(self.flags) - 1].copy())

    def duration(mut self, name: String, default_ns: Int):
        self.flags.append(_Flag(name, K_DURATION, "", 0, default_ns, False, False))
        self.defaults.append(self.flags[len(self.flags) - 1].copy())

    def get_bool(self, name: String) -> Bool:
        return self.flags[self._idx(name)].b

    def get_str(self, name: String) -> String:
        return self.flags[self._idx(name)].s

    def get_int(self, name: String) -> Int:
        return self.flags[self._idx(name)].i

    def get_float(self, name: String) -> Float64:
        return self.flags[self._idx(name)].f

    def get_duration(self, name: String) -> Int:
        return self.flags[self._idx(name)].i

    def was_set(self, name: String) -> Bool:
        return self.flags[self._idx(name)].set

    def changed(self, name: String) -> Bool:
        """True when the flag's parsed value differs from its declared default (NaN-safe)."""
        var k = self._idx(name)
        var f = self.flags[k].copy()
        var d = self.defaults[k].copy()
        if f.kind == K_STRING:
            return f.s != d.s
        if f.kind == K_BOOL:
            return f.b != d.b
        if f.kind == K_FLOAT:
            return not (f.f == d.f)
        return f.i != d.i

    def names(self) -> List[String]:
        var out = List[String]()
        for f in self.flags:
            out.append(f.name)
        return out^

    def _set_value(mut self, k: Int, value: String) raises:
        var kind = self.flags[k].kind
        if kind == K_STRING:
            self.flags[k].s = value
        elif kind == K_BOOL:
            if value == "1" or value == "t" or value == "T" or value == "true" or value == "TRUE" or value == "True":
                self.flags[k].b = True
            elif value == "0" or value == "f" or value == "F" or value == "false" or value == "FALSE" or value == "False":
                self.flags[k].b = False
            else:
                raise Error("parse error")
        elif kind == K_FLOAT:
            var r = go_parse_float(value)
            if not r.ok:
                raise Error("value out of range" if r.range_err else "parse error")
            self.flags[k].f = r.value
        elif kind == K_INT:
            var r = _parse_int_base0(value)
            if not r[1]:
                raise Error("value out of range" if r[2] else "parse error")
            self.flags[k].i = r[0]
        else:
            try:
                self.flags[k].i = parse_duration(value)
            except:
                raise Error("parse error")
        self.flags[k].set = True

    def parse(mut self, args: List[String]) raises:
        """flag.Parse; raises with the bare Go error text."""
        var i = 0
        while i < len(args):
            var s = args[i]
            if s.byte_length() < 2 or not s.startswith("-"):
                break
            var minuses = 1
            if s.as_bytes()[1] == 45:
                minuses = 2
                if s.byte_length() == 2:
                    i += 1
                    break
            var name = String(s[byte=minuses:])
            if name.byte_length() == 0 or name.startswith("-") or name.startswith("="):
                raise Error("bad flag syntax: " + s)
            i += 1
            var has_value = False
            var value = String("")
            var eq = name.find("=")
            if eq >= 1:
                value = String(name[byte = eq + 1 :])
                has_value = True
                var n2 = String(name[byte=0:eq])
                name = n2
            var k = self._idx(name)
            if k < 0:
                if name == "help" or name == "h":
                    raise Error("flag: help requested")
                raise Error("flag provided but not defined: -" + name)
            if self.flags[k].kind == K_BOOL:
                if has_value:
                    try:
                        self._set_value(k, value)
                    except e:
                        raise Error("invalid boolean value " + go_quote(value) + " for -" + name + ": " + String(e))
                else:
                    self._set_value(k, "true")
                continue
            if not has_value and i < len(args):
                value = args[i]
                has_value = True
                i += 1
            if not has_value:
                raise Error("flag needs an argument: -" + name)
            try:
                self._set_value(k, value)
            except e:
                raise Error("invalid value " + go_quote(value) + " for flag -" + name + ": " + String(e))
        while i < len(args):
            self.rest.append(args[i])
            i += 1

    def parse_command(mut self, args: List[String]) raises:
        """parseCommandFlags: help word, parse errors, stray positionals (callers prefix "<cmd>: options: ")."""
        if len(args) == 1 and args[0] == "help":
            raise Error("flag: help requested")
        self.parse(args)
        if len(self.rest) > 0:
            raise Error("unexpected positional argument " + go_quote(self.rest[0]))


def _parse_int_base0(s0: String) -> Tuple[Int, Bool, Bool]:
    """strconv.ParseInt(s, 0, 64): sign, 0x/0o/0b/0 prefixes, underscores after a prefix."""
    var s = s0
    if s.byte_length() == 0:
        return (0, False, False)
    var neg = False
    var b = s.as_bytes()
    var start = 0
    if b[0] == 43 or b[0] == 45:
        neg = b[0] == 45
        start = 1
    var base = 10
    var body = String(s[byte=start:])
    var bb = body.as_bytes()
    var prefixed = False
    if len(bb) >= 1 and bb[0] == 48:
        if len(bb) >= 2 and (bb[1] == 120 or bb[1] == 88):
            base = 16
            var _tmp1 = String(body[byte=2:])
            body = _tmp1
            prefixed = True
        elif len(bb) >= 2 and (bb[1] == 111 or bb[1] == 79):
            base = 8
            var _tmp2 = String(body[byte=2:])
            body = _tmp2
            prefixed = True
        elif len(bb) >= 2 and (bb[1] == 98 or bb[1] == 66):
            base = 2
            var _tmp3 = String(body[byte=2:])
            body = _tmp3
            prefixed = True
        elif len(bb) >= 2:
            base = 8
            var _tmp4 = String(body[byte=1:])
            body = _tmp4
            prefixed = True
    if base == 10:
        var r = go_parse_int(s)
        return (r.value, r.ok, r.range_err)
    var digits = String("")
    var last_us = True
    for c in body.as_bytes():
        if c == 95:
            if last_us and not (prefixed and digits.byte_length() == 0):
                return (0, False, False)
            last_us = True
            continue
        last_us = False
        digits += chr(Int(c))
    if body.byte_length() > 0 and body.as_bytes()[body.byte_length() - 1] == 95:
        return (0, False, False)
    if digits.byte_length() == 0:
        if base == 8 and not prefixed:
            return (0, True, False)
        if base == 8 and body.byte_length() == 0 and s0.find("o") < 0 and s0.find("O") < 0:
            return (0, True, False)
        return (0, False, False)
    var v: UInt64 = 0
    for c in digits.as_bytes():
        var d: Int
        if c >= 48 and c <= 57:
            d = Int(c) - 48
        elif c >= 97 and c <= 102:
            d = Int(c) - 87
        elif c >= 65 and c <= 70:
            d = Int(c) - 55
        else:
            return (0, False, False)
        if d >= base:
            return (0, False, False)
        var nv = v * UInt64(base) + UInt64(d)
        if nv < v or v > UInt64.MAX // UInt64(base):
            return (0, False, True)
        v = nv
    var cutoff: UInt64 = UInt64(1) << 63
    if not neg and v >= cutoff:
        return (Int(cutoff - 1), False, True)
    if neg and v > cutoff:
        return (Int(Int64.MIN), False, True)
    var out = Int(Int64(v)) if v < cutoff else Int(Int64.MIN)
    return (-out if neg else out, True, False)
