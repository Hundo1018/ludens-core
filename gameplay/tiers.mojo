"""Tiered simulation policies (ROADMAP 17.85). Seam: `TierPolicy`.

A policy turns (scene, observers, step index) into a tier per body slot;
`ContactScene6.set_body_tiers` applies it and the scene's tier table maps a
tier to (iters, substeps, period). The solver gives an island the finest tier
among its members, so a policy only has to rank bodies.

- `DistanceTiers`: distance to the nearest observer against ascending radii,
  with hysteresis (a body moves to a coarser tier only past `radius +
  hysteresis`, back to a finer one inside `radius`). Generalises 17.31's
  `DistanceLOD` (one radius, freeze / unfreeze).
- `CausalReach`: breadth-first search over the contact / joint graph from
  the bodies within `seed_radius` of an observer; contact-graph depth d
  maps to a tier through ascending depth thresholds; bodies the search does
  not reach get the coarsest tier. Near in space but causally far (behind a
  wall, on a separate pile) stays coarse.
- `RoundRobin`: every body in one tier whose period spreads the work; the
  solver's phase (an island's first slot index) makes every island tick
  exactly once per period.
- `AggregateTiers`: islands farther than `radius` from every observer whose
  members are all slower than `rest_speed` go to `frozen_tier` (a tier the
  caller gives period 0: not solved, still an obstacle), and each frozen
  island is summarised as one `ClusterProxy` (members, mass, centroid,
  bounds) for the host -- the far crowd as aggregates instead of bodies.
  Nothing extra wakes a frozen island: anything that touches it joins its
  island, which then takes the toucher's finer tier.
- `BudgetTiers`: `DistanceTiers` whose radii scale with a measured step cost
  (generalises 17.31's `SimBudget`): above the target the radii shrink by
  `shrink`, comfortably below it they grow back to the configured values.

Policies are deterministic functions of their inputs plus their own
hysteresis state; `copy()` the policy alongside a snapshot to replay.
Parity anchor (`test_tiers_parity`): a plan with every body at tier 0, tier 0
= the step's config, is bit-identical to the untiered step.
"""

from std.math import sqrt
from std.collections import Dict
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase
from ecs.component import ComponentType


struct Tier[N: Int, BASE: Int](ComponentType):
    """ECS tag for simulation tier N (ROADMAP 17.85): `Runtime.sync_tier_tags`
    puts `Tier[t, BASE]` on each body entity in tier t and removes the
    others, so a system that only wants the near set queries
    `(Tier[0, BASE], ...)` -- archetype, sparse-set and reactive backends
    then iterate the tagged set only. The component id is BASE + N, chosen
    by the caller like any other id (duplicates are a compile error)."""

    comptime ID: Int = Self.BASE + Self.N

    def __init__(out self):
        pass


trait TierPolicy(Movable, Deinitable):
    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        """Tier per body slot (len == number of slots)."""
        ...


def _nearest_dist(p: Vec3, observers: List[Vec3]) -> Real:
    var best = Real(1e30)
    for o in observers:
        var d = p - o
        best = min(best, sqrt(dot(d, d)))
    return best


def _arrival_time(p: Vec3, v: Vec3, observers: List[Vec3], seed_radius: Real) -> Real:
    """Earliest time a body at `p` moving at `v` reaches `seed_radius` of an
    observer, along its current closing speed (`dot(v, toward the
    observer)`); 0 inside the radius, a large value when moving away."""
    var best = Real(1e30)
    for o in observers:
        var d = o - p
        var dist = sqrt(dot(d, d))
        if dist <= seed_radius:
            return 0
        var closing = dot(v, d) / dist
        if closing > 0:
            best = min(best, (dist - seed_radius) / closing)
    return best


struct DistanceTiers(TierPolicy, Copyable):
    var radii: List[Real]  # ascending: tier t covers up to radii[t]
    var hysteresis: Real
    var last: List[Int]

    def __init__(out self, var radii: List[Real], hysteresis: Real = 1.0) raises:
        for i in range(1, len(radii)):
            if not (radii[i] > radii[i - 1]):
                raise Error("DistanceTiers: radii must be strictly ascending")
        if hysteresis < 0:
            raise Error("DistanceTiers: hysteresis must be >= 0")
        self.radii = radii^
        self.hysteresis = hysteresis
        self.last = List[Int]()

    def tier_for(self, dist: Real, prev: Int) -> Int:
        """Raw tier = first radius covering dist; hysteresis keeps a finer
        previous tier until dist exceeds its radius + hysteresis."""
        var t = len(self.radii)
        for i in range(len(self.radii)):
            if dist <= self.radii[i]:
                t = i
                break
        if prev >= 0 and prev < t and dist <= self.radii[prev] + self.hysteresis:
            return prev
        return t

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        var n = len(scene.bset.bodies)
        while len(self.last) < n:
            self.last.append(-1)
        var out = List[Int](length=n, fill=len(self.radii))
        for i in range(n):
            if scene.bset.is_removed(i):
                continue
            var d = _nearest_dist(scene.bset.bodies[i].position(), observers)
            out[i] = self.tier_for(d, self.last[i])
            self.last[i] = out[i]
        return out^


struct CausalReach(TierPolicy, Copyable):
    var seed_radius: Real
    var depths: List[Int]  # ascending: tier t covers graph depth <= depths[t]
    var horizons: List[Real]  # ascending seconds: tier t also covers arrival time <= horizons[t] (empty = off)
    var reached: Int  # bodies reached by the last search (diagnostic)
    var arriving: Int  # bodies the arrival time made finer than the graph depth (diagnostic)

    def __init__(out self, seed_radius: Real, var depths: List[Int], var horizons: List[Real] = List[Real]()) raises:
        """`horizons` adds the light cone (ROADMAP 17.85 / 17.100): a body not
        yet in contact with the observer's neighbourhood but closing on it
        fast is ranked by when it can arrive, `(distance - seed_radius) /
        closing speed`, so a projectile is solved finely before it hits
        rather than from the tick it touches something. A body's tier is the
        finer of its graph tier and its arrival tier; an empty list keeps
        the graph-only behaviour bit for bit."""
        for i in range(1, len(depths)):
            if not (depths[i] > depths[i - 1]):
                raise Error("CausalReach: depths must be strictly ascending")
        for i in range(len(horizons)):
            if not (horizons[i] >= 0) or (i > 0 and not (horizons[i] > horizons[i - 1])):
                raise Error("CausalReach: horizons must be >= 0 and strictly ascending")
        self.seed_radius = seed_radius
        self.depths = depths^
        self.horizons = horizons^
        self.reached = 0
        self.arriving = 0

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        var n = len(scene.bset.bodies)
        # adjacency from last step's contacts and the joints (CSR)
        var deg = List[Int](length=n + 1, fill=0)
        for c in scene.cache:
            deg[c.a + 1] += 1
            deg[c.b + 1] += 1
        for j in scene.joints:
            deg[j.a + 1] += 1
            deg[j.b + 1] += 1
        for i in range(n):
            deg[i + 1] += deg[i]
        var fill = deg.copy()
        var adj = List[Int](length=deg[n], fill=-1)
        for c in scene.cache:
            adj[fill[c.a]] = c.b
            fill[c.a] += 1
            adj[fill[c.b]] = c.a
            fill[c.b] += 1
        for j in scene.joints:
            adj[fill[j.a]] = j.b
            fill[j.a] += 1
            adj[fill[j.b]] = j.a
            fill[j.b] += 1
        var depth = List[Int](length=n, fill=-1)
        var queue = List[Int]()
        var r2 = self.seed_radius * self.seed_radius
        for i in range(n):
            if scene.bset.is_removed(i) or not scene.bset.moves(i):
                continue
            for o in observers:
                var d = scene.bset.bodies[i].position() - o
                if dot(d, d) <= r2:
                    depth[i] = 0
                    queue.append(i)
                    break
        var head = 0
        while head < len(queue):
            var u = queue[head]
            head += 1
            for e in range(deg[u], deg[u + 1]):
                var v = adj[e]
                # static bodies conduct nothing: a shared floor would put the
                # whole level at depth 1
                if depth[v] >= 0 or not scene.bset.moves(v):
                    continue
                depth[v] = depth[u] + 1
                queue.append(v)
        self.reached = len(queue)
        var coarsest = len(self.depths)
        var out = List[Int](length=n, fill=coarsest)
        for i in range(n):
            if depth[i] < 0:
                continue
            for t in range(len(self.depths)):
                if depth[i] <= self.depths[t]:
                    out[i] = t
                    break
        self.arriving = 0
        if len(self.horizons) > 0:
            for i in range(n):
                if scene.bset.is_removed(i) or not scene.bset.moves(i) or out[i] == 0:
                    continue
                var t_arr = _arrival_time(scene.bset.bodies[i].position(), scene.bset.bodies[i].linear_velocity(), observers, self.seed_radius)
                for t in range(min(len(self.horizons), out[i])):
                    if t_arr <= self.horizons[t]:
                        out[i] = t
                        self.arriving += 1
                        break
        return out^


struct RoundRobin(TierPolicy, Copyable):
    var tier: Int  # the tier (in the scene's table) whose period spreads the work

    def __init__(out self, tier: Int = 1):
        self.tier = tier

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        return List[Int](length=len(scene.bset.bodies), fill=self.tier)


struct BudgetTiers(TierPolicy, Copyable):
    var inner: DistanceTiers
    var base: List[Real]
    var target_ns: Int
    var shrink: Real
    var scale: Real
    var last_ns: Int

    def __init__(out self, var radii: List[Real], target_ns: Int, hysteresis: Real = 1.0, shrink: Real = 0.8) raises:
        if target_ns <= 0 or not (shrink > 0 and shrink < 1):
            raise Error("BudgetTiers: target_ns > 0 and 0 < shrink < 1")
        self.base = radii.copy()
        self.inner = DistanceTiers(radii^, hysteresis)
        self.target_ns = target_ns
        self.shrink = shrink
        self.scale = 1
        self.last_ns = 0

    def measured(mut self, ns: Int):
        """Feed the last step's cost: above 110 % of the target the radii
        shrink, below 70 % they grow back toward the configured values."""
        self.last_ns = ns
        if ns * 10 > self.target_ns * 11:
            self.scale *= self.shrink
        elif ns * 10 < self.target_ns * 7:
            self.scale = min(Real(1), self.scale / self.shrink)
        for i in range(len(self.base)):
            self.inner.radii[i] = self.base[i] * self.scale

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        return self.inner.assign(scene, observers, step)


@fieldwise_init
struct ClusterProxy(Copyable, ImplicitlyCopyable, Movable):
    """A frozen island seen from afar (`AggregateTiers`)."""

    var island: Int
    var members: Int
    var mass: Real
    var centroid: Vec3  # mass-weighted
    var lo: Vec3  # bounds of the member centres
    var hi: Vec3


struct AggregateTiers(TierPolicy, Copyable):
    var radius: Real
    var rest_speed: Real
    var frozen_tier: Int
    var proxies: List[ClusterProxy]

    def __init__(out self, radius: Real, rest_speed: Real, frozen_tier: Int) raises:
        if not (radius > 0) or rest_speed < 0 or frozen_tier < 1:
            raise Error("AggregateTiers: radius > 0, rest_speed >= 0, frozen_tier >= 1")
        self.radius = radius
        self.rest_speed = rest_speed
        self.frozen_tier = frozen_tier
        self.proxies = List[ClusterProxy]()

    def assign[Body: Body6, BP: BroadPhase](mut self, scene: ContactScene6[Body, BP], observers: List[Vec3], step: Int) -> List[Int]:
        ref bs = scene.bset
        var n = len(bs.bodies)
        var out = List[Int](length=n, fill=0)
        # per island (labels from the last step): nearest member distance
        # and fastest member speed
        var near = Dict[Int, Real]()
        var fast = Dict[Int, Real]()
        for i in range(n):
            if bs.is_removed(i) or not bs.is_dynamic(i) or i >= len(bs.island):
                continue
            var l = bs.island[i]
            if l < 0:
                continue
            var d = _nearest_dist(bs.bodies[i].position(), observers)
            var v = bs.bodies[i].linear_velocity()
            var sp = sqrt(dot(v, v))
            near[l] = min(near.get(l, Real(1e30)), d)
            fast[l] = max(fast.get(l, Real(0)), sp)
        var proxy_of = Dict[Int, Int]()
        self.proxies = List[ClusterProxy]()
        for i in range(n):
            if bs.is_removed(i) or not bs.is_dynamic(i) or i >= len(bs.island):
                continue
            var l = bs.island[i]
            if l < 0 or near.get(l, Real(0)) <= self.radius or fast.get(l, Real(1e30)) >= self.rest_speed:
                continue
            out[i] = self.frozen_tier
            var m = Real(1) / bs.bodies[i].inv_mass()
            var p = bs.bodies[i].position()
            var k = proxy_of.get(l, -1)
            if k < 0:
                proxy_of[l] = len(self.proxies)
                self.proxies.append(ClusterProxy(l, 1, m, p * m, p, p))
            else:
                ref c = self.proxies[k]
                c.members += 1
                c.mass += m
                c.centroid = c.centroid + p * m
                for a in range(3):
                    c.lo[a] = min(c.lo[a], p[a])
                    c.hi[a] = max(c.hi[a], p[a])
        for ref c in self.proxies:
            c.centroid = c.centroid / c.mass
        return out^
