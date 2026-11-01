"""The two wasm-gate scenes that need code inside the module (17.89 W2 / #74).

  * `gate_callback`: host callbacks through the C-ABI -- a system and a contact subscriber are
    function pointers into this module, and they change the world while it steps.
  * `gate_soft`: a soft cube dropped on a rigid ground (the C-ABI has no soft entry).

Each returns one hash. Native, `main` prints both; wasm64, `gate_*` are exports:

  pixi run wasm-gate          # builds this entry for both targets and compares
"""

from std.memory import alloc, Layout, bitcast
from std.builtin.rebind import rebind
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody
from embed.world import fnv1a
from embed.capi import (
    Handle,
    HandlePtr,
    I64Ptr,
    U64Ptr,
    ld_world_create,
    ld_world_destroy,
    ld_world_hash,
    ld_world_step_ticks,
    ld_world_set_gravity,
    ld_world_add_system,
    ld_world_subscribe_contacts,
    ld_body_add_box,
    ld_body_add_sphere,
)


def _sys(w: Optional[Handle], dt: Float64, tick: Int64, user: Optional[Handle]) abi("C") -> Int32:
    _ = ld_world_set_gravity(w, Float32(Int(tick % 3)) * 0.25, Float32(-9.81), 0)
    return 0


def _con(w: Optional[Handle], ev: I64Ptr, user: Optional[Handle]) abi("C") -> Int32:
    _ = ld_world_set_gravity(w, Float32(Int(ev[unsafe_offset=3])) * 0.01, Float32(-9.81), 0)
    return 0


def callback_hash() -> UInt64:
    var slot = alloc[Handle](Layout[Handle](count=1)).unsafe_leak()
    if ld_world_create(1.0 / 60.0, 0, -9.81, 0, rebind[HandlePtr](slot)) != 0:
        return 0
    var w: Optional[Handle] = slot[]
    _ = ld_body_add_box(w, 0, -0.5, 0, 20, 0.5, 20, 0, 1)
    for i in range(5):
        _ = ld_body_add_box(w, 0.1 * Float32(i), 0.5 + Float32(i), 0, 0.5, 0.5, 0.5, 1, 0)
    _ = ld_body_add_sphere(w, 0.3, 8, 0, 0.5, 2, 0)
    var token: Optional[Handle] = slot[]
    var sid = ld_world_add_system(w, 0, _sys, token)
    var cid = ld_world_subscribe_contacts(w, 7, _con, token)
    var rc = ld_world_step_ticks(w, 120)
    var out = alloc[UInt64](Layout[UInt64](count=1)).unsafe_leak()
    _ = ld_world_hash(w, rebind[U64Ptr](out))
    var h = out[] ^ UInt64(Int(rc) + 3 * Int(sid) + 7 * Int(cid))
    _ = ld_world_destroy(w)
    return h


def soft_hash() raises -> UInt64:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)), Vec3(10, 1, 10, 0), True)
    _ = sc.add_soft(SoftBody.box_lattice(Vec3(0, 1.0, 0, 0), Vec3(0.3, 0.3, 0.3, 0), 4, 2.0, Real(1e-6)))
    for _ in range(200):
        sc.step_soft(Real(1.0 / 60.0), Vec3(0, -9.8, 0, 0))
    var bytes = List[UInt8]()
    for p in sc.softs[0].pts:
        for k in range(3):
            var b = bitcast[DType.uint32, 1](Float32(p.x[k]))
            for j in range(4):
                bytes.append(UInt8((b >> UInt32(8 * j)) & 0xFF))
    return fnv1a(bytes)


@export
def gate_callback() abi("C") -> UInt64:
    return callback_hash()


@export
def gate_soft() abi("C") -> UInt64:
    try:
        return soft_hash()
    except:
        return 0


def main() raises:
    print("callback", hex(callback_hash()))
    print("soft    ", hex(soft_hash()))
