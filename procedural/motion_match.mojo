"""Motion matching on a character's clips: trajectory features, the per-column scale and a per-agent controller
(ROADMAP 17.92).

`anim_graph.MotionDB` stores feature rows and finds the nearest one. This module builds those rows from what a character
does, and drives agents with them:

  `MotionTrack`     per frame of one clip: the hip's position, the character's facing on the ground (a unit (x, z)) and
                    the positions of the feet, all in model space. The caller fills it from its own skeleton (which
                    joints are the feet and how the facing is read is the character's business).
  `raw_feature`     one frame's feature, in that frame's facing frame (u along the facing, v to its left), so a match
                    does not depend on where the character stands or which way it faces. Layout, for F feet and H
                    horizons (dim = 5 F + 2 + 4 H):
                      per foot: position relative to the hip (u, y, v) and velocity (u, v)
                      the hip's velocity (u, v)
                      per horizon s: the hip's position at +s relative to now (u, v) and its facing then (u, v)
                    Velocities are central differences over the neighbouring frames; frames past either end of a clip
                    are clamped to that end (no wrap: a clip's root travel is not periodic), and no feature reads across
                    a clip boundary.
  `MotionMatchDB`   the frames of every track as one MotionDB. Each column is divided by its root mean square over all
                    rows (no mean removed); a column that is 0 everywhere keeps scale 1. Probes are divided the same way.
  `MotionMatcher`   per agent: a clip, a fractional frame played at the clip's rate (looping) and a heading. Every
                    `query_ticks` ticks (staggered: agent a queries when (ticks + a) % query_ticks == 0) it probes with
                    its current frame's feet and, in place of the hip velocity and the trajectory, moving straight ahead
                    at its own speed for the horizons. The nearest row is taken when its squared distance is below
                    `keep_ratio` of the current row's and it is another clip or more than `switch_frames` frames away;
                    `step` returns those switches, so a caller can blend across them (`inertialize.Inertializer`).
"""

from std.math import sqrt, atan2
from geometry.vec import Real, Vec2, Vec3
from .anim_graph import MotionDB


struct MotionTrack(Copyable, Movable):
    """One clip's frames. Stored flat: a frame's hip at 3 f, its facing at 2 f, its feet at 3 (feet f + k)."""

    var frames: Int
    var fps: Int
    var feet_count: Int
    var hip: List[Real]
    var facing: List[Real]
    var feet: List[Real]
    var min_ground: Real  # the shortest facing passed to add_frame, before normalising (a collapsing facing shows here)

    def __init__(out self, fps: Int, feet_count: Int):
        self.frames = 0
        self.fps = fps
        self.feet_count = feet_count
        self.hip = List[Real]()
        self.facing = List[Real]()
        self.feet = List[Real]()
        self.min_ground = Real(1e30)

    def add_frame(mut self, hip: Vec3, facing_x: Real, facing_z: Real, feet: List[Vec3]):
        """Append a frame. The facing is normalised here; one shorter than 1e-6 becomes +z."""
        self.hip.append(hip[0])
        self.hip.append(hip[1])
        self.hip.append(hip[2])
        var fx = facing_x
        var fz = facing_z
        var n = sqrt(fx * fx + fz * fz)
        if n < self.min_ground:
            self.min_ground = n
        if n < Real(1e-6):
            fx = Real(0)
            fz = Real(1)
            n = Real(1)
        self.facing.append(fx / n)
        self.facing.append(fz / n)
        for k in range(self.feet_count):
            self.feet.append(feet[k][0])
            self.feet.append(feet[k][1])
            self.feet.append(feet[k][2])
        self.frames += 1

    def facing_yaw(self, f: Int) -> Real:
        """The facing of frame f as a turn about +Y (0 faces +z)."""
        return atan2(self.facing[2 * f], self.facing[2 * f + 1])


def feature_dim(feet_count: Int, horizons: Int) -> Int:
    return 5 * feet_count + 2 + 4 * horizons


def _clamp(i: Int, frames: Int) -> Int:
    if i < 0:
        return 0
    if i > frames - 1:
        return frames - 1
    return i


def _to_facing(t: MotionTrack, f: Int, dx: Real, dz: Real) -> Tuple[Real, Real]:
    """A ground vector in frame f's facing frame: u along the facing, v to its left."""
    var fx = t.facing[2 * f]
    var fz = t.facing[2 * f + 1]
    return (dx * fx + dz * fz, dx * (-fz) + dz * fx)


def raw_feature(t: MotionTrack, f: Int, horizons: List[Real]) -> List[Real]:
    """Frame f's feature, unscaled (layout in the module comment)."""
    var out = List[Real]()
    var fps = Real(t.fps)
    var hx = t.hip[3 * f]
    var hz = t.hip[3 * f + 2]
    for k in range(t.feet_count):
        var base = 3 * (t.feet_count * f + k)
        var rel = _to_facing(t, f, t.feet[base] - hx, t.feet[base + 2] - hz)
        out.append(rel[0])
        out.append(t.feet[base + 1] - t.hip[3 * f + 1])
        out.append(rel[1])
        var a = _clamp(f - 1, t.frames)
        var b = _clamp(f + 1, t.frames)
        var dt = Real(b - a) / fps
        if b == a:
            dt = Real(1)
        var va = 3 * (t.feet_count * a + k)
        var vb = 3 * (t.feet_count * b + k)
        var vel = _to_facing(t, f, (t.feet[vb] - t.feet[va]) / dt, (t.feet[vb + 2] - t.feet[va + 2]) / dt)
        out.append(vel[0])
        out.append(vel[1])
    var a = _clamp(f - 1, t.frames)
    var b = _clamp(f + 1, t.frames)
    var dt = Real(b - a) / fps
    if b == a:
        dt = Real(1)
    var hv = _to_facing(
        t, f,
        (t.hip[3 * b] - t.hip[3 * a]) / dt,
        (t.hip[3 * b + 2] - t.hip[3 * a + 2]) / dt,
    )
    out.append(hv[0])
    out.append(hv[1])
    for s in horizons:
        var i = _clamp(f + Int(s * fps + Real(0.5)), t.frames)
        var pos = _to_facing(t, f, t.hip[3 * i] - hx, t.hip[3 * i + 2] - hz)
        var dir = _to_facing(t, f, t.facing[2 * i], t.facing[2 * i + 1])
        out.append(pos[0])
        out.append(pos[1])
        out.append(dir[0])
        out.append(dir[1])
    return out^


struct MotionMatchDB(Movable):
    """Every track's frames as one MotionDB: rows are the frames of track 0, then track 1, and so on."""

    var db: MotionDB
    var scale: List[Real]
    var tracks: List[MotionTrack]
    var horizons: List[Real]
    var frame_of: List[Int]
    var offset: List[Int]  # per track: its first row
    var dim: Int

    def __init__(out self, var tracks: List[MotionTrack], var horizons: List[Real]) raises:
        """Build the rows and the per-column scale. All tracks need the same number of feet and at least one frame."""
        if len(tracks) == 0:
            raise Error("MotionMatchDB: no tracks")
        var feet = tracks[0].feet_count
        self.dim = feature_dim(feet, len(horizons))
        var raws = List[List[Real]]()
        self.frame_of = List[Int]()
        self.offset = List[Int]()
        var clip_of = List[Int]()
        var sumsq = List[Real](length=self.dim, fill=Real(0))
        for i in range(len(tracks)):
            if tracks[i].feet_count != feet:
                raise Error("MotionMatchDB: track " + String(i) + " has " + String(tracks[i].feet_count) + " feet, track 0 " + String(feet))
            if tracks[i].frames == 0:
                raise Error("MotionMatchDB: track " + String(i) + " has no frames")
            self.offset.append(len(raws))
            for f in range(tracks[i].frames):
                var r = raw_feature(tracks[i], f, horizons)
                for d in range(self.dim):
                    sumsq[d] += r[d] * r[d]
                raws.append(r^)
                self.frame_of.append(f)
                clip_of.append(i)
        var total = len(raws)
        self.scale = List[Real]()
        for d in range(self.dim):
            var sd = sqrt(sumsq[d] / Real(total))
            if sd < Real(1e-9):
                sd = Real(1)
            self.scale.append(sd)
        self.db = MotionDB()
        self.db.dim = self.dim
        for row in range(total):
            for d in range(self.dim):
                self.db.feats.append(raws[row][d] / self.scale[d])
            self.db.clip_of.append(clip_of[row])
            self.db.time_of.append(Real(self.frame_of[row]) / Real(tracks[clip_of[row]].fps))
        self.tracks = tracks^
        self.horizons = horizons^

    def rows(self) -> Int:
        return len(self.frame_of)

    def raw_row(self, row: Int) -> List[Real]:
        """The unscaled feature of row `row`."""
        return raw_feature(self.tracks[self.db.clip_of[row]], self.frame_of[row], self.horizons)

    def scaled(self, raw: List[Real]) -> List[Real]:
        var out = List[Real]()
        for d in range(self.dim):
            out.append(raw[d] / self.scale[d])
        return out^

    def probe_row(self, row: Int) -> List[Real]:
        """The scaled feature of row `row`: what a query from that frame sends to `nearest`."""
        return self.scaled(self.raw_row(row))

    def nearest(self, probe: List[Real]) raises -> Int:
        """The nearest row to a scaled probe."""
        if len(probe) != self.dim:
            raise Error("MotionMatchDB: probe has " + String(len(probe)) + " values, the rows " + String(self.dim))
        return self.db.query(probe)

    def distance(self, probe: List[Real], row: Int) -> Real:
        """Squared distance from a scaled probe to row `row`."""
        var d = Real(0)
        for k in range(self.dim):
            var e = self.db.feats[row * self.dim + k] - probe[k]
            d += e * e
        return d


@fieldwise_init
struct MotionSwitch(Copyable, ImplicitlyCopyable, Movable):
    """One switch `MotionMatcher.step` made: agent, the clip and frame it left (after this tick's advance), and the
    clip and frame it took."""

    var agent: Int
    var from_clip: Int
    var from_frame: Real
    var to_clip: Int
    var to_frame: Int


struct MotionMatcher(Movable):
    var mm: MotionMatchDB
    var query_ticks: Int
    var switch_frames: Int
    var keep_ratio: Real
    var min_speed: Real  # below this an agent keeps its last heading
    var clip: List[Int]
    var frame: List[Real]
    var heading: List[Real]  # radians about +Y, 0 faces +z
    var switches: Int
    var ticks: Int

    def __init__(
        out self, var mm: MotionMatchDB, agents: Int, query_ticks: Int = 10, switch_frames: Int = 3,
        keep_ratio: Real = 0.8, min_speed: Real = 0.2,
    ) raises:
        if query_ticks < 1:
            raise Error("MotionMatcher: query_ticks must be at least 1")
        self.mm = mm^
        self.query_ticks = query_ticks
        self.switch_frames = switch_frames
        self.keep_ratio = keep_ratio
        self.min_speed = min_speed
        self.clip = List[Int](length=agents, fill=0)
        self.frame = List[Real](length=agents, fill=Real(0))
        self.heading = List[Real](length=agents, fill=Real(0))
        self.switches = 0
        self.ticks = 0

    def agents(self) -> Int:
        return len(self.clip)

    def place(mut self, a: Int, clip: Int, frame: Real):
        """Put agent a on a clip and frame (no switch is counted)."""
        self.clip[a] = clip
        self.frame[a] = frame

    def current_row(self, a: Int) -> Int:
        return self.mm.offset[self.clip[a]] + Int(self.frame[a])

    def probe(self, a: Int, speed: Real) -> List[Real]:
        """Agent a's scaled query: its current frame's feet, then moving straight ahead at `speed` over the horizons."""
        var raw = self.mm.raw_row(self.current_row(a))
        var hv = 5 * self.mm.tracks[0].feet_count
        raw[hv] = speed
        raw[hv + 1] = Real(0)
        for h in range(len(self.mm.horizons)):
            raw[hv + 2 + 4 * h] = speed * self.mm.horizons[h]
            raw[hv + 3 + 4 * h] = Real(0)
            raw[hv + 4 + 4 * h] = Real(1)
            raw[hv + 5 + 4 * h] = Real(0)
        return self.mm.scaled(raw)

    def match(self, a: Int, speed: Real) raises -> Int:
        """The nearest row for agent a moving at `speed`."""
        return self.mm.nearest(self.probe(a, speed))

    def step(mut self, dt: Real, vel: List[Vec2]) raises -> List[MotionSwitch]:
        """Advance every agent by dt (looping its clip), update its heading from its velocity (x, z), and query on its
        tick. Returns the switches made."""
        if len(vel) < len(self.clip):
            raise Error("MotionMatcher.step: " + String(len(vel)) + " velocities for " + String(len(self.clip)) + " agents")
        var out = List[MotionSwitch]()
        self.ticks += 1
        for a in range(len(self.clip)):
            var f = self.frame[a] + dt * Real(self.mm.tracks[self.clip[a]].fps)
            var n = Real(self.mm.tracks[self.clip[a]].frames)
            while f >= n:
                f -= n
            self.frame[a] = f
            var vx = vel[a][0]
            var vz = vel[a][1]
            var speed = sqrt(vx * vx + vz * vz)
            if speed > self.min_speed:
                self.heading[a] = atan2(vx, vz)
            if (self.ticks + a) % self.query_ticks == 0:
                var probe = self.probe(a, speed)
                var row = self.mm.nearest(probe)
                var nc = self.mm.db.clip_of[row]
                var nf = self.mm.frame_of[row]
                var better = self.mm.distance(probe, row) < self.keep_ratio * self.mm.distance(probe, self.current_row(a))
                if better and (nc != self.clip[a] or abs(Real(nf) - self.frame[a]) > Real(self.switch_frames)):
                    out.append(MotionSwitch(a, self.clip[a], self.frame[a], nc, nf))
                    self.clip[a] = nc
                    self.frame[a] = Real(nf)
                    self.switches += 1
        return out^

    def frame_index(self, a: Int) -> Int:
        return Int(self.frame[a])

    def yaw(self, a: Int) -> Real:
        """The turn about +Y that points agent a's clip frame's facing along its heading."""
        return self.heading[a] - self.mm.tracks[self.clip[a]].facing_yaw(Int(self.frame[a]))
