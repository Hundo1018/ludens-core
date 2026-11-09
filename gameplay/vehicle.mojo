"""Raycast-suspension vehicle on a real `ContactScene6` body (ROADMAP 17.4).

The chassis is an ordinary dynamic box in the contact solver: it collides with
the road, other cars and rigid bodies, it rolls over and sleeps like any other
body. The wheels are NOT bodies. Each step `Vehicle.update`, before the scene
step,

1. asks the world where each wheel meets the road (`WheelCast`, the seam in
   `vehicle_wheel.mojo`: one ray, or a swept sphere / capsule),
2. turns the hub height into a suspension force (spring + two-rate damper +
   bump stop + anti-roll bar) which is the tire's normal load,
3. integrates each wheel's spin from drive torque (engine curve -> gearbox ->
   centre split -> differential), brake torque and rolling resistance,
4. turns the slip between rim and road into a tire force with a friction
   ellipse and a Pacejka-shaped falloff (`vehicle_tire.mojo`), limited so that
   it can never reverse the slip inside one step (no parked-on-a-slope jitter),
5. applies the tire and suspension forces, and aerodynamic drag / downforce, to
   the chassis as impulses at the contact points -- and the opposite impulse to
   the ground body when that is a dynamic rigid body.

Conventions. Chassis local axes: forward +X, up +Y, right +Z. Positive steer
turns toward +Z. Wheel `omega` is positive when the wheel rolls forward. Ground
friction is relative to the solver default 0.5: the tire's `mu` applies on a
0.5 surface, scales linearly with the surface's friction, and a surface of
friction 0 gives no grip at all. The surface's friction is the material
friction of the triangle under the tire when its mesh / heightfield carries
material ids and the scene has a friction for that id
(`ContactScene6.set_material_friction`, ROADMAP 17.53: one terrain mesh with
asphalt and grass), else the ground body's own friction.

Why impulses applied before `step`: the solver owns integration, gravity and
contacts, and applying the vehicle's forces as impulses at the contact points
reuses exactly the `Body6.apply_impulse` every other gameplay system uses. The
chassis is marked never-sleeping (a parked car is cheap anyway, a car that sleeps
while the player holds the throttle is a bug).
"""

from std.math import sqrt, atan, atan2
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3, dot, cross, length, normalize_or
from geometry.quat import Quat
from collision.world_query import QueryFilter
from collision.collider_set import Pose3
from physics.rigid6 import Body6, Pose6, Inertia3, QuatBody6
from physics.body_set import BodyId
from physics.solver6 import ContactScene6
from physics.state_io import StateWriter, StateReader
from diag.counters import VEHICLE_FORCE_DROPPED
from .vehicle_tire import TireModel, solve_axis
from .vehicle_wheel import WheelCast, RayWheel, WheelHit
from .vehicle_drive import (
    DriveConfig,
    TorqueCurve,
    split_axle,
    RAD_S_TO_RPM,
    DIFF_OPEN,
)

comptime _UP = Vec3(0, 1, 0, 0)
comptime _FWD = Vec3(1, 0, 0, 0)
comptime _RIGHT = Vec3(0, 0, 1, 0)
comptime _ZERO = Vec3(0, 0, 0, 0)
comptime _EPS: Real = 1e-6
comptime _REF_MU: Real = 0.5  # the solver's default friction = the tire's nominal surface
comptime _REVERSE_SPEED: Real = 1.0  # m/s below which throttle-back selects reverse


@always_inline
def _finite(v: Vec3) -> Bool:
    return (
        v[0] == v[0] and v[1] == v[1] and v[2] == v[2]
        and abs(v[0]) < 1e18 and abs(v[1]) < 1e18 and abs(v[2]) < 1e18
    )


@always_inline
def _clamp(x: Real, lo: Real, hi: Real) -> Real:
    return lo if x < lo else (hi if x > hi else x)


@always_inline
def _decay(x: Real, d: Real) -> Real:
    """Move `x` toward zero by at most `d` (a brake can stop a wheel, never
    spin it the other way)."""
    if x > d:
        return x - d
    if x < -d:
        return x + d
    return 0


@fieldwise_init
struct VehicleInput(Copyable, ImplicitlyCopyable, Movable):
    """Driver input. throttle in [-1, 1] (negative = brake while rolling forward, reverse
    from a standstill), brake / handbrake in [0, 1], steer in [-1, 1]."""

    var throttle: Real
    var brake: Real
    var steer: Real
    var handbrake: Real

    @staticmethod
    def idle() -> Self:
        return Self(0, 0, 0, 0)


@fieldwise_init
struct WheelConfig(Copyable, ImplicitlyCopyable, Movable):
    var mount: Vec3  # chassis-local top of the suspension
    var radius: Real
    var half_width: Real
    var inertia: Real  # wheel + tire spin inertia
    var axle: Int  # 0 front, 1 rear (differential and anti-roll-bar pairing)
    var steer: Real  # fraction of the steering angle (rear-steer: negative)
    var driven: Bool
    var handbrake: Bool
    var brake_share: Real  # fraction of the maximum brake torque


@fieldwise_init
struct SuspensionConfig(Copyable, ImplicitlyCopyable, Movable):
    var length: Real  # mount-to-hub distance at full droop
    var stiffness: Real  # N/m of compression
    var damp_compress: Real  # N s/m
    var damp_rebound: Real
    var min_length: Real  # bump stop engages below this hub distance
    var bump_stiffness: Real
    var anti_roll: Real  # N/m of left-right compression difference


@fieldwise_init
struct Aero(Copyable, ImplicitlyCopyable, Movable):
    """Aerodynamic body forces: drag `1/2 rho Cd A |v| v` opposite the air-
    relative velocity and downforce `1/2 rho Cl A v^2` along -up, both at the
    centre of mass. `cd` is where the LBM wind tunnel (fluid/, ROADMAP 14.4)
    plugs in: see `vehicle_tunnel.mojo`."""

    var rho: Real
    var cd: Real
    var area: Real  # frontal area, m^2
    var cl: Real  # downforce coefficient (positive pushes the car down)
    var wind: Vec3

    @staticmethod
    def none() -> Self:
        return Self(1.225, 0, 0, 0, _ZERO)

    @staticmethod
    def from_cd(cd: Real, area: Real) -> Self:
        return Self(1.225, cd, area, 0, _ZERO)

    def drag_force(self, v: Vec3) -> Vec3:
        var vr = v - self.wind
        var s = length(vr)
        return vr * (-Real(0.5) * self.rho * self.cd * self.area * s)


struct VehicleConfig(Copyable, Movable):
    var mass: Real
    var inertia: Vec3  # principal moments (x roll, y yaw, z pitch)
    var half: Vec3  # chassis box collider half extents
    var wheels: List[WheelConfig]
    var susp: SuspensionConfig
    var tire: TireModel
    var drive: DriveConfig
    var aero: Aero
    var brake_torque: Real  # per wheel at full brake (times brake_share)
    var handbrake_torque: Real
    var max_steer: Real  # rad at full lock, standstill
    var steer_rate: Real  # rad/s the wheels move toward the target (0 = instant)
    var steer_fade: Real  # speed (m/s) at which steering halves (0 = off)
    var rolling_resistance: Real  # Crr: wheel torque Crr * Fz * R
    var abs_on: Bool
    var traction_control: Bool
    var tire_force_lift: Real  # 0 = tire forces at the road, 1 = at hub height
    var gravity: Vec3  # what the scene will apply this step (for slip prediction)

    def __init__(out self):
        """A 1200 kg rear-drive sedan: 2.7 m wheelbase, 1.6 m track."""
        self.mass = 1200
        var b = Inertia3.box(1200, 2.0, 0.35, 0.9)
        self.inertia = Vec3(b.ix, b.iy, b.iz, 0)
        self.half = Vec3(2.0, 0.35, 0.9, 0)
        self.wheels = List[WheelConfig]()
        for k in range(4):
            var front = k < 2
            var x = Real(1.35) if front else Real(-1.35)
            var z = Real(-0.8) if (k % 2 == 0) else Real(0.8)
            self.wheels.append(
                WheelConfig(
                    Vec3(x, -0.15, z, 0), 0.33, 0.12, 1.5,
                    0 if front else 1,
                    Real(1.0) if front else Real(0.0),
                    not front,
                    not front,
                    Real(0.6) if front else Real(0.4),
                )
            )
        self.susp = SuspensionConfig(0.35, 22000, 2400, 3200, 0.05, 120000, 8000)
        self.tire = TireModel.default()
        self.drive = DriveConfig()
        self.aero = Aero.from_cd(0.32, 2.2)
        self.brake_torque = 4000
        self.handbrake_torque = 4500
        self.max_steer = 0.55
        self.steer_rate = 4.0
        self.steer_fade = 30.0
        self.rolling_resistance = 0.012
        self.abs_on = True
        self.traction_control = True
        self.tire_force_lift = 0.7
        self.gravity = Vec3(0, -9.8, 0, 0)

    def set_drive_layout(mut self, front: Bool, rear: Bool):
        """FWD / RWD / AWD by which axles get engine torque."""
        for w in range(len(self.wheels)):
            self.wheels[w].driven = (self.wheels[w].axle == 0 and front) or (
                self.wheels[w].axle != 0 and rear
            )

    def validate(self) raises:
        if self.mass <= 0:
            raise Error("VehicleConfig: mass must be > 0")
        if self.inertia[0] <= 0 or self.inertia[1] <= 0 or self.inertia[2] <= 0:
            raise Error("VehicleConfig: principal inertia must be > 0")
        if len(self.wheels) < 2 or len(self.wheels) > 8:
            raise Error("VehicleConfig: need 2..8 wheels")
        if self.susp.length <= 0 or self.susp.stiffness <= 0:
            raise Error("VehicleConfig: suspension length / stiffness must be > 0")
        if self.susp.damp_compress < 0 or self.susp.damp_rebound < 0:
            raise Error("VehicleConfig: damping must be >= 0")
        if self.tire.mu < 0 or self.tire.long_peak <= 0 or self.tire.lat_peak <= 0:
            raise Error("VehicleConfig: tire mu >= 0 and peak slips > 0 required")
        if len(self.drive.gears) == 0:
            raise Error("VehicleConfig: need at least one forward gear")
        for w in range(len(self.wheels)):
            var wc = self.wheels[w]
            if wc.radius <= 0 or wc.inertia <= 0:
                raise Error("VehicleConfig: wheel radius / inertia must be > 0")
            if wc.axle < 0 or wc.axle > 3:
                raise Error("VehicleConfig: wheel axle must be 0..3")


@fieldwise_init
struct WheelState(Copyable, ImplicitlyCopyable, Movable):
    var grounded: Bool
    var hub: Real  # mount-to-hub distance (full droop when airborne)
    var omega: Real  # spin, rad/s, forward positive
    var spin: Real  # accumulated rotation angle (for rendering)
    var steer: Real  # steering angle of this wheel
    var fz: Real  # normal load this step (N)
    var fx: Real  # longitudinal tire force (N)
    var fy: Real  # lateral tire force (N)
    var kappa: Real  # slip ratio
    var tan_alpha: Real  # lateral slip
    var drive_torque: Real
    var point: Vec3
    var normal: Vec3
    var ground: Int  # body index under the wheel, -1 airborne
    var material: Int  # surface material id under the tire (17.53), -1 none

    @staticmethod
    def fresh(hub: Real) -> Self:
        return Self(
            False, hub, 0, 0, 0, 0, 0, 0, 0, 0, 0, _ZERO, _UP, -1, -1
        )


struct Vehicle[W: WheelCast = RayWheel](Movable):
    var cfg: VehicleConfig
    var chassis: BodyId
    var cast: Self.W
    var wheels: List[WheelState]
    var partner: List[Int]  # other wheel of the same axle, -1 if none
    var gear: Int  # 1..n forward, -1 reverse
    var shift_timer: Real
    var steer_angle: Real
    var rpm: Real
    var grounded: Int

    def __init__(out self, chassis: BodyId, var cfg: VehicleConfig, var cast: Self.W):
        self.chassis = chassis
        self.cast = cast^
        self.wheels = List[WheelState]()
        self.partner = List[Int]()
        var n = len(cfg.wheels)
        for w in range(n):
            self.wheels.append(WheelState.fresh(cfg.susp.length))
            var p = -1
            for o in range(n):
                if o != w and cfg.wheels[o].axle == cfg.wheels[w].axle:
                    p = o
            self.partner.append(p)
        self.cfg = cfg^
        self.gear = 1
        self.shift_timer = 0
        self.steer_angle = 0
        self.rpm = self.cfg.drive.idle_rpm
        self.grounded = 0

    # ------------------------------------------------------------ setup

    @staticmethod
    def attach[B: Body6](
        mut sc: ContactScene6[B], chassis: BodyId, var cfg: VehicleConfig, var cast: Self.W
    ) raises -> Self:
        """Validate `cfg`, check that `chassis` is a live dynamic body and keep
        it awake. The body's mass / inertia are the scene's, `cfg.mass` is only
        used by `spawn_chassis`."""
        cfg.validate()
        if not sc.bset.is_valid(chassis):
            raise Error("Vehicle.attach: invalid chassis BodyId")
        if not sc.bset.is_dynamic(chassis.index()):
            raise Error("Vehicle.attach: the chassis must be a dynamic body")
        sc.set_can_sleep(chassis, False)
        return Self(chassis, cfg^, cast^)

    # ------------------------------------------------------------ queries

    def forward_speed[B: Body6](self, sc: ContactScene6[B]) -> Real:
        var i = self.chassis.index()
        return dot(sc.bset.bodies[i].linear_velocity(), sc.bset.bodies[i].rotation().rotate(_FWD))

    def speed[B: Body6](self, sc: ContactScene6[B]) -> Real:
        return length(sc.bset.bodies[self.chassis.index()].linear_velocity())

    def up_dot[B: Body6](self, sc: ContactScene6[B]) -> Real:
        """Chassis up axis against world up: 1 upright, 0 on its side, -1 roof down."""
        return dot(sc.bset.bodies[self.chassis.index()].rotation().rotate(_UP), _UP)

    def is_flipped[B: Body6](self, sc: ContactScene6[B]) -> Bool:
        return self.up_dot(sc) < 0.3

    # ------------------------------------------------------------ snapshot

    def write_state[Wr: StateWriter](self, mut out: Wr):
        """Dynamic state beside a scene snapshot (ROADMAP 17.48, the 17.4
        leftover): gear, shift timer, steering, engine rpm and every wheel's
        spin / suspension / tire state. The config and the wheel cast are
        construction data: restore into a vehicle attached with the same
        ones (`read_state`)."""
        out.wi(self.gear)
        out.wf(self.shift_timer)
        out.wf(self.steer_angle)
        out.wf(self.rpm)
        out.wi(self.grounded)
        out.wi(len(self.wheels))
        for w in range(len(self.wheels)):
            var ws = self.wheels[w]
            out.wi(1 if ws.grounded else 0)
            out.wf(ws.hub)
            out.wf(ws.omega)
            out.wf(ws.spin)
            out.wf(ws.steer)
            out.wf(ws.fz)
            out.wf(ws.fx)
            out.wf(ws.fy)
            out.wf(ws.kappa)
            out.wf(ws.tan_alpha)
            out.wf(ws.drive_torque)
            out.wv(ws.point)
            out.wv(ws.normal)
            out.wi(ws.ground)
            out.wi(ws.material)

    def read_state[Rd: StateReader](mut self, mut r: Rd) raises:
        """Overwrite this vehicle's dynamic state; raises if the snapshot
        has a different wheel count (it was taken of another vehicle)."""
        self.gear = r.ri()
        self.shift_timer = r.rf()
        self.steer_angle = r.rf()
        self.rpm = r.rf()
        self.grounded = r.ri()
        var n = r.ri()
        if n != len(self.wheels):
            raise Error("Vehicle.read_state: snapshot wheel count differs from this vehicle's")
        for w in range(n):
            var grounded = r.ri() == 1
            var hub = r.rf()
            var omega = r.rf()
            var spin = r.rf()
            var steer = r.rf()
            var fz = r.rf()
            var fx = r.rf()
            var fy = r.rf()
            var kappa = r.rf()
            var tan_alpha = r.rf()
            var drive_torque = r.rf()
            var point = r.rv()
            var normal = r.rv()
            var ground = r.ri()
            var material = r.ri()
            self.wheels[w] = WheelState(
                grounded, hub, omega, spin, steer, fz, fx, fy, kappa, tan_alpha,
                drive_torque, point, normal, ground, material,
            )

    def grounded_count(self) -> Int:
        return self.grounded

    def sync_wheels(mut self, speed: Real):
        """Spin every wheel to roll at `speed` m/s (call after giving the
        chassis an initial velocity, or the first steps are a skid)."""
        for w in range(len(self.wheels)):
            self.wheels[w].omega = speed / self.cfg.wheels[w].radius

    def wheel_hub[B: Body6](self, sc: ContactScene6[B], w: Int) -> Vec3:
        """World position of wheel `w`'s hub (full droop when airborne)."""
        var i = self.chassis.index()
        var up = sc.bset.bodies[i].rotation().rotate(_UP)
        return sc.bset.bodies[i].act(self.cfg.wheels[w].mount) - up * self.wheels[w].hub

    # ------------------------------------------------------------ drivetrain

    def _intent(mut self, inp: VehicleInput, speed_f: Real) -> Tuple[Real, Real]:
        """(engine throttle >= 0, brake in [0, 1]) after gear logic: throttle
        back while rolling forward brakes, from a standstill it selects reverse,
        and throttle forward while rolling backward brakes."""
        var thr = _clamp(inp.throttle, -1, 1)
        var brk = _clamp(inp.brake, 0, 1)
        var eng = Real(0)
        if thr < 0:
            if speed_f > _REVERSE_SPEED:
                brk = max(brk, -thr)
            else:
                if self.gear > 0:
                    self.gear = -1
                    self.shift_timer = self.cfg.drive.shift_time
                eng = -thr
        elif thr > 0:
            if self.gear < 0:
                if speed_f < -_REVERSE_SPEED:
                    brk = max(brk, thr)
                else:
                    self.gear = 1
                    self.shift_timer = self.cfg.drive.shift_time
                    eng = thr
            else:
                eng = thr
        return (eng, brk)

    def _auto_shift(mut self, wheel_rpm: Real, thr: Real, dt: Real):
        if self.shift_timer > 0:
            self.shift_timer -= dt
            return
        if self.gear < 0:
            return
        if wheel_rpm > self.cfg.drive.up_rpm and thr > 0.1 and self.gear < len(self.cfg.drive.gears):
            self.gear += 1
            self.shift_timer = self.cfg.drive.shift_time
        elif wheel_rpm < self.cfg.drive.down_rpm and self.gear > 1:
            # only when the lower gear does not land past the upshift point
            var lower = wheel_rpm * self.cfg.drive.gear_ratio(self.gear - 1) / self.cfg.drive.gear_ratio(self.gear)
            if lower < self.cfg.drive.up_rpm * 0.9:
                self.gear -= 1
                self.shift_timer = self.cfg.drive.shift_time

    def _drive_torques(mut self, thr: Real, dt: Real):
        """Fill each wheel's `drive_torque` from throttle, gear and the diffs."""
        var n = len(self.cfg.wheels)
        for w in range(n):
            self.wheels[w].drive_torque = 0
        var sgn = Real(-1) if self.gear < 0 else Real(1)
        var sum_w = Real(0)
        var cnt = 0
        var axle_mask = 0
        for w in range(n):
            if self.cfg.wheels[w].driven:
                sum_w += self.wheels[w].omega * sgn
                cnt += 1
                axle_mask |= 1 << self.cfg.wheels[w].axle
        if cnt == 0:
            return
        var omega_dir = sum_w / Real(cnt)  # driven-wheel speed along the gear's direction
        var ratio = self.cfg.drive.gear_ratio(self.gear)
        var wheel_rpm = omega_dir * ratio * RAD_S_TO_RPM
        var abs_rpm = wheel_rpm if wheel_rpm >= 0 else -wheel_rpm
        self._auto_shift(abs_rpm, thr, dt)
        ratio = self.cfg.drive.gear_ratio(self.gear)
        sgn = Real(-1) if self.gear < 0 else Real(1)
        self.rpm = self.cfg.drive.engine_rpm(abs_rpm, thr)
        var te = self.cfg.drive.engine_torque(self.rpm, abs_rpm, thr)
        if thr <= 0.02 and wheel_rpm < 0:
            te = -te  # engine braking opposes whichever way the wheels turn
        if self.shift_timer > 0:
            te = 0
        var total = te * ratio * self.cfg.drive.efficiency  # along the gear direction
        # Axle shares: two driven axles that include axle 0 split by front_bias, otherwise equal (a pair like axles
        # 1 and 2 used to get 1 - front_bias each, 20 % more torque than the engine made).
        var axles = 0
        for a in range(4):
            if (axle_mask >> a) & 1 == 1:
                axles += 1
        var axle_t = List[Real](length=4, fill=0)
        var first = -1
        var second = -1
        for a in range(4):
            if (axle_mask >> a) & 1 == 0:
                continue
            if first < 0:
                first = a
            else:
                second = a
            var share = Real(1) / Real(axles)
            if axles == 2 and (axle_mask & 1) == 1:
                share = self.cfg.drive.front_bias if a == 0 else (1 - self.cfg.drive.front_bias)
            axle_t[a] = total * share
        if axles == 2 and self.cfg.drive.axle_diff_kind != DIFF_OPEN:
            # a diff / limited slip between the two driven axles replaces the fixed split: the slower axle gets more
            var w1 = Real(0)
            var n1 = 0
            var w2 = Real(0)
            var n2 = 0
            for w in range(n):
                if self.cfg.wheels[w].driven:
                    if self.cfg.wheels[w].axle == first:
                        w1 += self.wheels[w].omega * sgn
                        n1 += 1
                    else:
                        w2 += self.wheels[w].omega * sgn
                        n2 += 1
            var ax = split_axle(
                self.cfg.drive.axle_diff_kind, total, w1 / Real(n1), w2 / Real(n2),
                self.cfg.drive.axle_diff_preload, self.cfg.drive.axle_diff_lock, self.cfg.drive.axle_diff_max,
            )
            axle_t[first] = ax[0]
            axle_t[second] = ax[1]
        for a in range(4):
            if (axle_mask >> a) & 1 == 0:
                continue
            var t_axle = axle_t[a]
            var a0 = -1
            var a1 = -1
            for w in range(n):
                if self.cfg.wheels[w].driven and self.cfg.wheels[w].axle == a:
                    if a0 < 0:
                        a0 = w
                    else:
                        a1 = w
            if a1 < 0:
                self.wheels[a0].drive_torque = t_axle * sgn
                continue
            # left = smaller mount z
            var l = a0
            var r = a1
            if self.cfg.wheels[a0].mount[2] > self.cfg.wheels[a1].mount[2]:
                l = a1
                r = a0
            var tr = split_axle(
                self.cfg.drive.diff_kind, t_axle,
                self.wheels[l].omega * sgn, self.wheels[r].omega * sgn,
                self.cfg.drive.diff_preload, self.cfg.drive.diff_lock, self.cfg.drive.diff_max,
            )
            self.wheels[l].drive_torque = tr[0] * sgn
            self.wheels[r].drive_torque = tr[1] * sgn

    # ------------------------------------------------------------ update

    def update[B: Body6](mut self, mut sc: ContactScene6[B], inp: VehicleInput, dt: Real):
        """Convenience form: builds the query poses itself. With several
        vehicles in one scene call `update_with` and share one pose list."""
        var poses = sc.query_poses()
        self.update_with(sc, poses, inp, dt)

    def update_with[B: Body6](
        mut self, mut sc: ContactScene6[B], poses: List[Pose3], inp: VehicleInput, dt: Real
    ):
        """Apply this step's vehicle forces to the chassis (call before the
        scene's `step`). `poses` is `sc.query_poses()` of the same step."""
        if not sc.bset.is_valid(self.chassis):
            sc.counters.incr(VEHICLE_FORCE_DROPPED)  # the chassis was removed under us
            return
        var ci = self.chassis.index()
        var q = sc.bset.bodies[ci].rotation()
        var pos = sc.bset.bodies[ci].position()
        var v = sc.bset.bodies[ci].linear_velocity()
        if dt <= 0 or not _finite(pos) or not _finite(v) or not _finite(sc.bset.bodies[ci].omega_world()):
            sc.counters.incr(VEHICLE_FORCE_DROPPED)
            return
        var up = q.rotate(_UP)
        var fwd = q.rotate(_FWD)
        var right = q.rotate(_RIGHT)
        var speed_f = dot(v, fwd)
        var n = len(self.cfg.wheels)

        # ---- steering
        var fade = Real(1)
        if self.cfg.steer_fade > 0:
            var r = speed_f / self.cfg.steer_fade
            fade = 1 / (1 + r * r)
        var target = _clamp(inp.steer, -1, 1) * self.cfg.max_steer * fade
        if self.cfg.steer_rate <= 0:
            self.steer_angle = target
        else:
            var dmax = self.cfg.steer_rate * dt
            self.steer_angle += _clamp(target - self.steer_angle, -dmax, dmax)

        # ---- driver intent and drivetrain
        var it = self._intent(inp, speed_f)
        var thr = it[0]
        var brk = it[1]
        self._drive_torques(thr, dt)

        # ---- aerodynamics (at the centre of mass)
        var fa = self.cfg.aero.drag_force(v)
        if self.cfg.aero.cl != 0:
            var s2 = dot(v - self.cfg.aero.wind, v - self.cfg.aero.wind)
            fa = fa - up * (Real(0.5) * self.cfg.aero.rho * self.cfg.aero.cl * self.cfg.aero.area * s2)
        if _finite(fa):
            var ja = fa * dt
            # Drag can at most stop the car, never reverse it.
            var jm = length(ja)
            var vm = length(v - self.cfg.aero.wind) * self.cfg.mass
            if jm > vm and jm > _EPS and self.cfg.aero.cl == 0:
                ja = ja * (vm / jm)
            try:  # ci is the live chassis slot: id_of cannot be stale
                sc.apply_impulse(sc.bset.id_of(ci), ja, pos, wake=False)
            except:
                pass
        else:
            sc.counters.incr(VEHICLE_FORCE_DROPPED)

        # ---- probe the road under every wheel
        var filt = QueryFilter.ignoring(ci)
        var g = 0
        for w in range(n):
            var wc = self.cfg.wheels[w]
            var mount = sc.bset.bodies[ci].act(wc.mount)
            var h = self.cast.cast(
                sc.colliders, poses, mount, -up, right,
                self.cfg.susp.length, wc.radius, wc.half_width, filt,
            )
            self.wheels[w].grounded = h.hit
            if h.hit:
                self.wheels[w].hub = h.hub
                self.wheels[w].point = h.point
                self.wheels[w].normal = h.normal
                self.wheels[w].ground = h.body
                self.wheels[w].material = sc.colliders.material(h.body, h.feat)
                g += 1
            else:
                self.wheels[w].hub = self.cfg.susp.length
                self.wheels[w].ground = -1
                self.wheels[w].material = -1
                self.wheels[w].fz = 0
                self.wheels[w].fx = 0
                self.wheels[w].fy = 0
                self.wheels[w].kappa = 0
                self.wheels[w].tan_alpha = 0
        self.grounded = g

        # ---- suspension: spring + damper + bump stop -> normal load
        var inv_m = sc.bset.bodies[ci].inv_mass()
        var comp = List[Real]()
        for _ in range(n):
            comp.append(0)
        for w in range(n):
            if not self.wheels[w].grounded:
                continue
            var ws = self.wheels[w]
            var s = self.cfg.susp
            var c = s.length - ws.hub
            comp[w] = c
            var f = s.stiffness * c
            if ws.hub < s.min_length:
                f += s.bump_stiffness * (s.min_length - ws.hub)
            var gv = _ZERO
            if ws.ground >= 0:
                gv = sc.bset.bodies[ws.ground].velocity_at(ws.point)
            var vrel = sc.bset.bodies[ci].velocity_at(ws.point) - gv
            var comp_speed = -dot(vrel, up)
            var dmp = (s.damp_compress if comp_speed > 0 else s.damp_rebound) * comp_speed
            # The damper alone may not reverse the relative velocity in one step.
            var arm = ws.point - pos
            var im = (inv_m + sc.bset.bodies[ci].angular_factor(arm, up)) * Real(g)
            var dlim = (comp_speed if comp_speed >= 0 else -comp_speed) / (dt * im + _EPS)
            if dmp > dlim:
                dmp = dlim
            elif dmp < -dlim:
                dmp = -dlim
            self.wheels[w].fz = max(Real(0), f + dmp)
        # anti-roll bar: stiffer axle roll by transferring load across the pair
        if self.cfg.susp.anti_roll > 0:
            for w in range(n):
                var p = self.partner[w]
                if p > w and self.wheels[w].grounded and self.wheels[p].grounded:
                    var t = self.cfg.susp.anti_roll * (comp[w] - comp[p])
                    var t_use = t
                    # never pull a wheel's load below zero
                    if t_use > self.wheels[p].fz:
                        t_use = self.wheels[p].fz
                    if -t_use > self.wheels[w].fz:
                        t_use = -self.wheels[w].fz
                    self.wheels[w].fz += t_use
                    self.wheels[p].fz -= t_use

        # ---- wheels: spin, tire forces, impulses. Every wheel reads the chassis
        # state of the START of the step and the impulses are summed and applied
        # once at the end: applying wheel by wheel would let the first wheel's
        # impulse change the slip the next wheel sees (Gauss-Seidel on a force
        # model), which shows up as left-right alternating lateral forces.
        var sum_j = _ZERO
        var sum_l = _ZERO
        # How many wheels push longitudinally (driven or braked): the implicit
        # force limit below is shared among them, not among all four.
        var n_long = 0
        for w in range(n):
            var tbw = brk * self.cfg.brake_torque * self.cfg.wheels[w].brake_share
            if self.cfg.wheels[w].handbrake:
                tbw += _clamp(inp.handbrake, 0, 1) * self.cfg.handbrake_torque
            if self.wheels[w].grounded and (abs(self.wheels[w].drive_torque) > 1 or tbw > 1):
                n_long += 1
        if n_long < 1:
            n_long = 1
        for w in range(n):
            var wc = self.cfg.wheels[w]
            var ws = self.wheels[w]
            ws.steer = self.steer_angle * wc.steer

            # contact frame and slip velocities (grounded wheels)
            var n_c = ws.normal
            var ff = fwd
            var lat = right
            var vx = Real(0)
            var vy = Real(0)
            var mu_eff = Real(0)
            if ws.grounded:
                var hd = fwd * cos(ws.steer) + right * sin(ws.steer)
                ff = hd - n_c * dot(hd, n_c)
                var fl = length(ff)
                if fl < 1e-4:
                    ff = fwd - n_c * dot(fwd, n_c)
                    fl = length(ff)
                if fl < 1e-4:
                    ws.grounded = False  # edge-on to the road: no tire force
                else:
                    ff = ff / fl
                    lat = cross(ff, n_c)
                    var gv = _ZERO
                    var gmu = _REF_MU
                    if ws.ground >= 0:
                        gv = sc.bset.bodies[ws.ground].velocity_at(ws.point)
                        gmu = sc.surface_friction(ws.ground, ws.material, _REF_MU)
                    var vrel = sc.bset.bodies[ci].velocity_at(ws.point) - gv
                    # Slip is taken at the velocity the solver will give the
                    # contact after gravity acts this step; otherwise a car
                    # parked on a slope has to creep before the tire may push back.
                    vx = dot(vrel, ff) + dt * dot(self.cfg.gravity, ff)
                    vy = dot(vrel, lat) + dt * dot(self.cfg.gravity, lat)
                    mu_eff = self.cfg.tire.mu * gmu / _REF_MU

            # torques on the wheel. Traction control caps the drive torque at what
            # the tire can transmit; ABS caps the brake torque the same way, so
            # neither spins nor locks the tire into the low sliding tail.
            var t_drive = ws.drive_torque
            var t_brake = brk * self.cfg.brake_torque * wc.brake_share
            if wc.handbrake:
                t_brake += _clamp(inp.handbrake, 0, 1) * self.cfg.handbrake_torque
            if ws.grounded:
                var t_grip = mu_eff * ws.fz * wc.radius
                if self.cfg.traction_control:
                    t_drive = _clamp(t_drive, -Real(0.9) * t_grip, Real(0.9) * t_grip)
                if self.cfg.abs_on and brk > 0.05 and vx > 1.0 and t_brake > Real(0.95) * t_grip:
                    t_brake = Real(0.95) * t_grip
            var tb = t_brake + self.cfg.rolling_resistance * ws.fz * wc.radius
            tb += Real(0.2)  # bearing friction (N m): a free wheel in the air winds down
            var om_drive = ws.omega + dt * t_drive / wc.inertia
            var dres = dt * tb / wc.inertia
            var om = _decay(om_drive, dres)

            if not ws.grounded:
                ws.omega = om
                ws.spin += om * dt
                ws.fx = 0
                ws.fy = 0
                self.wheels[w] = ws
                continue

            var den = max(abs(vx), self.cfg.tire.v_min)
            # arm and response of this contact; a wheel the brake has locked cannot
            # be spun by the road, so its inertia drops out
            var arm = ws.point - pos
            var im_x = (inv_m + sc.bset.bodies[ci].angular_factor(arm, ff)) * Real(n_long)
            var im_y = (inv_m + sc.bset.bodies[ci].angular_factor(arm, lat)) * Real(g)
            if ws.ground >= 0 and sc.bset.is_dynamic(ws.ground):
                var gim = sc.bset.bodies[ws.ground].inv_mass()
                im_x += gim
                im_y += gim
            var wheel_resp = wc.radius * wc.radius / wc.inertia
            var s_x = om * wc.radius - vx
            var s_y = -vy
            var kappa = s_x / den
            var tan_a = s_y / den
            var locked = om == 0 and t_brake > 0  # a wheel the brake has stopped
            var bx = dt * (im_x + (Real(0) if locked else wheel_resp))
            var fx = solve_axis(self.cfg.tire, True, s_x, bx, s_y, den, mu_eff, ws.fz)
            if locked and abs(fx) * wc.radius > tb:  # the brake cannot hold the wheel against the road
                bx = dt * (im_x + wheel_resp)
                fx = solve_axis(self.cfg.tire, True, s_x, bx, s_y, den, mu_eff, ws.fz)
            var fy = solve_axis(self.cfg.tire, False, s_y, dt * im_y, s_x - bx * fx, den, mu_eff, ws.fz)

            if not (fx == fx and fy == fy and ws.fz == ws.fz):
                sc.counters.incr(VEHICLE_FORCE_DROPPED)
                ws.omega = om
                self.wheels[w] = ws
                continue

            # The road's reaction torque spins the wheel, then the brake gets its
            # say: a locked wheel stays locked however hard the road pulls on it.
            om = _decay(om_drive - dt * fx * wc.radius / wc.inertia, dres)
            ws.omega = om
            ws.spin += om * dt
            ws.fx = fx
            ws.fy = fy
            ws.kappa = kappa
            ws.tan_alpha = tan_a
            self.wheels[w] = ws

            # apply: load along the road normal at the contact, traction at a
            # point lifted toward the hub (less body roll per N of lateral force)
            var jn = n_c * (ws.fz * dt)
            var jt = (ff * fx + lat * fy) * dt
            var p_t = ws.point + n_c * (self.cfg.tire_force_lift * wc.radius)
            sum_j = sum_j + jn + jt
            sum_l = sum_l + cross(ws.point - pos, jn) + cross(p_t - pos, jt)
            if ws.ground >= 0 and sc.bset.is_dynamic(ws.ground):
                var gid = sc.bset.id_of(ws.ground)
                var asleep = sc.bset.sleeping[ws.ground]
                try:
                    sc.apply_impulse(gid, -jn, ws.point, wake=False)
                    sc.apply_impulse(gid, -jt, p_t, wake=asleep)
                except:
                    pass
        if _finite(sum_j) and _finite(sum_l):
            try:
                sc.apply_impulse(sc.bset.id_of(ci), sum_j, pos, wake=False)
                sc.apply_angular_impulse(sc.bset.id_of(ci), sum_l, wake=False)
            except:
                pass
        else:
            sc.counters.incr(VEHICLE_FORCE_DROPPED)


struct VehicleSet[W: WheelCast = RayWheel](Movable):
    """Several vehicles stepped together: one pose list for all of them."""

    var items: List[Vehicle[Self.W]]

    def __init__(out self):
        self.items = List[Vehicle[Self.W]]()

    def add(mut self, var v: Vehicle[Self.W]) -> Int:
        self.items.append(v^)
        return len(self.items) - 1

    def __len__(self) -> Int:
        return len(self.items)

    def update[B: Body6](
        mut self, mut sc: ContactScene6[B], inputs: List[VehicleInput], dt: Real
    ):
        var poses = sc.query_poses()
        for k in range(len(self.items)):
            var inp = inputs[k] if k < len(inputs) else VehicleInput.idle()
            self.items[k].update_with(sc, poses, inp, dt)


def chassis_body(cfg: VehicleConfig, pos: Vec3, rot: Quat) -> QuatBody6:
    return QuatBody6(
        pos, rot, _ZERO, _ZERO, Inertia3(cfg.mass, cfg.inertia[0], cfg.inertia[1], cfg.inertia[2])
    )


def spawn_chassis(
    mut sc: ContactScene6[QuatBody6], cfg: VehicleConfig, pos: Vec3, rot: Quat = Quat.identity()
) raises -> BodyId:
    """Add the chassis box for `cfg` to the scene at `pos` / `rot`."""
    cfg.validate()
    return sc.add(chassis_body(cfg, pos, rot), cfg.half, False)
