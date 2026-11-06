# tier: integration
"""Module-swap world transfer (ROADMAP 17.91, ludens-engine #84).

- hand-over: a world saved at tick 60 and loaded into a fresh instance continues bit for bit like the world that was
  never interrupted (same hash after N more ticks, same events), with a scene that has bodies of both shapes, host
  materials and user data (neither is in `EmbedWorld.save` alone: materials come from the transfer table);
- refusals, each leaving the target world unchanged: a blob from another format version, another scalar width,
  other settings (dt, gravity, a solver knob), a different set of registered names, a flipped payload byte, a
  truncated blob at every length, a blob that is not ours;
- registration set is compared as a set (order does not matter);
- extremes: an empty world, a world loaded into a world that already has bodies, a fractured world is refused on save.
The times are measured by `experiments/exp_transfer_cost.mojo`; this test prints no times (the golden compares it).
"""
from harness.runner import Suite
from embed.scene_io import export_scene
from embed.transfer import (
    TRANSFER_VERSION,
    XFER_CORRUPT,
    XFER_MAGIC,
    XFER_OK,
    XFER_REGISTRATION,
    XFER_SCALAR,
    XFER_SETTINGS,
    XFER_TRUNCATED,
    XFER_VERSION,
    transfer_check,
    transfer_info,
    transfer_load,
    transfer_save,
)
from embed.world import EmbedWorld
from geometry.quat import Quat
from geometry.vec import Real, Vec3

comptime DT = 1.0 / 60.0


def build() raises -> EmbedWorld:
    var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    var floor = w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
    w.set_material(floor, 7)
    for i in range(6):
        var b = w.add_box(Vec3(Real(i) * 1.1 - 3.0, 1.0 + Real(i) * 1.05, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
        w.set_material(b, UInt32(10 + i))
        w.set_user(b, UInt64(1000 + i))
    var s = w.add_sphere(Vec3(0.3, 9.0, 0.1, 0.0), 0.4, 2.0, False)
    w.set_material(s, 99)
    return w^


def run(mut w: EmbedWorld, ticks: Int) raises:
    for _ in range(ticks):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def set_of(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def flip(blob: List[UInt8], at: Int) -> List[UInt8]:
    var out = blob.copy()
    out[at] = out[at] ^ 0x5A
    return out^


def main() raises:
    var s = Suite("transfer")
    var names = set_of("gravity_zone", "pickup_sensor")

    # hand-over
    var a = build()
    run(a, 60)
    var blob = transfer_save(a, names)
    var info = transfer_info(blob)
    s.eqi(info.status, XFER_OK, "header of a fresh blob reads ok")
    s.eqi(info.version, TRANSFER_VERSION, "header carries the format version")
    run(a, 120)  # the uninterrupted world continues
    var b = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    s.eqi(transfer_check(b, blob, names), XFER_OK, "a fresh instance with the same settings and names accepts it")
    transfer_load(b, blob, names)
    s.eqi(b.tick, 60, "tick restored")
    run(b, 120)
    s.check(a.hash() == b.hash(), "after 120 more ticks the handed-over world has the same hash as the uninterrupted one")
    s.eqi(b.tick, a.tick, "same tick")
    # materials and user data cross the swap
    var first = b.scene.bset.id_of(1)
    s.check(b.get_material(Int64(first.slot) | (Int64(first.gen) << 32)) == 10, "host material survives")
    s.check(b.get_user(Int64(first.slot) | (Int64(first.gen) << 32)) == 1000, "user data survives")

    # registered set, order independent
    var rev = set_of("pickup_sensor", "gravity_zone")
    var c = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    s.eqi(transfer_check(c, blob, rev), XFER_OK, "registration order does not matter")
    var d = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    var missing = List[String]()
    missing.append("gravity_zone")
    s.eqi(transfer_check(d, blob, missing), XFER_REGISTRATION, "a name missing after the swap is refused")
    var extra = set_of("gravity_zone", "pickup_sensor")
    extra.append("new_system")
    s.eqi(transfer_check(d, blob, extra), XFER_REGISTRATION, "an extra name is refused too")
    var failed = False
    try:
        transfer_load(d, blob, missing)
    except e:
        failed = True
        s.check(String(e).startswith("transfer_load(-6)"), "the error carries the status: " + String(e))
    s.check(failed, "load raises when a registration is missing")
    s.eqi(d.tick, 0, "...and the target world is unchanged")

    # settings
    var g = EmbedWorld(DT, Vec3(0.0, -1.62, 0.0, 0.0))
    s.eqi(transfer_check(g, blob, names), XFER_SETTINGS, "other gravity is refused")
    var dt2 = EmbedWorld(1.0 / 120.0, Vec3(0.0, -9.81, 0.0, 0.0))
    s.eqi(transfer_check(dt2, blob, names), XFER_SETTINGS, "other dt is refused")
    var knob = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    knob.cfg.iters = knob.cfg.iters + 1
    s.eqi(transfer_check(knob, blob, names), XFER_SETTINGS, "a changed solver knob is refused")
    var par = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    par.cfg.workers = par.cfg.workers + 3
    s.eqi(transfer_check(par, blob, names), XFER_OK, "an execution-only knob (workers) is not part of the settings")

    # version and scalar width: patch the header of a valid blob
    var v2 = blob.copy()
    v2[8] = UInt8(TRANSFER_VERSION + 1)
    var e1 = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    s.eqi(transfer_check(e1, v2, names), XFER_VERSION, "another format version is refused")
    var raised = String()
    try:
        transfer_load(e1, v2, names)
    except e:
        raised = String(e)
    s.check(raised.startswith("transfer_load(-3)") and "blob 2, here 1" in raised, "version error names both versions: " + raised)
    var wide = blob.copy()
    wide[16] = UInt8(16)
    s.eqi(transfer_check(e1, wide, names), XFER_SCALAR, "another scalar width is refused")

    # damage
    var any_ok = 0
    for k in range(60, len(blob), 97):
        if transfer_check(e1, flip(blob, k), names) == XFER_OK:
            any_ok += 1
    s.eqi(any_ok, 0, "a flipped byte anywhere in the payload is never accepted")
    s.eqi(transfer_check(e1, flip(blob, 49), names), XFER_CORRUPT, "a flipped checksum byte is reported as corruption")
    var not_ours = blob.copy()
    not_ours[0] = 0
    s.eqi(transfer_check(e1, not_ours, names), XFER_MAGIC, "a blob with another magic is refused")
    var accepted = 0
    var wrong_status = 0
    for n in range(0, len(blob), 1):
        var cut = List[UInt8]()
        for i in range(n):
            cut.append(blob[i])
        var st = transfer_check(e1, cut, names)
        if st == XFER_OK:
            accepted += 1
        elif st != XFER_TRUNCATED and st != XFER_MAGIC:
            wrong_status += 1
    s.eqi(accepted, 0, "no truncated prefix is accepted (every length from 0 to size-1 tried)")
    s.eqi(wrong_status, 0, "every truncation is reported as truncated (or as a bad magic for the empty prefix)")
    s.eqi(e1.tick, 0, "...and the target world was never touched")

    # extremes
    var empty = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    var eblob = transfer_save(empty, List[String]())
    var target = build()
    run(target, 10)
    transfer_load(target, eblob, List[String]())
    s.eqi(target.tick, 0, "an empty world loaded into a populated one replaces it")
    run(target, 5)
    s.eqi(len(export_scene(target).bodies), 0, "...and the bodies are gone")

    s.finish()
