"""Pythonic layer over the C-ABI (ROADMAP 17.21).

Status codes become exceptions; handles become `World`, `Body` and `NavMesh`
objects; Python callables become systems and contact subscribers. Everything
still runs through the same frozen C functions a C host would call, so a
world driven from Python is bit-identical to one driven from C or Mojo.
"""

from collections import namedtuple
import ctypes
import struct
from ctypes import POINTER, byref, c_float, c_int32, c_int64, c_uint8, c_uint32, c_uint64, c_void_p

from . import _capi as C

Vec = tuple
BodyState = namedtuple("BodyState", "pos rot vel omega")
Hit = namedtuple("Hit", "body t point normal")
ContactEvent = namedtuple("ContactEvent", "tick a b kind feature")

PRE = C.LD_PHASE_PRE
POST = C.LD_PHASE_POST
BEGAN = C.LD_EVENT_BEGAN
STAY = C.LD_EVENT_STAY
ENDED = C.LD_EVENT_ENDED


class LudensError(Exception):
    code = 0


class HandleError(LudensError):
    code = C.LD_ERR_HANDLE


class ArgumentError(LudensError, ValueError):
    code = C.LD_ERR_ARG


class StaleBodyError(LudensError):
    code = C.LD_ERR_STALE


class BufferTooSmallError(LudensError):
    code = C.LD_ERR_BUFFER


class FormatError(LudensError, ValueError):
    code = C.LD_ERR_FORMAT


class CallbackError(LudensError):
    code = C.LD_ERR_CALLBACK


class StateError(LudensError):
    code = C.LD_ERR_STATE


class ThreadError(LudensError):
    """Called from a thread other than the one bound by `World.bind_thread`."""
    code = C.LD_ERR_THREAD


_BY_CODE = {e.code: e for e in (HandleError, ArgumentError, StaleBodyError, BufferTooSmallError, FormatError, CallbackError, StateError, ThreadError)}


def abi_version():
    v = C.lib.ld_abi_version()
    return (v >> 16, v & 0xFFFF)


def _f3(v, name):
    try:
        x, y, z = v
        return float(x), float(y), float(z)
    except (TypeError, ValueError):
        raise ArgumentError("%s must be a 3-sequence of numbers, got %r" % (name, v)) from None


_get_state = C.lib.ld_body_get_state
_STATE13 = struct.Struct("13f")


class Body:
    """A body handle. Comparable and hashable by handle value."""

    __slots__ = ("world", "handle")

    def __init__(self, world, handle):
        self.world = world
        self.handle = handle

    def __eq__(self, other):
        return isinstance(other, Body) and other.world is self.world and other.handle == self.handle

    def __hash__(self):
        return hash(self.handle)

    def __repr__(self):
        return "Body(slot=%d, gen=%d)" % (self.handle & 0xFFFFFFFF, self.handle >> 32)

    @property
    def alive(self):
        return self.world._check(C.lib.ld_body_alive(self.world._h, self.handle)) == 1

    def state(self):
        w = self.world
        out = w._st
        rc = _get_state(w._h, self.handle, out)
        if rc < 0:
            w._check(rc)
        v = _STATE13.unpack_from(out)
        return BodyState((v[0], v[1], v[2]), (v[3], v[4], v[5], v[6]), (v[7], v[8], v[9]), (v[10], v[11], v[12]))

    def set_velocity(self, v, w=(0.0, 0.0, 0.0)):
        self.world._check(C.lib.ld_body_set_velocity(self.world._h, self.handle, *_f3(v, "v"), *_f3(w, "w")))

    def apply_impulse(self, j):
        self.world._check(C.lib.ld_body_apply_impulse(self.world._h, self.handle, *_f3(j, "impulse")))

    def teleport(self, pos, rot=(0.0, 0.0, 0.0, 1.0)):
        if len(rot) != 4:
            raise ArgumentError("rot must be a quaternion x, y, z, w")
        self.world._check(C.lib.ld_body_teleport(self.world._h, self.handle, *_f3(pos, "pos"), *map(float, rot)))

    def remove(self):
        self.world._check(C.lib.ld_body_remove(self.world._h, self.handle))

    def set_layer(self, category, mask=0xFFFFFFFF):
        """Collision layer: category bits and the categories it collides with."""
        self.world._check(C.lib.ld_body_set_layer(self.world._h, self.handle, int(category), int(mask)))

    @property
    def user(self):
        """Host value attached to the body (0 = none); saved with the world."""
        out = c_uint64(0)
        self.world._check(C.lib.ld_body_get_user(self.world._h, self.handle, byref(out)))
        return out.value

    @user.setter
    def user(self, value):
        self.world._check(C.lib.ld_body_set_user(self.world._h, self.handle, int(value)))

    @property
    def material(self):
        """Host material id (0 = none), reported on contact events (ABI 0.6); not saved."""
        out = c_uint32(0)
        self.world._check(C.lib.ld_body_get_material(self.world._h, self.handle, byref(out)))
        return out.value

    @material.setter
    def material(self, value):
        self.world._check(C.lib.ld_body_set_material(self.world._h, self.handle, int(value)))


class World:
    """One simulation. Use as a context manager or call `close()`.

    Systems are Python callables `fn(world, dt, tick)`; contact subscribers
    are `fn(world, event)`. A Python exception raised inside one stops the
    step and is re-raised from `step` / `step_ticks` (chained to a
    `CallbackError`)."""

    def __init__(self, dt=1.0 / 60.0, gravity=(0.0, -9.8, 0.0)):
        h = c_void_p()
        rc = C.lib.ld_world_create(float(dt), *_f3(gravity, "gravity"), byref(h))
        if rc != C.LD_OK:
            raise ArgumentError("World: dt must be finite and > 0, gravity finite (got dt=%r, gravity=%r)" % (dt, gravity))
        self._h = h
        self._st = (c_float * 13)()  # reused by Body.state (one world = one thread, see ludens.h)
        self._callbacks = {}  # id -> ctypes thunk (kept alive while registered)
        self._subs = {}
        self._pending = None
        self.dt = float(dt)

    # -- lifecycle

    def close(self):
        if self._h is not None:
            self._check(C.lib.ld_world_destroy(self._h))
            self._h = None
            self._callbacks.clear()
            self._subs.clear()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        try:
            if getattr(self, "_h", None) is not None:
                C.lib.ld_world_destroy(self._h)
        except Exception:
            pass

    # -- errors

    def _message(self):
        if self._h is None:
            return "world is closed"
        buf = ctypes.create_string_buffer(512)
        C.lib.ld_world_last_error(self._h, buf, 512)
        return buf.value.decode("utf-8", "replace")

    def _check(self, rc):
        if rc >= 0:
            return rc
        if self._h is None:
            raise HandleError("world is closed")
        exc = _BY_CODE.get(rc, LudensError)(self._message())
        if rc == C.LD_ERR_CALLBACK and self._pending is not None:
            cause, self._pending = self._pending, None
            raise cause from exc
        raise exc

    # -- settings

    def set_solver(self, iterations, substeps):
        self._check(C.lib.ld_world_set_solver(self._h, int(iterations), int(substeps)))

    def set_gravity(self, g):
        self._check(C.lib.ld_world_set_gravity(self._h, *_f3(g, "gravity")))

    def set_unit_scale(self, per_meter):
        """Host length units per meter (ABI 0.5): 100 for centimetres. All
        lengths, velocities and gravity are then given in host units."""
        self._check(C.lib.ld_world_set_unit_scale(self._h, float(per_meter)))

    @property
    def tick(self):
        return self._check(C.lib.ld_world_tick(self._h))

    # -- bodies

    def add_box(self, pos, half, mass=1.0, static=False):
        return Body(self, self._check(C.lib.ld_body_add_box(self._h, *_f3(pos, "pos"), *_f3(half, "half"), float(mass), int(bool(static)))))

    def add_sphere(self, pos, radius, mass=1.0, static=False):
        return Body(self, self._check(C.lib.ld_body_add_sphere(self._h, *_f3(pos, "pos"), float(radius), float(mass), int(bool(static)))))

    def body(self, handle):
        return Body(self, int(handle))

    def bodies(self):
        """(bodies, poses): live bodies in slot order and their poses as
        7-tuples (position xyz, rotation xyzw), from one C call."""
        n = self._check(C.lib.ld_world_body_count(self._h))
        hs = (c_int64 * max(n, 1))()
        ps = (c_float * (7 * max(n, 1)))()
        n = self._check(C.lib.ld_world_get_bodies(self._h, hs, ps, n))
        return [Body(self, hs[i]) for i in range(n)], [tuple(ps[7 * i : 7 * i + 7]) for i in range(n)]

    def poses_into(self, buf):
        """Fill a caller-owned ctypes float array (7 floats per body); returns the count.
        No per-body Python objects: the cheap path for per-frame rendering sync."""
        cap = len(buf) // 7
        return self._check(C.lib.ld_world_get_bodies(self._h, None, buf, cap))

    def set_poses(self, bodies, poses):
        """Write many poses in one C call: `bodies` a list of Body (or
        handles), `poses` matching 7-tuples (position xyz, rotation xyzw)."""
        n = len(bodies)
        if len(poses) != n:
            raise ValueError("set_poses: bodies and poses differ in length")
        hs = (c_int64 * max(n, 1))(*[int(b.handle) if isinstance(b, Body) else int(b) for b in bodies])
        ps = (c_float * (7 * max(n, 1)))(*[float(x) for p in poses for x in p])
        return self._check(C.lib.ld_world_set_poses(self._h, hs, ps, n))

    def set_poses_from(self, handles, buf, n):
        """Bulk write from caller-owned ctypes arrays (no per-body Python
        objects): handles c_int64[n], buf c_float[7 n]."""
        return self._check(C.lib.ld_world_set_poses(self._h, handles, buf, int(n)))

    def counters(self):
        """{name: value} of the scene's diagnostic counters."""
        n = C.lib.ld_counter_count()
        out = (c_int64 * n)()
        self._check(C.lib.ld_world_get_counters(self._h, out, n))
        names = []
        for i in range(n):
            buf = ctypes.create_string_buffer(64)
            C.lib.ld_counter_name(i, buf, 64)
            names.append(buf.value.decode())
        return dict(zip(names, list(out)))

    # -- queries

    def raycast(self, origin, direction, max_t=1e30, mask=None):
        b = c_int64(-1)
        out = (c_float * 7)()
        if mask is None:
            r = self._check(C.lib.ld_world_raycast(self._h, *_f3(origin, "origin"), *_f3(direction, "direction"), float(max_t), byref(b), out))
        else:
            r = self._check(C.lib.ld_world_raycast_mask(self._h, *_f3(origin, "origin"), *_f3(direction, "direction"), float(max_t), int(mask), byref(b), out))
        if r == 0:
            return None
        return Hit(Body(self, b.value), out[0], tuple(out[1:4]), tuple(out[4:7]))

    def find_user(self, value):
        """The live body carrying host value `value`, or None."""
        r = C.lib.ld_world_find_user(self._h, int(value))
        if r == C.LD_ERR_STALE:
            return None
        return Body(self, self._check(r))

    def bind_thread(self, on=True):
        """Bind the world to the calling thread: calls from other threads
        raise ThreadError (ABI 0.4). `on=False` unbinds."""
        self._check(C.lib.ld_world_bind_thread(self._h, 1 if on else 0))

    # -- systems and events

    def add_system(self, fn, phase=PRE):
        """Register `fn(world, dt, tick)`; returns its id."""

        def thunk(_w, dt, tick, _user):
            try:
                rc = fn(self, dt, tick)
                return int(rc or 0)
            except BaseException as e:  # noqa: BLE001 -- re-raised from step
                self._pending = e
                return 1

        cb = C.SYSTEM_FN(thunk)
        sid = self._check(C.lib.ld_world_add_system(self._h, int(phase), cb, None))
        self._callbacks[sid] = cb
        return sid

    def system(self, phase=PRE):
        """Decorator form of `add_system`."""

        def deco(fn):
            fn.system_id = self.add_system(fn, phase)
            return fn

        return deco

    def remove_system(self, sid):
        self._check(C.lib.ld_world_remove_system(self._h, int(sid)))
        self._callbacks.pop(sid, None)

    def subscribe_contacts(self, fn, kinds=(BEGAN, ENDED)):
        """Register `fn(world, ContactEvent)` for the given event kinds; returns its id."""
        mask = 0
        for k in kinds:
            mask |= 1 << int(k)

        def thunk(_w, ev, _user):
            e = ev.contents
            try:
                rc = fn(self, ContactEvent(e.tick, Body(self, e.a), Body(self, e.b), e.kind, e.feature))
                return int(rc or 0)
            except BaseException as ex:  # noqa: BLE001
                self._pending = ex
                return 1

        cb = C.CONTACT_FN(thunk)
        sid = self._check(C.lib.ld_world_subscribe_contacts(self._h, mask, cb, None))
        self._subs[sid] = cb
        return sid

    def unsubscribe(self, sid):
        self._check(C.lib.ld_world_unsubscribe(self._h, int(sid)))
        self._subs.pop(sid, None)

    def step(self, frame_dt=None):
        """Advance by frame_dt seconds (default: one dt); returns ticks run."""
        self._pending = None
        return self._check(C.lib.ld_world_step(self._h, float(self.dt if frame_dt is None else frame_dt)))

    def step_ticks(self, n):
        self._pending = None
        return self._check(C.lib.ld_world_step_ticks(self._h, int(n)))

    def events(self):
        """Contact events of the last step call."""
        n = self._check(C.lib.ld_world_event_count(self._h))
        buf = (C.ContactEventC * max(n, 1))()
        n = self._check(C.lib.ld_world_get_events(self._h, buf, n))
        return [ContactEvent(e.tick, Body(self, e.a), Body(self, e.b), e.kind, e.feature) for e in buf[:n]]

    def events_ex(self):
        """Contact events of the last step call with impulse, tangential velocity and
        material ids (ABI 0.6): a list of `_capi.ContactEventExC` records."""
        n = self._check(C.lib.ld_world_event_count(self._h))
        buf = (C.ContactEventExC * max(n, 1))()
        n = self._check(C.lib.ld_world_get_events_ex(self._h, buf, n))
        return list(buf[:n])

    def add_fracture_box(self, pos, half, pieces, seed=0, stress=2.0e4, density=1000.0):
        """A box of `pieces` welded Voronoi fragments (ABI 0.6). Returns the fragment handles.
        A world with a fractured object cannot be saved or loaded."""
        first = c_int64(-1)
        n = self._check(
            C.lib.ld_world_add_fracture_box(
                self._h, pos[0], pos[1], pos[2], half[0], half[1], half[2], int(pieces), int(seed), stress, density, byref(first)
            )
        )
        buf = (c_int64 * max(n, 1))()
        self._check(C.lib.ld_world_get_fragments(self._h, buf, n))
        return list(buf[:n])

    def fracture_events(self):
        """Fracture events of the last step call: `_capi.FractureEventC` records."""
        n = self._check(C.lib.ld_world_fracture_event_count(self._h))
        buf = (C.FractureEventC * max(n, 1))()
        n = self._check(C.lib.ld_world_get_fracture_events(self._h, buf, n))
        return list(buf[:n])

    def add_water(self, nx, ny, cell, fill, seed=1):
        """A 2D FLIP tank (xy plane, walls all round) of nx x ny cells of `cell` metres, filled over
        fill = (x0, y0, x1, y1) (ABI 0.6). Returns the particle count. A world with a tank cannot be
        saved or loaded."""
        return self._check(C.lib.ld_world_add_water(self._h, int(nx), int(ny), cell, *fill, int(seed)))

    def bubble_events(self):
        """Particles that turned into air bubbles in the last step call: `_capi.BubbleEventC` records."""
        n = self._check(C.lib.ld_world_bubble_event_count(self._h))
        buf = (C.BubbleEventC * max(n, 1))()
        n = self._check(C.lib.ld_world_get_bubble_events(self._h, buf, n))
        return list(buf[:n])

    def export_frame(self):
        """The current frame as bytes in the ABI 0.6 frame stream layout (see ludens.h)."""
        n = self._check(C.lib.ld_world_frame_size(self._h))
        buf = (c_uint64 * ((n + 7) // 8))()
        n = self._check(C.lib.ld_world_export_frame(self._h, ctypes.cast(buf, POINTER(c_uint8)), n))
        return bytes(ctypes.string_at(buf, n))

    # -- save / restore

    def capture_begin(self, key_every=60):
        """Record every following tick into a physics capture (ABI 0.3)."""
        self._check(C.lib.ld_world_capture_begin(self._h, int(key_every)))

    def capture_end(self):
        self._check(C.lib.ld_world_capture_end(self._h))

    def capture_bytes(self):
        """The capture's file image (`physics.capture` format)."""
        n = self._check(C.lib.ld_world_capture_size(self._h))
        buf = (c_uint8 * n)()
        self._check(C.lib.ld_world_capture_read(self._h, buf, n))
        return bytes(buf)

    def save(self):
        n = self._check(C.lib.ld_world_save_size(self._h))
        buf = (c_uint8 * n)()
        self._check(C.lib.ld_world_save(self._h, buf, n))
        return bytes(buf)

    def load(self, blob):
        data = (c_uint8 * len(blob)).from_buffer_copy(blob)
        self._check(C.lib.ld_world_load(self._h, data, len(blob)))

    def hash(self):
        out = c_uint64()
        self._check(C.lib.ld_world_hash(self._h, byref(out)))
        return out.value


class NavMesh:
    """Navmesh baked from a triangle soup (vertices as xyz triples, triangles as index triples)."""

    def __init__(self, vertices, triangles, cell_size=0.25, cell_height=0.1, agent_height=1.8,
                 agent_radius=0.3, max_climb=0.4, max_slope_deg=45.0, tile_size=32):
        flat_v = [float(c) for v in vertices for c in _f3(v, "vertex")]
        flat_t = [int(i) for t in triangles for i in t]
        vs = (c_float * len(flat_v))(*flat_v)
        ts = (c_int32 * len(flat_t))(*flat_t)
        cfg = (c_float * 7)(cell_size, cell_height, agent_height, agent_radius, max_climb, max_slope_deg, tile_size)
        h = c_void_p()
        rc = C.lib.ld_nav_bake(vs, len(flat_v) // 3, ts, len(flat_t), cfg, byref(h))
        if rc != C.LD_OK:
            raise ArgumentError("NavMesh: bake failed (empty input, index out of range, non-finite vertex or bad config)")
        self._h = h

    def close(self):
        if self._h is not None:
            C.lib.ld_nav_destroy(self._h)
            self._h = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    @property
    def poly_count(self):
        return C.lib.ld_nav_poly_count(self._h)

    def find_path(self, start, goal, max_points=256):
        """Corner points start .. goal, or [] when unreachable."""
        while True:
            out = (c_float * (3 * max_points))()
            n = C.lib.ld_nav_find_path(self._h, *_f3(start, "start"), *_f3(goal, "goal"), out, max_points)
            if n == C.LD_ERR_BUFFER:
                max_points *= 4
                continue
            if n < 0:
                buf = ctypes.create_string_buffer(512)
                C.lib.ld_nav_last_error(self._h, buf, 512)
                raise _BY_CODE.get(n, LudensError)(buf.value.decode())
            return [tuple(out[3 * i : 3 * i + 3]) for i in range(n)]
