"""Bitset ECS backend (EntityX / Specs style).

Component *values* live in heap `List[Optional[C]]` columns indexed by entity id,
but component *presence* is tracked in per-component bitsets: `masks[slot]` is a
`List[UInt64]` where bit `id` means "id has this component". Liveness is its own
bitset. A multi-component query ANDs the relevant presence bitsets (and the
liveness bitset) word-by-word and walks the set bits with `count_trailing_zeros`
— skipping empty 64-id words wholesale, which is the bitset model's advantage on
sparse populations.

The value columns are heterogeneous and sit behind type-erased pointer slots, as
in the other backends; the bitsets are homogeneous `UInt64` and need no erasure.
"""

from std.bit import count_trailing_zeros
from std.memory import alloc, Layout
from .component import ComponentType
from .entity import Entity
from .storage import StorageBackend, Filter, resolve_filter, check_pack
from std.sys import size_of

comptime Slot = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())


def _word(i: Int) -> Int:
    return i >> 6


def _bit(i: Int) -> UInt64:
    return UInt64(1) << UInt64(i & 63)


struct BitsetBackend[*CTs: ComponentType](StorageBackend):
    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap List[Optional[CTs[i]]], indexed by id
    var masks: List[List[UInt64]]  # masks[slot][word] -> component presence bits
    var live_mask: List[UInt64]  # liveness bits
    var counter: Int
    # Generational recycling (see ArchetypeBackend): `gens[id]` outlives the
    # liveness bit, so a reused id returns with a higher generation and stale
    # handles stay dead. Gated per backend in `test_backend_parity`.
    var free_ids: List[Int]
    var gens: List[Int]
    var n_live: Int

    def __init__(out self):
        check_pack[*Self.CTs]()
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[List[Optional[T]]](Layout[List[Optional[T]]](count=1)).unsafe_leak()
            p.unsafe_write(List[Optional[T]]())
            self.slots.append(p.unsafe_bitcast[NoneType]())
        self.masks = List[List[UInt64]]()
        comptime for i in range(Self.N):
            self.masks.append(List[UInt64]())
        self.live_mask = List[UInt64]()
        self.counter = 0
        self.free_ids = List[Int]()
        self.gens = List[Int]()
        self.n_live = 0

    def __deinit__(deinit self):
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = self.slots[i].unsafe_bitcast[List[Optional[T]]]()
            p.unsafe_deinit_pointee()
            p.unsafe_free()

    @staticmethod
    def _slot_of[C: ComponentType]() -> Int:
        comptime for i in range(Self.N):
            comptime if Self.CTs[i].ID == C.ID:
                return i
        return -1

    def _store[C: ComponentType](self) -> type_of(alloc[List[Optional[C]]](Layout[List[Optional[C]]](count=1)).unsafe_leak()):
        return self.slots[Self._slot_of[C]()].unsafe_bitcast[List[Optional[C]]]()

    def _set_mask(mut self, slot: Int, id: Int):
        var w = _word(id)
        self.masks[slot][w] = self.masks[slot][w] | _bit(id)

    def _clear_mask(mut self, slot: Int, id: Int):
        var w = _word(id)
        self.masks[slot][w] = self.masks[slot][w] & ~_bit(id)

    def _ensure_word(mut self, w: Int):
        """Grow all presence bitsets + the liveness bitset to include word `w`."""
        while len(self.live_mask) <= w:
            self.live_mask.append(0)
            comptime for i in range(Self.N):
                self.masks[i].append(0)

    # --- lifecycle ---
    def _ensure_gen(mut self, id: Int):
        while len(self.gens) <= id:
            self.gens.append(0)

    def spawn(mut self) -> Entity:
        var id: Int
        var fresh = True
        if len(self.free_ids) > 0:
            id = self.free_ids.pop()
            fresh = False  # its column cells already exist (cleared on despawn)
        else:
            id = self.counter
            self.counter += 1
        var w = _word(id)
        self._ensure_word(w)
        self.live_mask[w] = self.live_mask[w] | _bit(id)
        self.n_live += 1
        if fresh:
            comptime for i in range(Self.N):
                comptime T = Self.CTs[i]
                self._store[T]()[].append(Optional[T]())
        self._ensure_gen(id)
        return Entity(id, self.gens[id])

    def _take_free(mut self, e: Entity) -> Bool:
        """Is `e` exactly the occupant a `despawn` just retired: its id is on the free list and its generation was
        bumped once past `e.gen`? Removes the id from the free list when so."""
        if e.id < 0 or e.id >= len(self.gens) or self.gens[e.id] != e.gen + 1:
            return False
        for k in range(len(self.free_ids)):
            if self.free_ids[k] == e.id:
                _ = self.free_ids.pop(k)
                self.gens[e.id] = e.gen
                return True
        return False

    def respawn(mut self, e: Entity) -> Bool:
        """Bring a despawned entity back under the same id and generation (undo of a delete): only while its id has not been reused. Components are not restored. False when it cannot."""
        if not self._take_free(e):
            return False
        var w = _word(e.id)
        self._ensure_word(w)
        self.live_mask[w] = self.live_mask[w] | _bit(e.id)
        self.n_live += 1
        return True

    def despawn(mut self, e: Entity):
        if not self.is_alive(e):
            return
        var w = _word(e.id)
        self.live_mask[w] = self.live_mask[w] & ~_bit(e.id)
        self.n_live -= 1
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            self._store[T]()[][e.id] = Optional[T]()
            self._clear_mask(i, e.id)
        self._ensure_gen(e.id)
        self.gens[e.id] = e.gen + 1
        self.free_ids.append(e.id)

    def is_alive(self, e: Entity) -> Bool:
        if e.id < 0 or e.id >= self.counter:
            return False
        if (self.live_mask[_word(e.id)] & _bit(e.id)) == 0:
            return False
        return e.id < len(self.gens) and self.gens[e.id] == e.gen

    def entity_count(self) -> Int:
        return self.n_live

    # --- typed component access ---
    def set[C: ComponentType](mut self, e: Entity, var value: C):
        self._store[C]()[][e.id] = Optional[C](value^)
        self._set_mask(Self._slot_of[C](), e.id)

    def has[C: ComponentType](self, e: Entity) -> Bool:
        var slot = Self._slot_of[C]()
        return (self.masks[slot][_word(e.id)] & _bit(e.id)) != 0

    def get[C: ComponentType](self, e: Entity) -> C:
        return self._store[C]()[][e.id].value()

    def remove[C: ComponentType](mut self, e: Entity):
        self._store[C]()[][e.id] = Optional[C]()
        self._clear_mask(Self._slot_of[C](), e.id)

    # --- queries: AND the presence bitsets, walk set bits ---
    def _emit(self, bits: UInt64, base: Int, mut out: List[Entity]):
        var b = bits
        while b != 0:
            var _id = base + Int(count_trailing_zeros(b))
            out.append(Entity(_id, self.gens[_id] if _id < len(self.gens) else 0))
            b &= b - 1

    def select(self, f: Filter) -> List[Entity]:
        """17.77: word-level AND / AND-NOT / OR over the presence bitsets."""
        var m = resolve_filter[*Self.CTs](f)
        var out = List[Entity]()
        if m.impossible:
            return out^
        for w in range(len(self.live_mask)):
            var bits = self.live_mask[w]
            var anyw = UInt64(0)
            for s in range(Self.N):
                if (m.with_bits >> s) & 1 == 1:
                    bits &= self.masks[s][w]
                if (m.without_bits >> s) & 1 == 1:
                    bits &= ~self.masks[s][w]
                if (m.any_bits >> s) & 1 == 1:
                    anyw |= self.masks[s][w]
            if m.any_bits != 0:
                bits &= anyw
            self._emit(bits, w * 64, out)
        return out^

    def matching1[A: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = Self._slot_of[A]()
        for w in range(len(self.live_mask)):
            self._emit(self.masks[sa][w] & self.live_mask[w], w * 64, out)
        return out^

    def matching2[A: ComponentType, B: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = Self._slot_of[A]()
        var sb = Self._slot_of[B]()
        for w in range(len(self.live_mask)):
            var bits = self.masks[sa][w] & self.masks[sb][w] & self.live_mask[w]
            self._emit(bits, w * 64, out)
        return out^

    def matching3[
        A: ComponentType, B: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = Self._slot_of[A]()
        var sb = Self._slot_of[B]()
        var sc = Self._slot_of[C]()
        for w in range(len(self.live_mask)):
            var bits = (
                self.masks[sa][w]
                & self.masks[sb][w]
                & self.masks[sc][w]
                & self.live_mask[w]
            )
            self._emit(bits, w * 64, out)
        return out^

    def storage_bytes(self) -> Int:
        """ROADMAP 17.79: bytes this backend holds in use (lengths x element
        sizes; list capacity slack and allocator overhead not counted, so a
        lower bound)."""
        var t = len(self.live_mask) * size_of[UInt64]()
        t += len(self.free_ids) * size_of[Int]() + len(self.gens) * size_of[Int]()
        for ref m in self.masks:
            t += len(m) * size_of[UInt64]()
        comptime for i in range(Self.N):
            t += len(self._store[Self.CTs[i]]()[]) * size_of[Optional[Self.CTs[i]]]()
        return t

    def for_each2[
        A: ComponentType,
        B: ComponentType,
        F: def (mut A, B) -> None,
    ](mut self, func: F):
        # AND the presence bitsets word-by-word, walk set bits, read/run/write-back.
        # No List[Entity] allocation.
        var sla = Self._slot_of[A]()
        var slb = Self._slot_of[B]()
        var sta = self._store[A]()
        var stb = self._store[B]()
        for w in range(len(self.live_mask)):
            var bits = self.masks[sla][w] & self.masks[slb][w] & self.live_mask[w]
            while bits != 0:
                var id = w * 64 + Int(count_trailing_zeros(bits))
                bits &= bits - 1
                var a = sta[][id].value()
                func(a, stb[][id].value())
                sta[][id] = Optional[A](a)

    def for_each3[
        A: ComponentType,
        B: ComponentType,
        C: ComponentType,
        F: def (mut A, B, C) -> None,
    ](mut self, func: F):
        var sla = Self._slot_of[A]()
        var slb = Self._slot_of[B]()
        var slc = Self._slot_of[C]()
        var sta = self._store[A]()
        var stb = self._store[B]()
        var stc = self._store[C]()
        for w in range(len(self.live_mask)):
            var bits = self.masks[sla][w] & self.masks[slb][w] & self.masks[slc][w] & self.live_mask[w]
            while bits != 0:
                var id = w * 64 + Int(count_trailing_zeros(bits))
                bits &= bits - 1
                var a = sta[][id].value()
                func(a, stb[][id].value(), stc[][id].value())
                sta[][id] = Optional[A](a)

