# ludens-core

A **test-driven, seam-swappable game-engine core** written in Mojo,
with a geometric-algebra spine: one `Multivector[p,q,r]` generator powers PGA
motors for transforms/skinning, screw-theory rigid dynamics, conformal (CGA)
collision tests, and forward/reverse automatic differentiation.

Two laws govern the codebase (see [docs/CATEGORY.md](docs/CATEGORY.md)):

1. **Every swappable subsystem hides behind a trait** and is chosen at compile
   time — identical game code runs on any implementation, and every seam ships
   with a **parity test** proving the swaps are observationally identical.
2. **Every comparable-method seam has a benchmark row** in
   [BENCHMARK_REPORT.md](BENCHMARK_REPORT.md) — performance claims carry
   measured numbers, never adjectives.

## What's inside

| Subsystem | Seam | Implementations |
|---|---|---|
| ECS storage | `StorageBackend` | sparse-set (EnTT), archetype/SoA (flecs), chunked, bitset, reactive (+push observers), naive baseline |
| ECS extras | — | entity relationships (pair store, wildcard queries), command buffers (deferred despawn/relate/**set**), transform hierarchy (matrix & motor propagation) |
| Scheduling | `Scheduler` / `DispatchPolicy` | sequential baseline; **system-as-actor** and **entity-as-actor** (mailbox dataflow) under serial/parallel dispatch — all produce bit-identical worlds (`test_scheduler_parity`) |
| Broadphase | `BroadPhase` | brute force, quad/octree, spatial hash, sweep-and-prune, BVH, **persistent dynamic BVH + pair cache** |
| Narrowphase | `NarrowPhase` / `ManifoldNarrowPhase` | AABB, circle, SAT, OBB, SDF, GJK+EPA (2D/3D with witness points), CGA spheres/planes; **contact manifolds** (clipped patches, per-point depth), rotated box-box (15-axis SAT) |
| Solver shapes (6-DOF) | — | box, sphere, capsule, **convex hull**, and static triangle-mesh / heightfield — all dispatched through one manifold path |
| Rigid bodies (6-DOF) | `Body6` | `QuatBody6` (quat + inertia tensor) **and** `ScrewBody6` (PGA motor pose + twist bivector, Lie–Poisson) — parity compared **by action**, not coefficients |
| Contact solving | — | Box2D-v3-style sub-stepped soft constraints: warm starting, Coulomb friction, **restitution** (per-body coefficient, pair takes the max), body-frame anchors, joints (ball/distance/hinge), **islands + sleeping, solved in parallel across islands**, speculative **and swept-TOI** CCD |
| Spin integrators | `SpinIntegrator` | semi-implicit Euler, RK2, implicit midpoint, **LGVCI** (Moser–Veselov variational) |
| GA math | `Field` | `Multivector[p,q,r]` (comptime-unrolled products), motors/dual quats, closed-form exp/log, CGA; AD coefficients: `DualReal`, `DualBatch` (4 SIMD lanes), `RevReal` + `Tape` (reverse mode) |
| GPU physics | — | XPBD cloth (gather-Jacobi, CPU/GPU parity ~1e-6) and a VBD prototype, `has_accelerator`-guarded |
| Differentiable sim | — | Field-generic rollouts: gradients through smooth contact, one-tape N-parameter gradients |

Measured highlights (RTX 3060 laptop; context in the report): a 6-box tower
stands 1000 steps with millimetric lean · pendulum period within 0.35 % of
analytic · persistent broadphase 70 µs vs 18.9 ms full rebuild at N=4096 ·
GPU cloth 8.3× CPU at 16k particles · LGVCI holds world angular momentum to
float-roundoff over 20k chaotic-tumble steps.

## Build & run

Linux x86-64 + [pixi](https://pixi.sh). Built on the **stable** toolchain
(Mojo 1.2.0 / modular 26.7.0, pinned exactly in `pixi.toml`); every package
precompiles into `build/` first, because cross-file imports resolve only
through precompiled packages.

```sh
pixi run build       # precompile all engine packages
pixi run test        # arch gate + every tests/test_*.mojo program, unit → component → integration → system
pixi run test-all    # same, plus the stress tier
pixi run gate        # full suite + summary + compare with tests/golden/test_stdout.txt
pixi run arch -- check   # layer / cycle / private-name gate (see docs/ARCHITECTURE.md)
pixi run examples    # runnable demos (01 movement … 24 locomotion graph)
pixi run benchmark   # regenerate BENCHMARK_REPORT.md
```

Run one thing directly after `pixi run build`:

```sh
pixi run mojo run -D ASSERT=all -I build tests/test_softstep6.mojo
pixi run mojo run -I build examples/06_ga_motor.mojo
```

GPU tests and benches self-skip on hosts without an accelerator. Rendering is
intentionally out of this repo: the core stays presentation-free, and any
renderer binds to it as a separate layer.

## Layout

```
diag/        invariants · leveled log · counters · trace spans · debug draw · frame arena
geometry/    vec/mat/quat · GA core (multivector, motors, galie, cga, AD fields) · gjk/epa/sat/clip
collision/   broadphase seams · narrowphase seams · manifolds · dynamic BVH · swept TOI
physics/     6-DOF bodies (quat & screw) · soft-step solver · joints/islands/sleeping ·
             spin integrators · GPU cloth (XPBD, VBD) · differentiable rollouts ·
             articulated chains · FEM/MPM/SPH/PBF softbodies · actuators · sensors
ecs/         storage backends · relations · command buffers · observers · transforms · schemas
scheduler/   sequential / job-graph / work-stealing / actor schedulers · dispatch policies ·
             fixed loop · events · timers · seeded RNGs
gameplay/    runtime · character controller · interpolation · active ragdoll · replay · save
spatial/     loose quad/octree · hash grid · BVH/LBVH
fluid/       lattice-Boltzmann (D3Q19, CPU + GPU)
numerics/    CG · sparse · vec ops
procedural/  noise · animation graph · IK · tween · FSM
oop/         the OOP control engine (benchmark baseline only)
harness/     test & bench harness (tests/benchmarks/examples only)
tests/       one self-checking program per seam       benchmarks/ one cross matrix per seam
tests/_spikes/  language probes (`pixi run spikes`)   experiments/ GA research probes
tools/       archindex (architecture index + gate) · golden (output identity gate)
scripts/     pixi task bodies · arch_layers.toml · benchmark report template
docs/        ARCHITECTURE (layers, error policy, test tiers) · CATEGORY (laws) ·
             SOTA_GAP_ANALYSIS · ROADMAP (status + plan by subsystem) · ROADMAP_HISTORY · design/ · audits/
```

Packages are layered (`scripts/arch_layers.toml`): a package imports only
strictly lower layers — `diag` → `geometry` → {`numerics`, `spatial`,
`procedural`, `fluid`, `ecs`} → {`scheduler`, `collision`} → `physics` →
`gameplay` → `oop`. `pixi run test` fails when that is violated.

## Honest status

- Triangle meshes and heightfields are **static-only** collision shapes — they
  can be collided against but never simulated as moving bodies.
- No scripting or plugin layer — deliberate: the core API is still moving, and
  host layers will live behind a strict architectural boundary when they come.
- The two historical Mojo runtime hazards are closed rather than worked around.
  The bare-`List[Vec3]` teardown corruption no longer reproduces (the `SkinVert`
  struct wrapper it forced was removed after both of its stated reasons were
  disproven); the multiple-`DeviceContext` hang is still avoided by construction
  — GPU drivers share one context (`*_run_ctx`). Details in the docs/ notes.

Every claim above is backed by a test or a benchmark row — when in doubt, read
[docs/ROADMAP.md](docs/ROADMAP.md) (current status by subsystem) and
[docs/ROADMAP_HISTORY.md](docs/ROADMAP_HISTORY.md): each phase section records what was built,
the gate it passed, and the numbers it produced.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT), at your option. Unless you state otherwise, any
contribution you submit for inclusion is dual licensed the same way, without
additional terms. Binary artifacts (`libludens.so`, the Python wheel) bundle
Mojo / MAX runtime components under Modular's own license — see [NOTICE](NOTICE).
