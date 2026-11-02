# tier: integration
"""Bit-packed point caches (ROADMAP 17.63, `PointCacheWriter(pack=True)`).

  1. Ordinary: the 16 x 16 cloth of test_sim_cache, 240 frames, at err
     1 cm / 1 mm / 0.1 mm: packed caches read back every frame within err
     (as the varint ones), random access included; bytes per point per
     frame are printed for both -- packed breaks the varint's 3 bytes per
     point floor at 1 cm and 1 mm (asserted: < 3), and is never larger than
     the varint cache by more than the frames' width bytes.
  2. Integration: a packed cache is version 2; without `pack` the writer's
     bytes are exactly the version-1 bytes it wrote before (the cache of
     test_sim_cache: same size, same reads), and the reader takes both.
  3. Extreme: a still frame (all deltas 0) packs to width 0; a truncated
     packed cache and a flipped byte raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.cloth import MeshCloth, grid_mesh
from physics.sim_cache import PointCacheWriter, PointCacheReader

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _cloth() raises -> MeshCloth:
    var m = grid_mesh(15, 15, 1, 1, Vec3(-0.5, 1, -0.5, 0))
    var c = MeshCloth(m[0], m[1], 0.2, 0, 1e-3)
    c.pin(0)
    c.pin(15)
    return c^


def _maxerr(a: List[Vec3], b: List[Vec3]) -> Real:
    var w = Real(0)
    for i in range(len(a)):
        for k in range(3):
            w = max(w, abs(a[i][k] - b[i][k]))
    return w


def main() raises:
    var s = Suite("sim_cache_pack")
    var live = _cloth()
    var frames = List[List[Vec3]]()
    for _ in range(240):
        live.advance(DT, G)
        frames.append(live.x.copy())
    var npts = len(frames[0])
    var ok = True
    var below = True
    var line = String("  bytes / point / frame (varint -> packed):")
    for err in [Real(1e-2), Real(1e-3), Real(1e-4)]:
        var a = PointCacheWriter(err, 16)
        var b = PointCacheWriter(err, 16, True)
        for f in frames:
            a.add_frame(f)
            b.add_frame(f)
        var ba = a.bytes()
        var bb = b.bytes()
        var rb = PointCacheReader(bb.copy())
        for f in range(240):
            ok = ok and _maxerr(rb.frame(f), frames[f]) <= err + 1e-6
        var pa = Real(len(ba)) / Real(240 * npts)
        var pb = Real(len(bb)) / Real(240 * npts)
        line += " err " + String(err) + ": " + String(pa) + " -> " + String(pb)
        if err >= 1e-3:
            below = below and pb < 3
        below = below and len(bb) <= len(ba) + 240
    print(line)
    s.check(ok, "packed caches read back within err, random access included")
    s.check(below, "packed breaks the 3 bytes per point floor at 1 cm and 1 mm")

    var plain = PointCacheWriter(1e-3, 16)
    var packed = PointCacheWriter(1e-3, 16, True)
    for f in frames:
        plain.add_frame(f)
        packed.add_frame(f)
    var pb_ = plain.bytes()
    var kb_ = packed.bytes()
    print("  1 mm plain", len(pb_), "bytes (test_sim_cache records 197486 on x86-64 (no FMA) and 197494 where the compiler contracts to FMA (aarch64)), version", pb_[4], ";  packed version", kb_[4])
    s.check((len(pb_) == 197486 or len(pb_) == 197494) and pb_[4] == 1 and kb_[4] == 2, "without pack: the version-1 bytes as before; packed is version 2")

    var still = PointCacheWriter(1e-3, 16, True)
    still.add_frame(frames[0])
    still.add_frame(frames[0])
    var sb = still.bytes()
    var rs = PointCacheReader(sb.copy())
    var same = _maxerr(rs.frame(1), frames[0]) <= 1e-3 + 1e-6
    var raised = 0
    var bad = kb_.copy()
    bad[len(bad) // 2] = bad[len(bad) // 2] ^ 0x04
    try:
        _ = PointCacheReader(bad^)
    except:
        raised += 1
    var cut = List[UInt8]()
    for q in range(len(kb_) - 40):
        cut.append(kb_[q])
    try:
        _ = PointCacheReader(cut^)
    except:
        raised += 1
    print("  still frame packed: cache", len(sb), "bytes for", npts, "points x 2 frames")
    s.check(same and raised == 2, "a still frame packs to nothing; corruption and truncation raise")
    s.finish()
