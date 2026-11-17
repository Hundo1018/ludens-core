# expect: REJECTED
# mode: must-fail
# Mojo 1.2.0: a define-selected WorldType loses the static floating-point proof sin() needs ("lacking evidence to
# prove correctness"), and `mojo precompile` refuses -D; so scripts/build_f64.sh keeps rewriting the source line.
from std.math import sin
from std.sys import is_defined

comptime WorldType = DType.float64 if is_defined["LUDENS_F64"]() else DType.float32
comptime Real = Scalar[WorldType]


def half(x: Real) -> Real:
    return x * 0.5 + sin(Real(0))


def main():
    print("ok", WorldType, half(1.0))
