# tier: system
"""Rules owned by the Runtime (ROADMAP 17.70, ludens-engine #97).

`Runtime.enable_rules` / `add_actor`: the runtime steps its `rules` over its `actors` on every tick that runs the timers.

  1. Off by default: a runtime that never calls `enable_rules` leaves `rules.tick` at 0 and its actors alone.
  2. Parity with a standalone `Rules`: the same buff and damage-over-time effects, applied to the same actor, stepped by
     the runtime for 400 frames and by hand for 400 ticks: the actor bytes (`actor_to_bytes`) are equal at ticks 150,
     301 and 400 and the death is reported on the same tick.
  3. Flow: a state that runs the simulation but not the timers pauses the rules (the rule tick does not move and the
     effects do not expire); after it ends the runtime's actor equals a standalone one stepped the same number of ticks.
Times are not printed (the golden compares this output)."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.flow import TICK_ALL, TICK_SIM
from gameplay.rules import (
    Actor, EffectDef, FX, KIND_DURATION, KIND_PERIODIC, OP_ADD, OP_MUL, Rules, STACK_REFRESH, actor_to_bytes,
)

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]
comptime HEALTH = 0
comptime SPEED = 1
comptime PLAYING = 1
comptime PAUSED = 2


def make_actor() -> Actor:
    var a = Actor(2, 1)
    a.attrs.set_range(HEALTH, 0, 100 * FX)
    a.attrs.set_base(HEALTH, 100 * FX)
    a.attrs.set_base(SPEED, 5 * FX)
    return a^


def define_effects(mut r: Rules) -> Tuple[Int, Int]:
    var buff = r.define(EffectDef(KIND_DURATION, 300, 0, SPEED, OP_MUL, 200, 0, 0, STACK_REFRESH, 1))
    var dot = r.define(EffectDef(KIND_PERIODIC, 300, 30, HEALTH, OP_ADD, -10 * FX, 0, 0, STACK_REFRESH, 1))
    return (buff, dot)


def runtime() raises -> Rt:
    var rt = Rt(DT, G)
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    return rt^


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


def frames(mut rt: Rt, n: Int) raises:
    for _ in range(n):
        _ = rt.advance(Float64(DT))


def main() raises:
    var s = Suite("runtime_rules")

    # 1. off by default
    var off = runtime()
    _ = off.add_actor(2, 1)
    frames(off, 30)
    s.check(off.rules.tick == 0 and not off.rules_on, "rules are off until enable_rules: the rule tick stays 0")

    # 2. parity with a standalone Rules
    var rt = runtime()
    rt.enable_rules(HEALTH)
    var ids = define_effects(rt.rules)
    var idx = rt.add_actor(2, 1)
    rt.actors[idx].attrs.set_range(HEALTH, 0, 100 * FX)
    rt.actors[idx].attrs.set_base(HEALTH, 100 * FX)
    rt.actors[idx].attrs.set_base(SPEED, 5 * FX)
    _ = rt.rules.apply(rt.actors[idx], ids[0], 1)
    _ = rt.rules.apply(rt.actors[idx], ids[1], 1)

    var ref_rules = Rules(HEALTH)
    var ref_ids = define_effects(ref_rules)
    var ref_actors = List[Actor]()
    ref_actors.append(make_actor())
    _ = ref_rules.apply(ref_actors[0], ref_ids[0], 1)
    _ = ref_rules.apply(ref_actors[0], ref_ids[1], 1)

    var ok150 = False
    var ok301 = False
    var ok400 = False
    var death_rt = -1
    var death_ref = -1
    for t in range(1, 401):
        frames(rt, 1)
        ref_rules.step(ref_actors)
        if len(rt.rules.deaths) > 0 and death_rt < 0:
            death_rt = rt.rules.tick
        if len(ref_rules.deaths) > 0 and death_ref < 0:
            death_ref = ref_rules.tick
        if t == 150:
            ok150 = same(actor_to_bytes(rt.actors[0]), actor_to_bytes(ref_actors[0]))
        if t == 301:
            ok301 = same(actor_to_bytes(rt.actors[0]), actor_to_bytes(ref_actors[0]))
        if t == 400:
            ok400 = same(actor_to_bytes(rt.actors[0]), actor_to_bytes(ref_actors[0]))
    s.check(rt.rules.tick == 400, "the runtime stepped the rules once per frame (400)")
    s.check(ok150 and ok301 and ok400, "the actor's bytes equal the standalone run at ticks 150, 301 and 400")
    s.check(death_rt == death_ref, "a death, if any, is reported on the same tick (" + String(death_rt) + " vs " + String(death_ref) + ")")
    s.check(rt.actors[0].attrs.value(SPEED) == 5 * FX, "the buff expired exactly (speed back to 5.000)")

    # 3. flow: a state without TICK_TIMERS pauses the rules
    var fl = runtime()
    fl.enable_rules(HEALTH)
    var fids = define_effects(fl.rules)
    var fi = fl.add_actor(2, 1)
    fl.actors[fi].attrs.set_range(HEALTH, 0, 100 * FX)
    fl.actors[fi].attrs.set_base(HEALTH, 100 * FX)
    fl.actors[fi].attrs.set_base(SPEED, 5 * FX)
    _ = fl.rules.apply(fl.actors[fi], fids[0], 1)
    fl.flow.push(PLAYING, TICK_ALL)
    frames(fl, 100)
    var tick_before = fl.rules.tick
    var bytes_before = actor_to_bytes(fl.actors[0])
    fl.flow.push(PAUSED, TICK_SIM)
    frames(fl, 250)
    s.check(fl.rules.tick == tick_before and same(bytes_before, actor_to_bytes(fl.actors[0])), "250 frames in a state without timers: the rule tick and the actor do not move")
    _ = fl.flow.pop()
    frames(fl, 200)
    var sr = Rules(HEALTH)
    var sids = define_effects(sr)
    var sa = List[Actor]()
    sa.append(make_actor())
    _ = sr.apply(sa[0], sids[0], 1)
    for _ in range(300):
        sr.step(sa)
    s.check(fl.rules.tick == 300 and same(actor_to_bytes(fl.actors[0]), actor_to_bytes(sa[0])), "after the pause, 300 rule ticks in all equal a standalone actor stepped 300 ticks")
    s.finish()
