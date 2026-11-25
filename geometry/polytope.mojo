"""Convex polytopes as closed triangle meshes: the geometry under destruction
(ROADMAP 17.5).

Fracture needs four geometric services, and they are all the same object:

  * a convex hull of a point cloud (the output of every convex-decomposition
    variant, and what `collision.hull.HullShape` is later built from);
  * clipping a convex solid by a plane, giving two new closed solids with a
    cap polygon each (runtime cutting, Voronoi cells = repeated bisector cuts);
  * volume, centroid and a diagonal inertia (a fragment must become a rigid
    body with the mass its shape implies);
  * the area and centre of a labelled patch of the surface (the seam between
    two fragments is where a bond is anchored and how strong it is).

Storage is deliberately flat: `v` is x, y, z per vertex in FLOAT64, `t` is
three vertex indices per triangle (CCW seen from outside), `tag` labels every
triangle (`-1` = original surface, `>= 0` = the id given to the cut that made
the triangle). No `List[Vec3]` is held, passed or returned anywhere here (the
nightly's width-3 list hazard, see `collision/hull.mojo`), and float64 keeps
a thousand successive cuts of one solid from drifting off the planes they cut
along.

WATERTIGHT BY CONSTRUCTION: `split` classifies each vertex against the plane
exactly once and creates the point where an edge crosses it exactly once --
keyed by the (sorted) vertex pair, so the two triangles sharing the edge read
the SAME new vertex index. Nothing is recomputed per triangle, so a crack
between the pieces cannot appear from two roundings of one point. (The
classification itself is an epsilon band, not the exact predicate of
`geometry/predicates.mojo`: vertices within `eps` of the plane count as ON
it. TODO (10.1): route the sign test through `orient3d` for plane-through-3-points
cuts.)
"""

from std.math import sqrt, atan2
from std.collections import Dict


@fieldwise_init
struct Polytope(Copyable, Movable):
    """A closed triangle mesh, normally convex. See the module docstring."""

    var v: List[Float64]  # vertices, stride 3
    var t: List[Int]  # triangles, stride 3, CCW from outside
    var tag: List[Int]  # one label per triangle

    @staticmethod
    def empty() -> Self:
        return Self(List[Float64](), List[Int](), List[Int]())

    @staticmethod
    def box(
        cx: Float64, cy: Float64, cz: Float64, hx: Float64, hy: Float64, hz: Float64
    ) -> Self:
        """Axis-aligned box centred at (cx, cy, cz) with half extents h."""
        var v = List[Float64](capacity=24)
        for k in range(8):
            v.append(cx + (hx if (k & 4) != 0 else -hx))
            v.append(cy + (hy if (k & 2) != 0 else -hy))
            v.append(cz + (hz if (k & 1) != 0 else -hz))
        # vertex index = 4*sx + 2*sy + sz, each s in {0 (min), 1 (max)}
        var t = List[Int](capacity=36)
        # x- (0,1,3,2), x+ (4,6,7,5), y- (0,4,5,1), y+ (2,3,7,6),
        # z- (0,2,6,4), z+ (1,5,7,3), each quad CCW from outside
        var quads = List[Int](capacity=24)
        for q in [0, 1, 3, 2, 4, 6, 7, 5, 0, 4, 5, 1, 2, 3, 7, 6, 0, 2, 6, 4, 1, 5, 7, 3]:
            quads.append(q)
        var tg = List[Int](capacity=12)
        for f in range(6):
            var a = quads[4 * f]
            var b = quads[4 * f + 1]
            var c = quads[4 * f + 2]
            var d = quads[4 * f + 3]
            t.append(a)
            t.append(b)
            t.append(c)
            t.append(a)
            t.append(c)
            t.append(d)
            tg.append(-1)
            tg.append(-1)
        return Self(v^, t^, tg^)

    def nv(self) -> Int:
        return len(self.v) // 3

    def nt(self) -> Int:
        return len(self.t) // 3

    def is_empty(self) -> Bool:
        return len(self.t) == 0

    def volume(self) -> Float64:
        """Enclosed volume (divergence theorem, vertex 0 as the origin)."""
        if self.nt() == 0:
            return 0
        var ox = self.v[0]
        var oy = self.v[1]
        var oz = self.v[2]
        var vol = Float64(0)
        for f in range(self.nt()):
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var c = 3 * self.t[3 * f + 2]
            var ax = self.v[a] - ox
            var ay = self.v[a + 1] - oy
            var az = self.v[a + 2] - oz
            var bx = self.v[b] - ox
            var by = self.v[b + 1] - oy
            var bz = self.v[b + 2] - oz
            var cx = self.v[c] - ox
            var cy = self.v[c + 1] - oy
            var cz = self.v[c + 2] - oz
            vol += ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)
        return vol / 6

    def centroid(self) -> List[Float64]:
        """Volume centroid [x, y, z] (vertex mean for a zero-volume mesh)."""
        var out = List[Float64](capacity=3)
        out.append(0)
        out.append(0)
        out.append(0)
        if self.nt() == 0:
            return out^
        var ox = self.v[0]
        var oy = self.v[1]
        var oz = self.v[2]
        var vs = Float64(0)
        var sx = Float64(0)
        var sy = Float64(0)
        var sz = Float64(0)
        for f in range(self.nt()):
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var c = 3 * self.t[3 * f + 2]
            var ax = self.v[a] - ox
            var ay = self.v[a + 1] - oy
            var az = self.v[a + 2] - oz
            var bx = self.v[b] - ox
            var by = self.v[b + 1] - oy
            var bz = self.v[b + 2] - oz
            var cx = self.v[c] - ox
            var cy = self.v[c + 1] - oy
            var cz = self.v[c + 2] - oz
            var dv = ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)
            vs += dv
            sx += dv * (ax + bx + cx)
            sy += dv * (ay + by + cy)
            sz += dv * (az + bz + cz)
        if abs(vs) < 1e-300:
            var n = self.nv()
            var mx = Float64(0)
            var my = Float64(0)
            var mz = Float64(0)
            for i in range(n):
                mx += self.v[3 * i]
                my += self.v[3 * i + 1]
                mz += self.v[3 * i + 2]
            out[0] = mx / Float64(n)
            out[1] = my / Float64(n)
            out[2] = mz / Float64(n)
            return out^
        # each tetrahedron (o, a, b, c) has centroid (a + b + c) / 4 (o = 0)
        out[0] = ox + sx / (4 * vs)
        out[1] = oy + sy / (4 * vs)
        out[2] = oz + sz / (4 * vs)
        return out^

    def inertia_tensor(self) -> List[Float64]:
        """[Ixx, Iyy, Izz, Ixy, Ixz, Iyz] about the volume centroid, per unit
        density, in the mesh's own axes (off-diagonal entries are the
        products of inertia, I_ij = -∫ x_i x_j dV). Exact for any closed
        mesh: each triangle with the centroid as apex is a tetrahedron with
        ∫ x_i x_j = V/20 (Σ_k p_ki p_kj + S_i S_j) over its three corners."""
        var out = List[Float64](capacity=6)
        for _ in range(6):
            out.append(0)
        if self.nt() == 0:
            return out^
        var c = self.centroid()
        var m = List[Float64](capacity=6)
        for _ in range(6):
            m.append(0)  # ∫ x_i x_j dV in order xx, yy, zz, xy, xz, yz
        for f in range(self.nt()):
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var d = 3 * self.t[3 * f + 2]
            var p0 = self.v[a] - c[0]
            var p1 = self.v[a + 1] - c[1]
            var p2 = self.v[a + 2] - c[2]
            var q0 = self.v[b] - c[0]
            var q1 = self.v[b + 1] - c[1]
            var q2 = self.v[b + 2] - c[2]
            var r0 = self.v[d] - c[0]
            var r1 = self.v[d + 1] - c[1]
            var r2 = self.v[d + 2] - c[2]
            var dv = p0 * (q1 * r2 - q2 * r1) - p1 * (q0 * r2 - q2 * r0) + p2 * (q0 * r1 - q1 * r0)
            var tv = dv / 6
            var s0 = p0 + q0 + r0
            var s1 = p1 + q1 + r1
            var s2 = p2 + q2 + r2
            m[0] += tv / 20 * (p0 * p0 + q0 * q0 + r0 * r0 + s0 * s0)
            m[1] += tv / 20 * (p1 * p1 + q1 * q1 + r1 * r1 + s1 * s1)
            m[2] += tv / 20 * (p2 * p2 + q2 * q2 + r2 * r2 + s2 * s2)
            m[3] += tv / 20 * (p0 * p1 + q0 * q1 + r0 * r1 + s0 * s1)
            m[4] += tv / 20 * (p0 * p2 + q0 * q2 + r0 * r2 + s0 * s2)
            m[5] += tv / 20 * (p1 * p2 + q1 * q2 + r1 * r2 + s1 * s2)
        out[0] = m[1] + m[2]
        out[1] = m[0] + m[2]
        out[2] = m[0] + m[1]
        out[3] = -m[3]
        out[4] = -m[4]
        out[5] = -m[5]
        return out^

    def inertia_diag(self) -> List[Float64]:
        """[Ixx, Iyy, Izz] about the volume centroid, per unit density, in the
        mesh's own axes (products of inertia dropped: see `inertia_tensor`
        and `physics/fracture.mojo`, which rotates to the principal frame).
        Exact for an axis-aligned box."""
        var t = self.inertia_tensor()
        var out = List[Float64](capacity=3)
        out.append(t[0])
        out.append(t[1])
        out.append(t[2])
        return out^

    def bounds(self) -> List[Float64]:
        """[minx, miny, minz, maxx, maxy, maxz]."""
        var out = List[Float64](capacity=6)
        for _ in range(3):
            out.append(1e300)
        for _ in range(3):
            out.append(-1e300)
        for i in range(self.nv()):
            for k in range(3):
                var x = self.v[3 * i + k]
                if x < out[k]:
                    out[k] = x
                if x > out[3 + k]:
                    out[3 + k] = x
        return out^

    def radius_from(self, x: Float64, y: Float64, z: Float64) -> Float64:
        """Largest distance from (x, y, z) to a vertex."""
        var r2 = Float64(0)
        for i in range(self.nv()):
            var dx = self.v[3 * i] - x
            var dy = self.v[3 * i + 1] - y
            var dz = self.v[3 * i + 2] - z
            r2 = max(r2, dx * dx + dy * dy + dz * dz)
        return sqrt(r2)

    def tag_patch(self, tag: Int) -> List[Float64]:
        """Surface patch labelled `tag`: [area, cx, cy, cz, nx, ny, nz] (area-
        weighted centre and mean unit normal). All zero when no triangle
        carries the label."""
        var out = List[Float64](capacity=7)
        for _ in range(7):
            out.append(0)
        var area = Float64(0)
        var mx = Float64(0)
        var my = Float64(0)
        var mz = Float64(0)
        var nx = Float64(0)
        var ny = Float64(0)
        var nz = Float64(0)
        for f in range(self.nt()):
            if self.tag[f] != tag:
                continue
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var c = 3 * self.t[3 * f + 2]
            var e1x = self.v[b] - self.v[a]
            var e1y = self.v[b + 1] - self.v[a + 1]
            var e1z = self.v[b + 2] - self.v[a + 2]
            var e2x = self.v[c] - self.v[a]
            var e2y = self.v[c + 1] - self.v[a + 1]
            var e2z = self.v[c + 2] - self.v[a + 2]
            var cx = e1y * e2z - e1z * e2y
            var cy = e1z * e2x - e1x * e2z
            var cz = e1x * e2y - e1y * e2x
            var ar = sqrt(cx * cx + cy * cy + cz * cz) / 2
            area += ar
            mx += ar * (self.v[a] + self.v[b] + self.v[c]) / 3
            my += ar * (self.v[a + 1] + self.v[b + 1] + self.v[c + 1]) / 3
            mz += ar * (self.v[a + 2] + self.v[b + 2] + self.v[c + 2]) / 3
            nx += cx / 2
            ny += cy / 2
            nz += cz / 2
        if area <= 0:
            return out^
        var nl = sqrt(nx * nx + ny * ny + nz * nz)
        out[0] = area
        out[1] = mx / area
        out[2] = my / area
        out[3] = mz / area
        if nl > 0:
            out[4] = nx / nl
            out[5] = ny / nl
            out[6] = nz / nl
        return out^

    def plane_patch(
        self, nx: Float64, ny: Float64, nz: Float64, d: Float64, tol: Float64
    ) -> List[Float64]:
        """The part of the surface lying in the plane `n . x = d` (`n` unit):
        [area, cx, cy, cz] over every triangle whose three vertices are within
        `tol` of it -- the footprint a body stands on or is anchored by. Zero
        when it does not touch."""
        var out = List[Float64](capacity=4)
        for _ in range(4):
            out.append(0)
        var area = Float64(0)
        for f in range(self.nt()):
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var c = 3 * self.t[3 * f + 2]
            if (
                abs(nx * self.v[a] + ny * self.v[a + 1] + nz * self.v[a + 2] - d) > tol
                or abs(nx * self.v[b] + ny * self.v[b + 1] + nz * self.v[b + 2] - d) > tol
                or abs(nx * self.v[c] + ny * self.v[c + 1] + nz * self.v[c + 2] - d) > tol
            ):
                continue
            var e1x = self.v[b] - self.v[a]
            var e1y = self.v[b + 1] - self.v[a + 1]
            var e1z = self.v[b + 2] - self.v[a + 2]
            var e2x = self.v[c] - self.v[a]
            var e2y = self.v[c + 1] - self.v[a + 1]
            var e2z = self.v[c + 2] - self.v[a + 2]
            var cx = e1y * e2z - e1z * e2y
            var cy = e1z * e2x - e1x * e2z
            var cz = e1x * e2y - e1y * e2x
            var ar = sqrt(cx * cx + cy * cy + cz * cz) / 2
            area += ar
            out[1] += ar * (self.v[a] + self.v[b] + self.v[c]) / 3
            out[2] += ar * (self.v[a + 1] + self.v[b + 1] + self.v[c + 1]) / 3
            out[3] += ar * (self.v[a + 2] + self.v[b + 2] + self.v[c + 2]) / 3
        if area > 0:
            out[0] = area
            out[1] /= area
            out[2] /= area
            out[3] /= area
        return out^

    def has_tag(self, tag: Int) -> Bool:
        for f in range(self.nt()):
            if self.tag[f] == tag:
                return True
        return False

    def moved(self, dx: Float64, dy: Float64, dz: Float64) -> Self:
        """A translated copy."""
        var c = self.copy()
        for i in range(c.nv()):
            c.v[3 * i] += dx
            c.v[3 * i + 1] += dy
            c.v[3 * i + 2] += dz
        return c^

    def hull_vertices(self, ox: Float64, oy: Float64, oz: Float64, tol: Float64) -> List[Float64]:
        """The distinct vertices, relative to (ox, oy, oz), with those within
        `tol` of an earlier one merged -- the flat list `HullShape` takes."""
        var out = List[Float64](capacity=len(self.v))
        var n = self.nv()
        var t2 = tol * tol
        for i in range(n):
            var x = self.v[3 * i] - ox
            var y = self.v[3 * i + 1] - oy
            var z = self.v[3 * i + 2] - oz
            var dup = False
            for k in range(len(out) // 3):
                var dx = out[3 * k] - x
                var dy = out[3 * k + 1] - y
                var dz = out[3 * k + 2] - z
                if dx * dx + dy * dy + dz * dz <= t2:
                    dup = True
                    break
            if not dup:
                out.append(x)
                out.append(y)
                out.append(z)
        return out^

    def simplified(self, tol: Float64) -> Self:
        """The same solid with only its true corners kept.

        Repeated cutting leaves vertices that are no corner at all -- points
        along an edge where a cap's fan crossed it, points in a face where a
        fan diagonal did -- and they compound: a Voronoi cell cut a dozen times
        can carry thousands. A vertex is a corner iff three DISTINCT face
        planes meet there. Planes are found by clustering triangles on
        (normal, offset); the corners are re-hulled and each new triangle takes
        the label of the plane it lies in."""
        if self.nt() < 5:
            return self.copy()
        var pl = List[Float64]()  # nx, ny, nz, d, tag per unique plane
        var tri_plane = List[Int](capacity=self.nt())
        for f in range(self.nt()):
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var c = 3 * self.t[3 * f + 2]
            var e1x = self.v[b] - self.v[a]
            var e1y = self.v[b + 1] - self.v[a + 1]
            var e1z = self.v[b + 2] - self.v[a + 2]
            var e2x = self.v[c] - self.v[a]
            var e2y = self.v[c + 1] - self.v[a + 1]
            var e2z = self.v[c + 2] - self.v[a + 2]
            var nx = e1y * e2z - e1z * e2y
            var ny = e1z * e2x - e1x * e2z
            var nz = e1x * e2y - e1y * e2x
            var nl = sqrt(nx * nx + ny * ny + nz * nz)
            if nl < 1e-300:
                tri_plane.append(-1)
                continue
            nx /= nl
            ny /= nl
            nz /= nl
            var d = nx * self.v[a] + ny * self.v[a + 1] + nz * self.v[a + 2]
            var found = -1
            for q in range(len(pl) // 5):
                if (
                    nx * pl[5 * q] + ny * pl[5 * q + 1] + nz * pl[5 * q + 2] > 1 - 1e-9
                    and abs(d - pl[5 * q + 3]) <= tol
                ):
                    found = q
                    break
            if found < 0:
                found = len(pl) // 5
                pl.append(nx)
                pl.append(ny)
                pl.append(nz)
                pl.append(d)
                pl.append(Float64(self.tag[f]))
            elif pl[5 * found + 4] < 0 and self.tag[f] >= 0:
                pl[5 * found + 4] = Float64(self.tag[f])
            tri_plane.append(found)
        # a corner lies on three planes whose normals are independent. Found
        # by incidence against the plane list, NOT by walking each vertex's
        # triangles: a fan skips zero-area triangles, which can leave a
        # collinear vertex out of one face's triangles though it is on it.
        var nvert = self.nv()
        var np_ = len(pl) // 5
        var bnd = self.bounds()
        var ext = max(bnd[3] - bnd[0], max(bnd[4] - bnd[1], bnd[5] - bnd[2]))
        var vtol = max(tol, ext * 1e-9)
        var pts = List[Float64]()
        var near = List[Int]()
        for i in range(nvert):
            var x = self.v[3 * i]
            var y = self.v[3 * i + 1]
            var z = self.v[3 * i + 2]
            near.clear()
            for q in range(np_):
                if abs(pl[5 * q] * x + pl[5 * q + 1] * y + pl[5 * q + 2] * z - pl[5 * q + 3]) <= vtol:
                    near.append(q)
            var corner = False
            if len(near) >= 3:
                var n1 = near[0]
                var n2 = -1
                for k in range(1, len(near)):
                    var q = near[k]
                    var cx = pl[5 * n1 + 1] * pl[5 * q + 2] - pl[5 * n1 + 2] * pl[5 * q + 1]
                    var cy = pl[5 * n1 + 2] * pl[5 * q] - pl[5 * n1] * pl[5 * q + 2]
                    var cz = pl[5 * n1] * pl[5 * q + 1] - pl[5 * n1 + 1] * pl[5 * q]
                    if cx * cx + cy * cy + cz * cz > 1e-12:
                        n2 = q
                        break
                if n2 >= 0:
                    var cx = pl[5 * n1 + 1] * pl[5 * n2 + 2] - pl[5 * n1 + 2] * pl[5 * n2 + 1]
                    var cy = pl[5 * n1 + 2] * pl[5 * n2] - pl[5 * n1] * pl[5 * n2 + 2]
                    var cz = pl[5 * n1] * pl[5 * n2 + 1] - pl[5 * n1 + 1] * pl[5 * n2]
                    for k in range(1, len(near)):
                        var q = near[k]
                        if abs(cx * pl[5 * q] + cy * pl[5 * q + 1] + cz * pl[5 * q + 2]) > 1e-6:
                            corner = True
                            break
            if corner:
                pts.append(x)
                pts.append(y)
                pts.append(z)
        var h = convex_hull(pts)
        if h.is_empty():
            return self.copy()
        for f in range(h.nt()):
            var a = 3 * h.t[3 * f]
            var b = 3 * h.t[3 * f + 1]
            var c = 3 * h.t[3 * f + 2]
            var e1x = h.v[b] - h.v[a]
            var e1y = h.v[b + 1] - h.v[a + 1]
            var e1z = h.v[b + 2] - h.v[a + 2]
            var e2x = h.v[c] - h.v[a]
            var e2y = h.v[c + 1] - h.v[a + 1]
            var e2z = h.v[c + 2] - h.v[a + 2]
            var nx = e1y * e2z - e1z * e2y
            var ny = e1z * e2x - e1x * e2z
            var nz = e1x * e2y - e1y * e2x
            var nl = sqrt(nx * nx + ny * ny + nz * nz)
            h.tag[f] = -1
            if nl < 1e-300:
                continue
            nx /= nl
            ny /= nl
            nz /= nl
            var d = nx * h.v[a] + ny * h.v[a + 1] + nz * h.v[a + 2]
            for q in range(len(pl) // 5):
                if (
                    nx * pl[5 * q] + ny * pl[5 * q + 1] + nz * pl[5 * q + 2] > 1 - 1e-7
                    and abs(d - pl[5 * q + 3]) <= 10 * tol
                ):
                    h.tag[f] = Int(pl[5 * q + 4])
                    break
        return h^

    def contains(self, x: Float64, y: Float64, z: Float64, tol: Float64) -> Bool:
        """Point-in-convex-polytope test against every face plane."""
        for f in range(self.nt()):
            var a = 3 * self.t[3 * f]
            var b = 3 * self.t[3 * f + 1]
            var c = 3 * self.t[3 * f + 2]
            var e1x = self.v[b] - self.v[a]
            var e1y = self.v[b + 1] - self.v[a + 1]
            var e1z = self.v[b + 2] - self.v[a + 2]
            var e2x = self.v[c] - self.v[a]
            var e2y = self.v[c + 1] - self.v[a + 1]
            var e2z = self.v[c + 2] - self.v[a + 2]
            var nx = e1y * e2z - e1z * e2y
            var ny = e1z * e2x - e1x * e2z
            var nz = e1x * e2y - e1y * e2x
            var nl = sqrt(nx * nx + ny * ny + nz * nz)
            if nl < 1e-300:
                continue
            var d = ((x - self.v[a]) * nx + (y - self.v[a + 1]) * ny + (z - self.v[a + 2]) * nz) / nl
            if d > tol:
                return False
        return True


@fieldwise_init
struct SplitResult(Movable):
    """The two pieces of `Polytope.split`: `front` is the side where
    `n . p > d`, `back` where `n . p < d`. A piece is empty (`is_empty()`)
    when the plane misses that side entirely."""

    var front: Polytope
    var back: Polytope

    def into_front(deinit self) -> Polytope:
        return self.front^

    def into_back(deinit self) -> Polytope:
        return self.back^

    def into_pair(deinit self) -> List[Polytope]:
        """[front, back] -- both pieces, for a caller that keeps both."""
        var out = List[Polytope]()
        out.append(self.front^)
        out.append(self.back^)
        return out^


def _compact(
    v: List[Float64], t: List[Int], tag: List[Int]
) -> Polytope:
    """Keep only the vertices some triangle uses, renumbered."""
    var remap = List[Int](capacity=len(v) // 3)
    for _ in range(len(v) // 3):
        remap.append(-1)
    var nv = List[Float64](capacity=len(v))
    var nt = List[Int](capacity=len(t))
    for i in range(len(t)):
        var o = t[i]
        if remap[o] < 0:
            remap[o] = len(nv) // 3
            nv.append(v[3 * o])
            nv.append(v[3 * o + 1])
            nv.append(v[3 * o + 2])
        nt.append(remap[o])
    return Polytope(nv^, nt^, tag.copy())


def _basis(nx: Float64, ny: Float64, nz: Float64) -> List[Float64]:
    """Two unit vectors u, w with u x w = n (n unit): [u, w] flat."""
    var ax = Float64(0)
    var ay = Float64(0)
    var az = Float64(0)
    if abs(nx) <= abs(ny) and abs(nx) <= abs(nz):
        ax = 1
    elif abs(ny) <= abs(nz):
        ay = 1
    else:
        az = 1
    var ux = ny * az - nz * ay
    var uy = nz * ax - nx * az
    var uz = nx * ay - ny * ax
    var ul = sqrt(ux * ux + uy * uy + uz * uz)
    ux /= ul
    uy /= ul
    uz /= ul
    var wx = ny * uz - nz * uy
    var wy = nz * ux - nx * uz
    var wz = nx * uy - ny * ux
    var out = List[Float64](capacity=6)
    out.append(ux)
    out.append(uy)
    out.append(uz)
    out.append(wx)
    out.append(wy)
    out.append(wz)
    return out^


def _push_poly(
    poly: List[Int], tag: Int, v: List[Float64], mut t: List[Int], mut tg: List[Int]
):
    """Fan-triangulate a clipped polygon (3+ vertices) onto a side's lists,
    dropping zero-area slivers."""
    for k in range(1, len(poly) - 1):
        var a = 3 * poly[0]
        var b = 3 * poly[k]
        var c = 3 * poly[k + 1]
        var e1x = v[b] - v[a]
        var e1y = v[b + 1] - v[a + 1]
        var e1z = v[b + 2] - v[a + 2]
        var e2x = v[c] - v[a]
        var e2y = v[c + 1] - v[a + 1]
        var e2z = v[c + 2] - v[a + 2]
        var cx = e1y * e2z - e1z * e2y
        var cy = e1z * e2x - e1x * e2z
        var cz = e1x * e2y - e1y * e2x
        if cx * cx + cy * cy + cz * cz < 1e-30:
            continue
        t.append(poly[0])
        t.append(poly[k])
        t.append(poly[k + 1])
        tg.append(tag)


def polytope_split(
    p: Polytope, nx: Float64, ny: Float64, nz: Float64, d: Float64, cap_tag: Int, eps: Float64
) -> SplitResult:
    """Cut the CONVEX polytope `p` by the plane `n . x = d` (`n` unit). Both
    pieces get a cap polygon labelled `cap_tag`. See the module docstring for
    the watertightness argument."""
    var nvert = p.nv()
    var s = List[Float64](capacity=nvert)
    var cls = List[Int](capacity=nvert)
    var any_pos = False
    var any_neg = False
    for i in range(nvert):
        var si = nx * p.v[3 * i] + ny * p.v[3 * i + 1] + nz * p.v[3 * i + 2] - d
        s.append(si)
        if si > eps:
            cls.append(1)
            any_pos = True
        elif si < -eps:
            cls.append(-1)
            any_neg = True
        else:
            cls.append(0)
    if not any_pos:
        return SplitResult(Polytope.empty(), p.copy())
    if not any_neg:
        return SplitResult(p.copy(), Polytope.empty())

    var v = p.v.copy()
    var edge = Dict[Int, Int]()
    var on_plane = Dict[Int, Bool]()
    var plane_pts = List[Int]()
    var ft = List[Int]()
    var ftag = List[Int]()
    var bt = List[Int]()
    var btag = List[Int]()
    for f in range(p.nt()):
        var tri = List[Int](capacity=3)
        tri.append(p.t[3 * f])
        tri.append(p.t[3 * f + 1])
        tri.append(p.t[3 * f + 2])
        if cls[tri[0]] == 0 and cls[tri[1]] == 0 and cls[tri[2]] == 0:
            continue  # lies in the plane: the cap replaces it
        # clip the triangle against each side
        var polys = List[List[Int]]()
        polys.append(List[Int]())  # front
        polys.append(List[Int]())  # back
        for e in range(3):
            var a = tri[e]
            var b = tri[(e + 1) % 3]
            var ca = cls[a]
            var cb = cls[b]
            if ca >= 0:
                polys[0].append(a)
            if ca <= 0:
                polys[1].append(a)
            if ca == 0 and a not in on_plane:
                on_plane[a] = True
                plane_pts.append(a)
            if ca * cb < 0:
                var lo = min(a, b)
                var hi = max(a, b)
                var key = lo * nvert + hi
                var m = edge.get(key, -1)
                if m < 0:
                    var tt = s[lo] / (s[lo] - s[hi])
                    m = len(v) // 3
                    v.append(p.v[3 * lo] + tt * (p.v[3 * hi] - p.v[3 * lo]))
                    v.append(p.v[3 * lo + 1] + tt * (p.v[3 * hi + 1] - p.v[3 * lo + 1]))
                    v.append(p.v[3 * lo + 2] + tt * (p.v[3 * hi + 2] - p.v[3 * lo + 2]))
                    edge[key] = m
                    on_plane[m] = True
                    plane_pts.append(m)
                polys[0].append(m)
                polys[1].append(m)
        if len(polys[0]) >= 3:
            _push_poly(polys[0], p.tag[f], v, ft, ftag)
        if len(polys[1]) >= 3:
            _push_poly(polys[1], p.tag[f], v, bt, btag)

    if len(plane_pts) < 3:
        return SplitResult(p.copy(), Polytope.empty())

    # cap: the plane section of a convex solid is a convex polygon whose
    # vertices are exactly the plane points, so angular order around their
    # mean gives its boundary.
    var bs = _basis(nx, ny, nz)
    var mx = Float64(0)
    var my = Float64(0)
    var mz = Float64(0)
    for k in range(len(plane_pts)):
        mx += v[3 * plane_pts[k]]
        my += v[3 * plane_pts[k] + 1]
        mz += v[3 * plane_pts[k] + 2]
    mx /= Float64(len(plane_pts))
    my /= Float64(len(plane_pts))
    mz /= Float64(len(plane_pts))
    var ang = List[Float64](capacity=len(plane_pts))
    for k in range(len(plane_pts)):
        var q = 3 * plane_pts[k]
        var rx = v[q] - mx
        var ry = v[q + 1] - my
        var rz = v[q + 2] - mz
        ang.append(
            atan2(
                rx * bs[3] + ry * bs[4] + rz * bs[5],
                rx * bs[0] + ry * bs[1] + rz * bs[2],
            )
        )
    # insertion sort of plane_pts by angle
    for i in range(1, len(plane_pts)):
        var pi = plane_pts[i]
        var ai = ang[i]
        var j = i - 1
        while j >= 0 and ang[j] > ai:
            plane_pts[j + 1] = plane_pts[j]
            ang[j + 1] = ang[j]
            j -= 1
        plane_pts[j + 1] = pi
        ang[j + 1] = ai
    # fan: ascending angle -> normal +n (outward for the BACK piece)
    var mp = len(plane_pts)
    for k in range(1, mp - 1):
        var cap = List[Int](capacity=3)
        cap.append(plane_pts[0])
        cap.append(plane_pts[k])
        cap.append(plane_pts[k + 1])
        _push_poly(cap, cap_tag, v, bt, btag)
        var rcap = List[Int](capacity=3)
        rcap.append(plane_pts[0])
        rcap.append(plane_pts[k + 1])
        rcap.append(plane_pts[k])
        _push_poly(rcap, cap_tag, v, ft, ftag)
    return SplitResult(_compact(v, ft, ftag), _compact(v, bt, btag))


# ------------------------------------------------------------------ hull


def _plane_of(
    v: List[Float64], a: Int, b: Int, c: Int
) -> List[Float64]:
    """Unit normal and offset [nx, ny, nz, d] of triangle (a, b, c)."""
    var e1x = v[3 * b] - v[3 * a]
    var e1y = v[3 * b + 1] - v[3 * a + 1]
    var e1z = v[3 * b + 2] - v[3 * a + 2]
    var e2x = v[3 * c] - v[3 * a]
    var e2y = v[3 * c + 1] - v[3 * a + 1]
    var e2z = v[3 * c + 2] - v[3 * a + 2]
    var nx = e1y * e2z - e1z * e2y
    var ny = e1z * e2x - e1x * e2z
    var nz = e1x * e2y - e1y * e2x
    var nl = sqrt(nx * nx + ny * ny + nz * nz)
    var out = List[Float64](capacity=4)
    if nl < 1e-300:
        out.append(0)
        out.append(0)
        out.append(0)
        out.append(0)
        return out^
    nx /= nl
    ny /= nl
    nz /= nl
    out.append(nx)
    out.append(ny)
    out.append(nz)
    out.append(nx * v[3 * a] + ny * v[3 * a + 1] + nz * v[3 * a + 2])
    return out^


def convex_hull(pts: List[Float64]) -> Polytope:
    """Convex hull of a flat (x, y, z per point) cloud by incremental
    insertion. Returns an EMPTY polytope when the cloud is degenerate
    (fewer than 4 points, or all coplanar / collinear / coincident) -- there
    is no volume to return, and the caller decides what a flat fragment is
    worth. Points on or inside the current hull are skipped (a point exactly
    on a face never becomes a vertex)."""
    var n = len(pts) // 3
    if n < 4:
        return Polytope.empty()
    # scale for tolerances
    var lo = List[Float64]()
    var hi = List[Float64]()
    for k in range(3):
        lo.append(pts[k])
        hi.append(pts[k])
    for i in range(n):
        for k in range(3):
            lo[k] = min(lo[k], pts[3 * i + k])
            hi[k] = max(hi[k], pts[3 * i + k])
    var ext = max(hi[0] - lo[0], max(hi[1] - lo[1], hi[2] - lo[2]))
    if ext <= 0:
        return Polytope.empty()
    var eps = ext * 1e-9

    # initial tetrahedron: extreme in x, then farthest from that point, from
    # the line, from the plane
    var i0 = 0
    for i in range(n):
        if pts[3 * i] < pts[3 * i0]:
            i0 = i
    var i1 = i0
    var best = Float64(-1)
    for i in range(n):
        var dx = pts[3 * i] - pts[3 * i0]
        var dy = pts[3 * i + 1] - pts[3 * i0 + 1]
        var dz = pts[3 * i + 2] - pts[3 * i0 + 2]
        var dd = dx * dx + dy * dy + dz * dz
        if dd > best:
            best = dd
            i1 = i
    if best <= eps * eps:
        return Polytope.empty()
    var ex = pts[3 * i1] - pts[3 * i0]
    var ey = pts[3 * i1 + 1] - pts[3 * i0 + 1]
    var ez = pts[3 * i1 + 2] - pts[3 * i0 + 2]
    var i2 = -1
    best = -1
    for i in range(n):
        var dx = pts[3 * i] - pts[3 * i0]
        var dy = pts[3 * i + 1] - pts[3 * i0 + 1]
        var dz = pts[3 * i + 2] - pts[3 * i0 + 2]
        var cx = ey * dz - ez * dy
        var cy = ez * dx - ex * dz
        var cz = ex * dy - ey * dx
        var cc = cx * cx + cy * cy + cz * cz
        if cc > best:
            best = cc
            i2 = i
    if i2 < 0 or sqrt(best) <= eps * sqrt(ex * ex + ey * ey + ez * ez):
        return Polytope.empty()
    var pl = _plane_of(pts, i0, i1, i2)
    var i3 = -1
    best = -1
    for i in range(n):
        var dist = abs(
            pl[0] * pts[3 * i] + pl[1] * pts[3 * i + 1] + pl[2] * pts[3 * i + 2] - pl[3]
        )
        if dist > best:
            best = dist
            i3 = i
    if i3 < 0 or best <= eps:
        return Polytope.empty()

    # faces: triangle (a, b, c) + plane; `alive` flags let faces die in place
    var fa = List[Int]()
    var fb = List[Int]()
    var fc = List[Int]()
    var fp = List[Float64]()  # 4 per face
    var alive = List[Bool]()
    var cenx = (pts[3 * i0] + pts[3 * i1] + pts[3 * i2] + pts[3 * i3]) / 4
    var ceny = (pts[3 * i0 + 1] + pts[3 * i1 + 1] + pts[3 * i2 + 1] + pts[3 * i3 + 1]) / 4
    var cenz = (pts[3 * i0 + 2] + pts[3 * i1 + 2] + pts[3 * i2 + 2] + pts[3 * i3 + 2]) / 4
    var tri_set = List[Int]()
    for q in [i0, i1, i2, i0, i1, i3, i0, i2, i3, i1, i2, i3]:
        tri_set.append(q)
    for k in range(4):
        var a = tri_set[3 * k]
        var b = tri_set[3 * k + 1]
        var c = tri_set[3 * k + 2]
        var q = _plane_of(pts, a, b, c)
        if q[0] * cenx + q[1] * ceny + q[2] * cenz - q[3] > 0:
            var tmp = b
            b = c
            c = tmp
            q = _plane_of(pts, a, b, c)
        fa.append(a)
        fb.append(b)
        fc.append(c)
        for z in range(4):
            fp.append(q[z])
        alive.append(True)

    for i in range(n):
        if i == i0 or i == i1 or i == i2 or i == i3:
            continue
        var px = pts[3 * i]
        var py = pts[3 * i + 1]
        var pz = pts[3 * i + 2]
        var vis = List[Int]()
        for f in range(len(fa)):
            if alive[f] and fp[4 * f] * px + fp[4 * f + 1] * py + fp[4 * f + 2] * pz - fp[4 * f + 3] > eps:
                vis.append(f)
        if len(vis) == 0:
            continue
        # directed edges of the visible faces; a horizon edge is one whose
        # reverse is not also a visible-face edge
        var hdir = Dict[Int, Bool]()
        for k in range(len(vis)):
            var f = vis[k]
            hdir[fa[f] * n + fb[f]] = True
            hdir[fb[f] * n + fc[f]] = True
            hdir[fc[f] * n + fa[f]] = True
        for k in range(len(vis)):
            var f = vis[k]
            alive[f] = False
        for k in range(len(vis)):
            var f = vis[k]
            var ea = List[Int]()
            ea.append(fa[f])
            ea.append(fb[f])
            ea.append(fc[f])
            for e in range(3):
                var a = ea[e]
                var b = ea[(e + 1) % 3]
                if (b * n + a) in hdir:
                    continue
                var q = _plane_of(pts, a, b, i)
                fa.append(a)
                fb.append(b)
                fc.append(i)
                for z in range(4):
                    fp.append(q[z])
                alive.append(True)
        # periodic compaction keeps the per-point scan proportional to the hull
        var dead = 0
        for f in range(len(alive)):
            if not alive[f]:
                dead += 1
        if dead > 64 and dead * 2 > len(alive):
            var na = List[Int]()
            var nb = List[Int]()
            var nc = List[Int]()
            var np = List[Float64]()
            for f in range(len(alive)):
                if alive[f]:
                    na.append(fa[f])
                    nb.append(fb[f])
                    nc.append(fc[f])
                    for z in range(4):
                        np.append(fp[4 * f + z])
            fa = na^
            fb = nb^
            fc = nc^
            fp = np^
            alive = List[Bool]()
            for _ in range(len(fa)):
                alive.append(True)
    var t = List[Int]()
    var tg = List[Int]()
    for f in range(len(fa)):
        if not alive[f]:
            continue
        t.append(fa[f])
        t.append(fb[f])
        t.append(fc[f])
        tg.append(-1)
    return _compact(pts, t, tg)
