"""Six-DOF rigid-body dynamics: quat+inertia-tensor baseline vs motor/screw.

Two parity-equivalent representations of the same physics (Newton-Euler with
gyroscopic term), compared BY ACTION on points, never by coefficients:

  * `QuatBody6` — the classical path: world-frame ω, inertia rotated
    `I_w = R I_b Rᵀ`, quaternion advanced by the axis-angle exponential.
  * `ScrewBody6` — the GA path: pose is a `Motor3`, velocity is a body-frame
    twist bivector (`Screw3`, half-angle factors folded as in
    `physics/screw.mojo`). The Euler equations run in the principal body frame
    (Lie–Poisson form: `I ω̇ = τ_b − ω × I ω`, `v̇_b = f_b/m − ω × v_b`), and
    the pose advances by the closed-form motor exponential — rotation and
    translation in one uniform screw, no quaternion drift.

Forques and impulses: `step(dt, force, torque)` takes world-frame force/torque
("forque" split into components at the seam boundary); `apply_impulse(j, at)`
converts a world impulse at a world point into velocity deltas through the
inverse inertia — on the screw side that is exactly `ΔV = I⁻¹[r_b × j_b]`
packed back into the twist bivector.

Both bodies share `Inertia3` (mass + principal diagonal). Parity gates live in
`tests/test_rigid6.mojo`.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, cross
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import Screw3, exp_screw3
from .screw import screw_velocity


@fieldwise_init
struct Pose6(Copyable, ImplicitlyCopyable, Movable):
    """A representation-agnostic target pose (ROADMAP 17.24/17.25):
    `ContactScene6.move_to`/`teleport` take one of these rather than a
    `Quat`+`Vec3` pair or a `Motor3`, so callers never need to know which
    `Body6` the scene was built with. `Body6.set_pose` unpacks it into
    whichever representation the concrete body uses."""

    var pos: Vec3
    var rot: Quat


@fieldwise_init
struct Inertia3(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Mass plus principal (body-frame diagonal) rotational inertia."""

    var mass: Real
    var ix: Real
    var iy: Real
    var iz: Real

    @staticmethod
    def box(mass: Real, hx: Real, hy: Real, hz: Real) -> Self:
        # Solid box, half-extents h: I = (m/3)(h_j² + h_k²) per axis.
        var k = mass / 3
        return Self(
            mass,
            k * (hy * hy + hz * hz),
            k * (hx * hx + hz * hz),
            k * (hx * hx + hy * hy),
        )

    @staticmethod
    def sphere(mass: Real, r: Real) -> Self:
        var i = 0.4 * mass * r * r
        return Self(mass, i, i, i)

    @staticmethod
    @no_inline  # one compiled copy: inlined with literal arguments, the sums fold without FMA while a caller with run-time
    # arguments (the C-ABI library) fuses them on FMA targets, and the inertia differs by 1 ulp (17.96; test_capi 0.8)
    def capsule(mass: Real, r: Real, hl: Real) -> Self:
        """Solid capsule, axis = local Y (cylinder + two hemispheres; the
        standard engine formula, mass split by volume)."""
        var cyl_h = 2 * hl
        var mcyl = mass * cyl_h / (cyl_h + r * Real(4.0 / 3.0))
        var msph = mass - mcyl
        var iy = r * r * (0.5 * mcyl + 0.4 * msph)
        var ixz = mcyl * (hl * hl / 3 + r * r / 4) + msph * (
            0.4 * r * r + hl * hl + 0.75 * hl * r
        )
        return Self(mass, ixz, iy, ixz)

    @staticmethod
    def cylinder(mass: Real, r: Real, hl: Real) -> Self:
        """Solid cylinder, axis = local Y, radius r, half length hl
        (ROADMAP 17.52)."""
        var iy = mass * r * r / 2
        var ixz = mass * (3 * r * r + 4 * hl * hl) / 12
        return Self(mass, ixz, iy, ixz)

    @staticmethod
    def ellipsoid(mass: Real, a: Real, b: Real, c: Real) -> Self:
        """Solid ellipsoid with semi-axes a, b, c along local x, y, z
        (ROADMAP 17.52)."""
        return Self(mass, mass * (b * b + c * c) / 5, mass * (a * a + c * c) / 5, mass * (a * a + b * b) / 5)

    def apply(self, w: Vec3) -> Vec3:
        """Body-frame angular momentum L = I ω."""
        return Vec3(w[0] * self.ix, w[1] * self.iy, w[2] * self.iz, 0)

    def apply_inv(self, l: Vec3) -> Vec3:
        return Vec3(l[0] / self.ix, l[1] / self.iy, l[2] / self.iz, 0)

    def validated(self) raises -> Self:
        """Raise if this is not a usable DYNAMIC inertia (audit E1/E2):
        `mass <= 0` makes `inv_mass()` return `inf`/`UB`-adjacent garbage,
        and a zero/negative principal moment makes `apply_inv` divide by
        zero -- both turn into a NaN pose within one integration step
        (`ContactScene6.add`'s docstring has the exact propagation).

        A static or kinematic body's `Inertia3` is never dereferenced by
        the solver (`BodySet.is_dynamic`'s gate gets there first), so this
        is an opt-in check for the caller building a DYNAMIC body from
        untrusted input, not something every `Inertia3` construction pays
        for -- same "validate-once object" shape as `SolverConfig
        .validated()`, for the same reason: `ContactScene6.add`/`add_sphere`/
        `add_capsule`/`add_hull` are ~100-call-site APIs, so they
        `debug_assert` this instead of raising themselves."""
        if self.mass <= 0:
            raise Error("Inertia3.validated: mass must be > 0")
        if self.ix <= 0 or self.iy <= 0 or self.iz <= 0:
            raise Error(
                "Inertia3.validated: principal moments must all be > 0"
            )
        return self


@fieldwise_init
struct InvInertiaW(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """World-frame inverse inertia `R diag(1/ix, 1/iy, 1/iz) Rᵀ`, stored as its
    three rows (the matrix is symmetric, so rows = columns). ROADMAP 17.100
    item 1: built once per pose change, it replaces the two quaternion
    rotations `apply_impulse` does per impulse with one 3 × 3 product."""

    var r0: Vec3
    var r1: Vec3
    var r2: Vec3

    @staticmethod
    def zero() -> Self:
        return Self(Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))

    @staticmethod
    def of(q: Quat, i: Inertia3) -> Self:
        var x = q.x
        var y = q.y
        var z = q.z
        var w = q.w
        var a0 = Vec3(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y), 0)
        var a1 = Vec3(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x), 0)
        var a2 = Vec3(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y), 0)
        var d = Vec3(1 / i.ix, 1 / i.iy, 1 / i.iz, 0)
        var d0 = a0 * d
        var d1 = a1 * d
        var d2 = a2 * d
        return Self(
            Vec3(dot(d0, a0), dot(d0, a1), dot(d0, a2), 0),
            Vec3(dot(d1, a0), dot(d1, a1), dot(d1, a2), 0),
            Vec3(dot(d2, a0), dot(d2, a1), dot(d2, a2), 0),
        )

    @always_inline
    def apply(self, v: Vec3) -> Vec3:
        return Vec3(dot(self.r0, v), dot(self.r1, v), dot(self.r2, v), 0)


trait Body6(Copyable, Movable, Deinitable):
    """What a 6-DOF contact solver needs from a body, representation-agnostic:
    world-point velocities, impulse response, and the normal-direction
    effective-mass term `n·((I⁻¹(r×n))×r)`. Both representations conform, so
    the solver seam is swappable and parity-testable."""

    def inv_mass(self) -> Real: ...
    def position(self) -> Vec3: ...
    def velocity_at(self, at: Vec3) -> Vec3: ...
    def apply_impulse(mut self, j: Vec3, at: Vec3): ...
    def angular_factor(self, r: Vec3, n: Vec3) -> Real: ...
    def integrate_force(mut self, dt: Real, force: Vec3, torque: Vec3): ...
    def integrate_pose(mut self, dt: Real): ...
    def act(self, p: Vec3) -> Vec3: ...
    def to_local(self, p: Vec3) -> Vec3: ...
    def omega_world(self) -> Vec3: ...
    def apply_angular_impulse(mut self, l: Vec3): ...
    def angular_only_factor(self, n: Vec3) -> Real: ...
    def linear_velocity(self) -> Vec3: ...
    def halt(mut self): ...
    # ROADMAP 17.24/17.25 additions below. `rotation`: orientation as a
    # `Quat` regardless of storage (a `ScrewBody6` has no quaternion field --
    # it derives one from its `Motor3`); `move_to` needs a representation-
    # agnostic orientation to compute an angular velocity from a pose delta.
    # `set_pose`: instantly overwrite position + orientation, velocity
    # untouched (`ContactScene6.teleport`, and the pose half of `move_to`,
    # which follows it with a `set_velocity` computed from the delta).
    # `set_velocity`: overwrite linear/angular velocity (world frame), pose
    # untouched -- a kinematic platform's velocity is entirely caller-driven,
    # never solver-derived.
    def rotation(self) -> Quat: ...
    def set_pose(mut self, p: Pose6): ...
    def set_velocity(mut self, v: Vec3, w: Vec3): ...
    # ROADMAP 17.0h: representation-agnostic access to the body's mass/
    # inertia, so `ContactScene6.add`/`add_sphere`/`add_capsule`/`add_hull`
    # can `debug_assert` a dynamic body's `Inertia3` is usable (audit E1/E2)
    # without knowing which concrete `Body6` they were handed. Named
    # `get_inertia`, not `inertia`: both concrete bodies already have a
    # field called `inertia`, and a struct cannot have a field and a method
    # share one name.
    def get_inertia(self) -> Inertia3: ...
    # ROADMAP 17.48: replace mass / principal inertia (`ContactScene6
    # .set_mass` / `set_inertia`); velocities and pose untouched.
    def set_inertia(mut self, i: Inertia3): ...
    # ROADMAP 17.100 item 1: impulse response through a world inverse inertia
    # the caller built at the current pose (`InvInertiaW.of(rotation(),
    # get_inertia())`). A body may ignore `iw` and use its own path.
    def apply_impulse_iw(mut self, j: Vec3, at: Vec3, iw: InvInertiaW): ...
    def apply_angular_impulse_iw(mut self, l: Vec3, iw: InvInertiaW): ...


@fieldwise_init
struct QuatBody6(
    Body6, Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Classical 6-DOF body: world-frame linear + angular velocity."""

    var pos: Vec3
    var q: Quat
    var vel: Vec3
    var omega: Vec3  # world frame
    var inertia: Inertia3

    @staticmethod
    def at_rest(pos: Vec3, inertia: Inertia3) -> Self:
        return Self(pos, Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), inertia)

    def angular_momentum(self) -> Vec3:
        """World-frame L = R I_b Rᵀ ω (conserved when torque-free)."""
        return self.q.rotate(self.inertia.apply(self.q.conjugate().rotate(self.omega)))

    def kinetic_energy(self) -> Real:
        var wb = self.q.conjugate().rotate(self.omega)
        var lb = self.inertia.apply(wb)
        var rot = (wb[0] * lb[0] + wb[1] * lb[1] + wb[2] * lb[2]) * 0.5
        var v2 = self.vel[0] * self.vel[0] + self.vel[1] * self.vel[1] + self.vel[2] * self.vel[2]
        return rot + self.inertia.mass * v2 * 0.5

    def apply_impulse(mut self, j: Vec3, at: Vec3):
        self.vel = self.vel + j / self.inertia.mass
        var dl = cross(at - self.pos, j)  # world angular impulse
        var dwb = self.inertia.apply_inv(self.q.conjugate().rotate(dl))
        self.omega = self.omega + self.q.rotate(dwb)

    def inv_mass(self) -> Real:
        return 1 / self.inertia.mass

    def position(self) -> Vec3:
        return self.pos

    def velocity_at(self, at: Vec3) -> Vec3:
        return self.vel + cross(self.omega, at - self.pos)

    def angular_factor(self, r: Vec3, n: Vec3) -> Real:
        var u = self.q.rotate(
            self.inertia.apply_inv(self.q.conjugate().rotate(cross(r, n)))
        )
        return dot(n, cross(u, r))

    def integrate_force(mut self, dt: Real, force: Vec3, torque: Vec3):
        # Euler equations in the world frame: ω̇ = I_w⁻¹(τ − ω × I_w ω).
        var gyro = torque - cross(self.omega, self.angular_momentum())
        var dwb = self.inertia.apply_inv(self.q.conjugate().rotate(gyro))
        self.omega = self.omega + self.q.rotate(dwb) * dt
        self.vel = self.vel + force * (dt / self.inertia.mass)

    def integrate_pose(mut self, dt: Real):
        self.pos = self.pos + self.vel * dt
        # Exact rotation exponential for the step's (now constant) world ω.
        var wlen = sqrt(
            self.omega[0] * self.omega[0]
            + self.omega[1] * self.omega[1]
            + self.omega[2] * self.omega[2]
        )
        if wlen > Real(1e-12):
            var axis = self.omega / wlen
            self.q = (Quat.from_axis_angle(axis, wlen * dt) * self.q).normalized()

    def step(mut self, dt: Real, force: Vec3, torque: Vec3):
        self.integrate_force(dt, force, torque)
        self.integrate_pose(dt)

    def act(self, p: Vec3) -> Vec3:
        """Body-frame point -> world (compare representations BY ACTION)."""
        return self.q.rotate(p) + self.pos

    def to_local(self, p: Vec3) -> Vec3:
        return self.q.conjugate().rotate(p - self.pos)

    def omega_world(self) -> Vec3:
        return self.omega

    def apply_angular_impulse(mut self, l: Vec3):
        var dwb = self.inertia.apply_inv(self.q.conjugate().rotate(l))
        self.omega = self.omega + self.q.rotate(dwb)

    def angular_only_factor(self, n: Vec3) -> Real:
        var u = self.q.rotate(
            self.inertia.apply_inv(self.q.conjugate().rotate(n))
        )
        return dot(n, u)

    def linear_velocity(self) -> Vec3:
        return self.vel

    def halt(mut self):
        self.vel = Vec3(0, 0, 0, 0)
        self.omega = Vec3(0, 0, 0, 0)

    def rotation(self) -> Quat:
        return self.q

    def set_pose(mut self, p: Pose6):
        self.pos = p.pos
        self.q = p.rot

    def set_velocity(mut self, v: Vec3, w: Vec3):
        self.vel = v
        self.omega = w

    def get_inertia(self) -> Inertia3:
        return self.inertia

    def set_inertia(mut self, i: Inertia3):
        self.inertia = i

    def apply_impulse_iw(mut self, j: Vec3, at: Vec3, iw: InvInertiaW):
        self.vel = self.vel + j / self.inertia.mass
        self.omega = self.omega + iw.apply(cross(at - self.pos, j))

    def apply_angular_impulse_iw(mut self, l: Vec3, iw: InvInertiaW):
        self.omega = self.omega + iw.apply(l)


@fieldwise_init
struct ScrewBody6(
    Body6, Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """GA 6-DOF body: `Motor3` pose + body-frame twist bivector velocity."""

    var pose: Motor3
    var vel: Screw3  # body twist, half factors folded (see screw_velocity)
    var inertia: Inertia3

    @staticmethod
    def at_rest(pos: Vec3, inertia: Inertia3) -> Self:
        return Self(Motor3.from_translation(pos), Screw3.zero(), inertia)

    def omega_body(self) -> Vec3:
        """Unpack ω from the twist (inverse of `screw_velocity`)."""
        return Vec3(-2 * self.vel.b23, 2 * self.vel.b13, -2 * self.vel.b12, 0)

    def vel_body(self) -> Vec3:
        return Vec3(2 * self.vel.b10, 2 * self.vel.b20, 2 * self.vel.b30, 0)

    def _rotation(self) -> Quat:
        return self.pose.to_quat_translation()[0]

    def position(self) -> Vec3:
        return self.pose.apply_point(Vec3(0, 0, 0, 0))

    def angular_momentum(self) -> Vec3:
        """World-frame L (conserved when torque-free) — for gates only."""
        return self._rotation().rotate(self.inertia.apply(self.omega_body()))

    def kinetic_energy(self) -> Real:
        var wb = self.omega_body()
        var lb = self.inertia.apply(wb)
        var vb = self.vel_body()
        var v2 = vb[0] * vb[0] + vb[1] * vb[1] + vb[2] * vb[2]
        return (wb[0] * lb[0] + wb[1] * lb[1] + wb[2] * lb[2]) * 0.5 + (
            self.inertia.mass * v2 * 0.5
        )

    def apply_impulse(mut self, j: Vec3, at: Vec3):
        """World impulse at a world point -> twist delta via I⁻¹ (screw form)."""
        var q = self._rotation()
        var jb = q.conjugate().rotate(j)
        var rb = q.conjugate().rotate(at - self.position())
        var wb = self.omega_body() + self.inertia.apply_inv(cross(rb, jb))
        var vb = self.vel_body() + jb / self.inertia.mass
        self.vel = screw_velocity(wb, vb)

    def inv_mass(self) -> Real:
        return 1 / self.inertia.mass

    def velocity_at(self, at: Vec3) -> Vec3:
        var q = self._rotation()
        var rb = q.conjugate().rotate(at - self.position())
        return q.rotate(self.vel_body() + cross(self.omega_body(), rb))

    def angular_factor(self, r: Vec3, n: Vec3) -> Real:
        var q = self._rotation()
        var rb = q.conjugate().rotate(r)
        var nb = q.conjugate().rotate(n)
        var u = self.inertia.apply_inv(cross(rb, nb))
        return dot(nb, cross(u, rb))

    def integrate_force(mut self, dt: Real, force: Vec3, torque: Vec3):
        # Lie–Poisson Euler equations in the principal body frame.
        var q = self._rotation()
        var wb = self.omega_body()
        var vb = self.vel_body()
        var tb = q.conjugate().rotate(torque)
        var fb = q.conjugate().rotate(force)
        var gyro = tb - cross(wb, self.inertia.apply(wb))
        wb = wb + self.inertia.apply_inv(gyro) * dt
        # Body-frame transport of the linear velocity: v̇_b = f_b/m − ω × v_b.
        vb = vb + (fb / self.inertia.mass - cross(wb, vb)) * dt
        self.vel = screw_velocity(wb, vb)

    def integrate_pose(mut self, dt: Real):
        # One uniform screw per step: closed-form motor exponential.
        self.pose = (self.pose * exp_screw3(self.vel.scaled(dt))).normalized()

    def step(mut self, dt: Real, force: Vec3, torque: Vec3):
        self.integrate_force(dt, force, torque)
        self.integrate_pose(dt)

    def act(self, p: Vec3) -> Vec3:
        return self.pose.apply_point(p)

    def to_local(self, p: Vec3) -> Vec3:
        return self.pose.reverse().apply_point(p)

    def omega_world(self) -> Vec3:
        return self._rotation().rotate(self.omega_body())

    def apply_angular_impulse(mut self, l: Vec3):
        var q = self._rotation()
        var wb = self.omega_body() + self.inertia.apply_inv(
            q.conjugate().rotate(l)
        )
        self.vel = screw_velocity(wb, self.vel_body())

    def angular_only_factor(self, n: Vec3) -> Real:
        var q = self._rotation()
        var nb = q.conjugate().rotate(n)
        return dot(nb, self.inertia.apply_inv(nb))

    def linear_velocity(self) -> Vec3:
        return self._rotation().rotate(self.vel_body())

    def halt(mut self):
        self.vel = Screw3.zero()

    def get_inertia(self) -> Inertia3:
        return self.inertia

    def set_inertia(mut self, i: Inertia3):
        self.inertia = i

    def apply_impulse_iw(mut self, j: Vec3, at: Vec3, iw: InvInertiaW):
        """The twist lives in the body frame, so the world matrix saves nothing:
        same result as `apply_impulse`."""
        self.apply_impulse(j, at)

    def apply_angular_impulse_iw(mut self, l: Vec3, iw: InvInertiaW):
        self.apply_angular_impulse(l)

    def rotation(self) -> Quat:
        return self._rotation()

    def set_pose(mut self, p: Pose6):
        self.pose = Motor3.from_quat_translation(p.rot, p.pos).normalized()

    def set_velocity(mut self, v: Vec3, w: Vec3):
        # World-frame v/w -> body-frame twist bivector (same conversion
        # `apply_impulse` already does for a world impulse).
        var q = self._rotation()
        var wb = q.conjugate().rotate(w)
        var vb = q.conjugate().rotate(v)
        self.vel = screw_velocity(wb, vb)
