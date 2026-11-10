"""Experiment: what a module-swap world transfer costs (ROADMAP 17.91, ludens-core #84).

Per body count N (boxes, never stepped, each with a host material id and user data): `transfer_save`, `transfer_check`
(header, checksum, settings, registrations), `transfer_load`, the blob size, and for comparison the plain
`EmbedWorld.save` / `load` it wraps. Wall clock; run on an idle machine.

Run: pixi run mojo run -I build experiments/exp_transfer_cost.mojo"""
from std.time import perf_counter_ns
from embed.transfer import transfer_check, transfer_load, transfer_save
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3


def make(n: Int) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    for i in range(n):
        var h = w.add_box(Vec3(Real(i % 100) * 1.2, Real(i // 10000) * 1.2, Real((i // 100) % 100) * 1.2, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
        w.set_material(h, UInt32(1 + i % 5))
        w.set_user(h, UInt64(i + 1))
    return w^


def ms(t0: Int, t1: Int) -> Float64:
    return Float64(t1 - t0) / 1e6


def main() raises:
    var names = List[String]()
    names.append("gravity_zone")
    print("| bodies | transfer_save | transfer_check | transfer_load | blob bytes | save | load |")
    print("|---:|---:|---:|---:|---:|---:|---:|")
    for n in [1000, 10000, 100000]:
        var w = make(n)
        var t0 = perf_counter_ns()
        var blob = transfer_save(w, names)
        var t1 = perf_counter_ns()
        var w2 = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
        var st = transfer_check(w2, blob, names)
        var t2 = perf_counter_ns()
        transfer_load(w2, blob, names)
        var t3 = perf_counter_ns()
        var plain = w.save()
        var t4 = perf_counter_ns()
        var w3 = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
        w3.load(plain)
        var t5 = perf_counter_ns()
        print("|", n, "|", ms(t0, t1), "|", ms(t1, t2), "|", ms(t2, t3), "|", len(blob), "|", ms(t3, t4), "|", ms(t4, t5), "|")
        _ = st
