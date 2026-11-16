"""Example 27 — motion matching on a slow and a fast walk (ROADMAP 17.92).

Two synthetic walks (1 m/s and 3 m/s, the feet swinging faster on the fast one) become a MotionMatchDB; three agents run
a MotionMatcher for 4 s. Agent 0 walks at 1 m/s throughout, agent 1 at 3 m/s, agent 2 speeds up from 1 to 3 m/s at
t = 2 s. Printed: every switch (tick, agent, from clip and frame, to clip and frame), then each agent's clip at the end.

Run:

    pixi run mojo run -I build examples/27_motion_matching.mojo
"""

from std.math import sin
from geometry.vec import Real, Vec2, Vec3
from procedural.motion_match import MotionTrack, MotionMatchDB, MotionMatcher


def walk(speed: Real, frames: Int) -> MotionTrack:
    var t = MotionTrack(30, 2)
    var w = Real(4) + Real(2) * speed
    for f in range(frames):
        var time = Real(f) / Real(30)
        var z = speed * time
        var sw = Real(0.3) * sin(w * time)
        var lift = Real(0.1) * abs(sin(w * time))
        var feet = List[Vec3]()
        feet.append(Vec3(0.1, lift, z + sw, 0))
        feet.append(Vec3(-0.1, Real(0.1) - lift, z - sw, 0))
        t.add_frame(Vec3(0, 1, z, 0), 0, 1, feet)
    return t^


def main() raises:
    var tracks = List[MotionTrack]()
    tracks.append(walk(1.0, 60))
    tracks.append(walk(3.0, 60))
    var h = List[Real]()
    h.append(Real(0.33))
    h.append(Real(0.67))
    h.append(Real(1.0))
    var m = MotionMatcher(MotionMatchDB(tracks^, h^), 3)
    for a in range(3):
        m.place(a, 0, Real(7 * a))
    var dt = Real(1) / Real(30)
    for tick in range(1, 121):
        var vel = List[Vec2]()
        vel.append(Vec2(0, 1))
        vel.append(Vec2(0, 3))
        vel.append(Vec2(0, 3) if tick > 60 else Vec2(0, 1))
        for e in m.step(dt, vel):
            print("tick", tick, "agent", e.agent, "clip", e.from_clip, "frame", Int(e.from_frame), "-> clip", e.to_clip, "frame", e.to_frame)
    print("after 4 s: agent clips", m.clip[0], m.clip[1], m.clip[2], "(0 slow walk, 1 fast walk);", m.switches, "switches")
