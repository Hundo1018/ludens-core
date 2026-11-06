"""Cross-build probe for the module-swap transfer (ROADMAP 17.91): `scripts/xfer_probe.py` builds this file twice, the
second time with `-D XFER_EXTRA=True`, which adds an unrelated function that is called (so the code layout differs).

    xfer_probe save <blob> <ticks_before> <ticks_after>   build the world, run, write the blob, run on, print hash
    xfer_probe load <blob> <ticks_after>                  fresh world, load the blob, run on, print hash
"""
from std.sys import argv
from std.sys.defines import get_defined_bool
from embed.transfer import transfer_load, transfer_save
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3

comptime DT = 1.0 / 60.0
comptime EXTRA = get_defined_bool["XFER_EXTRA", False]()


def unrelated(x: Int) -> Int:
    var acc = 0
    for i in range(x):
        acc += (i * 2654435761) % 97
    return acc


def build() raises -> EmbedWorld:
    var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    var floor = w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
    w.set_material(floor, 7)
    for i in range(24):
        var b = w.add_box(Vec3(Real(i % 4) * 1.1 - 1.6, 1.0 + Real(i // 4) * 1.05, Real(i % 3) * 0.2, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
        w.set_material(b, UInt32(10 + i))
        w.set_user(b, UInt64(1000 + i))
    _ = w.add_sphere(Vec3(0.3, 9.0, 0.1, 0.0), 0.4, 2.0, False)
    return w^


def run(mut w: EmbedWorld, ticks: Int) raises:
    for _ in range(ticks):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def write(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


def read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def main() raises:
    var args = argv()
    var names = List[String]()
    names.append("gravity_zone")
    comptime if EXTRA:
        print("extra", unrelated(1000))
    if args[1] == "save":
        var w = build()
        run(w, Int(args[3]))
        write(String(args[2]), transfer_save(w, names))
        run(w, Int(args[4]))
        print("hash", w.hash())
    else:
        var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
        transfer_load(w, read(String(args[2])), names)
        run(w, Int(args[3]))
        print("hash", w.hash())
