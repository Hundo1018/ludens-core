# tier: integration
"""`physics.solver6.ContactScene6.remove_body` (ROADMAP 17.0i): the
17.0g-1 deferral `physics/body_set.mojo`'s module docstring flagged --
`BodySet.remove`/`is_valid` existed and were tested there, but nothing on
`ContactScene6` called them, so a body could never actually leave a scene.

This is also the regression test for the landmine removal exposed: before
this commit, `BodySet.push` already reused a freed slot's LOW index (its
own free list, unrelated to removal ever reaching `ContactScene6`), but
`ColliderSet.add*` only ever appended, so a body added into a reused slot
would desync `collider i == body i` and trip `ContactScene6.add`'s own
`debug_assert` -- under `-D ASSERT=all` (every test run), that aborts the
whole process, not just this file. `ColliderSet.add`'s new `at` parameter
(overwrite-in-place instead of append, when the caller already knows the
target slot) is what `_push_body` + `add*` now thread through, verified
here by actually driving a remove -> add -> step cycle through a REAL
scene rather than unit-testing `ColliderSet` in isolation.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6
from physics.body_set import BodyId
from physics.solver_config import SolverConfig

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]) -> BodyId:
    return sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )


def _box(y: Real) -> QuatBody6:
    return QuatBody6.at_rest(Vec3(0, y, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25))


def _test_ordinary(mut s: Suite) raises:
    """Remove an unreferenced dynamic body: its id goes invalid, the scene
    keeps stepping, and the removed body plays no further part."""
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var a = sc.add(_box(0.3), Vec3(0.25, 0.25, 0.25, 0), False)
    var b = sc.add(_box(5.0), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(10):
        sc.step_soft(DT, G)
    s.check(sc.bset.is_valid(a) and sc.bset.is_valid(b), "both ids valid before removal")

    sc.remove_body(b)
    s.check(not sc.bset.is_valid(b), "removed id reads invalid")
    s.check(sc.bset.is_valid(a), "the OTHER body's id is untouched")

    # must keep stepping without crashing (the removed slot is now a
    # tombstone -- `BodySet.inactive`/`_collect_pairs`/`_quarantine_nonfinite` all
    # need to leave it alone).
    for _ in range(30):
        sc.step_soft(DT, G)
    s.check(sc.bset.is_valid(a), "surviving body still valid after more steps")
    s.almost(
        Float64(sc.bset.bodies[a.index()].position()[1]), 0.25, "box a rests on the ground undisturbed", 0.05,
    )


def _test_integration(mut s: Suite) raises:
    """Remove a body, add a NEW one (reuses the freed slot via `BodySet`'s
    free list), and confirm the new body's COLLIDER geometry is the new
    shape, not a stale copy of the removed one -- the `ColliderSet.add(...,
    at=...)` overwrite path this commit added."""
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var old = sc.add(_box(0.3), Vec3(0.25, 0.25, 0.25, 0), False)  # small box
    sc.remove_body(old)

    # A much bigger box should land in the freed (low) slot.
    var fresh = sc.add(
        QuatBody6.at_rest(Vec3(0, 3.0, 0, 0), Inertia3.box(4, 1, 1, 1)),
        Vec3(1, 1, 1, 0), False,
    )
    s.eqi(fresh.index(), old.index(), "the freed slot is reused by the next add")
    s.check(fresh.gen != old.gen, "the reused slot's generation is bumped")
    s.almost(
        Float64(sc.colliders.half[fresh.index()][0]), 1.0,
        "the reused collider slot holds the NEW body's half-extent, not the old one", 1e-6,
    )

    # Step it to rest on the ground -- exercises the reused collider row
    # through a real narrowphase pass, under -D ASSERT=all (the desync
    # `debug_assert` this whole file guards against).
    for _ in range(120):
        sc.step_soft(DT, G)
    s.almost(
        Float64(sc.bset.bodies[fresh.index()].position()[1]), 1.0,
        "the reused-slot body settles at ITS OWN (bigger) rest height", 0.05,
    )


def _test_extreme(mut s: Suite) raises:
    """Invalid id, joint-referenced id, and despawn-during-contact."""
    var sc = ContactScene6[QuatBody6]()
    _ = _ground(sc)
    var a = sc.add(_box(0.3), Vec3(0.25, 0.25, 0.25, 0), False)
    var b = sc.add(_box(5.0), Vec3(0.25, 0.25, 0.25, 0), False)

    # -- invalid BodyId: already removed --
    sc.remove_body(a)
    var raised_stale = False
    try:
        sc.remove_body(a)
    except:
        raised_stale = True
    s.check(raised_stale, "extreme: removing an already-removed id raises")

    # -- joint-referenced body: must raise, and must NOT remove it --
    var sc2 = ContactScene6[QuatBody6]()
    _ = _ground(sc2)
    var j_a = sc2.add(_box(0.3), Vec3(0.25, 0.25, 0.25, 0), False)
    var j_b = sc2.add(_box(1.0), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc2.add_joint(
        Joint6.distance(
            j_a.index(), j_b.index(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 0.7,
        )
    )
    var raised_joint = False
    try:
        sc2.remove_body(j_a)
    except:
        raised_joint = True
    s.check(raised_joint, "extreme: removing a joint-referenced body raises")
    s.check(sc2.bset.is_valid(j_a), "extreme: the refused removal left the body intact")
    # scene still steppable afterwards (the joint keeps working).
    for _ in range(10):
        sc2.step_soft(DT, G)
    s.check(sc2.bset.is_valid(j_a) and sc2.bset.is_valid(j_b), "extreme: joint-linked bodies still valid after stepping")

    # -- despawn a body mid-contact: stepping must not crash, and the
    # survivor keeps resting on the ground alone. --
    for _ in range(20):
        sc.step_soft(DT, G)  # b falls, not yet landed
    sc.remove_body(b)
    for _ in range(60):
        sc.step_soft(DT, G)
    s.check(not sc.bset.is_valid(b), "extreme: despawn-during-fall leaves id invalid")


def main() raises:
    var s = Suite("body_removal")
    _test_ordinary(s)
    _test_integration(s)
    _test_extreme(s)
    # ROADMAP 17.79: removed slots stay out of the broadphase. 400 boxes in
    # touching stacks, all removed: the BVH broadphase holds only the floor
    # (it held all 401, and their stale overlaps cost 12.5 ms a step at
    # 10000), and a box added afterwards reuses slot 1 and lands on the floor.
    var big = ContactScene6[QuatBody6]()
    _ = big.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    var many = List[BodyId]()
    for k in range(400):
        many.append(big.add(QuatBody6.at_rest(Vec3(Real(k % 20) - 10, 0.25 + 0.5 * Real(k // 20), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False))
    var bcfg = SolverConfig()
    bcfg.broadphase = True
    big.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), bcfg)
    var before = len(big.bp.items)
    for id in many:
        big.remove_body(id)
    big.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), bcfg)
    var after = len(big.bp.items)
    var again = big.add(QuatBody6.at_rest(Vec3(3, 1, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(90):
        big.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), bcfg)
    print("broadphase items before / after removing 400:", before, after, "  re-added box slot", again.index(), " y", big.pose(again).pos[1])
    s.check(before == 401 and after == 1, "removed bodies leave the broadphase")
    s.check(again.index() == 1 and abs(big.pose(again).pos[1] - 0.25) < 0.01, "a box added after the mass removal reuses slot 1 and rests on the floor")
    s.finish()
