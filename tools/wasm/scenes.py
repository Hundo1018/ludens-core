"""Parity scenes for the wasm gate (ROADMAP 17.89 W2 / #74).

The same C-ABI calls run on the native reference library (build/libludens.so,
`--target-cpu x86-64`) and on build/ludens64.wasm under wasmtime (memory64);
each scene prints one FNV-1a hash of its outputs. A scene whose bodies hold a
non-finite value prints `nan` instead (the NaN payload is not specified to
agree across hosts), and the gate then does not compare it.

    pixi run wasm-gate            # build both, run both, compare, check the golden
    python3 tools/wasm/scenes.py native build/libludens.so
    pixi run --manifest-path ../ludens-wasm-rt/pixi.toml python tools/wasm/scenes.py wasm build/ludens64.wasm
"""
import ctypes as C
import math
import os
import struct
import sys
from pathlib import Path

F, D, I32, I64, U32, U64, P = C.c_float, C.c_double, C.c_int32, C.c_int64, C.c_uint32, C.c_uint64, C.c_void_p
SIG = {
    "ld_world_create": (I32, [D, F, F, F, P]),
    "ld_world_destroy": (I32, [P]),
    "ld_world_set_solver": (I32, [P, I32, I32]),
    "ld_body_add_box": (I64, [P, F, F, F, F, F, F, F, I32]),
    "ld_body_add_sphere": (I64, [P, F, F, F, F, F, I32]),
    "ld_body_set_velocity": (I32, [P, I64, F, F, F, F, F, F]),
    "ld_body_get_state": (I32, [P, I64, P]),
    "ld_world_body_count": (I64, [P]),
    "ld_world_get_bodies": (I64, [P, P, P, I64]),
    "ld_world_raycast": (I32, [P, F, F, F, F, F, F, F, P, P]),
    "ld_world_step_ticks": (I32, [P, I32]),
    "ld_world_event_count": (I64, [P]),
    "ld_world_get_events_ex": (I64, [P, P, I64]),
    "ld_world_save_size": (I64, [P]),
    "ld_world_save": (I64, [P, P, I64]),
    "ld_world_load": (I32, [P, P, I64]),
    "ld_world_hash": (I32, [P, P]),
    "ld_nav_bake": (I32, [P, I64, P, I64, P, P]),
    "ld_nav_destroy": (I32, [P]),
    "ld_nav_poly_count": (I64, [P]),
    "ld_nav_find_path": (I64, [P, F, F, F, F, F, F, P, I64]),
    "ld_world_add_fracture_box": (I64, [P, F, F, F, F, F, F, I32, I32, F, F, P]),
    "ld_world_fracture_event_count": (I64, [P]),
    "ld_world_add_water": (I64, [P, I32, I32, F, F, F, F, F, I32]),
    "ld_world_bubble_event_count": (I64, [P]),
    "ld_world_get_bubble_events": (I64, [P, P, I64]),
}


class Native:
    def __init__(self, path):
        self.lib = C.CDLL(os.path.abspath(path))
        for n, (r, a) in SIG.items():
            f = getattr(self.lib, n)
            f.restype, f.argtypes = r, a
        self.keep = []

    def call(self, name, *a):
        return getattr(self.lib, name)(*[None if x is None else x for x in a])

    def buf(self, n):
        b = C.create_string_buffer(n)
        self.keep.append(b)
        return Buf(self, C.addressof(b), n, b)


class Wasm:
    def __init__(self, path):
        rt_root = Path(os.environ.get("LUDENS_WASM_RT", Path(__file__).resolve().parents[3] / "ludens-wasm-rt"))
        sys.path.insert(0, str(rt_root / "tests"))
        from wasmtime_host import Rt
        self.rt = Rt(Path(path))

    def call(self, name, *a):
        r = self.rt.call(name, *[0 if x is None else x for x in a])
        return r

    def buf(self, n):
        return Buf(self, self.rt.alloc(max(n, 8), 16), n, None)


class Buf:
    def __init__(self, be, ptr, n, raw):
        self.be, self.ptr, self.n, self.raw = be, ptr, n, raw

    def get(self):
        if self.raw is not None:
            return bytes(self.raw.raw[: self.n])
        return self.be.rt.read(self.ptr, self.n)

    def put(self, data):
        if self.raw is not None:
            C.memmove(self.ptr, data, len(data))
        else:
            self.be.rt.write(self.ptr, bytes(data))


def fnv(*chunks):
    h = 0xCBF29CE484222325
    for c in chunks:
        for byte in c:
            h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def new_world(be, g=-9.81, dt=1 / 60):
    p = be.buf(8)
    assert be.call("ld_world_create", dt, 0.0, g, 0.0, p.ptr) == 0
    return struct.unpack("<Q", p.get())[0]


def world_state(be, w):
    """Hash of the world plus its bodies' poses; None when any pose is not finite."""
    n = be.call("ld_world_body_count", w)
    h, poses = be.buf(8 * max(n, 1)), be.buf(28 * max(n, 1))
    be.call("ld_world_get_bodies", w, h.ptr, poses.ptr, n)
    vals = struct.unpack("<%df" % (7 * n), poses.get()[: 28 * n])
    if not all(math.isfinite(v) for v in vals):
        return None
    out = be.buf(8)
    be.call("ld_world_hash", w, out.ptr)
    return out.get() + poses.get()[: 28 * n]


def ground(be, w):
    be.call("ld_body_add_box", w, 0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1)


def scene_raycast(be):
    w = new_world(be)
    ground(be, w)
    for i in range(6):
        be.call("ld_body_add_box", w, 2.0 * i - 5, 0.5 + i * 0.01, 0.0, 0.5, 0.5, 0.5, 1.0, 0)
        be.call("ld_body_add_sphere", w, 2.0 * i - 5, 3.0 + i, 1.0, 0.5, 1.0, 0)
    be.call("ld_world_step_ticks", w, 90)
    out = []
    for k in range(24):
        a = k * 0.26
        body, hit = be.buf(8), be.buf(28)
        r = be.call("ld_world_raycast", w, 8 * math.cos(a), 2.0, 8 * math.sin(a), -math.cos(a), -0.1, -math.sin(a), 40.0, body.ptr, hit.ptr)
        out += [struct.pack("<i", r), body.get(), hit.get()]
    st = world_state(be, w)
    be.call("ld_world_destroy", w)
    return None if st is None else fnv(st, *out)


def scene_ccd(be):
    w = new_world(be)
    ground(be, w)
    be.call("ld_body_add_box", w, 5.0, 1.0, 0.0, 0.05, 1.0, 5.0, 0.0, 1)  # a thin wall
    for k in range(4):
        s = be.call("ld_body_add_sphere", w, -5.0, 1.0 + 0.4 * k, 0.5 * k, 0.15, 1.0, 0)
        be.call("ld_body_set_velocity", w, s, 220.0 + 40 * k, 0.0, 0.0, 0.0, 0.0, 0.0)
    be.call("ld_world_step_ticks", w, 30)
    st = world_state(be, w)
    be.call("ld_world_destroy", w)
    return None if st is None else fnv(st)


def scene_saveload(be):
    w = new_world(be)
    ground(be, w)
    for i in range(8):
        be.call("ld_body_add_box", w, 0.2 * (i % 2), 0.5 + i, 0.0, 0.5, 0.5, 0.5, 1.0, 0)
    be.call("ld_world_step_ticks", w, 45)
    n = be.call("ld_world_save_size", w)
    blob = be.buf(n)
    assert be.call("ld_world_save", w, blob.ptr, n) == n
    be.call("ld_world_step_ticks", w, 60)
    a = world_state(be, w)
    assert be.call("ld_world_load", w, blob.ptr, n) == 0
    be.call("ld_world_step_ticks", w, 60)
    b = world_state(be, w)
    be.call("ld_world_destroy", w)
    if a is None or b is None:
        return None
    assert a == b, "load + replay differs from the uninterrupted run"
    return fnv(blob.get(), a)


def scene_nav(be):
    verts = [-4, 0, -4, 4, 0, -4, 4, 0, 4, -4, 0, 4, -0.2, 0, -5, 0.2, 0, -5, 0.2, 0, 3, -0.2, 0, 3,
             -4, 2, -4, 4, 2, -4, 4, 2, 4, -4, 2, 4]
    # the host.c layout: a floor with a wall (tests/capi/host.c), reduced to the flat floor + two blocks
    verts = [-4, 0, -4, 4, 0, -4, 4, 0, 4, -4, 0, 4, -4, 2, -5, 4, 2, -5, 4, 2, 5, -4, 2, 5, -0.2, 2, -5, 0.2, 2, -5, 0.2, 2, 3, -0.2, 2, 3]
    tris = [0, 2, 1, 0, 3, 2, 8, 10, 9, 8, 11, 10, 4, 5, 9, 4, 9, 8, 6, 7, 11, 6, 11, 10, 5, 6, 10, 5, 10, 9, 7, 4, 8, 7, 8, 11]
    vb, tb = be.buf(4 * len(verts)), be.buf(4 * len(tris))
    vb.put(struct.pack("<%df" % len(verts), *verts))
    tb.put(struct.pack("<%di" % len(tris), *tris))
    pn = be.buf(8)
    rc = be.call("ld_nav_bake", vb.ptr, len(verts) // 3, tb.ptr, len(tris), None, pn.ptr)
    nav = struct.unpack("<Q", pn.get())[0]
    out = [struct.pack("<i", rc)]
    if rc == 0:
        out.append(struct.pack("<q", be.call("ld_nav_poly_count", nav)))
        for sx, sz, gx, gz in [(-3, -3, 3, 3), (-3, 3, 3, -3), (0, -3, 0, 3)]:
            pts = be.buf(12 * 64)
            n = be.call("ld_nav_find_path", nav, float(sx), 0.0, float(sz), float(gx), 0.0, float(gz), pts.ptr, 64)
            out += [struct.pack("<q", n), pts.get()[: 12 * max(n, 0)]]
        be.call("ld_nav_destroy", nav)
    return fnv(*out)


def scene_fracture(be):
    w = new_world(be)
    ground(be, w)
    first = be.buf(8)
    n = be.call("ld_world_add_fracture_box", w, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 12, 7, 5.0e4, 600.0, first.ptr)
    s = be.call("ld_body_add_sphere", w, 0.0, 6.0, 0.0, 0.4, 40.0, 0)
    be.call("ld_body_set_velocity", w, s, 0.0, -25.0, 0.0, 0.0, 0.0, 0.0)
    be.call("ld_world_step_ticks", w, 90)
    ev = be.call("ld_world_fracture_event_count", w)
    st = world_state(be, w)
    be.call("ld_world_destroy", w)
    return None if st is None else fnv(struct.pack("<qq", n, ev), st)


def scene_events(be):
    w = new_world(be)
    ground(be, w)
    for i in range(5):
        be.call("ld_body_add_box", w, 0.0, 0.5 + 1.1 * i, 0.0, 0.5, 0.5, 0.5, 1.0, 0)
    be.call("ld_body_add_sphere", w, 0.3, 9.0, 0.0, 0.5, 2.0, 0)
    chunks = []
    for _ in range(12):
        be.call("ld_world_step_ticks", w, 10)
        n = be.call("ld_world_event_count", w)
        eb = be.buf(104 * max(n, 1))
        got = be.call("ld_world_get_events_ex", w, eb.ptr, n)
        chunks.append(struct.pack("<qq", n, got))
        chunks.append(eb.get()[: 104 * max(got, 0)])
    st = world_state(be, w)
    be.call("ld_world_destroy", w)
    return None if st is None else fnv(st, *chunks)


def scene_water(be):
    w = new_world(be)
    np_ = be.call("ld_world_add_water", w, 80, 24, 0.025, 0.0, 0.0, 0.25, 0.5, 5)
    chunks = [struct.pack("<q", np_)]
    for _ in range(60):
        be.call("ld_world_step_ticks", w, 1)
        n = be.call("ld_world_bubble_event_count", w)
        eb = be.buf(32 * max(n, 1))
        got = be.call("ld_world_get_bubble_events", w, eb.ptr, n)
        chunks.append(struct.pack("<q", got))
        chunks.append(eb.get()[: 32 * max(got, 0)])
    be.call("ld_world_destroy", w)
    vals = b"".join(chunks)
    return fnv(vals)


SCENES = [("raycast", scene_raycast), ("ccd", scene_ccd), ("saveload", scene_saveload),
          ("nav", scene_nav), ("fracture", scene_fracture), ("events", scene_events), ("water", scene_water)]


def main():
    be = (Native if sys.argv[1] == "native" else Wasm)(sys.argv[2])
    for name, fn in SCENES:
        h = fn(be)
        print(f"{name} {'nan' if h is None else format(h, '016x')}")


if __name__ == "__main__":
    main()
