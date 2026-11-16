# tier: unit
"""Motion matching on tracks (ROADMAP 17.92: procedural/motion_match.mojo).

Tracks are synthetic walks: the hip moves along the facing at a speed, two feet swing about it.

  ordinary     a walk turned by 0.7 rad about +Y and moved by (3, 0, -5) gives the same features to 1e-4 (the feature
               is in the facing frame); every row's own probe finds itself; a column that is 0 in every row keeps
               scale 1 and the others are their root mean square.
  integration  a matcher over a slow and a fast walk: an agent on the slow walk moving at the fast walk's speed switches
               to it on its query tick and not before; one moving at the slow speed stays; keep_ratio 0 never
               switches; with query_ticks 4, agent a's first query is tick 4 - a (the stagger); the heading follows the
               velocity and is kept below min_speed; a switch reports where it came from.
  extreme      no tracks, a track with no frames, tracks with different feet counts, too few velocities: each raises.
"""

from std.math import sin, cos, atan2, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec2, Vec3
from procedural.motion_match import MotionTrack, MotionMatchDB, MotionMatcher, raw_feature, feature_dim


def _walk(speed: Real, frames: Int, yaw: Real = 0, shift: Vec3 = Vec3(0, 0, 0, 0)) -> MotionTrack:
    """A walk along +z at `speed` (30 fps), feet swinging with a stride that grows with the speed; then turned by yaw
    about +Y and moved by shift."""
    var t = MotionTrack(30, 2)
    var c = cos(yaw)
    var s = sin(yaw)
    var w = Real(4) + Real(2) * speed
    for f in range(frames):
        var time = Real(f) / Real(30)
        var z = speed * time + Real(0.1) * sin(Real(3) * time)  # the hip's speed varies a little
        var sw = Real(0.3) * sin(w * time)
        var lift = Real(0.1) * abs(sin(w * time))
        var pts = List[Vec3]()
        pts.append(Vec3(0, 1, z, 0))
        pts.append(Vec3(0.1, lift, z + sw, 0))
        pts.append(Vec3(-0.1, Real(0.1) - lift, z - sw, 0))
        var turned = List[Vec3]()
        for p in pts:
            turned.append(Vec3(c * p[0] + s * p[2], p[1], -s * p[0] + c * p[2], 0) + shift)
        var feet = List[Vec3]()
        feet.append(turned[1])
        feet.append(turned[2])
        # the facing +z, turned the same way
        t.add_frame(turned[0], s, c, feet)
    return t^


def _horizons() -> List[Real]:
    var h = List[Real]()
    h.append(Real(0.33))
    h.append(Real(0.67))
    h.append(Real(1.0))
    return h^


def _vels(n: Int, v: Vec2) -> List[Vec2]:
    var out = List[Vec2]()
    for _ in range(n):
        out.append(v)
    return out^


def main() raises:
    var s = Suite("motion_match")
    var h = _horizons()

    # rigid motion of the whole track leaves every feature unchanged
    var a = _walk(1.2, 60)
    var b = _walk(1.2, 60, 0.7, Vec3(3, 0, -5, 0))
    var worst = Real(0)
    for f in range(60):
        var fa = raw_feature(a, f, h)
        var fb = raw_feature(b, f, h)
        for d in range(len(fa)):
            worst = max(worst, abs(fa[d] - fb[d]))
    s.check(len(raw_feature(a, 0, h)) == feature_dim(2, 3) and feature_dim(2, 3) == 24, "layout: 5 per foot + 2 + 4 per horizon = 24")
    # f32: positions up to ~8 m round to ~1e-6, and the velocity columns divide by 2 / 30 s, so 1e-4 is the bound
    s.check(worst < 1e-4, "a turned and moved walk has the same features (max diff " + String(worst) + ")")

    # rows find themselves; the scale is the root mean square
    var tracks = List[MotionTrack]()
    tracks.append(_walk(1.0, 60))
    tracks.append(_walk(3.0, 60))
    var mm = MotionMatchDB(tracks^, h.copy())
    var self_hits = 0
    for r in range(mm.rows()):
        if mm.nearest(mm.probe_row(r)) == r:
            self_hits += 1
    s.check(self_hits == mm.rows(), "every row's probe finds itself (" + String(self_hits) + " / " + String(mm.rows()) + ")")
    var col = 0  # left foot u: nonzero
    var sq = Real(0)
    for r in range(mm.rows()):
        var x = mm.raw_row(r)[col]
        sq += x * x
    s.almost(Float64(mm.scale[col]), Float64(sqrt(sq / Real(mm.rows()))), "scale is the root mean square", 1e-6)
    var zero_col = 11  # the hip's lateral velocity: 0 on a straight walk
    s.check(mm.scale[zero_col] == Real(1), "a column that is 0 everywhere keeps scale 1 (" + String(mm.scale[zero_col]) + ")")

    # the matcher: switch to the fast walk at its speed, on the query tick only
    var t2 = List[MotionTrack]()
    t2.append(_walk(1.0, 60))
    t2.append(_walk(3.0, 60))
    var m = MotionMatcher(MotionMatchDB(t2^, h.copy()), 2, query_ticks=10)
    m.place(0, 0, 5)
    m.place(1, 0, 5)
    var vel = List[Vec2]()
    vel.append(Vec2(0, 3))  # agent 0 moves at the fast speed
    vel.append(Vec2(0, 1))  # agent 1 at the slow one
    var first_switch = -1
    var sw_from_clip = -1
    for tick in range(1, 31):
        var sws = m.step(Real(1) / Real(30), vel)
        for e in sws:
            if e.agent == 0 and first_switch < 0:
                first_switch = tick
                sw_from_clip = e.from_clip
    s.check(m.clip[0] == 1, "agent 0 at 3 m/s ends on the fast walk (clip " + String(m.clip[0]) + ")")
    s.check(first_switch == 10 and sw_from_clip == 0, "it switches on its query tick 10, from clip 0 (tick " + String(first_switch) + ")")
    s.check(m.clip[1] == 0, "agent 1 at 1 m/s stays on the slow walk")
    s.almost(Float64(m.heading[0]), 0.0, "heading along +z is 0", 1e-6)

    var t3 = List[MotionTrack]()
    t3.append(_walk(1.0, 60))
    t3.append(_walk(3.0, 60))
    var never = MotionMatcher(MotionMatchDB(t3^, h.copy()), 1, query_ticks=1, keep_ratio=0)
    for _ in range(30):
        _ = never.step(Real(1) / Real(30), _vels(1, Vec2(0, 3)))
    s.check(never.switches == 0 and never.clip[0] == 0, "keep_ratio 0 never switches")

    # stagger: with query_ticks 4, agent a first queries on tick 4 - a
    var t4 = List[MotionTrack]()
    t4.append(_walk(1.0, 60))
    t4.append(_walk(3.0, 60))
    var st = MotionMatcher(MotionMatchDB(t4^, h.copy()), 4, query_ticks=4)
    var first = List[Int](length=4, fill=-1)
    for tick in range(1, 9):
        var sws = st.step(Real(1) / Real(30), _vels(4, Vec2(0, 3)))
        for e in sws:
            if first[e.agent] < 0:
                first[e.agent] = tick
    s.check(first[0] == 4 and first[1] == 3 and first[2] == 2 and first[3] == 1,
            "staggered queries: first switch ticks " + String(first[0]) + " " + String(first[1]) + " " + String(first[2]) + " " + String(first[3]))

    # heading: follows the velocity, kept when standing
    _ = st.step(Real(1) / Real(30), _vels(4, Vec2(2, 0)))
    s.almost(Float64(st.heading[0]), Float64(atan2(Real(1), Real(0))), "moving along +x: heading pi/2", 1e-6)
    _ = st.step(Real(1) / Real(30), _vels(4, Vec2(0.05, 0)))
    s.almost(Float64(st.heading[0]), Float64(atan2(Real(1), Real(0))), "below min_speed the heading is kept", 1e-6)

    # bad input
    var raised = 0
    try:
        _ = MotionMatchDB(List[MotionTrack](), h.copy())
    except:
        raised += 1
    try:
        var e1 = List[MotionTrack]()
        e1.append(MotionTrack(30, 2))
        _ = MotionMatchDB(e1^, h.copy())
    except:
        raised += 1
    try:
        var e2 = List[MotionTrack]()
        e2.append(_walk(1.0, 10))
        var one = MotionTrack(30, 1)
        var ft = List[Vec3]()
        ft.append(Vec3(0, 0, 0, 0))
        one.add_frame(Vec3(0, 1, 0, 0), 0, 1, ft)
        e2.append(one^)
        _ = MotionMatchDB(e2^, h.copy())
    except:
        raised += 1
    try:
        var e3 = List[MotionTrack]()
        e3.append(_walk(1.0, 10))
        var mq = MotionMatcher(MotionMatchDB(e3^, h.copy()), 3)
        _ = mq.step(Real(1) / Real(30), _vels(1, Vec2(0, 1)))
    except:
        raised += 1
    s.check(raised == 4, "no tracks, an empty track, mixed feet counts, too few velocities all raise (" + String(raised) + " / 4)")
    s.finish()
