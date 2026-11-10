"""Hand a world to a new module instance (ROADMAP 17.91, ludens-core #84).

Code hot reload in the editor (ludens-engine #14) works by swapping the module: save the world from the old
instance, build the new instance, load. `EmbedWorld.save` / `load` already round-trip the simulation, but a swap needs
more than that, so this file wraps them in a transfer blob that checks, before anything is changed, that the new side
can continue the run bit for bit and says which condition failed:

    var blob = transfer_save(world, registered)       # old module
    transfer_load(world2, blob, registered2)          # new module; raises with a named status, world untouched

A blob holds: magic, `TRANSFER_VERSION`, the scalar width (4 for `Float32` worlds, 8 for `f64` builds), a hash of the
settings that change simulation results (dt, gravity, unit scale, max steps and the `SolverConfig` knobs that are not
execution-only), the host material ids (`save` does not hold them), the host's list of registered names, a checksum of
everything after the header, then the inner `save` blob.

State that is NOT in the blob and so is the new side's to rebuild:

| state | rule |
|---|---|
| systems (`ld_world_add_system`), contact subscriptions | the host registers them again; pass their names as `registered`, load refuses a different set (`XFER_REGISTRATION`) |
| settings (dt, gravity, solver) | the new instance is created with the same values; a different hash is refused (`XFER_SETTINGS`) |
| capture (`capture_begin`), trace, pending event lists | dropped; a capture running during the swap ends (`load` clears the event lists) |
| host pointers / callbacks | live in the host; `user` data (a `UInt64` per body) is in the blob |
| fractured objects, water | refused by `save` itself; `transfer_save` raises |
| sleeping state, warm-start caches | inside the inner snapshot as far as `save` holds them; what it does not hold is rebuilt by the solver |

Only the world moves; the shell registers systems again. See ROADMAP 17.21 for hot reload of Mojo systems.
"""
from std.sys import size_of
from embed.world import EmbedWorld, fnv1a
from geometry.vec import Real

comptime TRANSFER_MAGIC = 0x3158444C  # "LDX1" little-endian
comptime TRANSFER_VERSION = 1

comptime XFER_OK = 0
comptime XFER_TRUNCATED = -1
comptime XFER_MAGIC = -2
comptime XFER_VERSION = -3
comptime XFER_SCALAR = -4
comptime XFER_SETTINGS = -5
comptime XFER_REGISTRATION = -6
comptime XFER_CORRUPT = -7


def transfer_status_name(status: Int) -> String:
    if status == XFER_OK:
        return "ok"
    if status == XFER_TRUNCATED:
        return "truncated"
    if status == XFER_MAGIC:
        return "not a transfer blob"
    if status == XFER_VERSION:
        return "format version differs"
    if status == XFER_SCALAR:
        return "scalar width differs"
    if status == XFER_SETTINGS:
        return "world settings differ"
    if status == XFER_REGISTRATION:
        return "registered names differ"
    if status == XFER_CORRUPT:
        return "checksum mismatch"
    return "unknown"


def _put(mut out: List[UInt8], v: UInt64):
    for k in range(8):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _fold(h: UInt64, v: UInt64) -> UInt64:
    return (h ^ v) * UInt64(0x100000001B3)


def _rbits(r: Real) -> UInt64:
    return UInt64(Float64(r).to_bits())


def settings_hash(world: EmbedWorld) -> UInt64:
    """Hash of everything outside the snapshot that changes what the next tick computes. Execution-only knobs
    (`parallel`, `workers`, `dispatch`, `parallel_collision`) are left out: they are bit-identical by contract."""
    var h = UInt64(0xCBF29CE484222325)
    h = _fold(h, UInt64(world.dt.to_bits()))
    h = _fold(h, _rbits(world.gravity[0]))
    h = _fold(h, _rbits(world.gravity[1]))
    h = _fold(h, _rbits(world.gravity[2]))
    h = _fold(h, _rbits(world.per_meter))
    h = _fold(h, UInt64(world.max_steps))
    ref c = world.cfg
    h = _fold(h, _rbits(c.margin_base))
    h = _fold(h, _rbits(c.lin_sleep_tol))
    h = _fold(h, _rbits(c.ang_sleep_tol))
    h = _fold(h, _rbits(c.sleep_time))
    h = _fold(h, _rbits(c.restitution_threshold))
    h = _fold(h, _rbits(c.max_push_speed))
    h = _fold(h, UInt64(c.substeps))
    h = _fold(h, UInt64(c.iters))
    h = _fold(h, _rbits(c.hertz))
    h = _fold(h, _rbits(c.zeta))
    h = _fold(h, _rbits(c.default_friction))
    h = _fold(h, UInt64(1) if c.ccd else UInt64(0))
    h = _fold(h, UInt64(1) if c.colored else UInt64(0))
    h = _fold(h, UInt64(1) if c.broadphase else UInt64(0))
    h = _fold(h, UInt64(c.impulse_estimator))
    h = _fold(h, UInt64(c.friction_cone))
    h = _fold(h, UInt64(1) if c.reuse_still_pairs else UInt64(0))
    h = _fold(h, UInt64(c.max_contacts))
    h = _fold(h, UInt64(c.contact_solver))
    h = _fold(h, _rbits(c.max_mass_ratio))
    h = _fold(h, UInt64(1) if c.reduce_mesh_contacts else UInt64(0))
    return h


def _names_hash(names: List[String]) -> UInt64:
    """Order-independent hash of a set of names (a sum of per-name hashes), so registration order does not matter."""
    var total = UInt64(0)
    for n in names:
        var h = UInt64(0xCBF29CE484222325)
        for b in n.as_bytes():
            h = _fold(h, UInt64(b))
        total += h * 0x9E3779B97F4A7C15 + 1
    return total ^ UInt64(len(names))


def _rd(data: List[UInt8], pos: Int) -> Optional[UInt64]:
    if pos < 0 or pos + 8 > len(data):
        return None
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(data[pos + k]) << UInt64(8 * k)
    return v


def _fnv_from(data: List[UInt8], start: Int) -> UInt64:
    """`fnv1a` of data[start:], without copying the tail."""
    var h = UInt64(0xCBF29CE484222325)
    for i in range(start, len(data)):
        h = (h ^ UInt64(data[i])) * UInt64(0x100000001B3)
    return h


# header layout, byte offsets of u64 fields
comptime _O_MAGIC = 0
comptime _O_VERSION = 8
comptime _O_SCALAR = 16
comptime _O_SETTINGS = 24
comptime _O_REGISTERED = 32
comptime _O_LENGTH = 40
comptime _O_CHECKSUM = 48
comptime _O_BODY = 56


@fieldwise_init
struct TransferInfo(Copyable, Movable):
    """What the header says; `status` is `XFER_OK` when the blob can be read at all."""
    var status: Int
    var version: Int
    var scalar_bytes: Int
    var settings: UInt64
    var registered: UInt64
    var materials: Int
    var payload_bytes: Int


def transfer_save(world: EmbedWorld, registered: List[String]) raises -> List[UInt8]:
    """The transfer blob of `world`. `registered` names what the host has registered (systems, subscriptions)."""
    if world.fracture_on or world.water_on:
        raise Error("transfer_save: refused while the world has a fractured object or a water tank")
    var inner = world.save()
    var mats = List[UInt64]()  # (slot, gen, id) triples for slots that have a material
    var count = 0
    for i in range(len(world.material)):
        if world.material[i] != 0 and not world.scene.bset.is_removed(i) and world.scene.bset.id_of(i).gen == world.material_gen[i]:
            mats.append(UInt64(i))
            mats.append(UInt64(world.material_gen[i]))
            mats.append(UInt64(world.material[i]))
            count += 1
    var body = List[UInt8]()
    _put(body, UInt64(count))
    for v in mats:
        _put(body, v)
    _put(body, UInt64(len(inner)))
    body.extend(inner^)
    var out = List[UInt8]()
    _put(out, UInt64(TRANSFER_MAGIC))
    _put(out, UInt64(TRANSFER_VERSION))
    _put(out, UInt64(size_of[Real]()))
    _put(out, settings_hash(world))
    _put(out, _names_hash(registered))
    _put(out, UInt64(len(body)))
    _put(out, fnv1a(body))
    out.extend(body^)
    return out^


def transfer_info(blob: List[UInt8]) -> TransferInfo:
    """Read the header only. Never raises; a bad blob comes back with its status."""
    var magic = _rd(blob, _O_MAGIC)
    if not magic:
        return TransferInfo(XFER_TRUNCATED, 0, 0, 0, 0, 0, 0)
    if magic.value() != UInt64(TRANSFER_MAGIC):
        return TransferInfo(XFER_MAGIC, 0, 0, 0, 0, 0, 0)
    var ver = _rd(blob, _O_VERSION)
    var sc = _rd(blob, _O_SCALAR)
    var sh = _rd(blob, _O_SETTINGS)
    var reg = _rd(blob, _O_REGISTERED)
    var n = _rd(blob, _O_LENGTH)
    var ck = _rd(blob, _O_CHECKSUM)
    if not (ver and sc and sh and reg and n and ck):
        return TransferInfo(XFER_TRUNCATED, 0, 0, 0, 0, 0, 0)
    var status = XFER_OK
    if Int(ver.value()) != TRANSFER_VERSION:
        status = XFER_VERSION
    elif Int(n.value()) < 0 or _O_BODY + Int(n.value()) != len(blob):
        status = XFER_TRUNCATED
    return TransferInfo(status, Int(ver.value()), Int(sc.value()), sh.value(), reg.value(), 0, Int(n.value()))


def transfer_check(world: EmbedWorld, blob: List[UInt8], registered: List[String]) -> Int:
    """The status `transfer_load` would give, without touching anything. The first failing condition wins, in the
    order: truncated / magic, version, scalar width, checksum, settings, registration."""
    var info = transfer_info(blob)
    if info.status != XFER_OK:
        return info.status
    if info.scalar_bytes != size_of[Real]():
        return XFER_SCALAR
    var ck = _rd(blob, _O_CHECKSUM)
    if not ck or _fnv_from(blob, _O_BODY) != ck.value():
        return XFER_CORRUPT
    if info.settings != settings_hash(world):
        return XFER_SETTINGS
    if info.registered != _names_hash(registered):
        return XFER_REGISTRATION
    return XFER_OK


def transfer_load(mut world: EmbedWorld, blob: List[UInt8], registered: List[String]) raises:
    """Replace `world`'s simulation state with the blob's. On any failure the world is unchanged and the error
    starts with the status number and name, e.g. `transfer_load(-3): format version differs (blob 2, here 1)`."""
    var status = transfer_check(world, blob, registered)
    if status != XFER_OK:
        var info = transfer_info(blob)
        var detail = String()
        if status == XFER_VERSION:
            detail = " (blob " + String(info.version) + ", here " + String(TRANSFER_VERSION) + ")"
        elif status == XFER_SCALAR:
            detail = " (blob " + String(info.scalar_bytes) + " bytes, here " + String(size_of[Real]()) + ")"
        raise Error("transfer_load(" + String(status) + "): " + transfer_status_name(status) + detail)
    var pos = _O_BODY
    var count = Int(_rd(blob, pos).value())
    pos += 8
    var slots = List[Int]()
    var gens = List[UInt32]()
    var ids = List[UInt32]()
    if count < 0 or count > len(blob):
        raise Error("transfer_load(" + String(XFER_CORRUPT) + "): bad material count")
    for _ in range(count):
        var a = _rd(blob, pos)
        var b = _rd(blob, pos + 8)
        var c = _rd(blob, pos + 16)
        pos += 24
        if not (a and b and c):
            raise Error("transfer_load(" + String(XFER_TRUNCATED) + "): truncated")
        slots.append(Int(a.value()))
        gens.append(UInt32(b.value()))
        ids.append(UInt32(c.value()))
    var inner_len = _rd(blob, pos)
    pos += 8
    if not inner_len or Int(inner_len.value()) < 0 or pos + Int(inner_len.value()) != len(blob):
        raise Error("transfer_load(" + String(XFER_TRUNCATED) + "): truncated")
    var inner = List[UInt8](capacity=Int(inner_len.value()))
    for i in range(Int(inner_len.value())):
        inner.append(blob[pos + i])
    world.load(inner)  # raises before changing anything if the inner blob is bad
    world.material = List[UInt32]()
    world.material_gen = List[UInt32]()
    for k in range(count):
        while len(world.material) <= slots[k]:
            world.material.append(0)
            world.material_gen.append(0)
        world.material[slots[k]] = ids[k]
        world.material_gen[slots[k]] = gens[k]
