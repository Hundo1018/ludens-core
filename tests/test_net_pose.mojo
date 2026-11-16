# tier: integration
"""Quantised rotations that survive a network round trip (embed/world.mojo quantize_rotation; ludens-engine#75).

  ordinary     10 000 random rotations: quantize_rotation's integers, dequantised, teleported on an EmbedWorld body and
               read back with state().rot, round to the same integers every time; teleport_rotation predicts state().rot
               bit for bit.
  comparison   plain rounding of the same rotations does not survive the trip for some of them (the count is printed;
               the playground measured 2 of 160 integers off by one).
  extreme      a quaternion with a negative w and one along an axis round-trip as well; a non-unit input is normalised
               first.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from embed.world import EmbedWorld, teleport_rotation, quantize_rotation, dequantize_rotation


def _rand(mut seed: UInt64) -> Real:
    seed = seed * 6364136223846793005 + 1442695040888963407
    return Real(Float64((seed >> 33) & 0xFFFFFF) / Float64(0xFFFFFF)) * 2 - 1


def _round4(q: Quat) -> List[Int]:
    var r = List[Int]()
    r.append(Int(round(q.x * Real(1000000.0))))
    r.append(Int(round(q.y * Real(1000000.0))))
    r.append(Int(round(q.z * Real(1000000.0))))
    r.append(Int(round(q.w * Real(1000000.0))))
    return r^


def _same(a: List[Int], b: List[Int]) -> Bool:
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]


def _trip(mut w: EmbedWorld, h: Int64, r: List[Int]) raises -> List[Int]:
    w.teleport(h, Vec3(0, 0, 0, 0), dequantize_rotation(r))
    return _round4(w.state(h).rot)


def main() raises:
    var s = Suite("net_pose")
    var w = EmbedWorld(1.0 / 60.0, Vec3(0, 0, 0, 0))
    var h = w.add_box(Vec3(0, 0, 0, 0), Vec3(0.5, 0.5, 0.5, 0), 1.0, False)
    var seed = UInt64(7)
    var fixed_ok = 0
    var naive_bad = 0
    var predicted = 0
    var n = 10000
    for _ in range(n):
        var q = Quat(_rand(seed), _rand(seed), _rand(seed), _rand(seed))
        var r = quantize_rotation(q)
        if _same(_trip(w, h, r), r):
            fixed_ok += 1
        var plain = _round4(teleport_rotation(q))
        if not _same(_trip(w, h, plain), plain):
            naive_bad += 1
        w.teleport(h, Vec3(0, 0, 0, 0), q)
        var st = w.state(h).rot
        var t = teleport_rotation(q)
        if st.x == t.x and st.y == t.y and st.z == t.z and st.w == t.w:
            predicted += 1
    print("round trip: quantize_rotation", fixed_ok, "/", n, "; plain rounding off on", naive_bad, "of", n, "rotations")
    s.check(fixed_ok == n, "quantize_rotation survives dequantise -> teleport -> state -> round for every rotation (" + String(fixed_ok) + " / " + String(n) + ")")
    s.check(predicted == n, "teleport_rotation equals state().rot bit for bit (" + String(predicted) + " / " + String(n) + ")")
    s.check(naive_bad > 0, "plain rounding does not always survive (" + String(naive_bad) + " rotations off)")
    var edge = List[Quat]()
    edge.append(Quat(0.1, -0.2, 0.3, -0.9))
    edge.append(Quat(1, 0, 0, 0))
    edge.append(Quat(0, 0, 0, 3))
    var edge_ok = 0
    for q in edge:
        var r = quantize_rotation(q)
        if _same(_trip(w, h, r), r):
            edge_ok += 1
    s.check(edge_ok == 3, "negative w, an axis and a non-unit quaternion round-trip (" + String(edge_ok) + " / 3)")
    var unit = dequantize_rotation(quantize_rotation(Quat(0, 0, 0, 3)))
    s.check(unit.w == Real(1) and unit.x == Real(0), "a non-unit input is normalised (w " + String(unit.w) + ")")
    s.finish()
