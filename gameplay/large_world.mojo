"""Large worlds: origin rebasing and world partition (ROADMAP 17.8).

The simulation stays f32 and near the origin; the world's true coordinates
are `origin + local`, with `origin` held in f64 (a `WorldPos`, `Rebaser.origin`). Two pieces:

- `Rebaser[S: CoordStrategy]` decides when to move the origin and applies
  the move to the scene (`ContactScene6.shift_origin`). Strategies (the 17.8
  seam): `AbsoluteF32` never moves it (the engine before 17.8);
  `RebasedF32(threshold, grid)` moves it to the observer, snapped to a
  power-of-two grid so the subtraction is exact for coordinates on that
  grid, once the observer is `threshold` metres out. The third
  configuration, an f64 world scalar, is a build (`pixi run build-f64`),
  not a runtime choice -- `bench_large_world` compares all three.
  Every shift is logged with its tick; `save` / `load` carry origin and
  log, so a reloaded world continues where the saved one would have.

- `WorldPartition` streams bodies by cell. The host registers bodies in
  world (f64) coordinates; a cell's bodies exist in the scene only while an
  observer is within `load_radius` of the cell, and are captured back into
  world-coordinate specs (pose and velocity, so a reload continues the
  motion) when every observer is beyond `unload_radius` (hysteresis: an
  observer pacing along a cell border does not thrash). A dynamic body that
  crosses into another cell changes owner at the next `update`. Load and
  unload events are logged with their tick, in a deterministic order (cells
  by key, bodies by spec order).
"""

from std.math import floor, sqrt, isfinite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import Inertia3, Pose6, QuatBody6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_bytes, scene_from_bytes


@fieldwise_init
struct WorldPos(Copyable, ImplicitlyCopyable, Movable):
    """A world position in f64 (the coordinates the host and the partition use)."""

    var x: Float64
    var y: Float64
    var z: Float64

    def to_local(self, origin: WorldPos) -> Vec3:
        return Vec3(Real(self.x - origin.x), Real(self.y - origin.y), Real(self.z - origin.z), 0)

    @staticmethod
    def from_local(p: Vec3, origin: WorldPos) -> WorldPos:
        return WorldPos(origin.x + Float64(p[0]), origin.y + Float64(p[1]), origin.z + Float64(p[2]))


trait CoordStrategy(Movable, Deinitable):
    def shift_for(self, observer_local: Vec3) -> Vec3:
        """The origin move (local coordinates) to apply now; zero = none."""
        ...


struct AbsoluteF32(CoordStrategy):
    """Never rebase: world coordinates are the f32 scene coordinates."""

    def __init__(out self):
        pass

    def shift_for(self, observer_local: Vec3) -> Vec3:
        return Vec3(0, 0, 0, 0)


struct RebasedF32(CoordStrategy):
    """Rebase when the observer is more than `threshold` m from the origin,
    by the observer position rounded to multiples of `grid` (a power of two,
    so origin and shift stay exactly representable)."""

    var threshold: Real
    var grid: Real

    def __init__(out self, threshold: Real = 1024, grid: Real = 64) raises:
        if not (threshold > 0) or not (grid > 0):
            raise Error("RebasedF32: threshold and grid must be > 0")
        var g = grid
        while g > 1:
            g /= 2
        while g < 1:
            g *= 2
        if g != 1:
            raise Error("RebasedF32: grid must be a power of two")
        self.threshold = threshold
        self.grid = grid

    def shift_for(self, observer_local: Vec3) -> Vec3:
        var o = observer_local
        if abs(o[0]) <= self.threshold and abs(o[1]) <= self.threshold and abs(o[2]) <= self.threshold:
            return Vec3(0, 0, 0, 0)
        return Vec3(
            floor(o[0] / self.grid + 0.5) * self.grid,
            floor(o[1] / self.grid + 0.5) * self.grid,
            floor(o[2] / self.grid + 0.5) * self.grid,
            0,
        )


@fieldwise_init
struct RebaseEvent(Copyable, ImplicitlyCopyable, Movable):
    var tick: Int
    var d: Vec3


struct Rebaser[S: CoordStrategy](Movable):
    var strategy: Self.S
    var origin: WorldPos
    var log: List[RebaseEvent]

    def __init__(out self, var strategy: Self.S, origin: WorldPos = WorldPos(0, 0, 0)):
        self.strategy = strategy^
        self.origin = origin
        self.log = List[RebaseEvent]()

    def update(mut self, mut scene: ContactScene6[QuatBody6], observer_local: Vec3, tick: Int) raises -> Vec3:
        """Apply the strategy's shift (if any) before this tick's step;
        returns the shift so callers holding local coordinates can follow."""
        var d = self.strategy.shift_for(observer_local)
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            self.shift(scene, d, tick)
        return d

    def shift(mut self, mut scene: ContactScene6[QuatBody6], d: Vec3, tick: Int) raises:
        scene.shift_origin(d)
        self.origin = WorldPos(self.origin.x + Float64(d[0]), self.origin.y + Float64(d[1]), self.origin.z + Float64(d[2]))
        self.log.append(RebaseEvent(tick, d))

    def world(self, p_local: Vec3) -> WorldPos:
        return WorldPos.from_local(p_local, self.origin)

    def local(self, p: WorldPos) -> Vec3:
        return p.to_local(self.origin)



# ----------------------------------------------------------------- partition

comptime SPEC_BOX = 0
comptime SPEC_SPHERE = 1

comptime EV_LOAD = 0
comptime EV_UNLOAD = 1


@fieldwise_init
struct BodySpec(Copyable, ImplicitlyCopyable, Movable):
    """A body while its cell is not loaded: shape, mass, world pose, velocity."""

    var kind: Int
    var half: Vec3  # box half extents; sphere radius in [0]
    var mass: Real
    var is_static: Bool
    var pos: WorldPos
    var rot: Quat
    var vel: Vec3
    var omega: Vec3


@fieldwise_init
struct CellEvent(Copyable, ImplicitlyCopyable, Movable):
    var tick: Int
    var cell: Int  # key
    var kind: Int  # EV_LOAD / EV_UNLOAD
    var bodies: Int


def _cell_key(ix: Int, iz: Int) -> Int:
    return ((ix + (1 << 30)) << 31) | (iz + (1 << 30))


def _key_ix(k: Int) -> Int:
    return (k >> 31) - (1 << 30)


def _key_iz(k: Int) -> Int:
    return (k & ((1 << 31) - 1)) - (1 << 30)


struct WorldPartition(Movable):
    var cell_size: Float64
    var load_radius: Float64
    var unload_radius: Float64
    var specs: List[BodySpec]  # every body ever registered, stable index
    var live: List[Bool]  # spec is in the scene
    var body_of: List[BodyId]  # scene id while live
    var owner: List[Int]  # cell key that owns the spec
    var loaded: List[Int]  # loaded cell keys, sorted
    var events: List[CellEvent]

    def __init__(out self, cell_size: Float64, load_radius: Float64, unload_radius: Float64) raises:
        if not (cell_size > 0) or not (load_radius > 0) or not (unload_radius >= load_radius):
            raise Error("WorldPartition: cell_size > 0, load_radius > 0, unload_radius >= load_radius")
        self.cell_size = cell_size
        self.load_radius = load_radius
        self.unload_radius = unload_radius
        self.specs = List[BodySpec]()
        self.live = List[Bool]()
        self.body_of = List[BodyId]()
        self.owner = List[Int]()
        self.loaded = List[Int]()
        self.events = List[CellEvent]()

    def cell_of(self, p: WorldPos) -> Int:
        return _cell_key(Int(floor(p.x / self.cell_size)), Int(floor(p.z / self.cell_size)))

    def _cell_dist(self, key: Int, p: WorldPos) -> Float64:
        """Distance in xz from `p` to the cell's square (0 inside)."""
        var x0 = Float64(_key_ix(key)) * self.cell_size
        var z0 = Float64(_key_iz(key)) * self.cell_size
        var dx = max(x0 - p.x, 0.0, p.x - (x0 + self.cell_size))
        var dz = max(z0 - p.z, 0.0, p.z - (z0 + self.cell_size))
        return sqrt(dx * dx + dz * dz)

    def is_loaded(self, key: Int) -> Bool:
        for k in self.loaded:
            if k == key:
                return True
        return False

    def add(mut self, var spec: BodySpec) raises -> Int:
        """Register a body (in world coordinates); returns its spec index. It
        enters the scene at the next `update` that finds its cell loaded."""
        if not (isfinite(spec.pos.x) and isfinite(spec.pos.y) and isfinite(spec.pos.z)):
            raise Error("WorldPartition.add: position must be finite")
        if spec.kind != SPEC_BOX and spec.kind != SPEC_SPHERE:
            raise Error("WorldPartition.add: kind must be SPEC_BOX or SPEC_SPHERE")
        if not spec.is_static and not (spec.mass > 0):
            raise Error("WorldPartition.add: dynamic body needs mass > 0")
        self.owner.append(self.cell_of(spec.pos))
        self.specs.append(spec^)
        self.live.append(False)
        self.body_of.append(BodyId(0, 0))
        return len(self.specs) - 1

    def body(self, spec: Int) -> Optional[BodyId]:
        if self.live[spec]:
            return self.body_of[spec]
        return None

    def _spawn(mut self, mut scene: ContactScene6[QuatBody6], i: Int, origin: WorldPos):
        ref s = self.specs[i]
        var p = s.pos.to_local(origin)
        var b: QuatBody6
        if s.kind == SPEC_BOX:
            b = QuatBody6.at_rest(p, Inertia3.box(s.mass if not s.is_static else 1, s.half[0], s.half[1], s.half[2]))
        else:
            b = QuatBody6.at_rest(p, Inertia3.sphere(s.mass if not s.is_static else 1, s.half[0]))
        b.set_pose(Pose6(p, s.rot))
        b.set_velocity(s.vel, s.omega)
        var id = scene.add(b^, s.half, s.is_static) if s.kind == SPEC_BOX else scene.add_sphere(b^, s.half[0], s.is_static)
        self.body_of[i] = id
        self.live[i] = True

    def _capture(mut self, mut scene: ContactScene6[QuatBody6], i: Int, origin: WorldPos) raises:
        var id = self.body_of[i]
        if scene.bset.is_valid(id):
            ref b = scene.bset.bodies[id.index()]
            self.specs[i].pos = WorldPos.from_local(b.position(), origin)
            self.specs[i].rot = b.rotation()
            self.specs[i].vel = b.linear_velocity()
            self.specs[i].omega = b.omega_world()
            scene.remove_body(id)
        self.live[i] = False

    def update(mut self, mut scene: ContactScene6[QuatBody6], origin: WorldPos, observers: List[WorldPos], tick: Int) raises:
        """Re-own moved bodies, unload cells every observer has left, load
        cells an observer has come near. Call between steps."""
        # 1. ownership follows live dynamic bodies across cell borders
        for i in range(len(self.specs)):
            if self.live[i] and not self.specs[i].is_static and scene.bset.is_valid(self.body_of[i]):
                var wp = WorldPos.from_local(scene.bset.bodies[self.body_of[i].index()].position(), origin)
                self.owner[i] = self.cell_of(wp)
        # 2. wanted cells: the observers' neighbourhoods within load_radius
        var want = List[Int]()
        var reach = Int(self.load_radius / self.cell_size) + 1
        for o in observers:
            var cx = Int(floor(o.x / self.cell_size))
            var cz = Int(floor(o.z / self.cell_size))
            for ix in range(cx - reach, cx + reach + 1):
                for iz in range(cz - reach, cz + reach + 1):
                    var k = _cell_key(ix, iz)
                    if self._cell_dist(k, o) <= self.load_radius:
                        _insert_sorted(want, k)
        # 3. unload loaded cells farther than unload_radius from every observer
        var keep = List[Int]()
        for k in self.loaded:
            var near = False
            for o in observers:
                if self._cell_dist(k, o) <= self.unload_radius:
                    near = True
            if near:
                keep.append(k)
                continue
            var n = 0
            for i in range(len(self.specs)):
                if self.live[i] and self.owner[i] == k:
                    self._capture(scene, i, origin)
                    n += 1
            self.events.append(CellEvent(tick, k, EV_UNLOAD, n))
        self.loaded = keep^
        # 4. load wanted cells not yet loaded
        for k in want:
            if not self.is_loaded(k):
                _insert_sorted(self.loaded, k)
                var n = 0
                for i in range(len(self.specs)):
                    if not self.live[i] and self.owner[i] == k:
                        self._spawn(scene, i, origin)
                        n += 1
                self.events.append(CellEvent(tick, k, EV_LOAD, n))
        # 5. a body that crossed into a loaded cell stays; one that moved into
        # an unloaded cell is captured with it (its owner is not loaded)
        for i in range(len(self.specs)):
            if self.live[i] and not self.is_loaded(self.owner[i]):
                self._capture(scene, i, origin)


def _insert_sorted(mut l: List[Int], k: Int):
    var i = 0
    while i < len(l) and l[i] < k:
        i += 1
    if i < len(l) and l[i] == k:
        return
    l.insert(i, k)


# ---------------------------------------------------------- save / restore

def _put64(mut out: List[UInt8], v: UInt64):
    for k in range(8):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _get64(data: List[UInt8], mut pos: Int) raises -> UInt64:
    if pos + 8 > len(data):
        raise Error("large world blob truncated")
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return v


def _putf(mut out: List[UInt8], f: Float64):
    _put64(out, UInt64(f.to_bits()))


def _getf(data: List[UInt8], mut pos: Int) raises -> Float64:
    var u = _get64(data, pos)
    return Pointer(to=u).unsafe_bitcast[Float64]()[]


comptime _MAGIC = UInt64(0x31444C524F574C4C)  # "LLWORLD1"


def save_large_world[S: CoordStrategy](scene: ContactScene6[QuatBody6], rb: Rebaser[S]) -> List[UInt8]:
    """Origin, rebase log and the exact scene snapshot (17.16's
    `scene_to_bytes`): enough to continue bit-for-bit."""
    var out = List[UInt8]()
    _put64(out, _MAGIC)
    _putf(out, rb.origin.x)
    _putf(out, rb.origin.y)
    _putf(out, rb.origin.z)
    _put64(out, UInt64(len(rb.log)))
    for e in rb.log:
        _put64(out, UInt64(e.tick))
        for c in range(3):
            _putf(out, Float64(e.d[c]))
    var body = scene_to_bytes(scene)
    _put64(out, UInt64(len(body)))
    out.extend(body^)
    return out^


def load_large_world[S: CoordStrategy](data: List[UInt8], mut rb: Rebaser[S]) raises -> ContactScene6[QuatBody6]:
    var pos = 0
    if _get64(data, pos) != _MAGIC:
        raise Error("load_large_world: not a large-world blob")
    var x = _getf(data, pos)
    var y = _getf(data, pos)
    var z = _getf(data, pos)
    var n = Int(_get64(data, pos))
    var log = List[RebaseEvent]()
    for _ in range(n):
        var t = Int(_get64(data, pos))
        var dx = _getf(data, pos)
        var dy = _getf(data, pos)
        var dz = _getf(data, pos)
        log.append(RebaseEvent(t, Vec3(Real(dx), Real(dy), Real(dz), 0)))
    var m = Int(_get64(data, pos))
    if pos + m != len(data):
        raise Error("load_large_world: length mismatch")
    var body = List[UInt8](capacity=m)
    for i in range(m):
        body.append(data[pos + i])
    rb.origin = WorldPos(x, y, z)
    rb.log = log^
    return scene_from_bytes(body^)
