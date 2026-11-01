"""Movement modes and velocity models for the kinematic character
(ROADMAP 17.67).

`CharacterController.update` takes a desired horizontal velocity and sets
it directly; it has one mode (walking / airborne), no jump feel and no
external velocity. `Mover` wraps it:

  * modes: WALK, FALL, SWIM, FLY. Swimming starts when more than
    `swim_enter` of the capsule's height is under a `WaterVolume` surface
    and stops below `swim_exit` (the gap is the hysteresis that stops a
    character bobbing at the surface from flickering between modes); in the
    water gravity is scaled by `1 - buoyancy`, vertical wish moves the
    swimmer and `water_drag` damps it. FLY ignores gravity.
  * velocity models (a seam, `MoveConfig.model`): MODEL_DIRECT sets the
    wish velocity (the controller's old behaviour); MODEL_ACCEL moves toward
    it at `accel` (`decel` when there is no wish; times `air_control` in the
    air); MODEL_QUAKE is Quake's PM_Friction + PM_Accelerate (friction on
    the ground, then add speed along the wish direction up to the wish
    speed). On flat ground all three settle at the wish speed.
  * jump feel, counted in ticks so it replays exactly: coyote time (a jump
    pressed up to `coyote_ticks` after leaving the ground still jumps), a
    jump buffer (a press up to `buffer_ticks` before landing jumps on
    landing), variable height (releasing while rising multiplies the
    upward speed by `jump_cut` once), and `max_jumps` (2 = double jump).
  * external velocity (`add_velocity`): knockback, jump pads, wind; added
    to the move each tick and decaying at `ext_decay` per second, never
    overwritten by walking.
  * moving platforms: the controller already carries the position; `heading`
    (yaw, radians) now also turns with the platform's angular velocity.
  * ladders (`Mover.ladders`, `Ladder` = a box volume and the direction
    its face looks out of): inside one, pushing toward the face climbs at
    the ladder's speed, pushing away climbs down, nothing holds still;
    gravity is off. Climbing past the top pulls up onto the ledge behind
    (the ledge climb's motion);
    reaching the ground going down, or jumping, lets go (a jump pushes off
    along the face direction).
  * sliding (`slide_angle` > 0): on ground steeper than `slide_angle`
    (but still walkable) the character slides downhill like a block with
    kinetic friction `slide_friction`: along the slope it gains
    g (sin a - mu cos a) per second; the wish is ignored until the ground
    flattens.
  * gliding (`glide_sink` > 0): holding jump while falling caps the sink
    speed at `glide_sink` and steers toward the wish with air control.
  * the vertical is the controller's `up` (17.67; `cc.set_up`): jumps,
    the swim / fly wish, external vertical velocity and platform yaw are
    measured along it. Water volumes stay axis-aligned boxes with a +y
    surface.

`Mover` is a value type (copy = snapshot) and uses no wall clock.
"""

from std.math import sqrt, isfinite, exp
from geometry.trig import cos
from geometry.vec import Real, Vec3, dot, length
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from collision.world_query import QueryFilter
from .character import CharacterController

comptime MODE_WALK = 0
comptime MODE_FALL = 1
comptime MODE_SWIM = 2
comptime MODE_FLY = 3
comptime MODE_CLIMB = 4  # pulling up onto a ledge or vaulting a low wall (17.67)
comptime MODE_DRIVE = 5  # riding a vehicle seat (17.67)
comptime MODE_LADDER = 6  # on a ladder volume (17.67)
comptime MODE_SLIDE = 7  # sliding down a steep slope (17.67)
comptime MODE_GLIDE = 8  # gliding: falling with the sink speed capped (17.67)


@fieldwise_init
struct Ladder(Copyable, ImplicitlyCopyable, Movable):
    """A climbable volume: axis-aligned box `lo`..`hi`, `face` the unit
    horizontal direction its climbable side looks out of, `speed` m/s."""

    var lo: Vec3
    var hi: Vec3
    var face: Vec3
    var speed: Real

comptime MODEL_DIRECT = 0
comptime MODEL_ACCEL = 1
comptime MODEL_QUAKE = 2


@fieldwise_init
struct MoveConfig(Copyable, ImplicitlyCopyable, Movable):
    var model: Int
    var accel: Real  # m/s^2 (MODEL_ACCEL); 1/s x wish speed (MODEL_QUAKE)
    var decel: Real  # m/s^2 braking with no wish (MODEL_ACCEL)
    var friction: Real  # 1/s ground friction (MODEL_QUAKE)
    var air_control: Real  # fraction of accel in the air
    var jump_speed: Real
    var jump_cut: Real  # upward speed kept when jump is released while rising
    var coyote_ticks: Int
    var buffer_ticks: Int
    var max_jumps: Int
    var swim_enter: Real
    var swim_exit: Real
    var buoyancy: Real  # fraction of gravity cancelled in the water
    var water_drag: Real  # 1/s on vertical speed in the water
    var ext_decay: Real  # 1/s

    @staticmethod
    def default() -> Self:
        return Self(MODEL_DIRECT, 20, 20, 6, 0.3, 5, 0.5, 6, 6, 1, 0.6, 0.4, 0.95, 2, 3)


def _toward(v: Vec3, target: Vec3, step: Real) -> Vec3:
    var d = target - v
    var l = length(d)
    if l <= step or l == 0:
        return target
    return v + d * (step / l)


struct Mover(Copyable, Movable):
    var cc: CharacterController
    var cfg: MoveConfig
    var mode: Int
    var vel: Vec3  # horizontal model velocity
    var ext: Vec3  # external velocity, decaying
    var air_ticks: Int  # ticks since last on the ground
    var press_ticks: Int  # ticks since jump was last pressed (large = none pending)
    var jumps: Int  # jumps used since last grounded
    var rising_jump: Bool  # a jump is rising and has not been cut yet
    var heading: Real
    var mode_changes: Int
    # ROADMAP 17.67: ledge climb / vault (climb_height 0 = off) and driving
    var climb_height: Real  # highest ledge (above the foot) the character pulls up onto
    var climb_time: Real  # seconds a climb or vault takes
    var vault_depth: Real  # an obstacle thinner than this is vaulted, not climbed
    var climb_from: Vec3
    var climb_mid: Vec3
    var climb_to: Vec3
    var climb_t: Real
    var climbs: Int
    var vaults: Int
    var drive_body: Int
    var drive_seat: Vec3  # seat point in the vehicle body's frame
    # ROADMAP 17.67: ladders, sliding, gliding (all off by default)
    var ladders: List[Ladder]
    var ladder: Int  # the ladder being climbed (-1 = none)
    var slide_angle: Real  # radians; 0 = no sliding mode
    var slide_friction: Real
    var glide_sink: Real  # m/s; 0 = no gliding

    def __init__(out self, var cc: CharacterController, cfg: MoveConfig = MoveConfig.default()):
        self.cc = cc^
        self.cfg = cfg
        self.mode = MODE_FALL
        self.vel = Vec3(0, 0, 0, 0)
        self.ext = Vec3(0, 0, 0, 0)
        self.air_ticks = 1 << 30
        self.press_ticks = 1 << 30
        self.jumps = 0
        self.rising_jump = False
        self.heading = 0
        self.mode_changes = 0
        self.climb_height = 0
        self.climb_time = 0.5
        self.vault_depth = 0.5
        self.climb_from = Vec3(0, 0, 0, 0)
        self.climb_mid = Vec3(0, 0, 0, 0)
        self.climb_to = Vec3(0, 0, 0, 0)
        self.climb_t = 0
        self.climbs = 0
        self.vaults = 0
        self.drive_body = -1
        self.drive_seat = Vec3(0, 0, 0, 0)
        self.ladders = List[Ladder]()
        self.ladder = -1
        self.slide_angle = 0
        self.slide_friction = 0.2
        self.glide_sink = 0

    def add_velocity(mut self, dv: Vec3):
        if isfinite(dv[0]) and isfinite(dv[1]) and isfinite(dv[2]):
            self.ext = self.ext + dv

    def enter_vehicle[B: Body6](mut self, sc: ContactScene6[B], body: Int, seat_local: Vec3) raises:
        """Ride body `body` at `seat_local` (its frame): MODE_DRIVE until
        `exit_vehicle`; the character follows the seat and does not collide."""
        if body < 0 or body >= len(sc.bset.bodies) or sc.bset.is_removed(body):
            raise Error("Mover.enter_vehicle: body out of range")
        self.drive_body = body
        self.drive_seat = seat_local
        self._set_mode(MODE_DRIVE)
        self.cc.position = sc.bset.bodies[body].act(seat_local)
        self.cc.on_ground = False
        self.cc.ground_body = -1

    def exit_vehicle[B: Body6](mut self, sc: ContactScene6[B], exit_local: Vec3) raises:
        """Leave the vehicle at `exit_local` (its frame) with its velocity
        there; the character falls from there (MODE_FALL)."""
        if self.mode != MODE_DRIVE:
            raise Error("Mover.exit_vehicle: not driving")
        ref b = sc.bset.bodies[self.drive_body]
        var at = b.act(exit_local)
        self.cc.teleport(at)
        self.cc.velocity = b.velocity_at(at)
        self.drive_body = -1
        self._set_mode(MODE_FALL)

    def _try_ledge[B: Body6](mut self, sc: ContactScene6[B], dir: Vec3) -> Bool:
        """Blocked by a wall along `dir`: find its top; pull up onto it when
        it is above a step and at most `climb_height` above the foot, or
        vault it when it is thinner than `vault_depth` and the ground behind
        is at foot level. The landing must fit the capsule."""
        var cc = self.cc.copy()
        var up = cc.up
        var wall = cc._cast(sc, cc.position, dir, cc.cfg.radius + 0.25)
        if not wall.hit or cc._walkable(wall.normal):
            return False
        var foot = cc.foot()
        var flt = QueryFilter(cc.cfg.mask, -1, False)
        var ahead = wall.t + cc.cfg.radius + 0.1
        var o = foot + up * (self.climb_height + 0.05) + dir * ahead
        var top = sc.ray_cast(o, -up, self.climb_height + 0.05, flt)
        if not top.hit or not cc._walkable(top.normal):
            return False
        var top_h = dot(top.point - foot, up)
        if top_h <= cc.cfg.step_height or top_h > self.climb_height:
            return False
        var lift = cc.cfg.half_height + cc.cfg.radius + cc.cfg.skin
        var dest = top.point + up * lift
        var vault = False
        # vault: the wall ends within vault_depth and the ground behind is low
        var o2 = o + dir * self.vault_depth
        var behind = sc.ray_cast(o2, -up, self.climb_height + 0.05 + cc.cfg.step_height, flt)
        if behind.hit and cc._walkable(behind.normal) and dot(behind.point - foot, up) < cc.cfg.step_height:
            var d2 = behind.point + up * lift
            if len(cc._penetrations(sc, d2, cc.cfg.half_height, cc.cfg.skin)) == 0:
                dest = d2
                vault = True
        if not vault and len(cc._penetrations(sc, dest, cc.cfg.half_height, cc.cfg.skin)) > 0:
            return False
        self.climb_from = cc.position
        self.climb_mid = cc.position + up * (top_h + cc.cfg.skin * 2)
        self.climb_to = dest
        self.climb_t = 0
        if vault:
            self.vaults += 1
            # up and over the top, then down behind it
            self.climb_mid = self.climb_mid + dir * (ahead + self.vault_depth * 0.5)
        else:
            self.climbs += 1
        self._set_mode(MODE_CLIMB)
        self.cc.velocity = Vec3(0, 0, 0, 0)
        self.vel = Vec3(0, 0, 0, 0)
        return True

    def _climb_step(mut self, dt: Real):
        self.climb_t += dt
        var u = min(self.climb_t / self.climb_time, Real(1))
        if u < 0.5:
            self.cc.position = self.climb_from + (self.climb_mid - self.climb_from) * (u * 2)
        else:
            self.cc.position = self.climb_mid + (self.climb_to - self.climb_mid) * ((u - 0.5) * 2)
        if u >= 1:
            self._set_mode(MODE_FALL)
            self.cc.on_ground = False

    def _ladder_at(self) -> Int:
        """The ladder whose volume the character stands in: its centre
        within the box horizontally (grown by the radius), its foot between
        the bottom and the top (a centre test let go 0.6 m below the top,
        leaving the character hanging on the ledge edge). -1 when none."""
        var p = self.cc.position
        var f = self.cc.foot()[1]
        var r = self.cc.cfg.radius
        for i in range(len(self.ladders)):
            ref l = self.ladders[i]
            if p[0] >= l.lo[0] - r and p[0] <= l.hi[0] + r and p[2] >= l.lo[2] - r and p[2] <= l.hi[2] + r and f >= l.lo[1] - r and f <= l.hi[1]:
                return i
        return -1

    def _ladder_step[B: Body6](mut self, mut sc: ContactScene6[B], wish: Vec3, jump_pressed: Bool, dt: Real, gravity: Vec3):
        var l = self.ladders[self.ladder]
        var wl = length(self.cc._h(wish))
        var into = Real(0)
        if wl > 1e-6:
            into = min(max(dot(self.cc._h(wish) / wl, -l.face), Real(-1)), Real(1)) * min(wl, Real(1))
        if jump_pressed:
            self.ladder = -1
            self._set_mode(MODE_FALL)
            self.cc.velocity = l.face * 3 + self.cc.up * (self.cfg.jump_speed * 0.5)
            self.cc.on_ground = False
            self.cc.update(sc, l.face * 3, 0, dt, gravity)
            return
        var foot = self._vy(self.cc.foot())
        if into > 0 and foot >= l.hi[1] - 0.05:
            # over the top: the ledge climb (MODE_CLIMB) lifts the foot just
            # above the top and moves the capsule past the wall face onto it
            # (walking forward left its lower half hooked on the edge)
            var lift = self.cc.up * (l.hi[1] - foot + 0.02)
            # forward until the capsule clears the wall: from the centre to
            # the volume's far side along -face, plus the radius
            var into_dir = -l.face
            var far = Real(0)
            for ax in range(3):
                far += (l.hi[ax] if into_dir[ax] > 0 else l.lo[ax]) * into_dir[ax]
            var fwd = far - dot(self.cc.position, into_dir) + self.cc.cfg.radius + 0.05
            self.climb_from = self.cc.position
            self.climb_mid = self.cc.position + lift
            self.climb_to = self.climb_mid + into_dir * fwd
            self.climb_t = 0
            self.ladder = -1
            self.cc.velocity = Vec3(0, 0, 0, 0)
            self._set_mode(MODE_CLIMB)
            return
        if into < 0 and self.cc.on_ground:
            self.ladder = -1
            self._set_mode(MODE_WALK)
            self.cc.update(sc, Vec3(0, 0, 0, 0), 0, dt, gravity)
            return
        self.cc.velocity = self._with_vy(Vec3(0, 0, 0, 0), into * l.speed)
        # standing at the foot of the ladder the controller keeps a grounded
        # character's vertical speed at zero unless it is given a jump speed
        var up = into * l.speed if self.cc.on_ground and into > 0 else Real(0)
        self.cc.update(sc, Vec3(0, 0, 0, 0), up, dt, Vec3(0, 0, 0, 0))
        # left the volume sideways or below it: let go
        if self._ladder_at() != self.ladder:
            self.ladder = -1
            self._set_mode(MODE_FALL)

    def _set_mode(mut self, m: Int):
        if m != self.mode:
            self.mode = m
            self.mode_changes += 1

    def _submerged(self, waters: List[WaterVolume]) -> Real:
        var foot = self.cc.foot()[1]
        var height = 2 * (self.cc.cfg.half_height + self.cc.cfg.radius)
        var p = self.cc.position
        var best = Real(0)
        for w in waters:
            if p[0] < w.lo[0] or p[0] > w.hi[0] or p[2] < w.lo[2] or p[2] > w.hi[2] or foot > w.hi[1]:
                continue
            best = max(best, min(max((w.hi[1] - foot) / height, Real(0)), Real(1)))
        return best

    def _vy(self, v: Vec3) -> Real:
        """Component of `v` along the controller's up axis."""
        return self.cc._v(v)

    def _with_vy(self, v: Vec3, s: Real) -> Vec3:
        """`v` with its up component replaced by `s` (exact for +y: the
        other components pass through unchanged)."""
        return self.cc._h(v) + self.cc.up * s

    def _model(mut self, wish: Vec3, grounded: Bool, dt: Real):
        var w = self.cc._h(wish)
        if self.cfg.model == MODEL_DIRECT:
            self.vel = w
            return
        var ctrl = Real(1) if grounded else self.cfg.air_control
        if self.cfg.model == MODEL_ACCEL:
            if length(w) > 0:
                self.vel = _toward(self.vel, w, self.cfg.accel * ctrl * dt)
            elif grounded:
                self.vel = _toward(self.vel, Vec3(0, 0, 0, 0), self.cfg.decel * dt)
            return
        # MODEL_QUAKE: friction, then accelerate along the wish direction
        if grounded:
            var sp = length(self.vel)
            if sp > 0:
                var drop = sp * self.cfg.friction * dt
                self.vel = self.vel * (max(sp - drop, Real(0)) / sp)
        var ws = length(w)
        if ws > 0:
            var dir = w / ws
            var add = ws - dot(self.vel, dir)
            if add > 0:
                self.vel = self.vel + dir * min(self.cfg.accel * ctrl * dt * ws, add)

    def update[B: Body6](
        mut self, mut sc: ContactScene6[B], wish_in: Vec3, jump_pressed: Bool, jump_held: Bool,
        dt: Real, gravity: Vec3, waters: List[WaterVolume],
    ):
        """One tick. `wish_in` is the desired velocity (horizontal; its
        component along `cc.up` is used only when swimming or flying); non-finite input counts as no
        wish. `dt = 0` changes nothing."""
        if not (dt > 0):
            return
        var wish = wish_in
        if not (isfinite(wish[0]) and isfinite(wish[1]) and isfinite(wish[2])):
            wish = Vec3(0, 0, 0, 0)
        if self.mode == MODE_DRIVE:
            ref b = sc.bset.bodies[self.drive_body]
            self.cc.position = b.act(self.drive_seat)
            self.cc.velocity = b.velocity_at(self.cc.position)
            return
        if self.mode == MODE_CLIMB:
            self._climb_step(dt)
            return
        if self.mode == MODE_LADDER:
            self._ladder_step(sc, wish, jump_pressed, dt, gravity)
            return
        if len(self.ladders) > 0 and self.mode != MODE_FLY:
            var li = self._ladder_at()
            if li >= 0:
                var wl0 = length(self.cc._h(wish))
                if wl0 > 1e-6 and dot(self.cc._h(wish) / wl0, -self.ladders[li].face) > 0.5:
                    self.ladder = li
                    self._set_mode(MODE_LADDER)
                    self._ladder_step(sc, wish, False, dt, gravity)
                    return
        var grounded = self.cc.on_ground
        # ledge climb / vault when walking or falling into a wall
        if self.climb_height > 0 and self.mode != MODE_FLY and self.mode != MODE_SWIM:
            var wl = length(self.cc._h(wish))
            if wl > 1e-6 and self._try_ledge(sc, self.cc._h(wish) / wl):
                return
        # mode
        var sub = self._submerged(waters)
        if self.mode == MODE_FLY:
            pass
        elif self.mode == MODE_SWIM:
            if sub < self.cfg.swim_exit:
                self._set_mode(MODE_WALK if grounded else MODE_FALL)
        elif sub > self.cfg.swim_enter:
            self._set_mode(MODE_SWIM)
        elif grounded and self.slide_angle > 0 and dot(self.cc.ground_normal, self.cc.up) < cos(self.slide_angle):
            self._set_mode(MODE_SLIDE)
        elif not grounded and self.glide_sink > 0 and jump_held and not self.rising_jump and self._vy(self.cc.velocity) <= 0:
            self._set_mode(MODE_GLIDE)
        else:
            self._set_mode(MODE_WALK if grounded else MODE_FALL)
        # jump bookkeeping (ticks)
        if grounded:
            self.air_ticks = 0
            self.jumps = 0
        else:
            self.air_ticks += 1
        if jump_pressed:
            self.press_ticks = 0
        else:
            self.press_ticks += 1
        # horizontal model (a slide ignores the wish: the slope drives it)
        if self.mode == MODE_SLIDE:
            var n = self.cc.ground_normal
            var c = dot(n, self.cc.up)
            var gt = gravity - n * dot(gravity, n)  # gravity along the slope
            var dl = length(gt)
            if dl > 0:
                var down = gt / dl  # unit downhill along the slope
                var sa = sqrt(max(Real(1) - c * c, Real(0)))
                var a = length(gravity) * (sa - self.slide_friction * c)
                var hd = self.cc._h(down)
                var hl = length(hd)
                if hl > 0:
                    hd = hd / hl
                    # speed along the slope = horizontal speed / horizontal share
                    var s_along = dot(self.vel, hd) / max(hl, Real(1e-6))
                    s_along = max(s_along + a * dt, Real(0))
                    self.vel = hd * (s_along * hl)
        else:
            self._model(wish, grounded, dt)
        var walk = self.vel + self.cc._h(self.ext)
        var g = gravity
        var jump = Real(0)
        match self.mode:
            case == MODE_SWIM:
                g = gravity * (1 - self.cfg.buoyancy)
                var vy = self._vy(self.cc.velocity) * exp(-self.cfg.water_drag * dt) + self._vy(wish) * (1 - exp(-self.cfg.water_drag * dt))
                self.cc.velocity = self._with_vy(self.cc.velocity, vy)
                self.rising_jump = False
            case == MODE_GLIDE:
                # gravity integrated here and the sink speed clamped, so the
                # controller (given no gravity) never exceeds it
                var vy = max(self._vy(self.cc.velocity) + self._vy(gravity) * dt, -self.glide_sink)
                self.cc.velocity = self._with_vy(self.cc.velocity, vy)
                g = Vec3(0, 0, 0, 0)
            case == MODE_FLY:
                g = Vec3(0, 0, 0, 0)
                self.cc.velocity = self._with_vy(self.cc.velocity, self._vy(wish))
                if grounded and self._vy(wish) > 0:
                    jump = self._vy(wish)
            case _:
                var ground_ok = grounded or self.air_ticks <= self.cfg.coyote_ticks
                var pending = self.press_ticks <= self.cfg.buffer_ticks
                var fire = False
                if pending and self.jumps == 0 and ground_ok:
                    self.jumps = 1  # from the ground, or within coyote time
                    fire = True
                elif jump_pressed and (self.jumps >= 1 or not ground_ok) and max(self.jumps, 1) < self.cfg.max_jumps:
                    self.jumps = max(self.jumps, 1) + 1  # an air jump needs a fresh press
                    fire = True
                if fire:
                    self.press_ticks = 1 << 30
                    self.rising_jump = True
                    if grounded:
                        jump = self.cfg.jump_speed
                    else:
                        self.cc.velocity = self._with_vy(self.cc.velocity, self.cfg.jump_speed)
                elif self.rising_jump and not jump_held and self._vy(self.cc.velocity) > 0:
                    self.cc.velocity = self._with_vy(self.cc.velocity, self._vy(self.cc.velocity) * self.cfg.jump_cut)
                    self.rising_jump = False
        # external vertical velocity
        var ev = self._vy(self.ext)
        if ev != 0:
            if grounded and ev > 0 and jump == 0:
                jump = ev
            elif not grounded:
                self.cc.velocity = self._with_vy(self.cc.velocity, self._vy(self.cc.velocity) + ev * dt * self.cfg.ext_decay)
        var gb = self.cc.ground_body
        self.cc.update(sc, walk, jump, dt, g)
        if grounded and gb >= 0 and gb < len(sc.bset.bodies) and sc.bset.moves(gb):
            self.heading += self._vy(sc.bset.bodies[gb].omega_world()) * dt
        if self._vy(self.cc.velocity) <= 0:
            self.rising_jump = False
        self.ext = self.ext * exp(-self.cfg.ext_decay * dt)
