# expect: ok 52
# mode: run
# A compile-time check that a constant matches a struct's size (vertex layouts, C-ABI records).
from std.sys import size_of


@fieldwise_init
struct V4:
    var a: Float32
    var b: Float32
    var c: Float32
    var d: Float32


@fieldwise_init
struct BodyState13:
    var pos: V4
    var rot: V4
    var vel: V4
    var w: Float32


comptime FLOATS = 13


def check_layout():
    comptime assert size_of[BodyState13]() == FLOATS * 4, "BodyState13 must be 13 floats"


def main():
    check_layout()
    print("ok", size_of[BodyState13]())
