"""LightGBM text-model predictor (numerical splits only) matching Booster.predict raw scores.
Adapted from bitbank-mojo src/linemodel.mojo; adds lambdarank and the dense-row zero drop."""

from std.math import isnan
from p2.gofmt import go_parse_float

comptime K_ZERO = Float64(Float32(1e-35))


def _floats(s: String) raises -> List[Float64]:
    var out = List[Float64]()
    for tok in s.split(" "):
        var t = String(tok)
        if t.byte_length() == 0:
            continue
        var r = go_parse_float(t)
        if not r.ok:
            raise Error("bad number in model: " + t)
        out.append(r.value)
    return out^


def _ints(s: String) raises -> List[Int]:
    var out = List[Int]()
    for tok in s.split(" "):
        var t = String(tok)
        if t.byte_length() > 0:
            out.append(atol(t))
    return out^


struct Booster(Movable):
    var tree_off: List[Int]
    var leaf_off: List[Int]
    var feat: List[Int]
    var thr: List[Float64]
    var dtype: List[Int]
    var left: List[Int]
    var right: List[Int]
    var leaf: List[Float64]
    var average: Bool
    var nfeat: Int

    def __init__(out self, text: String) raises:
        self.tree_off = List[Int]()
        self.leaf_off = List[Int]()
        self.feat = List[Int]()
        self.thr = List[Float64]()
        self.dtype = List[Int]()
        self.left = List[Int]()
        self.right = List[Int]()
        self.leaf = List[Float64]()
        self.average = False
        self.nfeat = 0
        var in_tree = False
        var nl = 0
        for line0 in text.splitlines():
            var line = String(line0)
            if line.startswith("end of trees"):
                break
            if line.startswith("Tree="):
                in_tree = True
                continue
            var eq = line.find("=")
            if eq < 0:
                continue
            var key = String(line[byte=0:eq])
            var val = String(line[byte = eq + 1 :])
            if not in_tree:
                if key == "num_class" or key == "num_tree_per_iteration":
                    if atol(val) != 1:
                        raise Error("multiclass unsupported")
                elif key == "max_feature_idx":
                    self.nfeat = atol(val) + 1
                elif key == "objective":
                    if not (val.startswith("lambdarank") or val.startswith("regression") or val.startswith("rank_xendcg")):
                        raise Error("unsupported objective " + val)
                elif key == "average_output":
                    self.average = True
                continue
            if key == "num_leaves":
                nl = atol(val)
                self.tree_off.append(len(self.feat))
                self.leaf_off.append(len(self.leaf))
            elif key == "num_cat":
                if atol(val) != 0:
                    raise Error("categorical splits unsupported")
            elif key == "is_linear":
                if atol(val) != 0:
                    raise Error("linear trees unsupported")
            elif key == "split_feature":
                self.feat.extend(_ints(val))
            elif key == "decision_type":
                var d = _ints(val)
                for i in range(len(d)):
                    if d[i] & 1:
                        raise Error("categorical decision unsupported")
                self.dtype.extend(d^)
            elif key == "threshold":
                self.thr.extend(_floats(val))
            elif key == "left_child":
                self.left.extend(_ints(val))
            elif key == "right_child":
                self.right.extend(_ints(val))
            elif key == "leaf_value":
                var lv = _floats(val)
                if len(lv) != nl:
                    raise Error("leaf count mismatch")
                self.leaf.extend(lv^)
        var ni = len(self.feat)
        if len(self.tree_off) == 0 or len(self.thr) != ni or len(self.dtype) != ni or len(self.left) != ni or len(self.right) != ni:
            raise Error("malformed model")
        self.tree_off.append(ni)
        self.leaf_off.append(len(self.leaf))

    def predict(self, x0: List[Float64]) -> Float64:
        """Raw score; the dense row drops |v| <= kZeroThreshold (non-NaN) to 0 like LightGBM's row reader."""
        var x = x0.copy()
        for i in range(len(x)):
            var v = x[i]
            if not isnan(v) and abs(v) <= K_ZERO:
                x[i] = 0.0
        var s = Float64(0)
        var nt = len(self.tree_off) - 1
        for t in range(nt):
            var base = self.tree_off[t]
            var leaf = 0
            if self.tree_off[t + 1] > base:
                var node = 0
                while node >= 0:
                    var i = base + node
                    var v = x[self.feat[i]]
                    var dt = self.dtype[i]
                    if dt & 12 != 0 or isnan(v):
                        var mt = (dt >> 2) & 3
                        if isnan(v) and mt != 2:
                            v = 0.0
                        if (mt == 1 and v >= -K_ZERO and v <= K_ZERO) or (mt == 2 and isnan(v)):
                            node = self.left[i] if (dt & 2) != 0 else self.right[i]
                            continue
                    node = self.left[i] if v <= self.thr[i] else self.right[i]
                leaf = ~node
            s += self.leaf[self.leaf_off[t] + leaf]
        if self.average and nt > 0:
            s /= Float64(nt)
        return s
