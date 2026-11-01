"""Kinematic capsule character controller (ROADMAP 17.1).

A character is not a rigid body: players expect it to stop dead against a
wall, walk up gentle slopes and small steps without bouncing, stay glued to
the ground over bumps, ride moving platforms, and never be launched by the
solver. The controller therefore moves a capsule by SWEEPING it through the
world (`collision.world_query` through `ContactScene6`'s wrappers) and never
enters the contact solver itself (the Unity CharacterController / Jolt
CharacterVirtual / Godot CharacterBody3D shape).

One `update(sc, walk_velocity, jump, dt, gravity)` does, in order:
1. gravity / jump on the vertical velocity (zeroed while grounded);
2. platform inheritance: while standing on a kinematic or dynamic body, add
   that body's surface velocity at the foot point;
3. move-and-slide: sweep along the remaining displacement, stop a skin short of
   the hit, remove the component into the surface, repeat (`max_slides`);
   a steep surface hit while grounded first tries a STEP: up by
   `step_height`, across, back down, accepted only if it lands on walkable
   ground;
4. depenetration: push out of anything still overlapped (spawned inside a
   wall, squeezed by a platform);
5. ground probe: a short downward sweep decides `on_ground` (normal within
   `max_slope`), the ground body, and snaps the capsule down onto it when
   walking over small drops so it does not go airborne on every bump;
6. ceiling: an upward hit zeroes upward velocity.
Dynamic bodies hit during the slide receive an impulse along the push
direction (`push_strength`), which is the controller's half of two-way
interaction; the other half (a body shoving the character) is step 4.

The capsule is vertical: centre `position`, segment half-length `half_height`,
radius `radius`; its bottom is `position.y - half_height - radius`. It can
lie along a horizontal axis (`set_lying`, ROADMAP 17.67; then its bottom is
`position.y - radius`), and `half_height = 0` makes it a sphere.

Box option (ROADMAP 17.53): `CharacterController(p, cfg, box_rounding=r)`
with r >= 0 sweeps an axis-aligned box of half extents (radius,
half_height + radius, radius) instead -- the same footprint and height,
with a flat bottom that stands level on a ledge up to its edge (a capsule's
round bottom rests on the edge and sinks below the ledge top) -- through
`shape_cast` / `shape_penetrations`.
Its edges are rounded by r so an overlap up to r deep has a push-out
direction; the default -1 keeps the capsule.
"""

from std.math import sqrt, acos
from geometry.trig import cos
from geometry.vec import Real, Vec3, dot, length, cross
from geometry.quat import Quat
from collision.world_query import QueryFilter, Hit, QueryShape, Penetration, pose3_of
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6

comptime _UP = Vec3(0, 1, 0, 0)
comptime _EPS: Real = 1e-6


@fieldwise_init
struct CharacterConfig(Copyable, ImplicitlyCopyable, Movable):
    var radius: Real
    var half_height: Real  # half of the segment between the hemisphere centres
    var max_slope_cos: Real  # cos(max walkable slope)
    var step_height: Real
    var skin: Real  # gap kept to surfaces
    var snap_distance: Real  # how far down the ground is followed
    var max_slides: Int
    var push_strength: Real  # fraction of the character speed handed to a pushed body
    var mask: UInt32

    @staticmethod
    def default() -> Self:
        return Self(0.3, 0.6, cos(Real(0.785398)), 0.3, 0.01, 0.25, 4, 1.0, 0xFFFFFFFF)


struct CharacterController(Copyable, Movable):
    var cfg: CharacterConfig
    var position: Vec3
    var velocity: Vec3
    var on_ground: Bool
    var ground_normal: Vec3
    var ground_body: Int
    var hit_ceiling: Bool
    var pushed: Int  # dynamic bodies pushed during the last update
    var box_rounding: Real  # < 0: capsule; >= 0: rounded box (17.53)
    var crushed: Bool  # squeezed between surfaces below and above this update (17.67)
    var lie: Vec3  # unit horizontal capsule axis when lying (17.67); zero = upright
    var up: Vec3  # unit up axis (17.67); gravity need not point along -y
    var _orient: Quat  # rotation taking +y to `up` (identity for +y)

    def __init__(out self, position: Vec3, cfg: CharacterConfig = CharacterConfig.default(), box_rounding: Real = -1):
        self.cfg = cfg
        self.box_rounding = box_rounding
        self.crushed = False
        self.lie = Vec3(0, 0, 0, 0)
        self.position = position
        self.velocity = Vec3(0, 0, 0, 0)
        self.on_ground = False
        self.ground_normal = _UP
        self.ground_body = -1
        self.hit_ceiling = False
        self.pushed = 0
        self.up = _UP
        self._orient = Quat.identity()

    def set_up(mut self, up: Vec3) raises:
        """Use `up` (normalised) as the character's vertical: the capsule or
        box stands along it, steps, slopes, snapping, jumps and gravity are
        measured along it (ROADMAP 17.67; planets, wall-walking). +y keeps
        the results bit for bit."""
        var l = length(up)
        if not (l > 0):
            raise Error("CharacterController.set_up: up must be non-zero")
        var u = up / l
        self.up = u
        var c = u[1]
        if c > 1 - 1e-7:
            self._orient = Quat.identity()
        elif c < -1 + 1e-7:
            self._orient = Quat.from_axis_angle(Vec3(1, 0, 0, 0), Real(3.141592653589793))
        else:
            var ax = cross(_UP, u)
            self._orient = Quat.from_axis_angle(ax / length(ax), acos(c))
        self.ground_normal = u

    def _h(self, v: Vec3) -> Vec3:
        """`v` without its component along `up`."""
        return v - self.up * dot(v, self.up)

    def _v(self, v: Vec3) -> Real:
        """Component of `v` along `up`."""
        return dot(v, self.up)

    # ---------------------------------------------------------------- shape

    def _axis(self) -> Vec3:
        """The capsule segment's direction: `up`, or the lying axis."""
        return self.lie if self.lie[0] != 0 or self.lie[1] != 0 or self.lie[2] != 0 else self.up

    def _seg(self, at: Vec3) -> Tuple[Vec3, Vec3]:
        var h = self._axis() * self.cfg.half_height
        return (at - h, at + h)

    def _filter(self) -> QueryFilter:
        return QueryFilter(self.cfg.mask, -1, False)

    def _lying(self) -> Bool:
        return self.lie[0] != 0 or self.lie[1] != 0 or self.lie[2] != 0

    def foot(self) -> Vec3:
        if self._lying():
            return self.position - self.up * self.cfg.radius
        return self.position - self.up * (self.cfg.half_height + self.cfg.radius)

    def _walkable(self, n: Vec3) -> Bool:
        return self._v(n) >= self.cfg.max_slope_cos

    def is_box(self) -> Bool:
        return self.box_rounding >= 0

    def _box(self, half_height: Real, shrink: Real) -> QueryShape:
        var r = self.cfg.radius - shrink
        return QueryShape.rounded_box(Vec3(r, half_height + r, r, 0), self.box_rounding)

    def _penetrations[B: Body6](self, sc: ContactScene6[B], at: Vec3, half_height: Real, shrink: Real) -> List[Penetration]:
        if self.is_box():
            return sc.shape_penetrations(self._box(half_height, shrink), pose3_of(at, self._orient), self._filter())
        var s = self._axis() * half_height
        return sc.capsule_penetrations(at - s, at + s, self.cfg.radius - shrink, self._filter())

    def _cast[B: Body6](self, sc: ContactScene6[B], at: Vec3, d: Vec3, dist: Real) -> Hit:
        if self.is_box():
            return sc.shape_cast(self._box(self.cfg.half_height, 0), pose3_of(at, self._orient), d, dist, self._filter())
        var s = self._seg(at)
        return sc.capsule_cast(s[0], s[1], self.cfg.radius, d, dist, self._filter())

    def set_lying[B: Body6](mut self, sc: ContactScene6[B], axis: Vec3) raises -> Bool:
        """Lie down along horizontal `axis` (crawling, a prone or four-legged
        body; ROADMAP 17.67), or stand back up with a zero axis, keeping the
        foot in place. Refused (False) when the new pose would overlap
        something: standing up in a crawl space. A box character cannot lie."""
        if self.is_box():
            raise Error("CharacterController.set_lying: a box character cannot lie down")
        var foot = self.foot()
        var l = length(axis)
        var new_lie = Vec3(0, 0, 0, 0)
        if l > 0:
            new_lie = self._h(axis) / l
            if abs(length(new_lie) - 1) > 1e-3:
                raise Error("CharacterController.set_lying: the axis must be horizontal")
        var old = self.lie
        self.lie = new_lie
        var c = foot + self.up * self.cfg.radius
        if not self._lying():
            c = foot + self.up * (self.cfg.half_height + self.cfg.radius)
        if len(self._penetrations(sc, c, self.cfg.half_height, self.cfg.skin)) > 0:
            self.lie = old
            return False
        self.position = c
        return True

    def set_half_height[B: Body6](mut self, sc: ContactScene6[B], h: Real) -> Bool:
        """Crouch / stand: change the capsule height keeping the foot fixed.
        Growing is refused (returns False) when the taller capsule would
        overlap something -- standing up under a low ceiling."""
        var foot = self.foot()
        var c = foot + self.up * h + self.up * self.cfg.radius
        if self._lying():
            c = foot + self.up * self.cfg.radius
        if h > self.cfg.half_height:
            if len(self._penetrations(sc, c, h, self.cfg.skin)) > 0:
                return False
        self.cfg.half_height = h
        self.position = c
        return True

    # ---------------------------------------------------------------- steps

    def _push[B: Body6](mut self, mut sc: ContactScene6[B], h: Hit, blocked: Vec3, dt: Real):
        if h.body < 0 or not sc.bset.is_dynamic(h.body):
            return
        var im = sc.bset.bodies[h.body].inv_mass()
        if im <= 0:
            return
        # Velocity-level push: bring the body's speed along the push
        # direction up to the character's (times push_strength); an impulse
        # proportional to the blocked displacement is too small to beat
        # friction and the box never moves.
        var d = self._h(-h.normal)
        var dl = length(d)
        if dl < _EPS:
            return
        d = d / dl
        var rel = dot(self.velocity, d) - dot(sc.bset.bodies[h.body].velocity_at(h.point), d)
        if rel <= 0:
            return
        try:
            sc.apply_impulse(sc.bset.id_of(h.body), d * (rel * self.cfg.push_strength / im), h.point)
        except:
            pass
        self.pushed += 1

    def _slide[B: Body6](mut self, mut sc: ContactScene6[B], disp: Vec3, dt: Real, allow_step: Bool):
        var remaining = disp
        for _ in range(self.cfg.max_slides):
            var dist = length(remaining)
            if dist < _EPS:
                return
            var d = remaining / dist
            var h = self._cast(sc, self.position, d, dist + self.cfg.skin)
            if not h.hit:
                self.position += remaining
                return
            var travel = max(Real(0), h.t - self.cfg.skin)
            self.position += d * travel
            remaining -= d * travel
            var n = h.normal
            if self._v(n) < -0.5 and self._v(remaining) > 0:
                self.hit_ceiling = True
            # a steep wall while grounded and walking: try a step first
            if (
                allow_step
                and self.on_ground
                and not self._walkable(n)
                and self._v(n) > -0.5
                and dot(self._h(remaining), self._h(remaining)) > _EPS
            ):
                if self._try_step(sc, remaining):
                    return
            self._push(sc, h, remaining, dt)
            var into = dot(remaining, n)
            if into < 0:
                remaining -= n * into
            # never let a steep slope lift the character: it slides, it does
            # not climb (walkable slopes keep their vertical component)
            if not self._walkable(n) and self._v(remaining) > 0 and self._v(n) > 0:
                remaining = self._h(remaining)

    def _try_step[B: Body6](mut self, sc: ContactScene6[B], remaining: Vec3) -> Bool:
        var up = self._cast(sc, self.position, self.up, self.cfg.step_height)
        var rise = self.cfg.step_height if not up.hit else max(Real(0), up.t - self.cfg.skin)
        if rise < self.cfg.skin:
            return False
        var raised = self.position + self.up * rise
        var horiz = self._h(remaining)
        var hl = length(horiz)
        var hd = horiz / hl
        var across = self._cast(sc, raised, hd, hl + self.cfg.skin)
        var moved = raised + hd * (hl if not across.hit else max(Real(0), across.t - self.cfg.skin))
        if across.hit and length(moved - raised) < _EPS:
            return False
        var down = self._cast(sc, moved, -self.up, rise + self.cfg.snap_distance)
        if not down.hit:
            return False
        var landed = moved - self.up * max(Real(0), down.t - self.cfg.skin)
        # Judge the step by the SUPPORTING SURFACE's height above the current
        # foot, not by how far the capsule rose: a rounded bottom resting on a
        # 0.5 m box's edge has risen less than 0.3 m, but the box is 0.5 m.
        var surf = self._surface(sc, down)
        var rise_to = surf[1] - self._v(self.foot())
        if not self._walkable(surf[0]) or rise_to < self.cfg.skin:
            return False
        if rise_to > self.cfg.step_height + self.cfg.skin:
            return False
        self.position = landed
        return True

    def _depenetrate[B: Body6](mut self, sc: ContactScene6[B]):
        """Push out of overlaps. Squeezed between a surface below and one
        above (a lift rising into a ceiling, ROADMAP 17.67) there is no
        room: the vertical part of the push is dropped, so the character
        is never shoved through either surface, and `crushed` reports it
        for the game to act on (damage, respawn). Without this a lift
        rising into a 0.5 m ceiling pushed the character up through it."""
        # sides seen over all iterations: squeezed, the pushes alternate
        # (up out of the lift into the ceiling, then back down) and never
        # show both sides in one iteration
        var below = False
        var above = False
        for _ in range(4):
            var pens = self._penetrations(sc, self.position, self.cfg.half_height, 0)
            if len(pens) == 0:
                return
            var push = Vec3(0, 0, 0, 0)
            for k in range(len(pens)):
                push += pens[k].normal * (pens[k].depth + self.cfg.skin * 0.5)
                var nu = self._v(pens[k].normal)
                if nu > 0.5:
                    below = True
                elif nu < -0.5:
                    above = True
            if below and above:
                self.crushed = True
                push = self._h(push)
            self.position += push

    def _surface[B: Body6](self, sc: ContactScene6[B], h: Hit) -> Tuple[Vec3, Real]:
        """Normal and height of the SURFACE under a hit, not of the contact.
        A rounded bottom resting on an edge reports the edge's diagonal
        normal and a contact point below the surface; a short ray down just
        past the edge, AWAY from the capsule axis (where the supporting
        surface continues), finds the top face and its height."""
        if self._walkable(h.normal):
            return (h.normal, self._v(h.point))
        var toward = self._h(self.position - h.point)
        var tl = length(toward)
        if tl < _EPS:
            return (h.normal, self._v(h.point))
        var o = h.point - toward * (0.02 / tl) + self.up * 0.05
        var r = sc.ray_cast(o, -self.up, 0.1, self._filter())
        if r.hit and self._walkable(r.normal):
            return (r.normal, self._v(r.point))
        return (h.normal, self._v(h.point))

    def _probe_ground[B: Body6](mut self, sc: ContactScene6[B], snap: Bool):
        if self._v(self.velocity) > _EPS:
            # moving up (a jump): never grounded, or the jump is undone
            self.on_ground = False
            self.ground_normal = self.up
            self.ground_body = -1
            return
        var h = self._cast(sc, self.position, -self.up, self.cfg.snap_distance + self.cfg.skin * 2)
        var n = self._surface(sc, h)[0] if h.hit else self.up
        if h.hit and self._walkable(n):
            self.on_ground = True
            self.ground_normal = n
            self.ground_body = h.body
            if snap and h.t > self.cfg.skin:
                self.position -= self.up * (h.t - self.cfg.skin)
        else:
            self.on_ground = False
            self.ground_normal = self.up
            self.ground_body = -1

    # ---------------------------------------------------------------- update

    def update[B: Body6](
        mut self,
        mut sc: ContactScene6[B],
        walk: Vec3,
        jump_speed: Real,
        dt: Real,
        gravity: Vec3,
    ):
        """Advance the character by one step. `walk` is the desired horizontal
        velocity; `jump_speed > 0` jumps if grounded."""
        self.hit_ceiling = False
        self.pushed = 0
        self.crushed = False
        var was_grounded = self.on_ground
        var vy = self._v(self.velocity)
        var jumped = False
        if was_grounded:
            vy = 0
            if jump_speed > 0:
                vy = jump_speed
                jumped = True
        else:
            vy += self._v(gravity) * dt
        self.velocity = self._h(walk) + self.up * vy
        var disp = self.velocity * dt
        # ride what we stand on
        if was_grounded and self.ground_body >= 0 and self.ground_body < len(sc.bset.bodies):
            if sc.bset.moves(self.ground_body):
                disp += sc.bset.bodies[self.ground_body].velocity_at(self.foot()) * dt
        # walking along the ground: follow its slope instead of pushing into it
        if was_grounded and not jumped:
            var into = dot(disp, self.ground_normal)
            if into < 0:
                disp -= self.ground_normal * into
        self._slide(sc, disp, dt, was_grounded)
        self._depenetrate(sc)
        self._probe_ground(sc, was_grounded and not jumped)
        if self.hit_ceiling and self._v(self.velocity) > 0:
            self.velocity = self._h(self.velocity)
        if self.on_ground and self._v(self.velocity) < 0:
            self.velocity = self._h(self.velocity)

    def teleport(mut self, p: Vec3):
        self.position = p
        self.velocity = Vec3(0, 0, 0, 0)
        self.on_ground = False
        self.ground_body = -1
