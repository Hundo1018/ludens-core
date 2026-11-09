"""Sparse-set ECS backend (EnTT-style).

One `SparseSet[C, CAP]` per component type, plus a liveness sparse set mapping
`entity id -> generation`. O(1) add/remove/has; single-component iteration is
dense and cache-friendly; multi-component queries intersect the smallest set.

The N typed stores are heterogeneous, so they live on the heap behind
type-erased pointer slots indexed by the component's position in `*CTs`. Only
the *pointer* is erased — each store stays a fully typed `SparseSet[C, CAP]`.
The slot list is preallocated to exactly N (a realloc would corrupt erased
pointers) and all access goes through value-returning methods.
"""

from std.memory import alloc, Layout
from .component import ComponentType
from .entity import Entity
from .sparse_set import SparseSet
from .storage import StorageBackend, Filter, SlotMask, resolve_filter, check_pack
from std.sys import size_of

comptime Slot = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())


struct SparseSetBackend[*CTs: ComponentType](StorageBackend):
    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap SparseSet[CTs[i], cap]
    var alive: SparseSet[Int]  # entity id -> generation
    var counter: Int
    # Generational recycling, matching `ArchetypeBackend`: `gens[id]` survives
    # despawn (unlike `alive`, which drops the id), so a recycled id comes back
    # with a higher generation and every handle to the previous occupant stays
    # dead. Without this a reused id would silently resurrect stale handles —
    # the case `test_backend_parity` now checks on every backend.
    var free_ids: List[Int]
    var gens: List[Int]

    def __init__(out self):
        check_pack[*Self.CTs]()
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[SparseSet[T]](Layout[SparseSet[T]](count=1)).unsafe_leak()
            p.unsafe_write(SparseSet[T]())
            self.slots.append(p.unsafe_bitcast[NoneType]())
        self.alive = SparseSet[Int]()
        self.counter = 0
        self.free_ids = List[Int]()
        self.gens = List[Int]()

    def __deinit__(deinit self):
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = self.slots[i].unsafe_bitcast[SparseSet[T]]()
            p.unsafe_deinit_pointee()
            p.unsafe_free()

    @staticmethod
    def _slot_of[C: ComponentType]() -> Int:
        comptime for i in range(Self.N):
            comptime if Self.CTs[i].ID == C.ID:
                return i
        return -1

    def _store[C: ComponentType](self) -> type_of(alloc[SparseSet[C]](Layout[SparseSet[C]](count=1)).unsafe_leak()):
        return self.slots[Self._slot_of[C]()].unsafe_bitcast[SparseSet[C]]()

    # --- lifecycle ---
    def _ensure_gen(mut self, id: Int):
        while len(self.gens) <= id:
            self.gens.append(0)

    def spawn(mut self) -> Entity:
        var id: Int
        if len(self.free_ids) > 0:
            id = self.free_ids.pop()
        else:
            id = self.counter
            self.counter += 1
        self._ensure_gen(id)
        var gen = self.gens[id]
        self.alive.set(id, gen)
        return Entity(id, gen)

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
        self.alive.set(e.id, e.gen)
        return True

    def despawn(mut self, e: Entity):
        if not self.is_alive(e):
            return
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            self._store[T]()[].remove(e.id)
        self.alive.remove(e.id)
        self._ensure_gen(e.id)
        self.gens[e.id] = e.gen + 1
        self.free_ids.append(e.id)

    def is_alive(self, e: Entity) -> Bool:
        return self.alive.contains(e.id) and self.alive.get(e.id) == e.gen

    def entity_count(self) -> Int:
        return len(self.alive)

    # --- typed component access ---
    def set[C: ComponentType](mut self, e: Entity, var value: C):
        self._store[C]()[].set(e.id, value)

    def has[C: ComponentType](self, e: Entity) -> Bool:
        return self._store[C]()[].contains(e.id)

    def get[C: ComponentType](self, e: Entity) -> C:
        return self._store[C]()[].get(e.id)

    def remove[C: ComponentType](mut self, e: Entity):
        self._store[C]()[].remove(e.id)

    # --- queries ---
    def _entity(self, id: Int) -> Entity:
        return Entity(id, self.alive.get(id))

    def _has_slot(self, s: Int, id: Int) -> Bool:
        comptime for i in range(Self.N):
            if i == s:
                return self._store[Self.CTs[i]]()[].contains(id)
        return False

    def _len_slot(self, s: Int) -> Int:
        comptime for i in range(Self.N):
            if i == s:
                return self._store[Self.CTs[i]]()[].dense_len()
        return 0

    def _key_slot(self, s: Int, k: Int) -> Int:
        comptime for i in range(Self.N):
            if i == s:
                return self._store[Self.CTs[i]]()[].key_at(k)
        return -1

    def _passes(self, m: SlotMask, id: Int, skip: Int) -> Bool:
        var anyhit = m.any_bits == 0
        for s in range(Self.N):
            var bit = 1 << s
            if s != skip and (m.with_bits & bit) != 0 and not self._has_slot(s, id):
                return False
            if (m.without_bits & bit) != 0 and self._has_slot(s, id):
                return False
            if not anyhit and (m.any_bits & bit) != 0 and self._has_slot(s, id):
                anyhit = True
        return anyhit

    def select(self, f: Filter) -> List[Entity]:
        """17.77: walk the smallest `with_` store and probe the rest (every
        live entity when there is no `with_` type)."""
        var m = resolve_filter[*Self.CTs](f)
        var out = List[Entity]()
        if m.impossible:
            return out^
        var best = -1
        for s in range(Self.N):
            if (m.with_bits >> s) & 1 == 1 and (best < 0 or self._len_slot(s) < self._len_slot(best)):
                best = s
        if best >= 0:
            for k in range(self._len_slot(best)):
                var id = self._key_slot(best, k)
                if self._passes(m, id, best):
                    out.append(Entity(id, self.alive.get(id)))
        else:
            for k in range(len(self.alive)):
                var id = self.alive.key_at(k)
                if self._passes(m, id, -1):
                    out.append(Entity(id, self.alive.get(id)))
        return out^

    def matching1[A: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var store = self._store[A]()
        for i in range(store[].dense_len()):
            out.append(self._entity(store[].key_at(i)))
        return out^

    def matching2[A: ComponentType, B: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = self._store[A]()
        var sb = self._store[B]()
        # iterate the smaller store, probe the larger
        if sa[].dense_len() <= sb[].dense_len():
            for i in range(sa[].dense_len()):
                var id = sa[].key_at(i)
                if sb[].contains(id):
                    out.append(self._entity(id))
        else:
            for i in range(sb[].dense_len()):
                var id = sb[].key_at(i)
                if sa[].contains(id):
                    out.append(self._entity(id))
        return out^

    def matching3[
        A: ComponentType, B: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = self._store[A]()
        for i in range(sa[].dense_len()):
            var id = sa[].key_at(i)
            if self._store[B]()[].contains(id) and self._store[C]()[].contains(id):
                out.append(self._entity(id))
        return out^

    def storage_bytes(self) -> Int:
        """ROADMAP 17.79: bytes this backend holds in use (lengths x element
        sizes; list capacity slack and allocator overhead not counted, so a
        lower bound)."""
        var t = self.alive.bytes()
        t += len(self.free_ids) * size_of[Int]() + len(self.gens) * size_of[Int]()
        comptime for i in range(Self.N):
            t += self._store[Self.CTs[i]]()[].bytes()
        return t

    def for_each2[
        A: ComponentType,
        B: ComponentType,
        F: def (mut A, B) -> None,
    ](mut self, func: F):
        # Iterate the smaller dense store, probe the larger. No List[Entity]
        # allocation (the win); A is read/run/written-back (small-value copy).
        var sa = self._store[A]()
        var sb = self._store[B]()
        if sa[].dense_len() <= sb[].dense_len():
            for i in range(sa[].dense_len()):
                var id = sa[].key_at(i)
                if sb[].contains(id):
                    var a = sa[].value_at(i)
                    func(a, sb[].get(id))
                    sa[].set(id, a)
        else:
            for i in range(sb[].dense_len()):
                var id = sb[].key_at(i)
                if sa[].contains(id):
                    var a = sa[].get(id)
                    func(a, sb[].value_at(i))
                    sa[].set(id, a)

    def for_each3[
        A: ComponentType,
        B: ComponentType,
        C: ComponentType,
        F: def (mut A, B, C) -> None,
    ](mut self, func: F):
        # Drive with the smallest of the three dense stores, probe the others;
        # A is read/run/written-back as in for_each2.
        var sa = self._store[A]()
        var sb = self._store[B]()
        var sc = self._store[C]()
        var na = sa[].dense_len()
        var nb = sb[].dense_len()
        var nc = sc[].dense_len()
        var drive = 0
        if nb < na and nb <= nc:
            drive = 1
        elif nc < na and nc < nb:
            drive = 2
        var cnt = na if drive == 0 else (nb if drive == 1 else nc)
        for i in range(cnt):
            var id = sa[].key_at(i) if drive == 0 else (sb[].key_at(i) if drive == 1 else sc[].key_at(i))
            if sa[].contains(id) and sb[].contains(id) and sc[].contains(id):
                var a = sa[].get(id)
                func(a, sb[].get(id), sc[].get(id))
                sa[].set(id, a)

