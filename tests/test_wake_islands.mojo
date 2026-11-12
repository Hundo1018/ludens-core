# tier: integration
"""`wake_islands` (one pass for many bodies) against `wake_island` called once per body (ROADMAP 17.43, 17.25).

Three separate stacks fall asleep. From the same snapshot, waking a chosen set of bodies in one batch must leave
exactly the bodies awake that waking them one by one does: the whole island of each chosen body, and nothing else.
Cases: one body of one stack, bodies of two stacks, the same body twice, a static body (a no-op), an empty list."""

from harness.runner import Suite
from embed.world import EmbedWorld, unpack_body
from geometry.vec import Real, Vec3
from physics.islands import wake_island, wake_islands


def build(mut hs: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    hs.append(w.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(40.0, 0.5, 40.0, 0.0), 0.0, True))  # 0: the floor
    for s in range(3):  # three stacks of three boxes, far apart
        for k in range(3):
            hs.append(w.add_box(Vec3(Real(s) * 10.0 - 10.0, 0.5 + Real(k) * 1.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def asleep(w: EmbedWorld, hs: List[Int64]) raises -> List[Bool]:
    var out = List[Bool]()
    for i in range(len(hs)):
        out.append(w.is_sleeping(hs[i]))
    return out^


def count(xs: List[Bool]) -> Int:
    var n = 0
    for x in xs:
        if x:
            n += 1
    return n


def same(a: List[Bool], b: List[Bool]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def wake_case(mut s: Suite, blob: List[UInt8], hs: List[Int64], pick: List[Int], want_awake: Int, label: String) raises:
    var a = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    a.load(blob)
    var b = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    b.load(blob)
    var idx = List[Int]()
    for k in range(len(pick)):
        idx.append(unpack_body(hs[pick[k]]).index())
        wake_island(a.scene.bset, idx[k])
    wake_islands(b.scene.bset, idx)
    var sa = asleep(a, hs)
    var sb = asleep(b, hs)
    var awake = len(hs) - 1 - count(sb)  # dynamic bodies awake (the floor is never asleep)
    s.check(same(sa, sb), label + ": the batch leaves the same bodies asleep as one call per body")
    s.check(awake == want_awake, label + ": " + String(awake) + " dynamic bodies awake")


def main() raises:
    var s = Suite("wake_islands")
    var hs = List[Int64]()
    var w = build(hs)
    for _ in range(600):
        w.physics_tick()
    var all_asleep = count(asleep(w, hs)) == 9
    s.check(all_asleep, "the nine boxes are asleep after 10 s (" + String(count(asleep(w, hs))) + ")")
    var blob = w.save()
    wake_case(s, blob, hs, [2], 3, "one box of the first stack")
    wake_case(s, blob, hs, [1, 9], 6, "a box of the first stack and one of the third")
    wake_case(s, blob, hs, [5, 5, 6], 3, "the same box twice and its neighbour")
    wake_case(s, blob, hs, [0], 0, "the static floor")
    wake_case(s, blob, hs, List[Int](), 0, "an empty list")
    wake_case(s, blob, hs, [1, 4, 7], 9, "one box of every stack")
    s.finish()
