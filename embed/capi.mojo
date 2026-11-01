"""C-ABI shim (ROADMAP 12.1): every `ld_*` symbol of `embed/ludens.h`.

Built as a shared library, not imported: `pixi run capi` runs
`mojo build --emit shared-lib -I build embed/capi.mojo -o build/libludens.so`.

Rules every function follows (the v0.x contract, docs/design/12.1-embedding.md):
- Never raises across the boundary: a Mojo raise becomes a negative status
  (`LD_ERR_*`) and its message is kept for `ld_world_last_error`.
- A handle is checked for null and for the live magic before use; a
  destroyed handle is detected as long as its memory was not reused
  (best effort -- use after destroy is a host bug).
- Output buffers are host-owned. A buffer that is too small makes the call
  return `LD_ERR_BUFFER` without writing; the matching `*_count` / `*_size`
  call says how much is needed.
- Thread ownership (ABI 0.4, ROADMAP 17.78): after `ld_world_bind_thread(w,
  1)` every call on `w` from another thread returns `LD_ERR_THREAD` without
  touching the world (one `pthread_self` per call); unbound worlds keep the
  0.x contract "one thread at a time", unchecked. Different worlds are
  independent and may run on different threads at once.
- Host callbacks (systems, contact subscribers) run inside `ld_world_step`;
  they may call any `ld_*` function on the same world except
  `ld_world_destroy` and `ld_world_load` (refused with `LD_ERR_STATE`). The
  tick loop below holds no Mojo reference to the world across a callback:
  every access goes through the raw pointer again afterwards.
"""

from std.memory import alloc, Layout
from std.ffi import external_call
from scheduler.build_opts import SERIAL_ONLY
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from nav.heightfield import NavBakeConfig
from embed.world import (
    EmbedWorld,
    TickEvent,
    pack_body,
    ABI_MAJOR,
    ABI_MINOR,
    LD_OK,
    LD_ERR_HANDLE,
    LD_ERR_ARG,
    LD_ERR_STALE,
    LD_ERR_BUFFER,
    LD_ERR_FORMAT,
    LD_ERR_CALLBACK,
    LD_ERR_STATE,
    LD_ERR_THREAD,
    PHASE_PRE,
    PHASE_POST,
)
from embed.navigation import EmbedNav
from diag.counters import COUNT as COUNTER_COUNT, counter_name

comptime Handle = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())
comptime F32Ptr = Pointer[Float32, MutAnyOrigin]
comptime I64Ptr = Pointer[Int64, MutAnyOrigin]
comptime I32Ptr = Pointer[Int32, MutAnyOrigin]
comptime U8Ptr = Pointer[UInt8, MutAnyOrigin]
comptime U64Ptr = Pointer[UInt64, MutAnyOrigin]
comptime HandlePtr = Pointer[Handle, MutAnyOrigin]

# int32_t (*)(ld_world* w, double dt, int64_t tick, void* user)
comptime SystemFn = def(Optional[Handle], Float64, Int64, Optional[Handle]) thin abi("C") -> Int32
# int32_t (*)(ld_world* w, const ld_contact_event* ev, void* user)
comptime ContactFn = def(Optional[Handle], I64Ptr, Optional[Handle]) thin abi("C") -> Int32

comptime _WORLD_MAGIC = UInt64(0x4C44574F524C4431)  # "LDWORLD1"
comptime _NAV_MAGIC = UInt64(0x4C444E41564D4831)  # "LDNAVMH1"
comptime _DEAD = UInt64(0xDEADDEADDEADDEAD)
comptime _EVENT_WORDS = 5  # tick, a, b, kind, feat


@fieldwise_init
struct _System(Copyable, ImplicitlyCopyable, Movable):
    var f: SystemFn
    var user: Optional[Handle]
    var phase: Int
    var active: Bool


@fieldwise_init
struct _Sub(Copyable, ImplicitlyCopyable, Movable):
    var f: ContactFn
    var user: Optional[Handle]
    var mask: Int
    var active: Bool


struct _CWorld(Movable):
    var magic: UInt64
    var owner: UInt  # bound thread (pthread_self), 0 = unbound
    var w: EmbedWorld
    var systems: List[_System]
    var subs: List[_Sub]
    var in_step: Bool
    var ev: List[Int64]  # one event, handed to subscribers by pointer

    def __init__(out self, var w: EmbedWorld):
        self.magic = _WORLD_MAGIC
        self.owner = 0
        self.w = w^
        self.systems = List[_System]()
        self.subs = List[_Sub]()
        self.in_step = False
        self.ev = List[Int64](length=_EVENT_WORDS, fill=0)


struct _CNav(Movable):
    var magic: UInt64
    var nav: EmbedNav
    var error: String

    def __init__(out self, var nav: EmbedNav):
        self.magic = _NAV_MAGIC
        self.nav = nav^
        self.error = String()


comptime WPtr = type_of(alloc[_CWorld](Layout[_CWorld](count=1)).unsafe_leak())
comptime NPtr = type_of(alloc[_CNav](Layout[_CNav](count=1)).unsafe_leak())


def _thread() -> UInt:
    comptime if SERIAL_ONLY:
        return 1  # the wasm build is single-threaded (17.89 W1)
    else:
        return external_call["pthread_self", UInt]()


def _world_any(h: Optional[Handle]) -> Optional[WPtr]:
    """The world behind `h` whatever thread asks; None for null / dead."""
    if not h:
        return None
    var p = h.value().unsafe_bitcast[_CWorld]()
    if p[].magic != _WORLD_MAGIC:
        return None
    return p


def _world(h: Optional[Handle]) -> Optional[WPtr]:
    """The world behind `h`; None for null / dead handles and for a call
    from a thread other than the bound one (`_why` tells which)."""
    var o = _world_any(h)
    if not o:
        return None
    var p = o.value()
    if p[].owner != 0 and p[].owner != _thread():
        return None
    return p


def _why(h: Optional[Handle]) -> Int:
    """Status for a handle `_world` refused."""
    return LD_ERR_THREAD if _world_any(h) else LD_ERR_HANDLE


def _nav(h: Optional[Handle]) -> Optional[NPtr]:
    if not h:
        return None
    var p = h.value().unsafe_bitcast[_CNav]()
    if p[].magic != _NAV_MAGIC:
        return None
    return p


def _v(x: Float32, y: Float32, z: Float32) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), 0)


def _fail(p: WPtr, code: Int, msg: String) -> Int:
    p[].w.error = msg
    return code


def _live_count(p: WPtr) -> Int:
    var n = 0
    for i in range(len(p[].w.scene.bset.bodies)):
        if not p[].w.scene.bset.is_removed(i):
            n += 1
    return n


def _copy_str(s: String, buf: Optional[U8Ptr], cap: Int64) -> Int64:
    var b = s.as_bytes()
    var n = len(b)
    if buf and cap > 0:
        var d = buf.value()
        var m = min(n, Int(cap) - 1)
        for i in range(m):
            d[unsafe_offset=i] = b[i]
        d[unsafe_offset=m] = 0
    return Int64(n)


# ------------------------------------------------------------------ version


@export
def ld_abi_version() abi("C") -> UInt32:
    return UInt32((ABI_MAJOR << 16) | ABI_MINOR)


# -------------------------------------------------------------------- world


@export
def ld_world_create(dt: Float64, gx: Float32, gy: Float32, gz: Float32, out_world: Optional[HandlePtr]) abi("C") -> Int32:
    if not out_world:
        return Int32(LD_ERR_ARG)
    try:
        var w = EmbedWorld(dt, _v(gx, gy, gz))
        var p = alloc[_CWorld](Layout[_CWorld](count=1)).unsafe_leak()
        p.unsafe_write(_CWorld(w^))
        out_world.value()[] = p.unsafe_bitcast[NoneType]()
        return Int32(LD_OK)
    except:
        return Int32(LD_ERR_ARG)


@export
def ld_world_destroy(h: Optional[Handle]) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if p[].in_step:
        return Int32(_fail(p, LD_ERR_STATE, "ld_world_destroy: called from a callback"))
    p[].magic = _DEAD
    p.unsafe_deinit_pointee()
    p.unsafe_free()
    return Int32(LD_OK)


@export
def ld_world_last_error(h: Optional[Handle], buf: Optional[U8Ptr], cap: Int64) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    return _copy_str(p[].w.error, buf, cap)


@export
def ld_world_set_solver(h: Optional[Handle], iterations: Int32, substeps: Int32) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_solver(Int(iterations), Int(substeps))
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_world_set_gravity(h: Optional[Handle], gx: Float32, gy: Float32, gz: Float32) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_gravity(_v(gx, gy, gz))
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_world_set_unit_scale(h: Optional[Handle], per_meter: Float32) abi("C") -> Int32:
    """ROADMAP 17.78 (0.5): host length units per meter."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_unit_scale(Real(per_meter))
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_world_tick(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    return Int64(p[].w.tick)


# ------------------------------------------------------------------- bodies


@export
def ld_body_add_box(
    h: Optional[Handle], px: Float32, py: Float32, pz: Float32, hx: Float32, hy: Float32, hz: Float32, mass: Float32, is_static: Int32
) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    try:
        return p[].w.add_box(_v(px, py, pz), _v(hx, hy, hz), Real(mass), is_static != 0)
    except e:
        return Int64(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_body_add_sphere(
    h: Optional[Handle], px: Float32, py: Float32, pz: Float32, r: Float32, mass: Float32, is_static: Int32
) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    try:
        return p[].w.add_sphere(_v(px, py, pz), Real(r), Real(mass), is_static != 0)
    except e:
        return Int64(_fail(p, LD_ERR_ARG, String(e)))


def _body_err(p: WPtr, b: Int64, e: Error) -> Int:
    if not p[].w.is_alive(b):
        return _fail(p, LD_ERR_STALE, String(e))
    return _fail(p, LD_ERR_ARG, String(e))


@export
def ld_body_remove(h: Optional[Handle], b: Int64) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.remove(b)
        return Int32(LD_OK)
    except e:
        return Int32(_body_err(p, b, e))


@export
def ld_body_alive(h: Optional[Handle], b: Int64) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    return Int32(1) if p[].w.is_alive(b) else Int32(0)


@export
def ld_body_set_velocity(
    h: Optional[Handle], b: Int64, vx: Float32, vy: Float32, vz: Float32, wx: Float32, wy: Float32, wz: Float32
) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_velocity(b, _v(vx, vy, vz), _v(wx, wy, wz))
        return Int32(LD_OK)
    except e:
        return Int32(_body_err(p, b, e))


@export
def ld_body_apply_impulse(h: Optional[Handle], b: Int64, jx: Float32, jy: Float32, jz: Float32) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.apply_impulse(b, _v(jx, jy, jz))
        return Int32(LD_OK)
    except e:
        return Int32(_body_err(p, b, e))


@export
def ld_body_teleport(
    h: Optional[Handle], b: Int64, px: Float32, py: Float32, pz: Float32, qx: Float32, qy: Float32, qz: Float32, qw: Float32
) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.teleport(b, _v(px, py, pz), Quat(Real(qx), Real(qy), Real(qz), Real(qw)))
        return Int32(LD_OK)
    except e:
        return Int32(_body_err(p, b, e))


@export
def ld_body_get_state(h: Optional[Handle], b: Int64, out13: Optional[F32Ptr]) abi("C") -> Int32:
    """Output: out13 = position xyz, rotation xyzw, linear velocity xyz, angular velocity xyz."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if not out13:
        return Int32(_fail(p, LD_ERR_ARG, "ld_body_get_state: out is null"))
    try:
        var s = p[].w.state(b)
        for k in range(3):
            out13.value()[unsafe_offset=k] = Float32(s.pos[k])
            out13.value()[unsafe_offset=7 + k] = Float32(s.vel[k])
            out13.value()[unsafe_offset=10 + k] = Float32(s.omega[k])
        out13.value()[unsafe_offset=3] = Float32(s.rot.x)
        out13.value()[unsafe_offset=4] = Float32(s.rot.y)
        out13.value()[unsafe_offset=5] = Float32(s.rot.z)
        out13.value()[unsafe_offset=6] = Float32(s.rot.w)
        return Int32(LD_OK)
    except e:
        return Int32(_body_err(p, b, e))


@export
def ld_world_body_count(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    return Int64(_live_count(p))


@export
def ld_world_get_bodies(h: Optional[Handle], handles: Optional[I64Ptr], poses7: Optional[F32Ptr], cap: Int64) abi("C") -> Int64:
    """Live bodies in slot order: handles[i] and poses7[7 i .. 7 i + 6] =
    position xyz, rotation xyzw. Either array may be null."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = _live_count(p)
    if Int(cap) < n:
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_bodies: capacity below ld_world_body_count"))
    ref bset = p[].w.scene.bset
    var j = 0
    for i in range(len(bset.bodies)):
        if bset.is_removed(i):
            continue
        if case .Some(hp) = handles:
            hp[unsafe_offset=j] = pack_body(bset.id_of(i))
        if case .Some(d) = poses7:
            var pos = bset.bodies[i].position()
            var q = bset.bodies[i].rotation()
            d[unsafe_offset=7 * j] = Float32(pos[0])
            d[unsafe_offset=7 * j + 1] = Float32(pos[1])
            d[unsafe_offset=7 * j + 2] = Float32(pos[2])
            d[unsafe_offset=7 * j + 3] = Float32(q.x)
            d[unsafe_offset=7 * j + 4] = Float32(q.y)
            d[unsafe_offset=7 * j + 5] = Float32(q.z)
            d[unsafe_offset=7 * j + 6] = Float32(q.w)
        j += 1
    return Int64(n)


# 0.6 (ROADMAP 17.90): the frame export stream. One self-describing little-endian
# record set per call, for a renderer or a recorder that follows the world:
#   header 24 B: u32 magic 0x3146444C ("LDF1"), u32 version 1, i64 body count, i64 tick
#   per live body (slot order) 72 B: i64 handle, f32 pos[3], f32 rot[4] (xyzw),
#   f32 vel[3], f32 omega[3], u32 flags (bit 0 asleep, bit 1 static), u32 material,
#   u32 user_lo
# The buffer must be 8-byte aligned.
comptime _FRAME_MAGIC = 0x3146444C
comptime _FRAME_HEADER = 24
comptime _FRAME_RECORD = 72


@export
def ld_world_frame_size(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    return Int64(_FRAME_HEADER + _FRAME_RECORD * _live_count(o.value()))


@export
def ld_world_export_frame(h: Optional[Handle], buf: Optional[U8Ptr], cap: Int64) abi("C") -> Int64:
    """Write the current frame (poses, velocities, flags, materials) to `buf`;
    returns the bytes written or LD_ERR_BUFFER below ld_world_frame_size."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = _live_count(p)
    var need = _FRAME_HEADER + _FRAME_RECORD * n
    if Int(cap) < need or not buf:
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_export_frame: capacity below ld_world_frame_size"))
    var w64 = buf.value().unsafe_bitcast[Int64]()
    var w32 = buf.value().unsafe_bitcast[UInt32]()
    var f32 = buf.value().unsafe_bitcast[Float32]()
    w32[unsafe_offset=0] = UInt32(_FRAME_MAGIC)
    w32[unsafe_offset=1] = 1
    w64[unsafe_offset=1] = Int64(n)
    w64[unsafe_offset=2] = Int64(p[].w.tick)
    ref bset = p[].w.scene.bset
    var j = 0
    for i in range(len(bset.bodies)):
        if bset.is_removed(i):
            continue
        var base = _FRAME_HEADER // 4 + (_FRAME_RECORD // 4) * j  # in 4-byte words
        var id = bset.id_of(i)
        w64[unsafe_offset=(_FRAME_HEADER + _FRAME_RECORD * j) // 8] = pack_body(id)
        var pos = bset.bodies[i].position()
        var q = bset.bodies[i].rotation()
        var v = bset.bodies[i].linear_velocity()
        var om = bset.bodies[i].omega_world()
        for k in range(3):
            f32[unsafe_offset=base + 2 + k] = Float32(pos[k])
            f32[unsafe_offset=base + 9 + k] = Float32(v[k])
            f32[unsafe_offset=base + 12 + k] = Float32(om[k])
        f32[unsafe_offset=base + 5] = Float32(q.x)
        f32[unsafe_offset=base + 6] = Float32(q.y)
        f32[unsafe_offset=base + 7] = Float32(q.z)
        f32[unsafe_offset=base + 8] = Float32(q.w)
        var flags = UInt32(0)
        if bset.sleeping[i]:
            flags |= 1
        if bset.motion[i] == 0:
            flags |= 2
        w32[unsafe_offset=base + 15] = flags
        w32[unsafe_offset=base + 16] = p[].w._material_of(i)
        var user = UInt64(0)
        try:
            user = p[].w.get_user(pack_body(id))
        except:
            pass
        w32[unsafe_offset=base + 17] = UInt32(user & 0xFFFFFFFF)
        j += 1
    return Int64(need)


# ------------------------------------------------------------------ queries


@export
def ld_world_raycast(
    h: Optional[Handle],
    ox: Float32, oy: Float32, oz: Float32,
    dx: Float32, dy: Float32, dz: Float32,
    max_t: Float32,
    out_body: Optional[I64Ptr],
    out_hit7: Optional[F32Ptr],
) abi("C") -> Int32:
    """1 = hit (out_body, out_hit7 = t, point xyz, normal xyz), 0 = miss."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        var r = p[].w.raycast(_v(ox, oy, oz), _v(dx, dy, dz), Real(max_t))
        if r.body < 0:
            return Int32(0)
        if case .Some(ob) = out_body:
            ob[] = r.body
        if case .Some(oh) = out_hit7:
            oh[unsafe_offset=0] = Float32(r.t)
            for k in range(3):
                oh[unsafe_offset=1 + k] = Float32(r.point[k])
                oh[unsafe_offset=4 + k] = Float32(r.normal[k])
        return Int32(1)
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))


# ------------------------------------------------------- systems and events


@export
def ld_world_add_system(h: Optional[Handle], phase: Int32, f: SystemFn, user: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    if Int(phase) != PHASE_PRE and Int(phase) != PHASE_POST:
        return Int64(_fail(p, LD_ERR_ARG, "ld_world_add_system: phase must be LD_PHASE_PRE or LD_PHASE_POST"))
    p[].systems.append(_System(f, user, Int(phase), True))
    return Int64(len(p[].systems) - 1)


@export
def ld_world_remove_system(h: Optional[Handle], id: Int64) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if id < 0 or Int(id) >= len(p[].systems) or not p[].systems[Int(id)].active:
        return Int32(_fail(p, LD_ERR_ARG, "ld_world_remove_system: unknown system id"))
    p[].systems[Int(id)].active = False
    return Int32(LD_OK)


@export
def ld_world_subscribe_contacts(h: Optional[Handle], kind_mask: Int32, f: ContactFn, user: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    if kind_mask <= 0 or kind_mask > 7:
        return Int64(_fail(p, LD_ERR_ARG, "ld_world_subscribe_contacts: kind_mask must be a non-empty subset of 1 << LD_EVENT_*"))
    p[].subs.append(_Sub(f, user, Int(kind_mask), True))
    return Int64(len(p[].subs) - 1)


@export
def ld_world_unsubscribe(h: Optional[Handle], id: Int64) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if id < 0 or Int(id) >= len(p[].subs) or not p[].subs[Int(id)].active:
        return Int32(_fail(p, LD_ERR_ARG, "ld_world_unsubscribe: unknown subscription id"))
    p[].subs[Int(id)].active = False
    return Int32(LD_OK)


def _run_phase(h: Optional[Handle], p: WPtr, phase: Int) -> Int:
    var i = 0
    while i < len(p[].systems):
        var s = p[].systems[i]
        if s.active and s.phase == phase:
            var rc = s.f(h, p[].w.dt, Int64(p[].w.tick), s.user)
            if rc != 0:
                return _fail(p, LD_ERR_CALLBACK, "system " + String(i) + " returned " + String(rc) + " at tick " + String(p[].w.tick))
        i += 1
    return LD_OK


def _publish(h: Optional[Handle], p: WPtr) -> Int:
    var e = 0
    while e < len(p[].w.tick_events):
        var ev = p[].w.tick_events[e]
        var i = 0
        while i < len(p[].subs):
            var s = p[].subs[i]
            if s.active and (s.mask >> Int(ev.kind)) & 1 == 1:
                p[].ev[0] = ev.tick
                p[].ev[1] = ev.a
                p[].ev[2] = ev.b
                p[].ev[3] = ev.kind
                p[].ev[4] = ev.feat
                var rc = s.f(h, p[].ev.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](), s.user)
                if rc != 0:
                    return _fail(p, LD_ERR_CALLBACK, "contact subscriber " + String(i) + " returned " + String(rc))
            i += 1
        e += 1
    return LD_OK


def _run_ticks(h: Optional[Handle], p: WPtr, n: Int) -> Int:
    p[].in_step = True
    for _ in range(n):
        var rc = _run_phase(h, p, PHASE_PRE)
        if rc == LD_OK:
            p[].w.physics_tick()
            rc = _publish(h, p)
        if rc == LD_OK:
            rc = _run_phase(h, p, PHASE_POST)
        if rc != LD_OK:
            p[].in_step = False
            return rc
    p[].in_step = False
    return n


@export
def ld_world_step(h: Optional[Handle], frame_dt: Float64) abi("C") -> Int32:
    """Advance by `frame_dt` seconds of host time; returns the fixed ticks run."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if p[].in_step:
        return Int32(_fail(p, LD_ERR_STATE, "ld_world_step: called from a callback"))
    try:
        var n = p[].w.ticks_due(frame_dt)
        return Int32(_run_ticks(h, p, n))
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_world_step_ticks(h: Optional[Handle], n: Int32) abi("C") -> Int32:
    """Run exactly `n` fixed ticks, bypassing the frame-time accumulator."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if p[].in_step:
        return Int32(_fail(p, LD_ERR_STATE, "ld_world_step_ticks: called from a callback"))
    if n < 0:
        return Int32(_fail(p, LD_ERR_ARG, "ld_world_step_ticks: n must be >= 0"))
    p[].w.frame_events.clear()
    p[].w.frame_fracture.clear()
    p[].w.frame_bubbles.clear()
    return Int32(_run_ticks(h, p, Int(n)))


@export
def ld_world_event_count(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    return Int64(len(p[].w.frame_events))


@export
def ld_world_get_events(h: Optional[Handle], dst: Optional[I64Ptr], cap: Int64) abi("C") -> Int64:
    """Contact events of the last step call, as ld_contact_event records."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = len(p[].w.frame_events)
    if Int(cap) < n or (n > 0 and not dst):
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_events: capacity below ld_world_event_count"))
    for i in range(n):
        var e = p[].w.frame_events[i]
        dst.value()[unsafe_offset=_EVENT_WORDS * i] = e.tick
        dst.value()[unsafe_offset=_EVENT_WORDS * i + 1] = e.a
        dst.value()[unsafe_offset=_EVENT_WORDS * i + 2] = e.b
        dst.value()[unsafe_offset=_EVENT_WORDS * i + 3] = e.kind
        dst.value()[unsafe_offset=_EVENT_WORDS * i + 4] = e.feat
    return Int64(n)


# 0.6 (ROADMAP 17.90): the richer contact record. 13 int64 words = 104 bytes:
# tick, a, b, kind, feature, then 16 four-byte words (floats unless noted):
#   [0] normal_impulse [1] force [2] approach [3] peak [4..6] point [7..9] normal
#   [10..12] tangent_vel [13] material_a (u32) [14] material_b (u32) [15] flags (u32)
comptime _EVENT_EX_WORDS = 13
comptime _EVENT_EX_TAIL = 10  # first 4-byte word after the five int64 header fields
comptime LD_EVENT_FLAG_PERSISTENT = 1


@export
def ld_world_get_events_ex(h: Optional[Handle], dst: Optional[I64Ptr], cap: Int64) abi("C") -> Int64:
    """Like ld_world_get_events, as ld_contact_event_ex records (0.6)."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = len(p[].w.frame_events)
    if Int(cap) < n or (n > 0 and not dst):
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_events_ex: capacity below ld_world_event_count"))
    for i in range(n):
        var e = p[].w.frame_events[i]
        var base = _EVENT_EX_WORDS * i
        dst.value()[unsafe_offset=base] = e.tick
        dst.value()[unsafe_offset=base + 1] = e.a
        dst.value()[unsafe_offset=base + 2] = e.b
        dst.value()[unsafe_offset=base + 3] = e.kind
        dst.value()[unsafe_offset=base + 4] = e.feat
        var f = dst.value().unsafe_bitcast[Float32]()
        var u = dst.value().unsafe_bitcast[UInt32]()
        var t = 2 * base + _EVENT_EX_TAIL
        f[unsafe_offset=t] = e.impulse
        f[unsafe_offset=t + 1] = e.force
        f[unsafe_offset=t + 2] = e.approach
        f[unsafe_offset=t + 3] = e.peak
        for k in range(3):
            f[unsafe_offset=t + 4 + k] = Float32(e.point[k])
            f[unsafe_offset=t + 7 + k] = Float32(e.normal[k])
            f[unsafe_offset=t + 10 + k] = Float32(e.tvel[k])
        u[unsafe_offset=t + 13] = e.mat_a
        u[unsafe_offset=t + 14] = e.mat_b
        u[unsafe_offset=t + 15] = UInt32(LD_EVENT_FLAG_PERSISTENT) if e.kind == 1 else UInt32(0)
    return Int64(n)


@export
def ld_body_set_material(h: Optional[Handle], b: Int64, material: UInt32) abi("C") -> Int32:
    """Host material id (0 = none), reported as material_a / material_b on the
    body's contact events (0.6). Not saved with the world: set it again after a load."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_material(b, material)
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_STALE, String(e)))


@export
def ld_body_get_material(h: Optional[Handle], b: Int64, dst: Optional[Pointer[UInt32, MutAnyOrigin]]) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if not dst:
        return Int32(_fail(p, LD_ERR_ARG, "ld_body_get_material: out is null"))
    try:
        dst.value()[] = p[].w.get_material(b)
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_STALE, String(e)))


# 0.6 (ROADMAP 17.90): a destructible box. Fracture events are 5 int64 words:
# tick, kind (0 bond broken, 1 evicted), bond index, fragment a, fragment b
# (body handles; -1 = an external body or none).
comptime _FRACTURE_WORDS = 5


@export
def ld_world_add_fracture_box(
    h: Optional[Handle],
    px: Float32,
    py: Float32,
    pz: Float32,
    hx: Float32,
    hy: Float32,
    hz: Float32,
    pieces: Int32,
    seed: Int32,
    stress: Float32,
    density: Float32,
    first: Optional[I64Ptr],
) abi("C") -> Int64:
    """Add a box of `pieces` welded Voronoi fragments (one fractured object per
    world). Returns the fragment count; `first` receives the first fragment's
    handle. Each weld breaks at `stress` (Pa) times its seam area. Such a world
    cannot be saved or loaded (LD_ERR_STATE)."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    try:
        var f = p[].w.add_fracture_box(
            Vec3(Real(px), Real(py), Real(pz), 0),
            Vec3(Real(hx), Real(hy), Real(hz), 0),
            Int(pieces),
            Int(seed),
            Real(stress),
            Real(density),
        )
        if first:
            first.value()[] = f
        return Int64(p[].w.fracture.fragments())
    except e:
        return Int64(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_world_get_fragments(h: Optional[Handle], dst: Optional[I64Ptr], cap: Int64) abi("C") -> Int64:
    """Body handles of every fragment (index = the fragment ids used by fracture events)."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = p[].w.fracture.fragments()
    if Int(cap) < n or (n > 0 and not dst):
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_fragments: capacity below the fragment count"))
    for i in range(n):
        dst.value()[unsafe_offset=i] = p[].w.fragment_handle(i)
    return Int64(n)


@export
def ld_world_fracture_event_count(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    return Int64(len(o.value()[].w.frame_fracture))


@export
def ld_world_get_fracture_events(h: Optional[Handle], dst: Optional[I64Ptr], cap: Int64) abi("C") -> Int64:
    """Fracture events of the last step call, as ld_fracture_event records."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = len(p[].w.frame_fracture)
    if Int(cap) < n or (n > 0 and not dst):
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_fracture_events: capacity below ld_world_fracture_event_count"))
    for i in range(n):
        var e = p[].w.frame_fracture[i]
        var base = _FRACTURE_WORDS * i
        dst.value()[unsafe_offset=base] = e.tick
        dst.value()[unsafe_offset=base + 1] = e.kind
        dst.value()[unsafe_offset=base + 2] = e.bond
        dst.value()[unsafe_offset=base + 3] = e.a
        dst.value()[unsafe_offset=base + 4] = e.b
    return Int64(n)


# 0.6 (ROADMAP 17.90): a 2D FLIP water tank and its bubble events. A bubble event is
# 4 int64 words (ld_bubble_event): tick, then x|y and u|v as float32 pairs, then 0.
comptime _BUBBLE_WORDS = 4


@export
def ld_world_add_water(
    h: Optional[Handle],
    nx: Int32,
    ny: Int32,
    cell: Float32,
    x0: Float32,
    y0: Float32,
    x1: Float32,
    y1: Float32,
    seed: Int32,
) abi("C") -> Int64:
    """Add a 2D FLIP tank (xy plane, nx x ny cells of `cell` metres, walls all
    round) filled over [x0, x1] x [y0, y1]; gravity is the world's -y. One tank
    per world; such a world cannot be saved or loaded (LD_ERR_STATE). Returns
    the water particle count."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    try:
        return Int64(p[].w.add_water(Int(nx), Int(ny), Real(cell), Real(x0), Real(y0), Real(x1), Real(y1), Int(seed)))
    except e:
        return Int64(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_world_bubble_event_count(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    return Int64(len(o.value()[].w.frame_bubbles))


@export
def ld_world_get_bubble_events(h: Optional[Handle], dst: Optional[I64Ptr], cap: Int64) abi("C") -> Int64:
    """Particles that turned into air bubbles during the last step call, as
    ld_bubble_event records."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var n = len(p[].w.frame_bubbles)
    if Int(cap) < n or (n > 0 and not dst):
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_bubble_events: capacity below ld_world_bubble_event_count"))
    for i in range(n):
        var e = p[].w.frame_bubbles[i]
        var base = _BUBBLE_WORDS * i
        dst.value()[unsafe_offset=base] = e.tick
        var f = dst.value().unsafe_bitcast[Float32]()
        f[unsafe_offset=2 * base + 2] = e.x
        f[unsafe_offset=2 * base + 3] = e.y
        f[unsafe_offset=2 * base + 4] = e.u
        f[unsafe_offset=2 * base + 5] = e.v
        dst.value()[unsafe_offset=base + 3] = 0
    return Int64(n)


# ---------------------------------------------------------- save / restore


@export
def ld_world_save_size(h: Optional[Handle]) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    if p[].w.fracture_on or p[].w.water_on:
        return Int64(_fail(p, LD_ERR_STATE, "ld_world_save_size: a fractured object or water tank is not saveable yet"))
    return Int64(len(p[].w.save()))


@export
def ld_world_save(h: Optional[Handle], buf: Optional[U8Ptr], cap: Int64) abi("C") -> Int64:
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    if p[].w.fracture_on or p[].w.water_on:
        return Int64(_fail(p, LD_ERR_STATE, "ld_world_save: a fractured object or water tank is not saveable yet"))
    var blob = p[].w.save()
    if Int(cap) < len(blob) or not buf:
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_save: capacity below ld_world_save_size"))
    var d = buf.value()
    var src = blob.unsafe_ptr()
    for i in range(len(blob)):
        d[unsafe_offset=i] = src[unsafe_offset=i]
    return Int64(len(blob))


@export
def ld_world_load(h: Optional[Handle], data: Optional[U8Ptr], n: Int64) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if p[].in_step:
        return Int32(_fail(p, LD_ERR_STATE, "ld_world_load: called from a callback"))
    if n < 0 or (n > 0 and not data):
        return Int32(_fail(p, LD_ERR_ARG, "ld_world_load: bad buffer"))
    var blob = List[UInt8](length=Int(n), fill=0)
    if n > 0:
        var src = data.value()
        var d = blob.unsafe_ptr()
        for i in range(Int(n)):
            d[unsafe_offset=i] = src[unsafe_offset=i]
    try:
        p[].w.load(blob)
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_FORMAT, String(e)))


@export
def ld_world_hash(h: Optional[Handle], dst: Optional[U64Ptr]) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if not dst:
        return Int32(_fail(p, LD_ERR_ARG, "ld_world_hash: out is null"))
    dst.value()[] = p[].w.hash()
    return Int32(LD_OK)


@export
def ld_world_capture_begin(h: Optional[Handle], key_every: Int32) abi("C") -> Int32:
    """Start recording a physics capture of every tick (17.80); restarts a
    running one."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if key_every < 1:
        return Int32(_fail(p, LD_ERR_ARG, "ld_world_capture_begin: key_every must be >= 1"))
    try:
        p[].w.capture_begin(Int(key_every))
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))
    return Int32(LD_OK)


@export
def ld_world_capture_end(h: Optional[Handle]) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    o.value()[].w.capture_end()
    return Int32(LD_OK)


@export
def ld_world_capture_size(h: Optional[Handle]) abi("C") -> Int64:
    """Bytes of the capture's file image so far."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    return Int64(len(o.value()[].w.capture.to_bytes()))


@export
def ld_world_capture_read(h: Optional[Handle], buf: Optional[U8Ptr], cap: Int64) abi("C") -> Int64:
    """Copy the capture's file image (readable by `physics.capture.CaptureReader`)."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var blob = p[].w.capture.to_bytes()
    if Int(cap) < len(blob) or not buf:
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_capture_read: capacity below ld_world_capture_size"))
    var d = buf.value()
    var src = blob.unsafe_ptr()
    for i in range(len(blob)):
        d[unsafe_offset=i] = src[unsafe_offset=i]
    return Int64(len(blob))


# --------------------------------------------------------------- navigation


@export
def ld_nav_bake(verts_xyz: Optional[F32Ptr], nverts: Int64, tris: Optional[I32Ptr], nidx: Int64, cfg7: Optional[F32Ptr], out_nav: Optional[HandlePtr]) abi("C") -> Int32:
    """Config: cfg7 = cell_size, cell_height, agent_height, agent_radius, max_climb,
    max_slope_deg, tile_size (null = defaults)."""
    if not out_nav or nverts <= 0 or nidx <= 0 or not verts_xyz or not tris:
        return Int32(LD_ERR_ARG)
    var vs = List[Vec3](capacity=Int(nverts))
    for i in range(Int(nverts)):
        vs.append(_v(verts_xyz.value()[unsafe_offset=3 * i], verts_xyz.value()[unsafe_offset=3 * i + 1], verts_xyz.value()[unsafe_offset=3 * i + 2]))
    var ts = List[Int](capacity=Int(nidx))
    for i in range(Int(nidx)):
        ts.append(Int(tris.value()[unsafe_offset=i]))
    var cfg = NavBakeConfig.default()
    if case .Some(c7) = cfg7:
        cfg = NavBakeConfig(Real(c7[unsafe_offset=0]), Real(c7[unsafe_offset=1]), Real(c7[unsafe_offset=2]), Real(c7[unsafe_offset=3]), Real(c7[unsafe_offset=4]), Real(c7[unsafe_offset=5]), Int(c7[unsafe_offset=6]))
    try:
        var nav = EmbedNav(vs, ts, cfg)
        var p = alloc[_CNav](Layout[_CNav](count=1)).unsafe_leak()
        p.unsafe_write(_CNav(nav^))
        out_nav.value()[] = p.unsafe_bitcast[NoneType]()
        return Int32(LD_OK)
    except:
        return Int32(LD_ERR_ARG)


@export
def ld_nav_destroy(h: Optional[Handle]) abi("C") -> Int32:
    var o = _nav(h)
    if not o:
        return Int32(LD_ERR_HANDLE)
    var p = o.value()
    p[].magic = _DEAD
    p.unsafe_deinit_pointee()
    p.unsafe_free()
    return Int32(LD_OK)


@export
def ld_nav_poly_count(h: Optional[Handle]) abi("C") -> Int64:
    var o = _nav(h)
    if not o:
        return Int64(LD_ERR_HANDLE)
    var p = o.value()
    return Int64(p[].nav.poly_count())


@export
def ld_nav_find_path(
    h: Optional[Handle], sx: Float32, sy: Float32, sz: Float32, gx: Float32, gy: Float32, gz: Float32, out_xyz: Optional[F32Ptr], cap: Int64
) abi("C") -> Int64:
    """Corner points start .. goal; 0 = no path."""
    var o = _nav(h)
    if not o:
        return Int64(LD_ERR_HANDLE)
    var p = o.value()
    try:
        var path = p[].nav.find_path(_v(sx, sy, sz), _v(gx, gy, gz))
        if not path.found:
            return 0
        var n = len(path.points)
        if Int(cap) < n or not out_xyz:
            p[].error = "ld_nav_find_path: capacity below the path's point count (" + String(n) + ")"
            return Int64(LD_ERR_BUFFER)
        for i in range(n):
            for k in range(3):
                out_xyz.value()[unsafe_offset=3 * i + k] = Float32(path.points[i][k])
        return Int64(n)
    except e:
        p[].error = String(e)
        return Int64(LD_ERR_ARG)


@export
def ld_nav_last_error(h: Optional[Handle], buf: Optional[U8Ptr], cap: Int64) abi("C") -> Int64:
    var o = _nav(h)
    if not o:
        return Int64(LD_ERR_HANDLE)
    var p = o.value()
    return _copy_str(p[].error, buf, cap)


# ---------------------------------------------------------------- ABI 0.2 (17.78)


@export
def ld_world_set_poses(h: Optional[Handle], handles: Optional[I64Ptr], poses7: Optional[F32Ptr], n: Int64) abi("C") -> Int64:
    """Write the poses of `n` bodies in one call (handles[i], poses7[7 i ..
    7 i + 6] = position xyz, rotation xyzw); the result equals `n` calls of
    `ld_body_teleport`. Every entry is validated first: on a stale handle
    (LD_ERR_STALE) or a non-finite / zero quaternion pose (LD_ERR_ARG)
    nothing is moved. Returns n."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    if n < 0 or (n > 0 and (not handles or not poses7)):
        return Int64(_fail(p, LD_ERR_ARG, "ld_world_set_poses: null array or negative count"))
    var hs = List[Int64](capacity=Int(n))
    var ps = List[Vec3](capacity=Int(n))
    var rs = List[Quat](capacity=Int(n))
    if n == 0:
        return 0
    var d = poses7.value()
    for i in range(Int(n)):
        hs.append(handles.value()[unsafe_offset=i])
        ps.append(_v(d[unsafe_offset=7 * i], d[unsafe_offset=7 * i + 1], d[unsafe_offset=7 * i + 2]))
        rs.append(Quat(Real(d[unsafe_offset=7 * i + 3]), Real(d[unsafe_offset=7 * i + 4]), Real(d[unsafe_offset=7 * i + 5]), Real(d[unsafe_offset=7 * i + 6])))
    try:
        p[].w.teleport_many(hs, ps, rs)
    except e:
        return Int64(_fail(p, LD_ERR_ARG if "finite" in String(e) or "quaternion" in String(e) else LD_ERR_STALE, String(e)))
    return n


@export
def ld_counter_count() abi("C") -> Int64:
    """Number of diagnostic counters (ids 0 .. count - 1)."""
    return Int64(COUNTER_COUNT)


@export
def ld_counter_name(id: Int32, buf: Optional[U8Ptr], cap: Int64) abi("C") -> Int64:
    """Name of counter `id` into buf (NUL-terminated); returns its length,
    or LD_ERR_ARG for an unknown id."""
    if id < 0 or Int(id) >= COUNTER_COUNT:
        return Int64(LD_ERR_ARG)
    return _copy_str(counter_name(Int(id)), buf, cap)


@export
def ld_world_get_counters(h: Optional[Handle], values: Optional[I64Ptr], cap: Int64) abi("C") -> Int64:
    """All counters of the world's scene, indexed by id; returns the count."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    if Int(cap) < COUNTER_COUNT or not values:
        return Int64(_fail(p, LD_ERR_BUFFER, "ld_world_get_counters: capacity below ld_counter_count"))
    for i in range(COUNTER_COUNT):
        values.value()[unsafe_offset=i] = p[].w.scene.counters.get(i)
    return Int64(COUNTER_COUNT)


# ---------------------------------------------------------------- ABI 0.4 (17.78)


@export
def ld_world_bind_thread(h: Optional[Handle], on: Int32) abi("C") -> Int32:
    """Bind (on = 1) the world to the calling thread, so calls from any other
    thread return LD_ERR_THREAD; on = 0 unbinds. Re-binding from a new
    thread hands the world over (the host must make sure the old thread is
    done with it)."""
    var o = _world_any(h)
    if not o:
        return Int32(LD_ERR_HANDLE)
    var p = o.value()
    if on != 0 and on != 1:
        return Int32(LD_ERR_ARG)
    p[].owner = _thread() if on == 1 else 0
    return Int32(LD_OK)


@export
def ld_body_set_layer(h: Optional[Handle], b: Int64, category: UInt32, mask: UInt32) abi("C") -> Int32:
    """Collision layer: the body's category bits and the categories it
    collides with (two bodies touch when each one's mask has the other's
    category)."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_layer(b, category, mask)
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_STALE, String(e)))


@export
def ld_world_raycast_mask(
    h: Optional[Handle],
    ox: Float32, oy: Float32, oz: Float32,
    dx: Float32, dy: Float32, dz: Float32,
    max_t: Float32,
    mask: UInt32,
    out_body: Optional[I64Ptr],
    out_hit7: Optional[F32Ptr],
) abi("C") -> Int32:
    """`ld_world_raycast` that only sees bodies whose category is in `mask`."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        var r = p[].w.raycast(_v(ox, oy, oz), _v(dx, dy, dz), Real(max_t), mask)
        if r.body < 0:
            return Int32(0)
        if case .Some(ob) = out_body:
            ob[] = r.body
        if case .Some(oh) = out_hit7:
            oh[unsafe_offset=0] = Float32(r.t)
            for k in range(3):
                oh[unsafe_offset=1 + k] = Float32(r.point[k])
                oh[unsafe_offset=4 + k] = Float32(r.normal[k])
        return Int32(1)
    except e:
        return Int32(_fail(p, LD_ERR_ARG, String(e)))


@export
def ld_body_set_user(h: Optional[Handle], b: Int64, user: UInt64) abi("C") -> Int32:
    """Attach a host value (node id, pointer bits) to a body; 0 clears. It is
    saved with the world and dropped with the body."""
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    try:
        p[].w.set_user(b, user)
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_STALE, String(e)))


@export
def ld_body_get_user(h: Optional[Handle], b: Int64, dst: Optional[U64Ptr]) abi("C") -> Int32:
    var o = _world(h)
    if not o:
        return Int32(_why(h))
    var p = o.value()
    if not dst:
        return Int32(_fail(p, LD_ERR_ARG, "ld_body_get_user: null output"))
    try:
        dst.value()[] = p[].w.get_user(b)
        return Int32(LD_OK)
    except e:
        return Int32(_fail(p, LD_ERR_STALE, String(e)))


@export
def ld_world_find_user(h: Optional[Handle], user: UInt64) abi("C") -> Int64:
    """The live body carrying host value `user` (lowest slot if several),
    or LD_ERR_STALE when none does (and for 0)."""
    var o = _world(h)
    if not o:
        return Int64(_why(h))
    var p = o.value()
    var r = p[].w.find_user(user)
    if r < 0:
        return Int64(_fail(p, LD_ERR_STALE, "ld_world_find_user: no body carries this value"))
    return r
