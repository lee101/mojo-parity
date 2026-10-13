import random, sys
r = random.Random(int(sys.argv[1]))
def num():
    k = r.random()
    if k < 0.1: return r.choice(["0", "-0", "1", "0.1", "1000", "1e5", "1.5E-3", "-.5", "+2", "5.", "0.000", "12.3400"])
    if k < 0.15: return r.choice(["", "-", ".", "1..2", "abc", "1e", "1e+", "--1", "1_0", " 1", "1.2.3", "e5"])
    ip = str(r.randint(0, 10**r.randint(0, 9)))
    fp = "".join(r.choice("0123456789") for _ in range(r.randint(0, 18)))
    s = ip + ("." + fp if fp or r.random() < 0.1 else "")
    if r.random() < 0.3: s = "-" + s
    if r.random() < 0.05: s += "e" + str(r.randint(-20, 20))
    return s
for _ in range(int(sys.argv[2])):
    op = r.choice(["parse", "float", "add", "sub", "mul", "div", "div", "cmp", "floor", "ceil", "f64"])
    if op == "parse": print("parse", num())
    elif op == "float": print("float", repr(r.choice([r.random() * 10 ** r.randint(-12, 12), 1 - r.random() * 0.01, 0.001 + r.random() * 0.009, float(r.randint(1, 10**6)) / 7, 0.1, 0.25, 1.003, 0.0014])))
    elif op in ("floor", "ceil"): print(op, num(), r.randint(-3, 18))
    else: print(op, num(), num())
