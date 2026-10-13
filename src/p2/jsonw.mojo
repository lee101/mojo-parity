"""JSON writer matching Go encoding/json MarshalIndent(v, "", "  ") output.

Map keys are emitted sorted (Go sorts map[string]any keys); struct fields keep
declaration order. Floats follow encoding/json: shortest round-trip digits in
'f' form, or 'e' form when |x| < 1e-6 or |x| >= 1e21, with e-0N cleaned to e-N.
"""

from p2.format import fmt_short
from p2.gofmt import json_quote


def go_json_float(x: Float64) -> String:
    var a = abs(x)
    if a != 0 and (a < 1e-6 or a >= 1e21):
        return _exp_form(x)
    return fmt_short(x)


def _exp_form(x: Float64) -> String:
    var r = String(x)
    var neg = r.startswith("-")
    if neg:
        var r2 = String(r[byte=1:])
        r = r2
    var digits = String("")
    var point = 0
    var epos = r.find("e")
    var mant = r if epos < 0 else String(r[byte=0:epos])
    var ex = 0 if epos < 0 else _int_noraise(String(r[byte = epos + 1 :]))
    var dot = mant.find(".")
    if dot >= 0:
        digits = String(mant[byte=0:dot]) + String(mant[byte = dot + 1 :])
        point = dot + ex
    else:
        digits = mant
        point = mant.byte_length() + ex
    var lead = 0
    while lead < digits.byte_length() - 1 and digits[byte=lead] == "0":
        lead += 1
        point -= 1
    var d2 = String(digits[byte=lead:])
    digits = d2
    var end = digits.byte_length()
    while end > 1 and digits[byte = end - 1] == "0":
        end -= 1
    var d3 = String(digits[byte=0:end])
    digits = d3
    var e = point - 1
    var out = String(digits[byte=0:1])
    if digits.byte_length() > 1:
        out += "." + String(digits[byte=1:])
    out += "e"
    if e < 0:
        out += "-"
        e = -e
    else:
        out += "+"
    if e < 10:
        out += "0"
    out += String(e)
    if out.find("e-0") >= 0 and out.byte_length() >= 4:
        var n = out.byte_length()
        if out[byte = n - 4] == "e" and out[byte = n - 3] == "-" and out[byte = n - 2] == "0":
            var _a1_out = String(out[byte = 0 : n - 2]) + String(out[byte = n - 1 :])
            out = _a1_out
    if neg:
        return "-" + out
    return out


def go_json_string(s: String) -> String:
    return json_quote(s)


struct JW(Movable):
    """Builds pretty JSON with Go MarshalIndent layout via begin/end calls."""

    var buf: String
    var depth: Int
    var first: List[Bool]
    var pending_key: Bool

    def __init__(out self):
        self.buf = String("")
        self.depth = 0
        self.first = List[Bool]()
        self.pending_key = False

    def _indent(mut self):
        self.buf += "\n"
        for _ in range(self.depth):
            self.buf += "  "

    def _item(mut self):
        if len(self.first) > 0:
            if not self.first[len(self.first) - 1]:
                self.buf += ","
            self.first[len(self.first) - 1] = False
            self._indent()

    def key(mut self, k: String):
        self._item()
        self.buf += go_json_string(k) + ": "
        self.pending_key = True

    def _value_prefix(mut self):
        if self.pending_key:
            self.pending_key = False
        else:
            self._item()

    def begin_obj(mut self):
        self._value_prefix()
        self.buf += "{"
        self.depth += 1
        self.first.append(True)

    def end_obj(mut self):
        self.depth -= 1
        var empty = self.first.pop()
        if not empty:
            self._indent()
        self.buf += "}"

    def begin_arr(mut self):
        self._value_prefix()
        self.buf += "["
        self.depth += 1
        self.first.append(True)

    def end_arr(mut self):
        self.depth -= 1
        var empty = self.first.pop()
        if not empty:
            self._indent()
        self.buf += "]"

    def raw_key(mut self, quoted: String):
        """Object key already in JSON form (quotes included)."""
        self._item()
        self.buf += quoted + ": "
        self.pending_key = True

    def raw(mut self, text: String):
        """Scalar already in JSON form (number/literal/quoted string)."""
        self._value_prefix()
        self.buf += text

    def num(mut self, x: Float64):
        self._value_prefix()
        self.buf += go_json_float(x)

    def int(mut self, x: Int):
        self._value_prefix()
        self.buf += String(x)

    def str(mut self, s: String):
        self._value_prefix()
        self.buf += go_json_string(s)

    def bool(mut self, b: Bool):
        self._value_prefix()
        self.buf += "true" if b else "false"

    def null(mut self):
        self._value_prefix()
        self.buf += "null"

    def float_arr(mut self, xs: List[Float64]):
        if len(xs) == 0:
            self._value_prefix()
            self.buf += "[]"
            return
        self.begin_arr()
        for x in xs:
            self.num(x)
        self.end_arr()

    def int_arr(mut self, xs: List[Int]):
        if len(xs) == 0:
            self._value_prefix()
            self.buf += "[]"
            return
        self.begin_arr()
        for x in xs:
            self.int(x)
        self.end_arr()

    def str_arr(mut self, xs: List[String]):
        if len(xs) == 0:
            self._value_prefix()
            self.buf += "[]"
            return
        self.begin_arr()
        for x in xs:
            self.str(x)
        self.end_arr()


def _int_noraise(s: String) -> Int:
    var v = 0
    var neg = False
    for b in s.as_bytes():
        if b == 45:
            neg = True
        elif b >= 48 and b <= 57:
            v = v * 10 + Int(b - 48)
    return -v if neg else v
