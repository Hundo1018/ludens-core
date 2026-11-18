"""Physics capture: record what a scene did, read it back without
simulating, and check a recording against a re-simulation (ROADMAP 17.80).

`Capture.record(scene)` is called after each step. A frame holds, for every
recorded body slot, position, orientation, linear and angular velocity,
sleep flag and island label, and for every contact pair the normal, points,
depths and accumulated normal impulses. Every `key_every`-th frame also
stores a full `scene_to_bytes` snapshot (keyframe). An optional region
(`set_region`) records only bodies whose centre is inside it, and the
contacts touching them -- a 1e5-body world does not need every body.

`Capture.to_bytes()` is the file image; the engine does no file I/O, the
host writes it. `CaptureReader` parses it, returns any frame by index
(`frame(k)`, no simulation), and `verify` restores the keyframe at or
before frame k, steps forward with the caller's `dt` / gravity / config and
returns the first frame whose recorded bodies differ bit for bit (or -1):
a recording can be checked, not just trusted.

Layout (all integers 8 bytes little-endian, floats f32 bit patterns, as
`physics.serialize.BinWriter`): magic, version, key_every, frame count,
then per frame its byte length and bytes, then keyframe count and per
keyframe its frame index, byte length and bytes.

Version 2 (default, `Capture(delta=True)`) stores a frame as a delta: the
body records whose bytes changed since the previous frame and the body
slots no longer recorded; for contacts, while the (a, b, feat) sequence
is the previous frame's, the changed records by position, else the whole
list. Keyframe frames are full and
reset the base, so `frame(k)` decodes from the last keyframe at or before
k forward. A resting or sleeping body costs nothing after its first frame.
`delta=False` writes version 1 (every frame full); both read back the same.
"""

from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase
from physics.solver_config import SolverConfig
from physics.serialize import BinWriter, BinReader, scene_to_bytes, scene_from_bytes
from physics.contact6 import island_color
from diag.draw import DrawQueue
from geometry.vec import WorldType

comptime CAPTURE_MAGIC = 0x5041434C  # "LCAP" little-endian
comptime CAPTURE_VERSION = 2
comptime _BODY_BYTES = 76  # slot, pos, quat, vel, omega, sleep, island


struct CaptureFrame(Movable):
    """One recorded step. Body arrays are parallel (index k = body slot
    `slot[k]`); contact arrays are parallel per pair, with `npts[p]` points
    for pair p stored consecutively in `point` / `depth` / `impulse`."""

    var step_index: Int
    var slot: List[Int]
    var pos: List[Vec3]
    var rot: List[Real]  # x, y, z, w per body
    var vel: List[Vec3]
    var omega: List[Vec3]
    var sleeping: List[Bool]
    var island: List[Int]
    var ca: List[Int]
    var cb: List[Int]
    var feat: List[Int]  # version 2 only (0 when read from version 1)
    var normal: List[Vec3]
    var npts: List[Int]
    var point: List[Vec3]
    var depth: List[Real]
    var impulse: List[Real]

    def __init__(out self):
        self.step_index = 0
        self.slot = List[Int]()
        self.pos = List[Vec3]()
        self.rot = List[Real]()
        self.vel = List[Vec3]()
        self.omega = List[Vec3]()
        self.sleeping = List[Bool]()
        self.island = List[Int]()
        self.ca = List[Int]()
        self.cb = List[Int]()
        self.feat = List[Int]()
        self.normal = List[Vec3]()
        self.npts = List[Int]()
        self.point = List[Vec3]()
        self.depth = List[Real]()
        self.impulse = List[Real]()

    def body_index(self, slot: Int) -> Int:
        """Position of body `slot` in this frame's arrays, or -1."""
        for k in range(len(self.slot)):
            if self.slot[k] == slot:
                return k
        return -1


struct Capture(Movable):
    var key_every: Int
    var frames: List[List[UInt8]]
    var key_frame: List[Int]
    var keys: List[List[UInt8]]
    var has_region: Bool
    var region: AABB[3]
    var delta: Bool
    var _prev_body: List[List[UInt8]]  # by slot; empty = not recorded
    var _prev_con: List[List[UInt8]]  # in cache order
    var _prev_key: List[Int]  # a, b, feat per contact

    def __init__(out self, key_every: Int = 60, delta: Bool = True) raises:
        if key_every < 1:
            raise Error("Capture: key_every must be >= 1")
        self.key_every = key_every
        self.delta = delta
        self._prev_body = List[List[UInt8]]()
        self._prev_con = List[List[UInt8]]()
        self._prev_key = List[Int]()
        self.frames = List[List[UInt8]]()
        self.key_frame = List[Int]()
        self.keys = List[List[UInt8]]()
        self.has_region = False
        self.region = AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))

    def set_region(mut self, box: AABB[3]):
        """Record only bodies whose centre is inside `box` (and contacts
        touching them). Keyframes still hold the whole scene."""
        self.has_region = True
        self.region = box

    def _inside(self, p: Vec3) -> Bool:
        return not self.has_region or self.region.contains_point(p)

    def record[BP: BroadPhase](mut self, sc: ContactScene6[QuatBody6, BP]):
        """Append the scene's current state as the next frame."""
        if self.delta:
            self._record_delta(sc)
            return
        var w = BinWriter()
        w.wi(sc.step_index)
        var n = len(sc.bset.bodies)
        var keep = List[Bool](capacity=n)
        var count = 0
        for i in range(n):
            var k = not sc.bset.is_removed(i) and self._inside(sc.bset.bodies[i].pos)
            keep.append(k)
            if k:
                count += 1
        w.wi(count)
        for i in range(n):
            if not keep[i]:
                continue
            ref b = sc.bset.bodies[i]
            w.wi(i)
            w.wv(b.pos)
            w.wf(b.q.x)
            w.wf(b.q.y)
            w.wf(b.q.z)
            w.wf(b.q.w)
            w.wv(b.vel)
            w.wv(b.omega)
            w.wi(1 if sc.bset.sleeping[i] else 0)
            w.wi(sc.bset.island[i])
        var nc = 0
        for c in range(len(sc.cache)):
            if keep[sc.cache[c].a] or keep[sc.cache[c].b]:
                nc += 1
        w.wi(nc)
        for c in range(len(sc.cache)):
            ref pr = sc.cache[c]
            if not (keep[pr.a] or keep[pr.b]):
                continue
            w.wi(pr.a)
            w.wi(pr.b)
            w.wv(pr.m.normal)
            w.wi(pr.m.count)
            for k in range(pr.m.count):
                w.wv(pr.m.points[k])
                w.wf(pr.m.depths[k])
                w.wf(pr.acc[k])
        if len(self.frames) % self.key_every == 0:
            self.key_frame.append(len(self.frames))
            self.keys.append(scene_to_bytes(sc))
        self.frames.append(w.b.copy())

    def _record_delta[BP: BroadPhase](mut self, sc: ContactScene6[QuatBody6, BP]):
        var full = len(self.frames) % self.key_every == 0
        var n = len(sc.bset.bodies)
        var w = BinWriter()
        w.wi(sc.step_index)
        w.wi(1 if full else 0)
        var keep = List[Bool](capacity=n)
        for i in range(n):
            keep.append(not sc.bset.is_removed(i) and self._inside(sc.bset.bodies[i].pos))
        while len(self._prev_body) < n:
            self._prev_body.append(List[UInt8]())
        # bodies: changed records, then slots no longer recorded
        var changed = BinWriter()
        var nch = 0
        var gone = List[Int]()
        var r = BinWriter()  # scratch, reused per body
        for i in range(len(self._prev_body)):
            if i >= n or not keep[i]:
                if len(self._prev_body[i]) > 0:
                    if not full:
                        gone.append(i)
                    self._prev_body[i] = List[UInt8]()
                continue
            ref b = sc.bset.bodies[i]
            r.b.clear()
            r.wi(i)
            r.wv(b.pos)
            r.wf(b.q.x)
            r.wf(b.q.y)
            r.wf(b.q.z)
            r.wf(b.q.w)
            r.wv(b.vel)
            r.wv(b.omega)
            r.wi(1 if sc.bset.sleeping[i] else 0)
            r.wi(sc.bset.island[i])
            if full or self._prev_body[i] != r.b:
                for x in r.b:
                    changed.b.append(x)
                nch += 1
                self._prev_body[i] = r.b.copy()
        w.wi(nch)
        for x in changed.b:
            w.b.append(x)
        w.wi(len(gone))
        for i in gone:
            w.wi(i)
        # contacts: positional diff while the (a, b, feat) order holds,
        # else the whole list
        var keys = List[Int]()
        var recs = List[List[UInt8]]()
        for c in range(len(sc.cache)):
            ref pr = sc.cache[c]
            if not (keep[pr.a] or keep[pr.b]):
                continue
            keys.append(pr.a)
            keys.append(pr.b)
            keys.append(pr.feat)
            var r = BinWriter()
            r.wi(pr.a)
            r.wi(pr.b)
            r.wi(pr.feat)
            r.wv(pr.m.normal)
            r.wi(pr.m.count)
            for k in range(pr.m.count):
                r.wv(pr.m.points[k])
                r.wf(pr.m.depths[k])
                r.wf(pr.acc[k])
            recs.append(r.b.copy())
        var whole = full or keys != self._prev_key
        w.wi(1 if whole else 0)
        if whole:
            w.wi(len(recs))
            for ref rec in recs:
                for x in rec:
                    w.b.append(x)
        else:
            var cw = BinWriter()
            var ncc = 0
            for c in range(len(recs)):
                if recs[c] != self._prev_con[c]:
                    cw.wi(c)
                    for x in recs[c]:
                        cw.b.append(x)
                    ncc += 1
            w.wi(ncc)
            for x in cw.b:
                w.b.append(x)
        if full:
            self.key_frame.append(len(self.frames))
            self.keys.append(scene_to_bytes(sc))
        self.frames.append(w.b.copy())
        self._prev_con = recs^
        self._prev_key = keys^

    def frame_count(self) -> Int:
        return len(self.frames)

    def byte_size(self) -> Int:
        var t = 0
        for f in self.frames:
            t += len(f)
        for k in self.keys:
            t += len(k)
        return t

    def to_bytes(self) -> List[UInt8]:
        var w = BinWriter()
        w.wi(CAPTURE_MAGIC)
        w.wi(CAPTURE_VERSION if self.delta else 1)
        w.wi(self.key_every)
        w.wi(len(self.frames))
        for f in self.frames:
            w.wi(len(f))
            for x in f:
                w.b.append(x)
        w.wi(len(self.keys))
        for k in range(len(self.keys)):
            w.wi(self.key_frame[k])
            w.wi(len(self.keys[k]))
            for x in self.keys[k]:
                w.b.append(x)
        return w.b.copy()


def _rd(d: List[UInt8], at: Int) raises -> Int:
    if at + 8 > len(d):
        raise Error("CaptureReader: truncated capture")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(d[at + k]) << UInt64(8 * k)
    return Int(u)


struct CaptureReader(Movable):
    var version: Int
    var key_every: Int
    var frames: List[List[UInt8]]
    var key_frame: List[Int]
    var keys: List[List[UInt8]]

    def __init__(out self, data: List[UInt8]) raises:
        if _rd(data, 0) != CAPTURE_MAGIC:
            raise Error("CaptureReader: not a capture (bad magic)")
        self.version = _rd(data, 8)
        if self.version != 1 and self.version != CAPTURE_VERSION:
            raise Error("CaptureReader: unsupported capture version")
        self.key_every = _rd(data, 16)
        var nf = _rd(data, 24)
        var at = 32
        if nf < 0:
            raise Error("CaptureReader: corrupt frame count")
        self.frames = List[List[UInt8]](capacity=nf)
        for _ in range(nf):
            var ln = _rd(data, at)
            at += 8
            if ln < 0 or at + ln > len(data):
                raise Error("CaptureReader: truncated frame")
            var f = List[UInt8](capacity=ln)
            for q in range(at, at + ln):
                f.append(data[q])
            self.frames.append(f^)
            at += ln
        var nk = _rd(data, at)
        at += 8
        if nk < 0:
            raise Error("CaptureReader: corrupt keyframe count")
        self.key_frame = List[Int]()
        self.keys = List[List[UInt8]]()
        for _ in range(nk):
            self.key_frame.append(_rd(data, at))
            var ln = _rd(data, at + 8)
            at += 16
            if ln < 0 or at + ln > len(data):
                raise Error("CaptureReader: truncated keyframe")
            var kb = List[UInt8](capacity=ln)
            for q in range(at, at + ln):
                kb.append(data[q])
            self.keys.append(kb^)
            at += ln

    def frame_count(self) -> Int:
        return len(self.frames)

    def frame(self, k: Int) raises -> CaptureFrame:
        """Frame `k`, decoded -- random access, no simulation."""
        if k < 0 or k >= len(self.frames):
            raise Error("CaptureReader.frame: index out of range")
        if self.version >= 2:
            return self._frame_delta(k)
        var r = BinReader(self.frames[k].copy())
        var f = CaptureFrame()
        f.step_index = r.ri()
        var n = r.ri()
        for _ in range(n):
            f.slot.append(r.ri())
            f.pos.append(r.rv())
            for _ in range(4):
                f.rot.append(r.rf())
            f.vel.append(r.rv())
            f.omega.append(r.rv())
            f.sleeping.append(r.ri() == 1)
            f.island.append(r.ri())
        var nc = r.ri()
        for _ in range(nc):
            f.ca.append(r.ri())
            f.cb.append(r.ri())
            f.feat.append(0)
            f.normal.append(r.rv())
            var m = r.ri()
            f.npts.append(m)
            for _ in range(m):
                f.point.append(r.rv())
                f.depth.append(r.rf())
                f.impulse.append(r.rf())
        return f^

    def _frame_delta(self, k: Int) raises -> CaptureFrame:
        """Apply frames from the last full one at or before k up to k."""
        var base = (k // self.key_every) * self.key_every
        var bodies = List[List[UInt8]]()
        var cons = List[List[UInt8]]()
        var step = 0
        for q in range(base, k + 1):
            var r = BinReader(self.frames[q].copy())
            step = r.ri()
            if r.ri() == 1:
                bodies = List[List[UInt8]]()
            var nb = r.ri()
            for _ in range(nb):
                var at = r.at
                var slot = r.ri()
                r.at = at + _BODY_BYTES
                if r.at > len(r.d) or slot < 0:
                    raise Error("CaptureReader: truncated body record")
                while len(bodies) <= slot:
                    bodies.append(List[UInt8]())
                bodies[slot] = List[UInt8](r.d[at : r.at])
            var ng = r.ri()
            for _ in range(ng):
                var slot = r.ri()
                if slot >= 0 and slot < len(bodies):
                    bodies[slot] = List[UInt8]()
            var whole = r.ri() == 1
            var nc = r.ri()
            if whole:
                cons = List[List[UInt8]](capacity=nc)
            for _ in range(nc):
                var c = -1
                if not whole:
                    c = r.ri()
                var at = r.at
                _ = r.ri()
                _ = r.ri()
                _ = r.ri()
                _ = r.rv()
                var m = r.ri()
                for _ in range(m):
                    _ = r.rv()
                    _ = r.rf()
                    _ = r.rf()
                var rec = List[UInt8](r.d[at : r.at])
                if whole:
                    cons.append(rec^)
                elif c >= 0 and c < len(cons):
                    cons[c] = rec^
                else:
                    raise Error("CaptureReader: contact index out of range")
        var f = CaptureFrame()
        f.step_index = step
        for ref rec in bodies:
            if len(rec) == 0:
                continue
            var r = BinReader(rec.copy())
            f.slot.append(r.ri())
            f.pos.append(r.rv())
            for _ in range(4):
                f.rot.append(r.rf())
            f.vel.append(r.rv())
            f.omega.append(r.rv())
            f.sleeping.append(r.ri() == 1)
            f.island.append(r.ri())
        for ref rec in cons:
            var r = BinReader(rec.copy())
            f.ca.append(r.ri())
            f.cb.append(r.ri())
            f.feat.append(r.ri())
            f.normal.append(r.rv())
            var m = r.ri()
            f.npts.append(m)
            for _ in range(m):
                f.point.append(r.rv())
                f.depth.append(r.rf())
                f.impulse.append(r.rf())
        return f^

    def keyframe_at_or_before(self, k: Int) -> Int:
        """Index into `keys` of the last keyframe at frame <= k, or -1."""
        var best = -1
        for q in range(len(self.key_frame)):
            if self.key_frame[q] <= k:
                best = q
        return best


def _same_bodies[BP: BroadPhase](f: CaptureFrame, sc: ContactScene6[QuatBody6, BP]) -> Bool:
    for k in range(len(f.slot)):
        var i = f.slot[k]
        if i >= len(sc.bset.bodies):
            return False
        ref b = sc.bset.bodies[i]
        if (
            b.pos != f.pos[k] or b.vel != f.vel[k] or b.omega != f.omega[k]
            or b.q.x != f.rot[4 * k] or b.q.y != f.rot[4 * k + 1]
            or b.q.z != f.rot[4 * k + 2] or b.q.w != f.rot[4 * k + 3]
            or sc.bset.sleeping[i] != f.sleeping[k]
        ):
            return False
    return True


def verify(rd: CaptureReader, start: Int, frames: Int, dt: Real, gravity: Vec3, cfg: SolverConfig) raises -> Int:
    """Restore the keyframe at or before frame `start`, step forward with
    `dt` / `gravity` / `cfg` (the recording's own) through frame
    `start + frames - 1`, and return the first frame whose recorded bodies
    differ bit for bit from the simulation, or -1 if all match."""
    var kq = rd.keyframe_at_or_before(start)
    if kq < 0:
        raise Error("capture.verify: no keyframe at or before the start frame")
    var sc = scene_from_bytes(rd.keys[kq].copy())
    var k = rd.key_frame[kq]
    var last = min(start + frames, rd.frame_count())
    while k + 1 < last:
        sc.step(dt, gravity, cfg)
        k += 1
        if k >= start and not _same_bodies(rd.frame(k), sc):
            return k
    return -1


def draw_frame(f: CaptureFrame, mut q: DrawQueue[WorldType], arrow: Real = 0.15, life: Int = 0):
    """Replay a recorded frame as debug-draw commands (ROADMAP 17.80): a
    point per recorded body (grey when asleep, else its island's colour)
    and, as the scene's own debug draw does, an arrow per contact point
    from the point along the normal (`arrow` long) in the pair's island
    colour. The pair's island is its first side's recorded label, or the
    second's when the first is static (-1); for a kinematic first side
    this differs from the live draw, which takes the dynamic side."""
    for k in range(len(f.slot)):
        var c = SIMD[DType.float32, 4](0.5, 0.5, 0.5, 1) if f.sleeping[k] else island_color(f.island[k])
        q.point(f.pos[k], c, life)
    var p = 0
    for c in range(len(f.ca)):
        var ia = f.body_index(f.ca[c])
        var ib = f.body_index(f.cb[c])
        var lbl = -1
        if ia >= 0 and f.island[ia] >= 0:
            lbl = f.island[ia]
        elif ib >= 0:
            lbl = f.island[ib]
        var col = island_color(lbl)
        for _ in range(f.npts[c]):
            q.arrow(f.point[p], f.point[p] + f.normal[c] * arrow, col, life)
            p += 1
