"""Solver tuning knobs, collected into one struct (audit finding F19).

Before this, `step_soft` took eleven positional/keyword flags as the only
way to tune a step, the fat-AABB/margin speculative-contact parity guarantee
depended on two separate `SPEC_BASE` literals (`collision/collider_set.mojo`
and `collision/contact_gen.mojo`) staying equal by hand, and the sleep/
restitution thresholds were comptime locals baked into `_update_sleep`/
`_restitution_pass` with no way to read or override them. `SolverConfig`
gives every one of those a name and one owner; `SPEC_BASE` itself now has
exactly one definition (`collision.collider_set.SPEC_BASE`), imported here
and by `collision.contact_gen`.

`ContactScene6.step(dt, gravity, cfg)` is the config-driven entry point.
`step_soft(dt, gravity, substeps=..., ...)` is now a thin forwarder that
builds a `SolverConfig` from its keyword arguments and calls `step`, so
every existing call site (~100 across tests/benchmarks/examples) keeps
compiling and behaving identically -- this is a behaviour-preserving
refactor (ROADMAP 17.0g-1), not a new step mode.
"""

from geometry.vec import Real
from collision.collider_set import SPEC_BASE
from scheduler.dispatch import Dispatch


comptime IMPULSE_SUBSTEP_SUM = 0
"""Step impulse = the sum of every substep's accumulated impulse (exact)."""
comptime IMPULSE_LAST_SUBSTEP = 1
"""Step impulse = the last substep's accumulated impulse x substeps (free to
read; equal to the sum at steady state, low after an impact the earlier
substeps absorbed -- `test_impact_report` measures both)."""
comptime FRICTION_PYRAMID = 0
"""Friction cone (ROADMAP 17.50): each tangent axis clamped to mu·N on its own."""
comptime FRICTION_ELLIPTIC = 1
"""Friction cone: the tangent impulse vector clamped to a disk of radius mu·N."""
comptime CONTACT_GS = 0
"""Contact normals (ROADMAP 17.50): one point at a time (Gauss-Seidel)."""
comptime CONTACT_BLOCK = 1
"""Contact normals: a manifold's points solved together (a small LCP)."""
comptime MASS_RATIO_DEFAULT: Real = 10
"""ROADMAP 17.19: default `max_mass_ratio` (R). Every `SolverConfig()` and
`step_soft` call uses it unless the caller passes 0 to turn mass scaling off."""


@fieldwise_init
struct SolverConfig(Copyable, ImplicitlyCopyable, Movable):
    """Every `step_soft` tuning knob plus the sleep/restitution thresholds
    that used to be comptime locals. `SolverConfig()`'s defaults reproduce
    the values every call site already had before this struct existed --
    constructing one and stepping with it is bit-identical to the old
    hardcoded behaviour (the identity gate for this commit)."""

    # Speculative-contact margin base (F19): defined once, in
    # `collision.collider_set`, so `ColliderSet.fat_aabb` and
    # `collision.contact_gen`'s per-pair margin can no longer drift apart.
    # Defaults to `SPEC_BASE`. `ContactScene6` (`_step_impl`,
    # `begin_external_solve`) passes it to `_collect_pairs`, which hands
    # it to `ColliderSet.fat_aabb` and the narrowphase margin; `UnitScale.apply` scales it by `per_meter`.
    var margin_base: Real

    # Sleep thresholds (`_update_sleep`'s old comptime locals).
    var lin_sleep_tol: Real
    var ang_sleep_tol: Real
    var sleep_time: Real

    # Restitution: approach speed (m/s) above which the restitution pass
    # engages (`_restitution_pass`'s old comptime `REST_THRESH`).
    var restitution_threshold: Real

    # Cap on the soft push-out speed (m/s) when resolving penetration
    # (`contact6.solve_contact`'s bias clamp, a literal -4 before ROADMAP
    # 17.75 found it with the unit-scale similarity test).
    var max_push_speed: Real

    # `step_soft`'s old keyword arguments; defaults unchanged.
    var substeps: Int
    var iters: Int
    var hertz: Real
    var zeta: Real
    var default_friction: Real  # old `mu` keyword
    var ccd: Bool
    var parallel: Bool
    var colored: Bool
    var broadphase: Bool
    var workers: Int
    var dispatch: Dispatch  # who runs the parallel fan-outs (ROADMAP 17.75)
    # ROADMAP 17.49: how the reported step impulse is estimated (a seam:
    # IMPULSE_SUBSTEP_SUM exact, IMPULSE_LAST_SUBSTEP the free shortcut).
    var impulse_estimator: Int
    # ROADMAP 17.50: the contact friction cone (a seam: FRICTION_PYRAMID,
    # each tangent axis clamped to mu·N on its own; FRICTION_ELLIPTIC, the
    # tangent impulse vector clamped to a disk of radius mu·N).
    var friction_cone: Int
    # ROADMAP 17.54: fan the narrowphase and contact prep out through
    # `dispatch` (`workers` caps the width); bit-identical to False.
    var parallel_collision: Bool
    # ROADMAP 17.85: copy last collection's narrowphase output for pairs
    # whose two bodies have not moved (bit for bit); same result, skips the
    # work for frozen / sleeping / un-stepped bodies. Code that edits
    # `ColliderSet` fields directly must bump `colliders.epoch`.
    var reuse_still_pairs: Bool
    # ROADMAP 17.79: most contact manifolds a step keeps (0 = no cap); the
    # newest over it are dropped and counted (`CONTACT_DROPPED`).
    var max_contacts: Int
    # ROADMAP 17.50: how a manifold's normal impulses are solved (a seam:
    # CONTACT_GS per point, CONTACT_BLOCK all points of a manifold at once;
    # identical for one-point manifolds). The block matrix carries the mass
    # scale of `max_mass_ratio` (`_block_normal` applies the per-side `_cs`).
    var contact_solver: Int
    # ROADMAP 17.19: in contact and core joint rows every dynamic body acts
    # with at least (heaviest body of its contact / joint group) / R -- a
    # heavy box on a light one no longer crushes it into the floor and a
    # light chain holding a weight stretches less, at the price of light
    # bodies responding as heavier ones in those rows (PhysX-style mass
    # scaling). 0 = off (bit-identical to before); else >= 1.
    var max_mass_ratio: Real
    # ROADMAP 17.19 contact reduction: a convex body's coplanar triangle
    # manifolds against a mesh / heightfield merge into one of <= 4 points
    # (`collision.contact_gen._reduce_coplanar`). Off = one manifold per
    # triangle, as before.
    var reduce_mesh_contacts: Bool

    def __init__(out self):
        self.margin_base = SPEC_BASE
        self.lin_sleep_tol = 0.01
        self.ang_sleep_tol = 0.05
        self.sleep_time = 0.5
        self.restitution_threshold = 1.0
        self.max_push_speed = 4
        self.substeps = 4
        self.iters = 4
        self.hertz = 30
        self.zeta = 10
        self.default_friction = 0.5
        self.ccd = False
        self.parallel = False
        self.colored = False
        self.broadphase = False
        self.workers = 0
        self.dispatch = Dispatch.parallel()
        self.impulse_estimator = IMPULSE_SUBSTEP_SUM
        self.friction_cone = FRICTION_PYRAMID
        self.parallel_collision = False
        self.reuse_still_pairs = False
        self.max_contacts = 0
        self.contact_solver = CONTACT_GS
        self.max_mass_ratio = MASS_RATIO_DEFAULT
        self.reduce_mesh_contacts = False

    def validated(self) raises -> Self:
        """Raise if any tuning knob is outside the range the solver assumes
        (ROADMAP 17.0h / audit E5): `substeps`/`iters` < 1, `hertz` <= 0, or
        `zeta` < 0 each lead to a division producing `inf`/`NaN` inside
        `step`'s soft-constraint coefficients (`h = inf`, propagating to
        every body every substep).

        This is the RAISING half of the "invalid caller input at a public
        API" row in `docs/ARCHITECTURE.md` S2 for `step`/`step_soft`'s
        knobs. It is deliberately a method a caller opts into, not something
        `step`/`step_soft` call on every invocation: both have on the order
        of a hundred existing call sites across tests/benchmarks/examples,
        and making either of them `raises` would force every one of those
        (plus every caller of THEM) to become `raises` too -- exactly the
        large-signature-sweep compile-cost cliff `.campaign/mojo_1.1_migration
        .md` warns `physics` is prone to. Instead: a caller building a
        `SolverConfig` from untrusted input calls `.validated()` once at that
        boundary (raising is cheap there -- it is not a hot path), and `step`
        itself only `debug_assert`s the same invariants (terminate-on-bug,
        zero cost when assertions are off) as defence against a config that
        skipped validation, per the same file's guidance to prefer
        validate-once objects over a raising hot path."""
        if self.substeps < 1:
            raise Error("SolverConfig.validated: substeps must be >= 1")
        if self.iters < 1:
            raise Error("SolverConfig.validated: iters must be >= 1")
        if self.hertz <= 0:
            raise Error("SolverConfig.validated: hertz must be > 0")
        if self.zeta < 0:
            raise Error("SolverConfig.validated: zeta must be >= 0")
        if self.impulse_estimator != IMPULSE_SUBSTEP_SUM and self.impulse_estimator != IMPULSE_LAST_SUBSTEP:
            raise Error("SolverConfig.validated: unknown impulse_estimator")
        if self.friction_cone != FRICTION_PYRAMID and self.friction_cone != FRICTION_ELLIPTIC:
            raise Error("SolverConfig.validated: unknown friction_cone")
        if self.contact_solver != CONTACT_GS and self.contact_solver != CONTACT_BLOCK:
            raise Error("SolverConfig.validated: unknown contact_solver")
        if self.max_mass_ratio != 0 and not (self.max_mass_ratio >= 1):
            raise Error("SolverConfig.validated: max_mass_ratio must be 0 (off) or >= 1")
        return self


@fieldwise_init
struct UnitScale(Copyable, ImplicitlyCopyable, Movable):
    """How many host length units make one meter (ROADMAP 17.75): 1 for an
    engine working in meters, 100 for Unreal's centimetres, 0.01 for a host
    that counts in hundreds of meters. The core works in whatever unit its
    inputs use -- positions, extents, velocities, gravity -- and only the
    solver's ABSOLUTE length tolerances need telling: `apply` returns a copy
    of a `SolverConfig` with every length-dimensioned knob multiplied by
    `per_meter` (speculative margin in m, linear sleep threshold and
    restitution threshold and push-out speed cap in m/s). Angular thresholds (rad/s), times (s) and
    the dimensionless soft-constraint knobs are unit-free and unchanged.
    `test_unit_scale` checks the claim by similarity: a scene with every
    length multiplied by 2^k, stepped with `UnitScale(2^k)`, must follow the
    original trajectory times 2^k."""

    var per_meter: Real

    def apply(self, cfg: SolverConfig) -> SolverConfig:
        var c = cfg
        c.margin_base = cfg.margin_base * self.per_meter
        c.lin_sleep_tol = cfg.lin_sleep_tol * self.per_meter
        c.restitution_threshold = cfg.restitution_threshold * self.per_meter
        c.max_push_speed = cfg.max_push_speed * self.per_meter
        return c
