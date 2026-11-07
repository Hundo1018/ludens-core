"""ROADMAP 17.0i: the runtime that owns a world.

Audit F15: nothing owned stateful runtime. A physics scene was neither a
system nor a component, nothing synced `ContactScene6` poses into ECS
transforms, and `scheduler.scheduler.System.apply[B](mut world)` is
stateless -- it cannot capture a `ContactScene6`, a gravity vector, or a
`SolverConfig` the way a real per-frame driver needs to. `Runtime[B, Body]`
is that missing home: it owns an ECS `World[B]`, a physics `ContactScene6
[Body]`, the fixed-step accumulator (`scheduler.gameloop.FixedLoop`'s
fields, driven inline rather than through `FixedLoop.advance[S: Scheduler]`
-- see `advance`'s docstring for why), a contact-event channel
(`scheduler.events.Channel`), and a tick-based timer queue
(`scheduler.timers.TimerHeap`). 17.1 (character controller), 17.7
(interpolation) and every later gameplay feature build on top of this.

`gameplay` is layer 5 (`docs/ARCHITECTURE.md` S1, `scripts/arch_layers.toml`):
it may import every lower package (physics, collision, ecs, scheduler,
diag, geometry, ...) and nothing may import IT (the arch check enforces this
-- a `Runtime` is the top of the engine-package stack, one hop below
tests/benchmarks/examples).

WIRING PER FIXED TICK (`advance`): `timers.advance(1, ...)` first (so a
timer scheduled to fire "this tick" is visible to code that reacts to it
before the physics step runs; the fires collect in `fired` for the caller's
`take_fired`, ROADMAP 17.72), then `scene.step(dt, gravity, cfg)`, then
`scene.events` (this step's contact began/stay/ended, rebuilt fresh every
step since `scene.events_on` is turned on by `Runtime.__init__`) is
forwarded onto `events` (`scheduler.events.Channel`, the SAME adapter shape
`tests/test_events_contacts.mojo`'s `publish_contact_events` already
proved against a real `ContactScene6` stack -- this is that adapter's
production-code home the test file's own docstring said would exist once
`gameplay` did), then `events.update()` ages the double buffer one tick (so
"two update() calls" tracks fixed ticks, the runtime's natural per-tick
unit, matching that test's own per-step `ch.update()` call), then poses
sync into ECS transforms (`_sync_transforms`, one `for_each2` pass: reads
`BodySet`, writes `ecs.transform.Transform` -- no `List[Entity]`
allocation, the same zero-allocation path every other ECS system in this
engine uses).

GAME FLOW (ROADMAP 17.72): `flow` is a `gameplay.flow.FlowStack`. Empty, every
part ticks (the behaviour above). Otherwise the top state's `TICK_*` mask
gates each part of `_tick`: `TICK_TIMERS` the timer queue, `TICK_SIM` the
scene step with its pose sync and history, `TICK_EVENTS` forwarding that
step's contact events. Time still accumulates and is consumed while a part
is off, so a pause neither builds up a debt of ticks nor shifts what runs
after it: pause N ticks, resume, run M == run M (`test_runtime_flow`).
Systems passed to `advance_with` and coupled ports are the caller's; the
mask does not reach them.

OPERATIONS (ROADMAP 17.73): at the start of every frame the runtime takes
the host's queued config (`inbox`, `gameplay.host_inbox`), stamps it with
the frame's first tick and applies it to `config` (key -> value); data the
host posts during a frame, or while a `begin_advance` step is in flight,
lands on the next frame. At the end of every frame the `outbox`
(`diag.outbox`, written by gameplay code during ticks) is drained into
`ops` for the host to `take_ops`; `ops` is bounded by the outbox capacity,
and records dropped by either (a full outbox, a host that does not take)
are added to `OUTBOX_DROPPED`."""

from std.time import perf_counter_ns
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.transform import Transform
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Body6, Pose6
from physics.body_set import BodyId
from physics.solver6 import ContactScene6, FORCE_MODE_FORCE
from physics.solver_config import SolverConfig
from physics.lod import SimBudget
from physics.coupling import CouplingPort
from physics.continuum import step_checked
from scheduler.gameloop import FixedLoop
from scheduler.jobgraph import JobGraphScheduler, DeclaredSystem
from scheduler.events import Channel
from scheduler.timers import TimerHeap, TimerFire
from collision.contact_events import ContactEvent
from collision.collider_set import SHAPE_BOX, SHAPE_SPHERE
from diag.counters import GAMELOOP_DEBT_DROPPED, OUTBOX_DROPPED, TIMER_FIRES_DROPPED
from diag.outbox import Outbox, OutRecord
from .interpolation import PoseHistory, PoseQT, PoseInterpolator, DqNlerp
from .tiers import TierPolicy, Tier
from .flow import FlowStack, TICK_SIM, TICK_TIMERS, TICK_EVENTS
from .host_inbox import ConfigInbox
from .rules import Actor, Rules, TagRegistry


@fieldwise_init
struct StepHandle(Copyable, ImplicitlyCopyable, Movable):
    """What `Runtime.begin_advance` hands back (ROADMAP 17.75): how many fixed
    ticks this frame owes and which begin it belongs to. Pass it to
    `execute` (on any thread the host likes) and then `finish`."""

    var ticks: Int
    var serial: Int


@fieldwise_init
struct RigidBodyRef(ComponentType):
    """Links an entity to a scene body. `id` is a stable `BodyId` (slot +
    generation, `physics.body_set`): after `Runtime.despawn`, the id this
    component held reads `is_valid() == False` on `scene.bset` -- the same
    stale-handle contract `ecs.entity.Entity` already gives every other
    component."""

    comptime ID: Int = 2  # after ecs.transform's Transform=0 / Parent=1
    var id: BodyId


struct Runtime[B: StorageBackend, Body: Body6](Movable, Deinitable):
    """Owns a world, a physics scene, and the fixed-step loop between them.

    Generic over the ECS storage backend (`B`, same swap-seam every other
    `World[B]` caller uses) and the `Body6` representation (`Body` --
    `QuatBody6` or `ScrewBody6`, ROADMAP 17.0h's parity pair); `B`'s
    component set must include `RigidBodyRef` and `ecs.transform.Transform`
    for `spawn_body`/`_sync_transforms` to compile against it."""

    var world: World[Self.B]
    var scene: ContactScene6[Self.Body]
    var loop: FixedLoop
    var cfg: SolverConfig
    var gravity: Vec3
    var events: Channel[ContactEvent]
    var timers: TimerHeap
    var history: PoseHistory  # previous + current tick pose per body slot (17.7)
    # Non-blocking stepping (ROADMAP 17.75): `begin_advance` / `execute` /
    # `finish`. While a step is in flight the host reads `published` (the
    # poses of the last completed tick), never the scene.
    var in_flight: Bool
    var executed: Bool
    var serial: Int
    var published: List[PoseQT]
    var flow: FlowStack  # ROADMAP 17.72: empty = everything ticks
    var outbox: Outbox  # ROADMAP 17.73: written during ticks
    var ops: List[OutRecord]  # drained at frame end, for the host
    var inbox: ConfigInbox  # host data, applied at frame start
    var config: Dict[Int, Int]
    var fired: List[TimerFire]  # ROADMAP 17.72: this frame's timer fires, for `take_fired`
    var fired_capacity: Int
    # ROADMAP 17.70: gameplay rules owned by the runtime. Off until `enable_rules`; ticks with the timers (an effect is
    # a timed thing, so a state that pauses timers pauses effects) and is not carried by `carry_to`.
    var rules: Rules
    var actors: List[Actor]
    var tags: TagRegistry
    var rules_on: Bool

    def __init__(out self, dt: Real, gravity: Vec3, max_steps: Int = 8, outbox_capacity: Int = 4096, fired_capacity: Int = 4096):
        self.world = World[Self.B]()
        self.scene = ContactScene6[Self.Body]()
        # Contact events are off by default on a bare `ContactScene6` (the
        # diff sorts the contact set every step, real work a scene that
        # never reads it shouldn't pay for -- `solver6.mojo`'s field
        # docstring) but a `Runtime` exists specifically to publish them
        # onto `events`, so it always wants them on.
        self.scene.events_on = True
        self.loop = FixedLoop.new(Float64(dt), max_steps)
        self.cfg = SolverConfig()
        self.gravity = gravity
        self.events = Channel[ContactEvent]()
        self.timers = TimerHeap()
        self.history = PoseHistory()
        self.in_flight = False
        self.executed = False
        self.serial = 0
        self.published = List[PoseQT]()
        self.flow = FlowStack()
        self.outbox = Outbox(outbox_capacity)
        self.ops = List[OutRecord]()
        self.inbox = ConfigInbox()
        self.config = Dict[Int, Int]()
        self.fired = List[TimerFire]()
        self.fired_capacity = fired_capacity
        self.rules = Rules(0)
        self.actors = List[Actor]()
        self.tags = TagRegistry()
        self.rules_on = False

    def enable_rules(mut self, health_attr: Int):
        """Turn the rules on: from now on every tick that runs the timers also steps `rules` over `actors`. Define
        effects with `rules.define`, tags with `tags.intern`, and actors with `add_actor`."""
        self.rules = Rules(health_attr)
        self.rules_on = True

    def add_actor(mut self, n_attrs: Int, n_types: Int) -> Int:
        """A rules actor (attributes, effects, shield, resistances); returns its index into `actors`."""
        self.actors.append(Actor(n_attrs, n_types))
        return len(self.actors) - 1

    # ------------------------------------------------------------ lifecycle

    def spawn_body(mut self, var b: Self.Body, half: Vec3, is_static: Bool) -> Entity:
        """Add a box body to the scene AND an entity carrying `RigidBodyRef`
        + `Transform` (initialized to the body's own pose) -- one call, the
        design note's requirement that a gameplay caller never has a scene
        body without a matching entity or vice versa."""
        debug_assert(not self.in_flight, "Runtime: spawn while a step is in flight (begin_advance without finish)")
        var id = self.scene.add(b^, half, is_static)
        return self._spawn_entity(id)

    def spawn_sphere(mut self, var b: Self.Body, r: Real, is_static: Bool) -> Entity:
        """Same as `spawn_body`, for a sphere collider (`ContactScene6
        .add_sphere`)."""
        debug_assert(not self.in_flight, "Runtime: spawn while a step is in flight (begin_advance without finish)")
        var id = self.scene.add_sphere(b^, r, is_static)
        return self._spawn_entity(id)

    def _spawn_entity(mut self, id: BodyId) -> Entity:
        var e = self.world.spawn()
        self.world.set(e, RigidBodyRef(id))
        var i = id.index()
        var t = Transform.at(self.scene.bset.bodies[i].position())
        t = t.with_rotation(self.scene.bset.bodies[i].rotation())
        self.world.set(e, t)
        return e

    def _capture_history(mut self):
        var poses = List[PoseQT](capacity=len(self.scene.bset.bodies))
        for i in range(len(self.scene.bset.bodies)):
            poses.append(PoseQT(self.scene.bset.bodies[i].position(), self.scene.bset.bodies[i].rotation()))
        self.history.capture(poses)

    def render_pose[I: PoseInterpolator = DqNlerp](
        self, e: Entity, extrapolate: Bool = False
    ) raises -> PoseQT:
        """Entity `e`'s pose for drawing this frame: `loop.alpha` of the way
        from the previous tick to the current one (ROADMAP 17.7). Before the
        first tick it is the spawn pose."""
        var i = self.world.get[RigidBodyRef](e).id.index()
        if i >= len(self.history.curr):
            return PoseQT(self.scene.bset.bodies[i].position(), self.scene.bset.bodies[i].rotation())
        return self.history.sample[I](i, Real(self.loop.alpha), extrapolate)

    def teleport(mut self, e: Entity, p: Vec3) raises:
        """Move `e`'s body to `p` and suppress interpolation across the jump."""
        if self.in_flight:
            raise Error("Runtime: scene changed while a step is in flight (begin_advance without finish)")
        var r = self.world.get[RigidBodyRef](e)
        var i = r.id.index()
        self.scene.teleport(r.id, Pose6(p, self.scene.bset.bodies[i].rotation()))
        self.history.mark_teleport(i)

    # ---- per-body parameters (ROADMAP 17.48): thin forwards by entity ----

    def body_of(self, e: Entity) -> BodyId:
        """`e`'s scene body. Setters below refuse while a step is in flight."""
        return self.world.get[RigidBodyRef](e).id

    def _edit(mut self, e: Entity) raises -> BodyId:
        if self.in_flight:
            raise Error("Runtime: scene changed while a step is in flight (begin_advance without finish)")
        return self.body_of(e)

    def add_force(mut self, e: Entity, f: Vec3, mode: Int = FORCE_MODE_FORCE) raises:
        self.scene.add_force(self._edit(e), f, mode)

    def add_force_at(mut self, e: Entity, f: Vec3, at: Vec3, mode: Int = FORCE_MODE_FORCE) raises:
        self.scene.add_force_at(self._edit(e), f, at, mode)

    def add_torque(mut self, e: Entity, t: Vec3) raises:
        self.scene.add_torque(self._edit(e), t)

    def apply_impulse(mut self, e: Entity, j: Vec3, at: Vec3) raises:
        self.scene.apply_impulse(self._edit(e), j, at)

    def set_damping(mut self, e: Entity, linear: Real, angular: Real) raises:
        self.scene.set_damping(self._edit(e), linear, angular)

    def set_gravity_scale(mut self, e: Entity, scale: Real) raises:
        self.scene.set_gravity_scale(self._edit(e), scale)

    def set_axis_locks(
        mut self, e: Entity, lx: Bool, ly: Bool, lz: Bool, ax: Bool, ay: Bool, az: Bool
    ) raises:
        self.scene.set_axis_locks(self._edit(e), lx, ly, lz, ax, ay, az)

    def set_max_velocity(mut self, e: Entity, linear: Real, angular: Real) raises:
        self.scene.set_max_velocity(self._edit(e), linear, angular)

    def set_sleep_thresholds(mut self, e: Entity, linear: Real, angular: Real) raises:
        self.scene.set_sleep_thresholds(self._edit(e), linear, angular)

    def set_mass(mut self, e: Entity, mass: Real) raises:
        self.scene.set_mass(self._edit(e), mass)

    def set_mass_from_density(mut self, e: Entity, density: Real) raises:
        self.scene.set_mass_from_density(self._edit(e), density)

    def velocity(self, e: Entity) raises -> Vec3:
        return self.scene.velocity(self.body_of(e))

    def angular_velocity(self, e: Entity) raises -> Vec3:
        return self.scene.angular_velocity(self.body_of(e))

    def despawn(mut self, e: Entity) raises:
        """Remove both halves: the scene body (`ContactScene6.remove_body`,
        ROADMAP 17.0i -- tombstones the `BodySet` slot, drops it from the
        warm-start cache, raises if a joint still references it) and the
        entity (`World.despawn`). A `RigidBodyRef`-less entity (never
        spawned through `spawn_body`/`spawn_sphere`) just despawns from the
        world -- not every entity a gameplay `World` holds need be a rigid
        body."""
        if self.in_flight:
            raise Error("Runtime: scene changed while a step is in flight (begin_advance without finish)")
        if self.world.has[RigidBodyRef](e):
            var r = self.world.get[RigidBodyRef](e)
            if self.scene.bset.is_valid(r.id):
                self.scene.remove_body(r.id)
        self.world.despawn(e)

    def carry_to(mut self, e: Entity, mut dst: Self) raises -> Entity:
        """Move a dynamic body to another runtime (ROADMAP 17.72: the player
        carried into the next level): the body value (pose, velocities,
        mass) and its collider (box or sphere) are added to `dst` with the
        per-body settings a game sets -- damping, gravity scale, velocity
        caps, axis locks, friction (kinetic, static, combine mode),
        restitution (and its combine mode) -- and the body and entity
        leave this runtime. Returns the entity in `dst`. Other components
        on `e` are the caller's to move (a world's component set is its
        own). Raises for an entity that is not a live rigid body here, for
        static bodies and for other collider kinds."""
        if not self.world.is_alive(e) or not self.world.has[RigidBodyRef](e):
            raise Error("Runtime.carry_to: not a live rigid-body entity of this runtime")
        var id = self.body_of(e)
        var i = id.index()
        if self.scene.bset.is_static(i):
            raise Error("Runtime.carry_to: static bodies stay with their level")
        var kind = self.scene.colliders.shape[i]
        var half = self.scene.colliders.half[i]
        var body = self.scene.bset.bodies[i].copy()
        var out: Entity
        match kind:
            case == SHAPE_BOX:
                out = dst.spawn_body(body^, half, False)
            case == SHAPE_SPHERE:
                out = dst.spawn_sphere(body^, half[0], False)
            case _:
                raise Error("Runtime.carry_to: only box and sphere bodies are carried")
        ref bs = self.scene.bset
        var j = dst.body_of(out).index()
        dst.set_damping(out, bs.lin_damping[i], bs.ang_damping[i])
        dst.set_gravity_scale(out, bs.gravity_scale[i])
        dst.set_max_velocity(out, bs.max_lin[i], bs.max_ang[i])
        var lk = bs.locks[i]
        dst.set_axis_locks(out, lk & 1 != 0, lk & 2 != 0, lk & 4 != 0, lk & 8 != 0, lk & 16 != 0, lk & 32 != 0)
        # raw copies: a negative friction is the "never set" sentinel, which
        # `set_friction` refuses; combine modes and static friction go along
        dst.scene.bset.friction[j] = bs.friction[i]
        dst.scene.bset.static_friction[j] = bs.static_friction[i]
        dst.scene.bset.friction_combine[j] = bs.friction_combine[i]
        dst.scene.set_restitution(j, bs.restitution[i])
        dst.scene.bset.restitution_combine[j] = bs.restitution_combine[i]
        self.despawn(e)
        return out

    # --------------------------------------------------------------- update

    def advance(mut self, frame_dt: Float64) raises -> Float64:
        """Accumulate `frame_dt`, run as many fixed ticks as owed (capped by
        `loop.max_steps`), return the leftover `alpha` in `[0, 1)` for
        render-time interpolation (ROADMAP 17.7).

        Deliberately does NOT call `FixedLoop.advance[S: Scheduler](...)`:
        that method drives a `scheduler.scheduler.Scheduler` over a SINGLE
        `World[S.B]`, with no way for a registered `System.apply[B](mut
        world)` (a stateless, backend-generic static method) to also reach a
        `ContactScene6`, a gravity vector, and a `SolverConfig` -- exactly
        the gap this whole design note exists to close (module docstring).
        This method instead runs `FixedLoop`'s own accumulate/clamp/alpha
        algorithm inline against `self.loop`'s fields, substituting "tick
        the scene, publish events, sync poses" for "tick the scheduler" --
        same contract (`GAMELOOP_DEBT_DROPPED` counted on the same clamp,
        `alpha` in the same range), different per-tick body."""
        debug_assert(self.loop.dt > 0, "Runtime.advance: loop.dt must be > 0")
        if self.in_flight:
            raise Error("Runtime.advance: a begin_advance step is still in flight")
        self.loop.accumulator += frame_dt
        # Age the event double buffer once per FRAME, not per fixed tick: a
        # frame that runs several ticks must still deliver the first tick's
        # events to readers that read once per frame.
        self._begin_frame()
        var steps = 0
        while self.loop.accumulator >= self.loop.dt and steps < self.loop.max_steps:
            self._tick()
            self.loop.accumulator -= self.loop.dt
            steps += 1
        return self._finish_frame()

    def advance_with[*Systems: DeclaredSystem](
        mut self, frame_dt: Float64, mut sched: JobGraphScheduler[Self.B, *Systems]
    ) raises -> Float64:
        """`advance` plus user systems (ROADMAP 17.77): after each fixed
        tick's physics step, event publishing and transform sync, `sched`
        ticks the world once, so a system sees this tick's poses. The order
        among the systems is `JobGraphScheduler`'s (derived from their
        declared reads / writes; `sched.parallel` runs a level's systems on
        workers, bit-identical to serial). Systems are stateless statics;
        state that must persist between ticks lives in world resources
        (`World.set_resource` / `resource`), declared in the masks by the
        resource component's ID like any other component."""
        debug_assert(self.loop.dt > 0, "Runtime.advance_with: loop.dt must be > 0")
        if self.in_flight:
            raise Error("Runtime.advance_with: a begin_advance step is still in flight")
        self.loop.accumulator += frame_dt
        self._begin_frame()
        var steps = 0
        while self.loop.accumulator >= self.loop.dt and steps < self.loop.max_steps:
            self._tick()
            sched.tick(self.world)
            self.loop.accumulator -= self.loop.dt
            steps += 1
        return self._finish_frame()

    def begin_advance(mut self, frame_dt: Float64) raises -> StepHandle:
        """First half of a non-blocking `advance` (ROADMAP 17.75, PhysX
        `simulate` / `fetchResults` shape): the accumulator work and the
        event-buffer ageing `advance` does up front, plus a copy of the last
        completed tick's poses into `published` for the host to read while
        the step runs. The owed ticks are counted here and run by
        `execute(handle)` -- which a host may call on a worker thread --
        and `finish(handle)` returns the interpolation alpha. The three
        calls produce the same world, history and alpha as `advance`.

        Raises when a previous step was begun and not finished."""
        debug_assert(self.loop.dt > 0, "Runtime.begin_advance: loop.dt must be > 0")
        if self.in_flight:
            raise Error("Runtime.begin_advance: the previous step was not finished")
        self.loop.accumulator += frame_dt
        self._begin_frame()
        var ticks = 0
        while self.loop.accumulator >= self.loop.dt and ticks < self.loop.max_steps:
            self.loop.accumulator -= self.loop.dt
            ticks += 1
        self.published = self.history.curr.copy()
        self.serial += 1
        self.in_flight = True
        self.executed = False
        return StepHandle(ticks, self.serial)

    def execute(mut self, h: StepHandle) raises:
        """Run the fixed ticks `h` owes. Callable from any one thread; the
        host must not touch the scene or this runtime from another thread
        until it returns."""
        if not self.in_flight or h.serial != self.serial:
            raise Error("Runtime.execute: handle does not belong to the step in flight")
        if self.executed:
            raise Error("Runtime.execute: this step was already executed")
        for _ in range(h.ticks):
            self._tick()
        self.executed = True

    def finish(mut self, h: StepHandle) raises -> Float64:
        """Second half: close the frame and return `alpha` in [0, 1).
        Raises for a handle that is not the step in flight, a step not yet
        executed, or a second `finish`."""
        if not self.in_flight or h.serial != self.serial:
            raise Error("Runtime.finish: handle does not belong to the step in flight")
        if not self.executed:
            raise Error("Runtime.finish: execute(handle) has not run")
        self.in_flight = False
        return self._finish_frame()

    def advance_coupled[P: CouplingPort](mut self, frame_dt: Float64, mut port: P, mut solver: P.S) raises -> Float64:
        """`advance` with a continuum solver coupled to the scene (ROADMAP
        17.55): each fixed tick runs `port.before`, the solver's checked
        step (`step_checked`, counted in the scene's counters),
        `port.after`, then the rigid tick (events, transform sync,
        history) -- the order `physics.coupling.couple_step` fixes."""
        debug_assert(self.loop.dt > 0, "Runtime.advance_coupled: loop.dt must be > 0")
        if self.in_flight:
            raise Error("Runtime.advance_coupled: a begin_advance step is still in flight")
        self.loop.accumulator += frame_dt
        self._begin_frame()
        var steps = 0
        var dt = Real(self.loop.dt)
        while self.loop.accumulator >= self.loop.dt and steps < self.loop.max_steps:
            port.before(self.scene, solver, dt, self.gravity)
            _ = step_checked(solver, dt, self.gravity, self.scene.counters)
            port.after(self.scene, solver, dt, self.gravity)
            self._tick()
            self.loop.accumulator -= self.loop.dt
            steps += 1
        return self._finish_frame()

    def advance_budgeted(mut self, frame_dt: Float64, mut budget: SimBudget) raises -> Float64:
        """`advance` under a step-time budget (ROADMAP 17.79): before each
        fixed tick `budget` sets `cfg.iters` / `cfg.substeps`, and the
        tick's measured wall time is fed back (`SimBudget.update`: above
        110 % of the target it drops an iteration, then a substep; below
        70 % it restores them). The rest of the tick is `advance`'s."""
        debug_assert(self.loop.dt > 0, "Runtime.advance_budgeted: loop.dt must be > 0")
        if self.in_flight:
            raise Error("Runtime.advance_budgeted: a begin_advance step is still in flight")
        self.loop.accumulator += frame_dt
        self._begin_frame()
        var steps = 0
        while self.loop.accumulator >= self.loop.dt and steps < self.loop.max_steps:
            budget.apply(self.cfg)
            var t0 = Int(perf_counter_ns())
            self._tick()
            budget.update(Int(perf_counter_ns()) - t0)
            self.loop.accumulator -= self.loop.dt
            steps += 1
        return self._finish_frame()

    def advance_tiered[P: TierPolicy](
        mut self, frame_dt: Float64, mut policy: P, observers: List[Vec3]
    ) raises -> Float64:
        """`advance` with tiered simulation (ROADMAP 17.85): before every
        fixed tick `policy` assigns a tier per body from the observers and
        the scene's step index, and the scene solves each island at its
        tier (`ContactScene6.set_tier_table` must have been called). The
        rest of the tick -- timers, events, transform sync, interpolation
        history -- is `advance`'s."""
        debug_assert(self.loop.dt > 0, "Runtime.advance_tiered: loop.dt must be > 0")
        self.loop.accumulator += frame_dt
        self._begin_frame()
        var steps = 0
        while self.loop.accumulator >= self.loop.dt and steps < self.loop.max_steps:
            self.scene.set_body_tiers(policy.assign(self.scene, observers, self.scene.step_index))
            self._tick()
            self.loop.accumulator -= self.loop.dt
            steps += 1
        return self._finish_frame()

    def sync_tier_tags[NT: Int, BASE: Int](mut self):
        """ROADMAP 17.85: tag every body entity with `Tier[t, BASE]` for its
        scene tier t (`scene.tier_of`; tier 0 when no plan covers it) and
        drop its other `Tier[k, BASE]` tags, k < NT. Call after
        `advance_tiered`; the backend's pack must hold the NT tag types.
        An entity whose tier did not change is not written."""
        var es = self.world.query1[RigidBodyRef]()
        for e in es:
            var slot = self.world.get[RigidBodyRef](e).id.index()
            var t = self.scene.tier_of[slot] if slot < len(self.scene.tier_of) else 0
            comptime for k in range(NT):
                if k == t:
                    if not self.world.has[Tier[k, BASE]](e):
                        self.world.set(e, Tier[k, BASE]())
                elif self.world.has[Tier[k, BASE]](e):
                    self.world.remove[Tier[k, BASE]](e)

    def runs(self, what: Int) -> Bool:
        """Whether the flow state lets `what` (a `TICK_*` bit) tick."""
        return self.flow.depth() == 0 or self.flow.ticks(what)

    def _tick(mut self) raises:
        if self.runs(TICK_TIMERS):
            var fired = List[TimerFire]()
            self.timers.advance(1, fired)
            for f in fired:
                if len(self.fired) < self.fired_capacity:
                    self.fired.append(f)
                else:
                    self.loop.counters.incr(TIMER_FIRES_DROPPED)
            if self.rules_on:
                self.rules.step(self.actors)
        if not self.runs(TICK_SIM):
            return
        self.scene.step(Real(self.loop.dt), self.gravity, self.cfg)
        if self.runs(TICK_EVENTS):
            for i in range(len(self.scene.events)):
                self.events.send(self.scene.events[i].copy())
        self._sync_transforms()
        self._capture_history()

    def _begin_frame(mut self):
        self.events.update()
        for e in self.inbox.take(self.scene.step_index):
            self.config[e.key] = e.value

    def take_fired(mut self) -> List[TimerFire]:
        """The timer fires since the last call, in firing order (tick, then
        the timer queue's order within a tick). Not taken, they pile up to
        `fired_capacity`; past it the newest are dropped and counted in
        `TIMER_FIRES_DROPPED`."""
        var out = self.fired^
        self.fired = List[TimerFire]()
        return out^

    def take_ops(mut self) -> List[OutRecord]:
        var out = self.ops^
        self.ops = List[OutRecord]()
        return out^

    def _finish_frame(mut self) -> Float64:
        for r in self.outbox.drain():
            if len(self.ops) < self.outbox.capacity:
                self.ops.append(r)
            else:
                self.outbox.dropped += 1
        var d = self.outbox.take_dropped()
        if d > 0:
            self.loop.counters.incr(OUTBOX_DROPPED, Int64(d))
        if self.loop.accumulator >= self.loop.dt:
            # audit E22/F16's drop, replicated (FixedLoop.advance's own
            # docstring has the full reasoning): a frame-rate spike clamped
            # by `max_steps` with time still owed drops the excess rather
            # than carrying it, so `alpha` stays in [0, 1) instead of
            # drifting unbounded.
            self.loop.counters.incr(GAMELOOP_DEBT_DROPPED)
            self.loop.accumulator = 0
        self.loop.alpha = self.loop.accumulator / self.loop.dt
        return self.loop.alpha

    def _sync_transforms(mut self):
        """One system: reads `BodySet` (through `scene.bset`), writes
        `ecs.transform.Transform` for every entity carrying both it and
        `RigidBodyRef` -- the zero-allocation `World.for_each2` path (no
        `List[Entity]`), same as every other per-frame ECS pass in this
        engine.

        `for_each2`'s closure cannot borrow `self.scene.bset` directly while
        `self.world.for_each2` also borrows `self.world` mutably (both
        derive from the same `mut self` receiver, so the compiler rejects it
        as aliasing even though the two fields are disjoint) -- so the pose
        data this tick needs (position, rotation, and enough of `BodySet
        .is_valid`'s check to skip a stale `RigidBodyRef`: the slot's own
        current generation, and whether it is live at all) is copied into
        three plain `List`s first, and the closure captures THOSE instead.
        Cost is O(bodies) positions/rotations copied once per tick, already
        paid for by `write_state`-style snapshots elsewhere in this engine."""
        var n = len(self.scene.bset.bodies)
        var pos = List[Vec3](capacity=n)
        var rot = List[Quat](capacity=n)
        var live = List[Bool](capacity=n)
        var gens = List[UInt32](capacity=n)
        for i in range(n):
            pos.append(self.scene.bset.bodies[i].position())
            rot.append(self.scene.bset.bodies[i].rotation())
            live.append(not self.scene.bset.is_removed(i))
            gens.append(self.scene.bset.generation[i])

        def sync_pose(mut t: Transform, r: RigidBodyRef) {imm pos, imm rot, imm live, imm gens}:
            var i = r.id.index()
            if i < 0 or i >= len(live) or gens[i] != r.id.gen or not live[i]:
                return  # stale RigidBodyRef (despawned/out of range): leave the transform alone
            t.translation = pos[i]
            t.rotation = rot[i]
            t.local_dirty = True
            t.world_dirty = True

        self.world.for_each2[Transform, RigidBodyRef](sync_pose)
