"""Scene serialization: exact save/load of a `ContactScene6[QuatBody6]`.

The format is a flat stream of space-separated INTEGER tokens (version tag
first); every float is stored as its raw f32 bit pattern (`to_bits`), so a
round trip is exact and a loaded scene continues BIT-IDENTICALLY -- which
requires saving everything dynamical, including the cross-frame warm-start
cache (`_CPair` impulse accumulators + manifolds), joint accumulators, and
(audit F20) the contact-event stream's own state (`events_on`/
`_prev_keys`), so events continue identically too, not just rigid/soft
state.

`physics.solver6.write_state`/`read_state` decide WHICH fields make up a
snapshot and in what order (the solver's job, F5): they live next to
`ContactScene6` and walk its fields directly, so a new per-body list cannot
be added to the scene and forgotten here the way this module used to be
able to (it used to re-implement `add` by appending to each of
`ContactScene6`'s lists by hand). This module decides only HOW each field
is encoded, by implementing `physics.state_io.StateWriter`/`StateReader` --
it no longer touches scene lists directly at all.

The on-disk format is fixed at f32 bit patterns deliberately, independent of
`geometry.vec.WorldType`: it is a wire format, not the world's compute dtype,
and changing it would break every saved scene. `_fbits`/`_TextReader.rf`
assert at comptime that `WorldType == DType.float32`, so a future switch to
f64 fails the build here instead of silently truncating precision on
save/load.

Truncated or corrupt input raises (F20): `_TextReader` bounds-checks every
token read instead of indexing past the end, and `read_state` range-checks
every body/joint index it reads.
"""

from geometry.vec import Real, Vec3, WorldType
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6, write_state, read_state
from collision.broadphase import BroadPhase
from collision.bp_bvh import BVHBroadPhase
from physics.state_io import StateWriter, StateReader

comptime _VERSION = 6
"""6 since ROADMAP 17.19 (5): each cached contact pair carries its held report
load (`hold_jn` per point, `hold_jf`, `hold_span`, `hold_excess`,
`hold_excess_up`), so a loaded sleeping pair keeps reporting its resting load.
5 since ROADMAP 17.45 / 17.53: after the 17.50 contact-model block, the
kinematic meshes (body index, body-frame vertices, pose last placed at),
each mesh / heightfield's surface data (heightfield active-edge angle,
per-triangle material ids) and the material friction table -- without them
a restored kinematic platform mesh stopped following its body and a
heightfield lost its active-edge angle. Each joint also carries its
`ratio` (17.47 gear / pulley) after its accumulated impulses, and each
joint ext its D6 axis modes, ranges and row impulses after `acc_cone`.
4 since ROADMAP 17.48: after the island labels, per body the 17.29
gravity override, the 17.31 frozen motion type, the 17.48 parameters
(damping, gravity scale, locks, speed caps, accumulated force / torque,
sleep thresholds), each triangle mesh's 17.45 active-edge flags, the 17.29
joint break thresholds, the 17.2 angular drives and the 17.49 contact-report
flags and event peaks and the 17.47 joint exts, each block behind a
presence flag or count (a scene using none of them adds nine tokens).
3 since ROADMAP 17.85 / 17.16: the stream ends with the tier phase clock
(`step_index`), the tier table, the per-body tier plan and the island
labels. 2 since ROADMAP
17.0g-2: each body's fixed-size fields grew by
five tokens (`motion`, `friction`, `friction_combine`, `restitution_combine`,
`can_sleep` -- `physics.solver6.write_state`'s docstring), so a v1 snapshot
would silently misalign every read past that point rather than fail
cleanly. The version check below turns that into an explicit, early
rejection instead."""


def _fbits(f: Real) -> Int:
    comptime assert WorldType == DType.float32, (
        "physics/serialize.mojo's on-disk format is fixed at f32 bit"
        " patterns; a WorldType switch needs an explicit format migration,"
        " not a silent bit-width change"
    )
    return Int(Float32(f).to_bits())


struct _TextWriter(StateWriter, Movable, Deinitable):
    """Concrete `StateWriter`: accumulates the space-separated token stream
    `write_state` describes into `s`."""

    var s: String

    def __init__(out self):
        self.s = String()

    def wi(mut self, i: Int):
        self.s += String(i) + " "

    def wf(mut self, f: Real):
        self.s += String(_fbits(f)) + " "

    def wv(mut self, v: Vec3):
        self.wf(v[0])
        self.wf(v[1])
        self.wf(v[2])


struct _TextReader(StateReader, Movable, Deinitable):
    """Concrete `StateReader`: a bounds-checked cursor over the token
    stream. Every read raises instead of indexing past the end when the
    input is truncated (F20 -- the previous `_Reader.i` didn't)."""

    var toks: List[String]
    var at: Int

    def __init__(out self, data: String):
        self.toks = List[String]()
        for t in data.split(" "):
            if t.byte_length() > 0:
                self.toks.append(String(t))
        self.at = 0

    def ri(mut self) raises -> Int:
        if self.at >= len(self.toks):
            raise Error(
                "physics.serialize: truncated snapshot (expected another"
                " token at position " + String(self.at) + ")"
            )
        var v = atol(self.toks[self.at])
        self.at += 1
        return v

    def rf(mut self) raises -> Real:
        comptime assert WorldType == DType.float32, (
            "physics/serialize.mojo's on-disk format is fixed at f32 bit"
            " patterns; a WorldType switch needs an explicit format"
            " migration, not a silent bit-width change"
        )
        var u = UInt32(self.ri())
        return Real(Pointer(to=u).unsafe_bitcast[Float32]()[])

    def rv(mut self) raises -> Vec3:
        var x = self.rf()
        var y = self.rf()
        var z = self.rf()
        return Vec3(x, y, z, 0)


def scene_to_string[BP: BroadPhase](sc: ContactScene6[QuatBody6, BP]) raises -> String:
    var w = _TextWriter()
    w.wi(_VERSION)
    write_state(sc, w)
    return w.s.copy()


def scene_from_string[BP: BroadPhase = BVHBroadPhase[3]](data: String) raises -> ContactScene6[QuatBody6, BP]:
    var r = _TextReader(data)
    if r.ri() != _VERSION:
        raise Error("scene format version mismatch")
    var sc = ContactScene6[QuatBody6, BP]()
    read_state(sc, r)
    return sc^


struct BinWriter(StateWriter, Movable, Deinitable):
    """Fixed-width binary `StateWriter` (ROADMAP 17.16): ints as 8 bytes,
    floats as their 4-byte f32 bit pattern, little-endian. Fixed widths keep
    every field at the same offset from one snapshot to the next while the
    scene's shape is unchanged, which is what makes an XOR delta against the
    previous snapshot mostly zeros (`gameplay.netcode.delta_encode`)."""

    var b: List[UInt8]

    def __init__(out self):
        self.b = List[UInt8]()

    def wi(mut self, i: Int):
        var u = UInt64(i)
        for k in range(8):
            self.b.append(UInt8((u >> UInt64(8 * k)) & 0xFF))

    def wf(mut self, f: Real):
        var u = UInt32(_fbits(f))
        for k in range(4):
            self.b.append(UInt8((u >> UInt32(8 * k)) & 0xFF))

    def wv(mut self, v: Vec3):
        self.wf(v[0])
        self.wf(v[1])
        self.wf(v[2])


struct BinReader(StateReader, Movable, Deinitable):
    var d: List[UInt8]
    var at: Int

    def __init__(out self, var data: List[UInt8]):
        self.d = data^
        self.at = 0

    def ri(mut self) raises -> Int:
        if self.at + 8 > len(self.d):
            raise Error("physics.serialize: truncated binary snapshot")
        var u = UInt64(0)
        for k in range(8):
            u |= UInt64(self.d[self.at + k]) << UInt64(8 * k)
        self.at += 8
        return Int(u)

    def rf(mut self) raises -> Real:
        if self.at + 4 > len(self.d):
            raise Error("physics.serialize: truncated binary snapshot")
        var u = UInt32(0)
        for k in range(4):
            u |= UInt32(self.d[self.at + k]) << UInt32(8 * k)
        self.at += 4
        return Real(Pointer(to=u).unsafe_bitcast[Float32]()[])

    def rv(mut self) raises -> Vec3:
        var x = self.rf()
        var y = self.rf()
        var z = self.rf()
        return Vec3(x, y, z, 0)


def scene_to_bytes[BP: BroadPhase](sc: ContactScene6[QuatBody6, BP]) -> List[UInt8]:
    """Exact binary snapshot (same fields and guarantees as `scene_to_string`)."""
    var w = BinWriter()
    w.wi(_VERSION)
    write_state(sc, w)
    return w.b.copy()


def scene_from_bytes[BP: BroadPhase = BVHBroadPhase[3]](var data: List[UInt8]) raises -> ContactScene6[QuatBody6, BP]:
    var r = BinReader(data^)
    if r.ri() != _VERSION:
        raise Error("scene format version mismatch")
    var sc = ContactScene6[QuatBody6, BP]()
    read_state(sc, r)
    return sc^
