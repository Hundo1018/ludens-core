"""python3 -I run_native.py libludens.so [ticks] -- same scene as run64.py through the native C-ABI."""
import ctypes as C, struct, sys, time

L = C.CDLL(sys.argv[1])
vp, f, d, i32, i64 = C.c_void_p, C.c_float, C.c_double, C.c_int32, C.c_int64
L.ld_world_create.argtypes = [d, f, f, f, C.POINTER(vp)]
L.ld_body_add_box.argtypes = [vp, f, f, f, f, f, f, f, i32]; L.ld_body_add_box.restype = i64
L.ld_body_add_sphere.argtypes = [vp, f, f, f, f, f, i32]; L.ld_body_add_sphere.restype = i64
L.ld_world_body_count.argtypes = [vp]; L.ld_world_body_count.restype = i64
L.ld_world_step_ticks.argtypes = [vp, i32]
L.ld_body_get_state.argtypes = [vp, i64, C.POINTER(f)]
L.ld_world_hash.argtypes = [vp, C.POINTER(C.c_uint64)]
L.ld_world_destroy.argtypes = [vp]
w = vp()
print("world_create rc", L.ld_world_create(1 / 60, 0.0, -9.81, 0.0, C.byref(w)))
L.ld_body_add_box(w, 0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1)
ball = L.ld_body_add_sphere(w, 0.0, 5.0, 0.0, 0.5, 1.0, 0)
boxes = [L.ld_body_add_box(w, 2.0, 0.5 + k * 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0) for k in range(10)] + [L.ld_body_add_sphere(w, -8.0 + (k % 16) * 1.1, 1.0 + (k // 256) * 1.1, -8.0 + ((k // 16) % 16) * 1.1, 0.5, 1.0, 0) for k in range(int(__import__("os").environ.get("NB", "0")))]
print("bodies", L.ld_world_body_count(w))
N = int(sys.argv[2]) if len(sys.argv) > 2 else 240
t0 = time.perf_counter(); rc = L.ld_world_step_ticks(w, N); dt = time.perf_counter() - t0
print("step_ticks rc", rc, "ticks", N, "ms/tick", f"{dt * 1e3 / N:.4f}")
out = (f * 13)()
for name, b in (("ball", ball), ("box9", boxes[9])):
    rc = L.ld_body_get_state(w, b, out)
    raw = bytes(out)
    fl = struct.unpack("<13f", raw); u = struct.unpack("<13I", raw)
    print(name, "rc", rc, "pos", ",".join(f"{x:.6f}" for x in fl[:3]), "bits", " ".join(f"{x:x}" for x in u[:7]))
h = C.c_uint64()
print("hash rc", L.ld_world_hash(w, C.byref(h)), f"{h.value:x}")
print("destroy rc", L.ld_world_destroy(w))
