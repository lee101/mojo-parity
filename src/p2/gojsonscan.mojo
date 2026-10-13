"""encoding/json checkValid: the scanner state machine from Go's scanner.go, so
syntax errors carry Go's exact text ("invalid character 'o' in literal null
(expecting 'u')", "unexpected end of JSON input", ...)."""

from p2.gofmt import go_quote

comptime S_BEGIN_VALUE_OR_EMPTY = 0
comptime S_BEGIN_VALUE = 1
comptime S_BEGIN_STRING_OR_EMPTY = 2
comptime S_BEGIN_STRING = 3
comptime S_END_VALUE = 4
comptime S_END_TOP = 5
comptime S_IN_STRING = 6
comptime S_IN_STRING_ESC = 7
comptime S_IN_STRING_ESC_U = 8
comptime S_IN_STRING_ESC_U1 = 9
comptime S_IN_STRING_ESC_U12 = 10
comptime S_IN_STRING_ESC_U123 = 11
comptime S_NEG = 12
comptime S_1 = 13
comptime S_0 = 14
comptime S_DOT = 15
comptime S_DOT0 = 16
comptime S_E = 17
comptime S_ESIGN = 18
comptime S_E0 = 19
comptime S_T = 20
comptime S_TR = 21
comptime S_TRU = 22
comptime S_F = 23
comptime S_FA = 24
comptime S_FAL = 25
comptime S_FALS = 26
comptime S_N = 27
comptime S_NU = 28
comptime S_NUL = 29
comptime S_ERROR = 30

comptime P_OBJ_KEY = 0
comptime P_OBJ_VALUE = 1
comptime P_ARR_VALUE = 2


def quote_char(c: UInt8) -> String:
    if c == 39:
        return "'\\''"
    if c == 34:
        return "'\"'"
    var s = go_quote(chr(Int(c)))
    return "'" + String(s[byte = 1 : s.byte_length() - 1]) + "'"


@always_inline
def _space(c: UInt8) -> Bool:
    return c <= 32 and (c == 32 or c == 9 or c == 13 or c == 10)


struct _Scan:
    var step: Int
    var parse: List[Int]
    var err: String
    var end_top: Bool

    def __init__(out self):
        self.step = S_BEGIN_VALUE
        self.parse = List[Int]()
        self.err = ""
        self.end_top = False

    def error(mut self, c: UInt8, context: String) -> Bool:
        self.step = S_ERROR
        self.err = "invalid character " + quote_char(c) + " " + context
        return False

    def pop_parse(mut self):
        _ = self.parse.pop()
        if len(self.parse) == 0:
            self.step = S_END_TOP
            self.end_top = True
        else:
            self.step = S_END_VALUE

    def begin_value(mut self, c: UInt8) -> Bool:
        if _space(c):
            return True
        if c == 123:
            self.step = S_BEGIN_STRING_OR_EMPTY
            self.parse.append(P_OBJ_KEY)
            return True
        if c == 91:
            self.step = S_BEGIN_VALUE_OR_EMPTY
            self.parse.append(P_ARR_VALUE)
            return True
        if c == 34:
            self.step = S_IN_STRING
            return True
        if c == 45:
            self.step = S_NEG
            return True
        if c == 48:
            self.step = S_0
            return True
        if c == 116:
            self.step = S_T
            return True
        if c == 102:
            self.step = S_F
            return True
        if c == 110:
            self.step = S_N
            return True
        if c >= 49 and c <= 57:
            self.step = S_1
            return True
        return self.error(c, "looking for beginning of value")

    def end_value(mut self, c: UInt8) -> Bool:
        var n = len(self.parse)
        if n == 0:
            self.step = S_END_TOP
            self.end_top = True
            return self.end_top_fn(c)
        if _space(c):
            self.step = S_END_VALUE
            return True
        var ps = self.parse[n - 1]
        if ps == P_OBJ_KEY:
            if c == 58:
                self.parse[n - 1] = P_OBJ_VALUE
                self.step = S_BEGIN_VALUE
                return True
            return self.error(c, "after object key")
        if ps == P_OBJ_VALUE:
            if c == 44:
                self.parse[n - 1] = P_OBJ_KEY
                self.step = S_BEGIN_STRING
                return True
            if c == 125:
                self.pop_parse()
                return True
            return self.error(c, "after object key:value pair")
        if c == 44:
            self.step = S_BEGIN_VALUE
            return True
        if c == 93:
            self.pop_parse()
            return True
        return self.error(c, "after array element")

    def end_top_fn(mut self, c: UInt8) -> Bool:
        if not _space(c):
            return self.error(c, "after top-level value")
        return True

    def feed(mut self, c: UInt8) -> Bool:
        var s = self.step
        if s == S_BEGIN_VALUE:
            return self.begin_value(c)
        if s == S_BEGIN_VALUE_OR_EMPTY:
            if _space(c):
                return True
            if c == 93:
                return self.end_value(c)
            return self.begin_value(c)
        if s == S_BEGIN_STRING_OR_EMPTY:
            if _space(c):
                return True
            if c == 125:
                self.parse[len(self.parse) - 1] = P_OBJ_VALUE
                return self.end_value(c)
            return self._begin_string(c)
        if s == S_BEGIN_STRING:
            return self._begin_string(c)
        if s == S_END_VALUE:
            return self.end_value(c)
        if s == S_END_TOP:
            return self.end_top_fn(c)
        if s == S_IN_STRING:
            if c == 34:
                self.step = S_END_VALUE
                return True
            if c == 92:
                self.step = S_IN_STRING_ESC
                return True
            if c < 32:
                return self.error(c, "in string literal")
            return True
        if s == S_IN_STRING_ESC:
            if c == 98 or c == 102 or c == 110 or c == 114 or c == 116 or c == 92 or c == 47 or c == 34:
                self.step = S_IN_STRING
                return True
            if c == 117:
                self.step = S_IN_STRING_ESC_U
                return True
            return self.error(c, "in string escape code")
        if s >= S_IN_STRING_ESC_U and s <= S_IN_STRING_ESC_U123:
            if (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70):
                self.step = S_IN_STRING if s == S_IN_STRING_ESC_U123 else s + 1
                return True
            return self.error(c, "in \\u hexadecimal character escape")
        if s == S_NEG:
            if c == 48:
                self.step = S_0
                return True
            if c >= 49 and c <= 57:
                self.step = S_1
                return True
            return self.error(c, "in numeric literal")
        if s == S_1:
            if c >= 48 and c <= 57:
                return True
            return self._state0(c)
        if s == S_0:
            return self._state0(c)
        if s == S_DOT:
            if c >= 48 and c <= 57:
                self.step = S_DOT0
                return True
            return self.error(c, "after decimal point in numeric literal")
        if s == S_DOT0:
            if c >= 48 and c <= 57:
                return True
            if c == 101 or c == 69:
                self.step = S_E
                return True
            self.step = S_END_VALUE
            return self.end_value(c)
        if s == S_E:
            if c == 43 or c == 45:
                self.step = S_ESIGN
                return True
            return self._esign(c)
        if s == S_ESIGN:
            return self._esign(c)
        if s == S_E0:
            if c >= 48 and c <= 57:
                return True
            self.step = S_END_VALUE
            return self.end_value(c)
        return self._literal(c)

    def _begin_string(mut self, c: UInt8) -> Bool:
        if _space(c):
            return True
        if c == 34:
            self.step = S_IN_STRING
            return True
        return self.error(c, "looking for beginning of object key string")

    def _state0(mut self, c: UInt8) -> Bool:
        if c == 46:
            self.step = S_DOT
            return True
        if c == 101 or c == 69:
            self.step = S_E
            return True
        self.step = S_END_VALUE
        return self.end_value(c)

    def _esign(mut self, c: UInt8) -> Bool:
        if c >= 48 and c <= 57:
            self.step = S_E0
            return True
        return self.error(c, "in exponent of numeric literal")

    def _literal(mut self, c: UInt8) -> Bool:
        var s = self.step
        if s == S_T:
            return self._lit(c, 114, S_TR, "in literal true (expecting 'r')")
        if s == S_TR:
            return self._lit(c, 117, S_TRU, "in literal true (expecting 'u')")
        if s == S_TRU:
            return self._lit(c, 101, S_END_VALUE, "in literal true (expecting 'e')")
        if s == S_F:
            return self._lit(c, 97, S_FA, "in literal false (expecting 'a')")
        if s == S_FA:
            return self._lit(c, 108, S_FAL, "in literal false (expecting 'l')")
        if s == S_FAL:
            return self._lit(c, 115, S_FALS, "in literal false (expecting 's')")
        if s == S_FALS:
            return self._lit(c, 101, S_END_VALUE, "in literal false (expecting 'e')")
        if s == S_N:
            return self._lit(c, 117, S_NU, "in literal null (expecting 'u')")
        if s == S_NU:
            return self._lit(c, 108, S_NUL, "in literal null (expecting 'l')")
        if s == S_NUL:
            return self._lit(c, 108, S_END_VALUE, "in literal null (expecting 'l')")
        return False

    def _lit(mut self, c: UInt8, want: UInt8, nxt: Int, msg: String) -> Bool:
        if c == want:
            self.step = nxt
            return True
        return self.error(c, msg)


def json_check_valid(b: Span[UInt8, _]) -> String:
    """"" when b is one valid JSON value, else Go's SyntaxError text."""
    var sc = _Scan()
    for i in range(len(b)):
        if not sc.feed(b[i]):
            return sc.err
    if sc.end_top:
        return ""
    _ = sc.feed(32)
    if sc.end_top:
        return ""
    if sc.err.byte_length() > 0:
        return sc.err
    return "unexpected end of JSON input"
