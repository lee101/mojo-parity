"""Work partitioning for max.algorithm.parallelize.

Contiguous blocks let each task reuse one Workspace; ~8 blocks per worker absorb
load imbalance. P2M_THREADS caps the worker count (default: all logical cores),
which is how the single-core comparison against Go is measured.
"""

from std.os import getenv
from std.sys import num_logical_cores


def workers() -> Int:
    var raw = getenv("P2M_THREADS", "")
    if raw.byte_length() > 0:
        var v = 0
        for b in raw.as_bytes():
            if b >= 48 and b <= 57:
                v = v * 10 + Int(b - 48)
        if v > 0:
            return v
    return num_logical_cores()


def chunk_size(total: Int) -> Int:
    var blocks = max(1, workers() * 8)
    var per = (total + blocks - 1) // blocks
    return max(1, per)
