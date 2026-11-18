# tier: component  (override: spatial.cell_sort is the solver's internal neighbour grouping, not a second package under test)
"""Crowd + avoidance seam parity (ROADMAP 17.14): Orca / SampledRvo / SocialForce.

Scenarios, each run with all three variants:
- antipodal swap: 16 agents on a 6 m circle walk to the opposite point;
- corridor crossing: two groups of 6 meet head-on in a 4 m corridor;
- bottleneck: 12 agents through a 1.6 m door;
- coincident spawn: 4 agents created at the same point, targets apart.

Laws: every variant gets every agent to its target (no deadlock) within the
time limit, no agent ever leaves the walkable mesh, and the run is
deterministic (two runs, same final positions bit for bit). Overlap is the
measured difference, bounded per scenario after the first second (the
coincident spawn starts fully overlapped):
- open floor (swap, spawn): ORCA within 2 % of a radius -- its guarantee;
  the others within 15 % (swap) / 2 % (spawn);
- walls (corridor, door): 15 % for ORCA and RVO, 20 % for the social force.
  ORCA's guarantee does not survive the wall: the mesh constraint slides the
  agent after the linear program, so neighbours' reciprocal halves no longer
  add up (measured 0.03 m = 10 % of a radius in the door).
Measured minima are printed for the golden file.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from std.math import cos, sin, pi
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.crowd import Crowd, CrowdParams, Avoidance, Orca, SampledRvo, SocialForce


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


struct Scene(Movable):
    var verts: List[Vec3]
    var tris: List[Int]

    def __init__(out self):
        self.verts = List[Vec3]()
        self.tris = List[Int]()

    def _tri(mut self, a: Vec3, b: Vec3, c: Vec3):
        var n = len(self.verts)
        self.verts.append(a)
        self.verts.append(b)
        self.verts.append(c)
        self.tris.append(n)
        self.tris.append(n + 1)
        self.tris.append(n + 2)

    def quad(mut self, x0: Real, z0: Real, x1: Real, z1: Real, y: Real):
        self._tri(_v(x0, y, z0), _v(x0, y, z1), _v(x1, y, z0))
        self._tri(_v(x1, y, z0), _v(x0, y, z1), _v(x1, y, z1))

    def box(mut self, lo: Vec3, hi: Vec3):
        var x0 = lo[0]
        var y0 = lo[1]
        var z0 = lo[2]
        var x1 = hi[0]
        var y1 = hi[1]
        var z1 = hi[2]
        self.quad(x0, z0, x1, z1, y1)
        self._tri(_v(x0, y0, z0), _v(x0, y1, z0), _v(x0, y0, z1))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z0), _v(x0, y1, z1))
        self._tri(_v(x1, y0, z0), _v(x1, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y0, z1), _v(x1, y1, z1), _v(x1, y1, z0))
        self._tri(_v(x0, y0, z0), _v(x1, y0, z0), _v(x0, y1, z0))
        self._tri(_v(x1, y0, z0), _v(x1, y1, z0), _v(x0, y1, z0))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z1), _v(x1, y0, z1))
        self._tri(_v(x1, y0, z1), _v(x0, y1, z1), _v(x1, y1, z1))


comptime DT: Real = 1.0 / 30.0
comptime R: Real = 0.3


struct Outcome(Copyable, Movable):
    var arrived: Bool
    var on_mesh: Bool
    var min_sep: Real
    var min_sep_late: Real  # after the first second
    var time: Real
    var final: List[Vec3]

    def __init__(out self):
        self.arrived = False
        self.on_mesh = True
        self.min_sep = Real(1e30)
        self.min_sep_late = Real(1e30)
        self.time = 0
        self.final = List[Vec3]()


def _run[A: Avoidance](var avoid: A, mesh: NavMesh, starts: List[Vec3], goals: List[Vec3], t_max: Real) raises -> Outcome:
    var c = Crowd[A](avoid^, CrowdParams.default())
    for i in range(len(starts)):
        _ = c.add_agent(mesh, starts[i], R, 1.4)
    for i in range(len(starts)):
        if not c.set_target(mesh, i, goals[i]):
            raise Error("goal unreachable in a test scene")
    var o = Outcome()
    var steps = Int(t_max / DT)
    for k in range(steps):
        c.step(mesh, DT)
        var sep = c.min_separation()
        o.min_sep = min(o.min_sep, sep)
        if Real(k) * DT >= 1.0:
            o.min_sep_late = min(o.min_sep_late, sep)
        for i in range(len(c)):
            if mesh.find_span(c.pos[i]) < 0:
                o.on_mesh = False
        if c.all_arrived():
            o.arrived = True
            o.time = Real(k + 1) * DT
            break
    o.final = c.pos.copy()
    return o^


def _same(a: List[Vec3], b: List[Vec3]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        var d = a[i] - b[i]
        if d[0] != 0 or d[1] != 0 or d[2] != 0:
            return False
    return True


def _check(mut s: Suite, o: Outcome, again: Outcome, name: String, sep_floor: Real):
    s.check(o.arrived, name + ": all agents arrive")
    s.check(o.on_mesh, name + ": agents stay on the mesh")
    s.check(o.min_sep_late >= sep_floor, name + ": overlap bounded (min sep " + String(o.min_sep_late) + ")")
    s.check(_same(o.final, again.final), name + ": deterministic")
    print("  crowd:", name, "time", o.time, "min sep", o.min_sep, "late", o.min_sep_late)


def _scenario[A: Avoidance](mut s: Suite, mesh: NavMesh, starts: List[Vec3], goals: List[Vec3], t_max: Real, name: String, sep_floor: Real, var a1: A, var a2: A) raises:
    var o = _run(a1^, mesh, starts, goals, t_max)
    var o2 = _run(a2^, mesh, starts, goals, t_max)
    _check(s, o, o2, name, sep_floor)


def main() raises:
    var s = Suite("crowd")
    var cfg = NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)

    # ---- antipodal swap on an open floor ----
    var open = Scene()
    open.quad(0, 0, 20, 20, 0)
    var mo = bake_navmesh(open.verts, open.tris, cfg)
    var st = List[Vec3]()
    var gl = List[Vec3]()
    for i in range(16):
        var a = Real(2) * Real(pi) * Real(i) / 16
        st.append(_v(10 + 6 * cos(a), 0, 10 + 6 * sin(a)))
        gl.append(_v(10 - 6 * cos(a), 0, 10 - 6 * sin(a)))
    _scenario(s, mo, st, gl, 40, "swap/orca", -0.02 * R, Orca(), Orca())
    _scenario(s, mo, st, gl, 40, "swap/rvo", -0.15 * R, SampledRvo(), SampledRvo())
    _scenario(s, mo, st, gl, 40, "swap/force", -0.15 * R, SocialForce(), SocialForce())

    # ---- corridor crossing ----
    var cor = Scene()
    cor.quad(0, 0, 30, 4, 0)
    cor.box(_v(0, 0, -0.5), _v(30, 2.5, 0))
    cor.box(_v(0, 0, 4), _v(30, 2.5, 4.5))
    var mc = bake_navmesh(cor.verts, cor.tris, cfg)
    var cs = List[Vec3]()
    var cg = List[Vec3]()
    for i in range(6):
        var z = Real(1.2) + Real(i % 3) * 0.8
        var x = Real(2) + Real(i // 3) * 1.0
        cs.append(_v(x, 0, z))
        cg.append(_v(28 - Real(i // 3), 0, z))
        cs.append(_v(30 - x, 0, z))
        cg.append(_v(2 + Real(i // 3), 0, z))
    _scenario(s, mc, cs, cg, 60, "corridor/orca", -0.15 * R, Orca(), Orca())
    _scenario(s, mc, cs, cg, 60, "corridor/rvo", -0.15 * R, SampledRvo(), SampledRvo())
    _scenario(s, mc, cs, cg, 60, "corridor/force", -0.2 * R, SocialForce(), SocialForce())

    # ---- bottleneck door ----
    var dr = Scene()
    dr.quad(0, 0, 20, 12, 0)
    dr.box(_v(9.75, 0, -0.5), _v(10.25, 2.5, 5.2))
    dr.box(_v(9.75, 0, 6.8), _v(10.25, 2.5, 12.5))  # 1.6 m door at z 5.2..6.8
    var md = bake_navmesh(dr.verts, dr.tris, cfg)
    var ds = List[Vec3]()
    var dg = List[Vec3]()
    for i in range(12):
        ds.append(_v(3 + Real(i % 4) * 1.2, 0, 3 + Real(i // 4) * 2.5))
        dg.append(_v(14 + Real(i % 4) * 1.2, 0, 3 + Real(i // 4) * 2.5))
    _scenario(s, md, ds, dg, 90, "door/orca", -0.15 * R, Orca(), Orca())
    _scenario(s, md, ds, dg, 90, "door/rvo", -0.15 * R, SampledRvo(), SampledRvo())
    _scenario(s, md, ds, dg, 90, "door/force", -0.2 * R, SocialForce(), SocialForce())

    # ---- coincident spawn ----
    var ps = List[Vec3]()
    var pg = List[Vec3]()
    for i in range(4):
        ps.append(_v(10, 0, 10))
        var a = Real(pi) * 0.5 * Real(i)
        pg.append(_v(10 + 4 * cos(a), 0, 10 + 4 * sin(a)))
    _scenario(s, mo, ps, pg, 30, "spawn/orca", -0.02 * R, Orca(), Orca())
    _scenario(s, mo, ps, pg, 30, "spawn/rvo", -0.02 * R, SampledRvo(), SampledRvo())
    _scenario(s, mo, ps, pg, 30, "spawn/force", -0.02 * R, SocialForce(), SocialForce())

    # ---- off-mesh link: an agent jumps the gap between two islands ----
    var isl = Scene()
    isl.quad(0, 0, 5, 5, 0)
    isl.quad(8, 0, 13, 5, 0)
    var mi = bake_navmesh(isl.verts, isl.tris, cfg)
    _ = mi.add_offmesh_link(_v(4.4, 0, 2.5), _v(8.6, 0, 2.5), bidir=False)
    var cj = Crowd[Orca](Orca(), CrowdParams.default())
    _ = cj.add_agent(mi, _v(1, 0, 2.5), R, 1.4)
    s.check(cj.set_target(mi, 0, _v(12, 0, 2.5)), "jump: path planned over the link")
    var crossed = False
    for _ in range(300):
        cj.step(mi, DT)
        if cj.pos[0][0] > 5 and cj.pos[0][0] < 8:
            crossed = True
        if cj.all_arrived():
            break
    s.check(crossed and cj.all_arrived(), "jump: agent crosses the gap and arrives")

    # ---- errors ----
    var c = Crowd[Orca](Orca(), CrowdParams.default())
    var raised = False
    try:
        _ = c.add_agent(mo, _v(-5, 0, -5), R, 1.4)
    except:
        raised = True
    s.check(raised, "agent off the mesh raises")
    raised = False
    try:
        _ = c.add_agent(mo, _v(5, 0, 5), 0, 1.4)
    except:
        raised = True
    s.check(raised, "zero radius raises")
    s.finish()
