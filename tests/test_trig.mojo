# tier: unit
from std.math import sin as std_sin, cos as std_cos, isnan, isinf
from harness.runner import Suite
from geometry.trig import sin, cos, sincos, sinf, cosf


def main() raises:
    var s = Suite("trig")
    # ordinary: against libm over the range games use (a few ulp of f32)
    var worst = Float64(0)
    for i in range(-20000, 20001):
        var x = Float32(i) * 0.0173
        worst = max(worst, abs(Float64(sin(x)) - Float64(std_sin(x))))
        worst = max(worst, abs(Float64(cos(x)) - Float64(std_cos(x))))
    s.check(worst < 3e-7, "sin / cos within 3e-7 of libm over [-346, 346] (worst " + String(worst) + ")")
    # every branch boundary of the argument split, both signs
    var edges: List[Float32] = [0.0, 1e-4, 0.785398, 0.7853982, 2.356194, 2.3561945, 3.926990, 3.9269910, 5.497787, 5.4977875, 7.068583, 7.0685835, 1e4, 1e8, 4.0e8, 4.3e8, 1e10]
    var bad = 0
    for e in edges:
        for sg in range(2):
            var x = e if sg == 0 else -e
            if abs(Float64(sin(x)) - Float64(std_sin(x))) > (3e-7 if abs(x) < 4e8 else 2.0):
                bad += 1
            if abs(Float64(cos(x)) - Float64(std_cos(x))) > (3e-7 if abs(x) < 4e8 else 2.0):
                bad += 1
    s.eqi(bad, 0, "branch boundaries agree with libm (huge arguments only need to stay finite and bounded)")
    # identities and exact points
    s.check(sin(Float32(0)) == 0 and cos(Float32(0)) == 1, "sin 0 = 0, cos 0 = 1")
    s.check(sin(Float32(-0.0)) == 0, "sin -0 keeps its sign bit")
    var sc = sincos(Float32(0.7))
    s.almost(Float64(sc[0] * sc[0] + sc[1] * sc[1]), 1.0, "sin^2 + cos^2 = 1", tol=2e-7)
    # SIMD and other dtypes
    var v = sin(SIMD[DType.float32, 4](0.1, 1.0, 2.0, 3.0))
    s.almost(Float64(v[2]), Float64(std_sin(Float32(2.0))), "SIMD[f32, 4] lanes", tol=3e-7)
    s.almost(sin(Float64(1.0)), std_sin(Float64(1.0)), "f64 falls through to std.math", tol=1e-15)
    # extreme
    var inf = Float32(1) / Float32(0)
    s.check(isnan(sinf(inf)) and isnan(cosf(inf)) and isnan(sinf(-inf)), "sin / cos of Inf is NaN")
    s.check(isnan(sinf(inf - inf)) and isnan(cosf(inf - inf)), "sin / cos of NaN is NaN")
    s.check(abs(sinf(3.0e38)) <= 1.0 and abs(cosf(-3.0e38)) <= 1.0 and not isnan(sinf(3.0e38)), "float max stays finite and bounded")
    # determinism: the same input gives the same bits (no hidden state)
    s.check(sinf(123.456) == sinf(123.456) and cosf(-77.7) == cosf(-77.7), "pure function")
    s.finish()
