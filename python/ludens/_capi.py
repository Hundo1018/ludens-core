"""ctypes declarations for embed/ludens.h (ABI v0.6).

Every prototype here mirrors one line of embed/abi_v0.txt; the binding test
checks the two lists name the same functions.
"""

import ctypes
import os
from ctypes import (
    CFUNCTYPE,
    POINTER,
    Structure,
    c_char_p,
    c_double,
    c_float,
    c_int32,
    c_int64,
    c_uint8,
    c_uint32,
    c_uint64,
    c_void_p,
)

ABI_MAJOR = 0
ABI_MINOR = 6

LD_OK = 0
LD_ERR_HANDLE = -1
LD_ERR_ARG = -2
LD_ERR_STALE = -3
LD_ERR_BUFFER = -4
LD_ERR_FORMAT = -5
LD_ERR_CALLBACK = -6
LD_ERR_STATE = -7
LD_ERR_THREAD = -8

LD_PHASE_PRE = 0
LD_PHASE_POST = 1

LD_EVENT_BEGAN = 0
LD_EVENT_STAY = 1
LD_EVENT_ENDED = 2


class ContactEventC(Structure):
    _fields_ = [
        ("tick", c_int64),
        ("a", c_int64),
        ("b", c_int64),
        ("kind", c_int64),
        ("feature", c_int64),
    ]


class ContactEventExC(Structure):
    """ld_contact_event_ex (ABI 0.6), 104 bytes."""

    _fields_ = [
        ("tick", c_int64),
        ("a", c_int64),
        ("b", c_int64),
        ("kind", c_int64),
        ("feature", c_int64),
        ("normal_impulse", c_float),
        ("force", c_float),
        ("approach", c_float),
        ("peak", c_float),
        ("point_x", c_float),
        ("point_y", c_float),
        ("point_z", c_float),
        ("normal_x", c_float),
        ("normal_y", c_float),
        ("normal_z", c_float),
        ("tangent_vel_x", c_float),
        ("tangent_vel_y", c_float),
        ("tangent_vel_z", c_float),
        ("material_a", c_uint32),
        ("material_b", c_uint32),
        ("flags", c_uint32),
    ]


class FractureEventC(Structure):
    """ld_fracture_event (ABI 0.6)."""

    _fields_ = [("tick", c_int64), ("kind", c_int64), ("bond", c_int64), ("a", c_int64), ("b", c_int64)]


SYSTEM_FN = CFUNCTYPE(c_int32, c_void_p, c_double, c_int64, c_void_p)
CONTACT_FN = CFUNCTYPE(c_int32, c_void_p, POINTER(ContactEventC), c_void_p)

_F = c_float
_W = c_void_p  # ld_world* / ld_nav*

PROTOTYPES = {
    "ld_abi_version": (c_uint32, []),
    "ld_world_create": (c_int32, [c_double, _F, _F, _F, POINTER(c_void_p)]),
    "ld_world_destroy": (c_int32, [_W]),
    "ld_world_last_error": (c_int64, [_W, c_char_p, c_int64]),
    "ld_world_set_solver": (c_int32, [_W, c_int32, c_int32]),
    "ld_world_set_gravity": (c_int32, [_W, _F, _F, _F]),
    "ld_world_tick": (c_int64, [_W]),
    "ld_body_add_box": (c_int64, [_W, _F, _F, _F, _F, _F, _F, _F, c_int32]),
    "ld_body_add_sphere": (c_int64, [_W, _F, _F, _F, _F, _F, c_int32]),
    "ld_body_remove": (c_int32, [_W, c_int64]),
    "ld_body_alive": (c_int32, [_W, c_int64]),
    "ld_body_set_velocity": (c_int32, [_W, c_int64, _F, _F, _F, _F, _F, _F]),
    "ld_body_apply_impulse": (c_int32, [_W, c_int64, _F, _F, _F]),
    "ld_body_teleport": (c_int32, [_W, c_int64, _F, _F, _F, _F, _F, _F, _F]),
    "ld_body_get_state": (c_int32, [_W, c_int64, POINTER(c_float)]),
    "ld_world_body_count": (c_int64, [_W]),
    "ld_world_get_bodies": (c_int64, [_W, POINTER(c_int64), POINTER(c_float), c_int64]),
    "ld_world_raycast": (c_int32, [_W, _F, _F, _F, _F, _F, _F, _F, POINTER(c_int64), POINTER(c_float)]),
    "ld_world_add_system": (c_int64, [_W, c_int32, SYSTEM_FN, c_void_p]),
    "ld_world_remove_system": (c_int32, [_W, c_int64]),
    "ld_world_subscribe_contacts": (c_int64, [_W, c_int32, CONTACT_FN, c_void_p]),
    "ld_world_unsubscribe": (c_int32, [_W, c_int64]),
    "ld_world_step": (c_int32, [_W, c_double]),
    "ld_world_step_ticks": (c_int32, [_W, c_int32]),
    "ld_world_event_count": (c_int64, [_W]),
    "ld_world_get_events": (c_int64, [_W, POINTER(ContactEventC), c_int64]),
    "ld_world_save_size": (c_int64, [_W]),
    "ld_world_save": (c_int64, [_W, POINTER(c_uint8), c_int64]),
    "ld_world_load": (c_int32, [_W, POINTER(c_uint8), c_int64]),
    "ld_world_hash": (c_int32, [_W, POINTER(c_uint64)]),
    "ld_nav_bake": (c_int32, [POINTER(c_float), c_int64, POINTER(c_int32), c_int64, POINTER(c_float), POINTER(c_void_p)]),
    "ld_nav_destroy": (c_int32, [_W]),
    "ld_nav_poly_count": (c_int64, [_W]),
    "ld_nav_find_path": (c_int64, [_W, _F, _F, _F, _F, _F, _F, POINTER(c_float), c_int64]),
    "ld_nav_last_error": (c_int64, [_W, c_char_p, c_int64]),
    # ABI 0.2 (17.78)
    "ld_world_set_poses": (c_int64, [_W, POINTER(c_int64), POINTER(c_float), c_int64]),
    "ld_counter_count": (c_int64, []),
    "ld_counter_name": (c_int64, [c_int32, c_char_p, c_int64]),
    "ld_world_get_counters": (c_int64, [_W, POINTER(c_int64), c_int64]),
    # 0.3 (17.80): physics capture
    "ld_world_capture_begin": (c_int32, [_W, c_int32]),
    "ld_world_capture_end": (c_int32, [_W]),
    "ld_world_capture_size": (c_int64, [_W]),
    "ld_world_capture_read": (c_int64, [_W, POINTER(c_uint8), c_int64]),
    # 0.4 (17.78): host mapping
    "ld_world_bind_thread": (c_int32, [_W, c_int32]),
    "ld_body_set_layer": (c_int32, [_W, c_int64, c_uint32, c_uint32]),
    "ld_world_raycast_mask": (c_int32, [_W, _F, _F, _F, _F, _F, _F, _F, c_uint32, POINTER(c_int64), POINTER(c_float)]),
    "ld_body_set_user": (c_int32, [_W, c_int64, c_uint64]),
    "ld_body_get_user": (c_int32, [_W, c_int64, POINTER(c_uint64)]),
    "ld_world_find_user": (c_int64, [_W, c_uint64]),
    "ld_world_set_unit_scale": (c_int32, [_W, _F]),
    # 0.6 (17.90): richer events, a destructible box, the frame export stream
    "ld_world_get_events_ex": (c_int64, [_W, POINTER(ContactEventExC), c_int64]),
    "ld_body_set_material": (c_int32, [_W, c_int64, c_uint32]),
    "ld_body_get_material": (c_int32, [_W, c_int64, POINTER(c_uint32)]),
    "ld_world_add_fracture_box": (c_int64, [_W, _F, _F, _F, _F, _F, _F, c_int32, c_int32, _F, _F, POINTER(c_int64)]),
    "ld_world_get_fragments": (c_int64, [_W, POINTER(c_int64), c_int64]),
    "ld_world_fracture_event_count": (c_int64, [_W]),
    "ld_world_get_fracture_events": (c_int64, [_W, POINTER(FractureEventC), c_int64]),
    "ld_world_frame_size": (c_int64, [_W]),
    "ld_world_export_frame": (c_int64, [_W, POINTER(c_uint8), c_int64]),
}


def _load():
    path = os.environ.get("LUDENS_LIBRARY") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "libludens.so")
    lib = ctypes.CDLL(path)
    for name, (res, args) in PROTOTYPES.items():
        fn = getattr(lib, name)
        fn.restype = res
        fn.argtypes = args
    got = lib.ld_abi_version()
    if got >> 16 != ABI_MAJOR or (got & 0xFFFF) < ABI_MINOR:
        raise ImportError("ludens: library ABI %d.%d, binding needs %d.>=%d" % (got >> 16, got & 0xFFFF, ABI_MAJOR, ABI_MINOR))
    return lib, path


lib, library_path = _load()
