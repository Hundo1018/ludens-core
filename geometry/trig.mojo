"""Trigonometry that gives the same bits on every target (ROADMAP 17.89 / #75).

The engine's trigonometry must not depend on the platform's libm: glibc, musl and a browser's
`Math.sin` round differently, so a wasm module and a native build would drift apart. This module
is a line-by-line port of musl's `sinf` / `cosf` (`__sindf`, `__cosdf`, medium-size `__rem_pio2f`):
single-precision results, double-precision intermediates, no libm call. Compiled from the same
source for native and wasm64 (no FMA contraction on `--target-cpu x86-64`), both produce the same
bits; `scripts/trig_parity.py` checks the port against musl's own object code.

Engine packages above `geometry` import `sin` / `cos` from here, not from `std.math`
(`arch check` enforces it). Other float types fall through to `std.math`.

Beyond |x| ~ 2^28 * pi/2 musl switches to a multi-precision reduction (`__rem_pio2_large`); a float
that large has an ulp above 2 pi, so the angle carries no information. This port reduces it in
double precision while |x| < 1e15 and returns sin 0 / cos 1 past that -- deterministic, finite,
and not musl's value there.
"""

from std.math import sin as _std_sin, cos as _std_cos
from std.memory import bitcast

comptime _PIO2 = 1.5707963267948966  # 0x3FF921FB54442D18
comptime _S1PIO2 = 1.0 * _PIO2
comptime _S2PIO2 = 2.0 * _PIO2
comptime _S3PIO2 = 3.0 * _PIO2
comptime _S4PIO2 = 4.0 * _PIO2

# __sindf / __cosdf minimax coefficients: integer mantissa over a power of two, both exact in f64.
comptime _S1 = -Float64(0x15555554CBAC77) / 36028797018963968.0  # 2^55
comptime _S2 = Float64(0x111110896EFBB2) / 576460752303423488.0  # 2^59
comptime _S3 = -Float64(0x1A00F9E2CAE774) / 36893488147419103232.0  # 2^65
comptime _S4 = Float64(0x16CD878C3B46A7) / 2361183241434822606848.0  # 2^71
comptime _C0 = -Float64(0x1FFFFFFD0C5E81) / 18014398509481984.0  # 2^54
comptime _C1 = Float64(0x155553E1053A42) / 144115188075855872.0  # 2^57
comptime _C2 = -Float64(0x16C087E80F1E27) / 4611686018427387904.0  # 2^62
comptime _C3 = Float64(0x199342E0EE5069) / 295147905179352825856.0  # 2^68

# __rem_pio2f, medium size
comptime _TOINT = 6755399441055744.0  # 1.5 / DBL_EPSILON
comptime _PIO4 = 0.785398185253143310546875  # 0x1.921fb6p-1
comptime _INVPIO2 = 6.36619772367581382433e-01
comptime _PIO2_1 = 1.57079631090164184570e00
comptime _PIO2_1T = 1.58932547735281966916e-08
comptime _TWO_PI = 6.283185307179586
comptime _INV_TWO_PI = 0.15915494309189535


def _bits(x: Float32) -> UInt32:
    return bitcast[DType.uint32, 1](x)


def _sindf(x: Float64) -> Float32:
    var z = x * x
    var w = z * z
    var r = _S3 + z * _S4
    var s = z * x
    return Float32((x + s * (_S1 + z * _S2)) + s * w * r)


def _cosdf(x: Float64) -> Float32:
    var z = x * x
    var w = z * z
    var r = _C2 + z * _C3
    return Float32(((1.0 + z * _C0) + w * _C1) + (w * z) * r)


def _rem_pio2f(x: Float32, mut y: Float64) -> Int:
    """(quadrant, remainder) for |x| < 2^28 * pi/2; the remainder lands in `y`."""
    var xd = Float64(x)
    var fq = xd * _INVPIO2 + _TOINT - _TOINT
    var n = Int(fq)
    y = xd - fq * _PIO2_1 - fq * _PIO2_1T
    if y < -_PIO4:
        n -= 1
        fq -= 1.0
        y = xd - fq * _PIO2_1 - fq * _PIO2_1T
    elif y > _PIO4:
        n += 1
        fq += 1.0
        y = xd - fq * _PIO2_1 - fq * _PIO2_1T
    return n


def _huge_arg(x: Float32) -> Float32:
    """|x| >= 2^28 * pi/2, finite: fold into [-pi, pi] in double precision (see the module doc)."""
    var xd = Float64(x)
    var a = xd if xd >= 0 else -xd
    if a >= 1e15:
        return 0.0
    var k = xd * _INV_TWO_PI + _TOINT - _TOINT
    return Float32(xd - k * _TWO_PI)


def sinf(x: Float32) -> Float32:
    var hx = _bits(x)
    var sign = (hx >> 31) != 0
    var ix = hx & 0x7FFFFFFF
    if ix <= 0x3F490FDA:  # |x| ~<= pi/4
        if ix < 0x39800000:  # |x| < 2**-12
            return x
        return _sindf(Float64(x))
    if ix <= 0x407B53D1:  # |x| ~<= 5*pi/4
        if ix <= 0x4016CBE3:  # |x| ~<= 3pi/4
            if sign:
                return -_cosdf(Float64(x) + _S1PIO2)
            return _cosdf(Float64(x) - _S1PIO2)
        return _sindf(-(Float64(x) + _S2PIO2) if sign else -(Float64(x) - _S2PIO2))
    if ix <= 0x40E231D5:  # |x| ~<= 9*pi/4
        if ix <= 0x40AFEDDF:  # |x| ~<= 7*pi/4
            if sign:
                return _cosdf(Float64(x) + _S3PIO2)
            return -_cosdf(Float64(x) - _S3PIO2)
        return _sindf(Float64(x) + _S4PIO2 if sign else Float64(x) - _S4PIO2)
    if ix >= 0x7F800000:  # Inf or NaN
        return x - x
    if ix >= 0x4DC90FDB:
        return sinf(_huge_arg(x))
    var y = Float64(0)
    var n = _rem_pio2f(x, y)
    var q = n & 3
    if q == 0:
        return _sindf(y)
    if q == 1:
        return _cosdf(y)
    if q == 2:
        return _sindf(-y)
    return -_cosdf(y)


def cosf(x: Float32) -> Float32:
    var hx = _bits(x)
    var sign = (hx >> 31) != 0
    var ix = hx & 0x7FFFFFFF
    if ix <= 0x3F490FDA:  # |x| ~<= pi/4
        if ix < 0x39800000:  # |x| < 2**-12
            return 1.0
        return _cosdf(Float64(x))
    if ix <= 0x407B53D1:  # |x| ~<= 5*pi/4
        if ix > 0x4016CBE3:  # |x| ~> 3*pi/4
            return -_cosdf(Float64(x) + _S2PIO2 if sign else Float64(x) - _S2PIO2)
        if sign:
            return _sindf(Float64(x) + _S1PIO2)
        return _sindf(_S1PIO2 - Float64(x))
    if ix <= 0x40E231D5:  # |x| ~<= 9*pi/4
        if ix > 0x40AFEDDF:  # |x| ~> 7*pi/4
            return _cosdf(Float64(x) + _S4PIO2 if sign else Float64(x) - _S4PIO2)
        if sign:
            return _sindf(-Float64(x) - _S3PIO2)
        return _sindf(Float64(x) - _S3PIO2)
    if ix >= 0x7F800000:  # Inf or NaN
        return x - x
    if ix >= 0x4DC90FDB:
        return cosf(_huge_arg(x))
    var y = Float64(0)
    var n = _rem_pio2f(x, y)
    var q = n & 3
    if q == 0:
        return _cosdf(y)
    if q == 1:
        return _sindf(-y)
    if q == 2:
        return -_cosdf(y)
    return _sindf(y)


def sin[dtype: DType, width: SIMDLength, //](x: SIMD[dtype, width]) -> SIMD[dtype, width] where dtype.is_floating_point():
    comptime if dtype == DType.float32:
        var r = SIMD[dtype, width]()
        comptime for i in range(width):
            r[i] = rebind[Scalar[dtype]](sinf(rebind[Float32](x[i])))
        return r
    else:
        return _std_sin(x)


def cos[dtype: DType, width: SIMDLength, //](x: SIMD[dtype, width]) -> SIMD[dtype, width] where dtype.is_floating_point():
    comptime if dtype == DType.float32:
        var r = SIMD[dtype, width]()
        comptime for i in range(width):
            r[i] = rebind[Scalar[dtype]](cosf(rebind[Float32](x[i])))
        return r
    else:
        return _std_cos(x)


def sincos[dtype: DType, width: SIMDLength, //](x: SIMD[dtype, width]) -> Tuple[SIMD[dtype, width], SIMD[dtype, width]] where dtype.is_floating_point():
    return (sin(x), cos(x))
