from dec.decimal import Dec, dec_parse, dparse0
from p2.gofmt import go_format_float, go_parse_float


def main() raises:
    var f = open("/dev/stdin", "r")
    var data = f.read()
    f.close()
    var out = String("")
    for line in data.split("\n"):
        if line.byte_length() == 0:
            continue
        var p = String(line).split(" ")
        var op = String(p[0])
        if op == "parse":
            try:
                var d = dec_parse(String(p[1]))
                out += "true " + d.string() + "\n"
            except:
                out += "false 0\n"
        elif op == "float":
            out += Dec.from_f64(go_parse_float(String(p[1])).value).string() + "\n"
        else:
            var a = dparse0(String(p[1]))
            var bs = String(p[2])
            var b = dparse0(bs)
            if op == "add":
                out += a.add(b).string()
            elif op == "sub":
                out += a.sub(b).string()
            elif op == "mul":
                out += a.mul(b).string()
            elif op == "div":
                out += "divzero" if b.is_zero() else a.div(b).string()
            elif op == "cmp":
                out += String(a.cmp(b))
            elif op == "floor":
                out += a.round_floor(atol(bs)).string()
            elif op == "ceil":
                out += a.round_ceil(atol(bs)).string()
            elif op == "f64":
                out += go_format_float(a.f64(), "g", -1)
            out += "\n"
    print(out, end="")
