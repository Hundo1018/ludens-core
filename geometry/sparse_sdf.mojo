"""Sparse signed distance grid: only the narrow band around the surface is stored (ROADMAP 17.52 follow-up).

`SdfGrid` keeps `res`^3 nodes, so a 256^3 grid is 64 MiB of `Real`s of which almost all are far from the surface and
never decide a contact. `SparseSdfGrid` cuts the lattice into 8x8x8-node bricks and keeps a brick only if some node
of it, or of the one-node ring around it, is within `band` of the surface. A brick that is not kept reads as
`sign * band` for every node, with one sign per brick (inside or outside): far from the surface the field is the
constant `sign * band` and its gradient is zero, so the sign is right everywhere and the magnitude is only
meaningful inside the band. Stored bricks keep their true node values, also the ones beyond the band.

Where it is exact: a point whose eight surrounding nodes are all stored gets the same value and gradient as the dense
grid, bit for bit (same trilinear formula over the same node values). That holds for every point whose true
distance is within `band - 2 cell` of the surface, so keep `band` at a few cells more than the skin the contact code
looks at. Beyond that the value is `sign * band` in unstored bricks and the gradient may be zero, which the contact code
treats as "no contact".

Built from a dense grid (`from_dense`) or straight from a field (`from_field`), which never allocates the dense
lattice: it evaluates the field at a brick's centre and skips the brick when the field, assumed 1-Lipschitz as a true
distance field is, is further than the brick's half diagonal plus the ring plus `band` from the surface. `to_dense`
expands back (band nodes exact, the rest `sign * band`). Memory follows the stored bricks, `bytes()` reports it.

Not done: serialization into the physics snapshot (a `SHAPE_SDF` collider still takes a dense `SdfGrid`; use
`to_dense`), and a brick table for grids that are mostly stored."""

from std.math import floor, sqrt
from .vec import Real, Vec3
from .distance_field import DistanceField3
from .sdf_grid import SdfGrid

comptime BRICK = 8
comptime _BRICK3 = 512


struct SparseSdfGrid(Movable, DistanceField3):
    var res: Int  # nodes per axis
    var origin: Vec3
    var cell: Real
    var band: Real
    var nb: Int  # bricks per axis
    var slot: List[Int]  # per brick: index of its data block, -1 = not stored
    var sign: List[Int]  # per brick: -1 inside, +1 outside (used when not stored)
    var data: List[Real]  # stored bricks, 512 nodes each, x fastest

    def __init__(out self, res: Int, origin: Vec3, cell: Real, band: Real):
        self.res = res
        self.origin = origin
        self.cell = cell
        self.band = band
        self.nb = (res + BRICK - 1) // BRICK
        self.slot = List[Int]()
        self.sign = List[Int]()
        self.data = List[Real]()
        for _ in range(self.nb * self.nb * self.nb):
            self.slot.append(-1)
            self.sign.append(1)

    # ----------------------------------------------------------- building

    @staticmethod
    def from_dense(g: SdfGrid, band: Real) -> Self:
        """Keep the bricks of `g` that have a node within `band` of the surface, the one-node ring included."""
        var s = Self(g.res, g.origin, g.cell, band)
        var res = g.res
        for bz in range(s.nb):
            for by in range(s.nb):
                for bx in range(s.nb):
                    var b = (bz * s.nb + by) * s.nb + bx
                    var near = False
                    var i0 = max(bx * BRICK - 1, 0)
                    var j0 = max(by * BRICK - 1, 0)
                    var k0 = max(bz * BRICK - 1, 0)
                    var i1 = min(bx * BRICK + BRICK + 1, res)
                    var j1 = min(by * BRICK + BRICK + 1, res)
                    var k1 = min(bz * BRICK + BRICK + 1, res)
                    for k in range(k0, k1):
                        for j in range(j0, j1):
                            for i in range(i0, i1):
                                var v = g.at(i, j, k)
                                if v <= band and v >= -band:
                                    near = True
                    var first = g.at(bx * BRICK, by * BRICK, bz * BRICK)
                    s.sign[b] = -1 if first < 0 else 1
                    if near:
                        s.slot[b] = len(s.data) // _BRICK3
                        for k in range(BRICK):
                            for j in range(BRICK):
                                for i in range(BRICK):
                                    s.data.append(g.at(min(bx * BRICK + i, res - 1), min(by * BRICK + j, res - 1), min(bz * BRICK + k, res - 1)))
        return s^

    @staticmethod
    def from_field[F: DistanceField3](f: F, res: Int, origin: Vec3, cell: Real, band: Real) -> Self:
        """Sample `f` only in bricks that can reach the band. `f` must be a distance field (1-Lipschitz), as an
        analytic `Sdf3` primitive or a baked grid is; a CSG bound is also fine, it only makes the skip conservative."""
        var s = Self(res, origin, cell, band)
        var half_diag = sqrt(Real(3)) * Real(BRICK + 2) * cell * 0.5
        for bz in range(s.nb):
            for by in range(s.nb):
                for bx in range(s.nb):
                    var b = (bz * s.nb + by) * s.nb + bx
                    var c = origin + Vec3(Real(bx * BRICK) + Real(BRICK - 1) * 0.5, Real(by * BRICK) + Real(BRICK - 1) * 0.5, Real(bz * BRICK) + Real(BRICK - 1) * 0.5, 0) * cell
                    var dc = f.distance(c)
                    s.sign[b] = -1 if dc < 0 else 1
                    var mag = dc if dc >= 0 else -dc
                    if mag - half_diag > band:
                        continue
                    s.slot[b] = len(s.data) // _BRICK3
                    for k in range(BRICK):
                        for j in range(BRICK):
                            for i in range(BRICK):
                                var ii = min(bx * BRICK + i, res - 1)
                                var jj = min(by * BRICK + j, res - 1)
                                var kk = min(bz * BRICK + k, res - 1)
                                s.data.append(f.distance(origin + Vec3(Real(ii), Real(jj), Real(kk), 0) * cell))
        return s^

    # -------------------------------------------------------------- reading

    def stored_bricks(self) -> Int:
        return len(self.data) // _BRICK3

    def bytes(self) -> Int:
        """Memory held by the grid's arrays: node data, brick table and signs."""
        return len(self.data) * 4 + len(self.slot) * 8 + len(self.sign) * 8

    def at(self, i: Int, j: Int, k: Int) -> Real:
        var bx = i // BRICK
        var by = j // BRICK
        var bz = k // BRICK
        var b = (bz * self.nb + by) * self.nb + bx
        var s = self.slot[b]
        if s < 0:
            return self.band * Real(self.sign[b])
        return self.data[s * _BRICK3 + ((k - bz * BRICK) * BRICK + (j - by * BRICK)) * BRICK + (i - bx * BRICK)]

    def node(self, i: Int, j: Int, k: Int) -> Vec3:
        return self.origin + Vec3(Real(i), Real(j), Real(k), 0) * self.cell

    def _cell_of(self, p: Vec3) -> Tuple[Int, Int, Int, Vec3]:
        var q = (p - self.origin) / self.cell
        var hi = Real(self.res - 1)
        var ijk = Array[Int, 3](fill=0)
        var f = Vec3(0, 0, 0, 0)
        for a in range(3):
            var x = min(max(q[a], 0), hi)
            var ix = min(Int(floor(x)), self.res - 2) if self.res > 1 else 0
            ijk[a] = max(ix, 0)
            f[a] = x - Real(ijk[a])
        return (ijk[0], ijk[1], ijk[2], f)

    def distance(self, p: Vec3) -> Real:
        """Trilinear sample (clamped to the grid), the same formula as `SdfGrid.distance`."""
        if self.res == 1:
            return self.at(0, 0, 0)
        var c = self._cell_of(p)
        var i = c[0]
        var j = c[1]
        var k = c[2]
        var f = c[3]
        var c00 = self.at(i, j, k) * (1 - f[0]) + self.at(i + 1, j, k) * f[0]
        var c10 = self.at(i, j + 1, k) * (1 - f[0]) + self.at(i + 1, j + 1, k) * f[0]
        var c01 = self.at(i, j, k + 1) * (1 - f[0]) + self.at(i + 1, j, k + 1) * f[0]
        var c11 = self.at(i, j + 1, k + 1) * (1 - f[0]) + self.at(i + 1, j + 1, k + 1) * f[0]
        var c0 = c00 * (1 - f[1]) + c10 * f[1]
        var c1 = c01 * (1 - f[1]) + c11 * f[1]
        return c0 * (1 - f[2]) + c1 * f[2]

    def gradient(self, p: Vec3) -> Vec3:
        """Analytic gradient of the trilinear cell, the same formula as `SdfGrid.gradient`."""
        if self.res == 1:
            return Vec3(0, 0, 0, 0)
        var c = self._cell_of(p)
        var i = c[0]
        var j = c[1]
        var k = c[2]
        var f = c[3]
        var v = Array[Real, 8](fill=0)
        for n in range(8):
            v[n] = self.at(i + (n & 1), j + ((n >> 1) & 1), k + ((n >> 2) & 1))
        var gx = Real(0)
        var gy = Real(0)
        var gz = Real(0)
        for n in range(8):
            var bx = Real(n & 1)
            var by = Real((n >> 1) & 1)
            var bz = Real((n >> 2) & 1)
            var wx = f[0] if bx == 1 else 1 - f[0]
            var wy = f[1] if by == 1 else 1 - f[1]
            var wz = f[2] if bz == 1 else 1 - f[2]
            var sx = Real(1) if bx == 1 else Real(-1)
            var sy = Real(1) if by == 1 else Real(-1)
            var sz = Real(1) if bz == 1 else Real(-1)
            gx += v[n] * sx * wy * wz
            gy += v[n] * wx * sy * wz
            gz += v[n] * wx * wy * sz
        return Vec3(gx, gy, gz, 0) / self.cell

    def to_dense(self) -> SdfGrid:
        """The dense grid with the stored nodes exact and every node of an unstored brick `sign * band`."""
        var g = SdfGrid(self.res, self.origin, self.cell)
        for k in range(self.res):
            for j in range(self.res):
                for i in range(self.res):
                    g.values[(k * self.res + j) * self.res + i] = self.at(i, j, k)
        return g^
