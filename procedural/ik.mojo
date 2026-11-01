"""Character inverse kinematics (ROADMAP 17.3).

Positions in, positions (and the rotations that produce them) out -- every
solver here works on joint POSITIONS, so it composes with `anim_graph` poses
after forward kinematics and hands its result back as per-joint shortest-arc
rotations.

  `two_bone`      analytic (law of cosines) for hip-knee-ankle /
                  shoulder-elbow-wrist; the bend plane is set by a pole
                  vector; an unreachable target straightens the chain toward
                  it; bone lengths are preserved exactly by construction
  `fabrik`        FABRIK (Aristidou & Lasenby 2011) on one chain with a fixed
                  root; iterative, any number of joints
  `fabrik_multi`  several chains hanging off one shared root joint (a
                  spine with two arms): per-chain backward passes, the shared
                  root pulled to the centroid of what they want, then forward
                  passes -- the multi-end-effector variant
  `look_at`       the rotation turning `forward` toward a direction, limited
                  to a cone
  `foot_plant`    lift or lower an ankle target onto a ground height and tilt
                  the foot to its normal; the caller supplies height and
                  normal (from a world query), so this module needs no
                  collision layer

The analytic and the iterative solver are two implementations of one map for
a two-segment chain (the seam): both put the end effector on a reachable
target and keep the segment lengths; which knee they choose depends on the
pole (analytic) or the starting pose (FABRIK).
"""

from std.math import sqrt, acos, isfinite
from geometry.trig import cos, sin
from geometry.vec import Real, Vec3, dot, cross, length


def _norm(v: Vec3) -> Vec3:
    var l = sqrt(dot(v, v))
    if l < 1e-12:
        return Vec3(0, 0, 0, 0)
    return v * (1 / l)


def _finite(v: Vec3) -> Bool:
    return isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])


@fieldwise_init
struct TwoBone(Copyable, ImplicitlyCopyable, Movable):
    var mid: Vec3  # new middle joint (knee / elbow)
    var end: Vec3  # new end effector (ankle / wrist)
    var reached: Bool


def two_bone(root: Vec3, mid: Vec3, end: Vec3, target: Vec3, pole: Vec3) -> TwoBone:
    """Place `mid` and `end` so that `end` lands on `target` (or as close as
    the chain reaches), the root->mid and mid->end lengths are unchanged,
    and the chain bends in the plane of root, target and `pole`. A
    non-finite target returns the input unchanged."""
    var l1 = length(mid - root)
    var l2 = length(end - mid)
    if not _finite(target) or l1 < 1e-12 or l2 < 1e-12:
        return TwoBone(mid, end, False)
    var to = target - root
    var d = length(to)
    var dir: Vec3
    if d < 1e-9:
        # target on the root: fold along the current direction
        dir = _norm(end - root)
        if dot(dir, dir) == 0:
            dir = Vec3(0, 1, 0, 0)
    else:
        dir = to * (1 / d)
    var reach = l1 + l2
    var reached = d <= reach and d >= abs(l1 - l2)
    var dc = min(max(d, abs(l1 - l2)), reach)
    # bend direction: pole projected off the root->target line
    var pv = pole - root
    var bend = pv - dir * dot(pv, dir)
    if dot(bend, bend) < 1e-12:
        # pole on the line: keep the current knee's side
        var cv = mid - root
        bend = cv - dir * dot(cv, dir)
        if dot(bend, bend) < 1e-12:
            bend = cross(dir, Vec3(0, 0, 1, 0))
            if dot(bend, bend) < 1e-12:
                bend = cross(dir, Vec3(1, 0, 0, 0))
    bend = _norm(bend)
    # angle at the root between the target line and the upper bone
    var cos_a = (l1 * l1 + dc * dc - l2 * l2) / (2 * l1 * dc) if dc > 1e-12 else Real(1)
    cos_a = min(max(cos_a, Real(-1)), Real(1))
    var sin_a = sqrt(max(1 - cos_a * cos_a, Real(0)))
    var new_mid = root + (dir * cos_a + bend * sin_a) * l1
    var new_end = new_mid + _norm(root + dir * dc - new_mid) * l2
    return TwoBone(new_mid, new_end, reached)


def chain_lengths(joints: List[Vec3]) -> List[Real]:
    var l = List[Real]()
    for i in range(len(joints) - 1):
        l.append(length(joints[i + 1] - joints[i]))
    return l^


def fabrik(mut joints: List[Vec3], target: Vec3, iters: Int = 16, tol: Real = 1e-4) -> Int:
    """Solve in place with `joints[0]` fixed. Returns the iterations used
    (0 if the target is unreachable: the chain is laid straight toward it,
    or if the target is not finite: the chain is left as it was)."""
    var n = len(joints)
    if n < 2 or not _finite(target):
        return 0
    var lens = chain_lengths(joints)
    var total = Real(0)
    for i in range(n - 1):
        total += lens[i]
    var root = joints[0]
    if length(target - root) >= total:
        var dir = _norm(target - root)
        for i in range(n - 1):
            joints[i + 1] = joints[i] + dir * lens[i]
        return 0
    for it in range(iters):
        if length(joints[n - 1] - target) <= tol:
            return it
        # backward: end to target, walk to the root
        joints[n - 1] = target
        for i in range(n - 2, -1, -1):
            joints[i] = joints[i + 1] + _norm(joints[i] - joints[i + 1]) * lens[i]
        # forward: root back in place, walk to the end
        joints[0] = root
        for i in range(n - 1):
            joints[i + 1] = joints[i] + _norm(joints[i + 1] - joints[i]) * lens[i]
    return iters


def fabrik_multi(
    mut shared: Vec3, root_anchor: Vec3, root_len: Real,
    mut chains: List[List[Vec3]], targets: List[Vec3], iters: Int = 16,
) -> Real:
    """Chains hang off the joint `shared` (their element 0 is `shared`),
    which itself hangs at distance `root_len` from the fixed `root_anchor`
    (e.g. pelvis -> chest). Each iteration: every chain's backward pass
    proposes a position for `shared`; `shared` moves to their centroid and
    back onto its sphere around `root_anchor`; forward passes follow.
    Returns the worst end-effector error."""
    var nc = len(chains)
    var lens = List[List[Real]]()
    for c in range(nc):
        lens.append(chain_lengths(chains[c]))
    for _ in range(iters):
        var centroid = Vec3(0, 0, 0, 0)
        for c in range(nc):
            var n = len(chains[c])
            var j = chains[c].copy()
            j[n - 1] = targets[c]
            for i in range(n - 2, -1, -1):
                j[i] = j[i + 1] + _norm(j[i] - j[i + 1]) * lens[c][i]
            centroid = centroid + j[0]
        centroid = centroid * (1 / Real(nc))
        shared = root_anchor + _norm(centroid - root_anchor) * root_len
        for c in range(nc):
            var n = len(chains[c])
            chains[c][0] = shared
            # backward toward the target once more, then forward from shared
            chains[c][n - 1] = targets[c]
            for i in range(n - 2, 0, -1):
                chains[c][i] = chains[c][i + 1] + _norm(chains[c][i] - chains[c][i + 1]) * lens[c][i]
            for i in range(n - 1):
                chains[c][i + 1] = chains[c][i] + _norm(chains[c][i + 1] - chains[c][i]) * lens[c][i]
    var worst = Real(0)
    for c in range(nc):
        worst = max(worst, length(chains[c][len(chains[c]) - 1] - targets[c]))
    return worst


def look_at(forward: Vec3, desired: Vec3, max_angle: Real) -> Tuple[Vec3, Real]:
    """Axis and angle turning unit `forward` toward `desired`, the angle
    clamped to `max_angle` (radians). Parallel inputs give angle 0; an
    exactly opposite `desired` turns about any perpendicular axis."""
    var f = _norm(forward)
    var d = _norm(desired)
    if dot(d, d) == 0 or dot(f, f) == 0:
        return (Vec3(0, 1, 0, 0), Real(0))
    var c = min(max(dot(f, d), Real(-1)), Real(1))
    var ang = acos(c)
    var axis = cross(f, d)
    if dot(axis, axis) < 1e-12:
        if c > 0:
            return (Vec3(0, 1, 0, 0), Real(0))
        axis = cross(f, Vec3(0, 1, 0, 0))
        if dot(axis, axis) < 1e-12:
            axis = cross(f, Vec3(1, 0, 0, 0))
    return (_norm(axis), min(ang, max_angle))


def rotate(v: Vec3, axis: Vec3, angle: Real) -> Vec3:
    """Rodrigues: `v` turned by `angle` about unit `axis`."""
    var c = cos(angle)
    var s = sin(angle)
    return v * c + cross(axis, v) * s + axis * (dot(axis, v) * (1 - c))


@fieldwise_init
struct FootPlant(Copyable, ImplicitlyCopyable, Movable):
    var ankle: Vec3  # IK target for the ankle
    var foot_axis: Vec3  # rotation axis tilting the foot onto the ground
    var foot_angle: Real
    var planted: Bool


def foot_plant(
    ankle: Vec3, ankle_height: Real, ground_y: Real, ground_normal: Vec3,
    max_lift: Real, max_tilt: Real,
) -> FootPlant:
    """Move the ankle target so the sole sits on the ground (ankle
    `ankle_height` above it), if the ground is within `max_lift` of where
    the animation put the foot; tilt the foot toward the ground normal by
    at most `max_tilt`. Ground out of reach leaves the animated ankle."""
    var want = ground_y + ankle_height
    if abs(want - ankle[1]) > max_lift or not isfinite(ground_y):
        return FootPlant(ankle, Vec3(0, 1, 0, 0), 0, False)
    var la = look_at(Vec3(0, 1, 0, 0), ground_normal, max_tilt)
    return FootPlant(Vec3(ankle[0], want, ankle[2], 0), la[0], la[1], True)
