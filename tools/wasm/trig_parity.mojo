"""Compare geometry.trig with musl's own object code (libwasmrt_math.a, symbols wrt_sinf / wrt_cosf).

Built and run by `scripts/trig_parity.py`. Prints `mismatch <n> of <m>`; any mismatch is a bug in the port.
"""

from std.ffi import external_call
from std.memory import bitcast
from geometry.trig import sinf, cosf


def _same(a: Float32, b: Float32) -> Bool:
    # NaN payloads are not part of the contract; every other value must match bit for bit
    if a != a and b != b:
        return True
    return bitcast[DType.uint32, 1](a) == bitcast[DType.uint32, 1](b)


def main():
    var state = UInt64(0x9E3779B97F4A7C15)
    var bad = 0
    var total = 0
    for i in range(4_000_000):
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        var x: Float32
        if i % 4 == 0:  # every float bit pattern (includes NaN / Inf / subnormals / huge)
            x = bitcast[DType.float32, 1](UInt32(state >> 32))
        elif i % 4 == 1:  # the range games use
            x = Float32(Float64(state >> 11) / 9007199254740992.0 * 200.0 - 100.0)
        elif i % 4 == 2:  # around multiples of pi/4
            var k = Float64(Int(state % 4000) - 2000)
            x = Float32(k * 0.7853981633974483 + (Float64(state >> 40) / 16777216.0 - 0.5) * 1e-3)
        else:  # up to the reduction limit musl handles without the large path
            x = Float32((Float64(state >> 11) / 9007199254740992.0 * 2.0 - 1.0) * 4.0e8)
        if x == x and abs(x) >= 4.2e8 and abs(x) <= 3.4028235e38:  # musl's multi-precision path; the port differs on purpose
            continue
        var ms = external_call["wrt_sinf", Float32](x)
        var mc = external_call["wrt_cosf", Float32](x)
        total += 2
        if not _same(sinf(x), ms):
            bad += 1
            if bad <= 8:
                print("sin", x, i % 4, sinf(x), ms)

        if not _same(cosf(x), mc):
            bad += 1
            if bad <= 8:
                print("cos", x, i % 4, cosf(x), mc)

    print("mismatch", bad, "of", total)
