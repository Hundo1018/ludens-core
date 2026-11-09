"""Naive array-of-structs ECS backend — the brute-force baseline.

The simplest thing that works: each component lives in a heap `List[Optional[C]]`
indexed directly by entity id (holes are `None`), and every query is a full
linear scan over all ids that checks each required component's slot. No sparse
sets, no archetypes, no bitmasks, no smallest-set heuristic — deliberately the
slowest backend, included as the lower bound the others are measured against.

Component lists are heterogeneous, so they live behind type-erased pointer slots
exactly like `SparseSetBackend` (only the pointer is erased; each list stays a
typed `List[Optional[C]]`). `Optional` lets us pad new ids without requiring
components to be `Defaultable`.
"""

from std.memory import alloc, Layout
from .component import ComponentType
from .entity import Entity
from .storage import StorageBackend, Filter, resolve_filter, check_pack
from std.sys import size_of

comptime Slot = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())


struct NaiveBackend[*CTs: ComponentType](StorageBackend):
    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap List[Optional[CTs[i]]], indexed by id
    var live: List[Bool]  # live[id] -> is entity id alive
    var n_live: Int
    # Generational recycling (see ArchetypeBackend): `gens[id]` outlives the
    # live flag, so a reused id returns with a higher generation and stale
    # handles stay dead. Gated per backend in `test_backend_parity`.
    var free_ids: List[Int]
    var gens: List[Int]

    def __init__(out self):
        check_pack[*Self.CTs]()
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[List[Optional[T]]](Layout[List[Optional[T]]](count=1)).unsafe_leak()
            p.unsafe_write(List[Optional[T]]())
            self.slots.append(p.unsafe_bitcast[NoneType]())
        self.live = List[Bool]()
        self.n_live = 0
        self.free_ids = List[Int]()
        self.gens = List[Int]()

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

    # --- lifecycle ---
    def _ensure_gen(mut self, id: Int):
        while len(self.gens) <= id:
            self.gens.append(0)

    def spawn(mut self) -> Entity:
        var id: Int
        if len(self.free_ids) > 0:
            id = self.free_ids.pop()
            self.live[id] = True  # columns already have a cell for this id
        else:
            id = len(self.live)
            self.live.append(True)
            # Grow every component column with an empty cell for the new id.
            comptime for i in range(Self.N):
                comptime T = Self.CTs[i]
                self._store[T]()[].append(Optional[T]())
        self.n_live += 1
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
        self.live[e.id] = True
        self.n_live += 1
        return True

    def despawn(mut self, e: Entity):
        if not self.is_alive(e):
            return
        self.live[e.id] = False
        self.n_live -= 1
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            self._store[T]()[][e.id] = Optional[T]()
        self._ensure_gen(e.id)
        self.gens[e.id] = e.gen + 1
        self.free_ids.append(e.id)

    def is_alive(self, e: Entity) -> Bool:
        if e.id < 0 or e.id >= len(self.live) or not self.live[e.id]:
            return False
        return e.id < len(self.gens) and self.gens[e.id] == e.gen

    def entity_count(self) -> Int:
        return self.n_live

    # --- typed component access ---
    def set[C: ComponentType](mut self, e: Entity, var value: C):
        self._store[C]()[][e.id] = Optional[C](value^)

    def has[C: ComponentType](self, e: Entity) -> Bool:
        return Bool(self._store[C]()[][e.id])

    def get[C: ComponentType](self, e: Entity) -> C:
        return self._store[C]()[][e.id].value()

    def remove[C: ComponentType](mut self, e: Entity):
        self._store[C]()[][e.id] = Optional[C]()

    # --- queries: brute-force linear scans over every id ---
    def _has_slot(self, s: Int, id: Int) -> Bool:
        comptime for i in range(Self.N):
            if i == s:
                return Bool(self._store[Self.CTs[i]]()[][id])
        return False

    def select(self, f: Filter) -> List[Entity]:
        """17.77: one pass over every id (this backend has no index)."""
        var m = resolve_filter[*Self.CTs](f)
        var out = List[Entity]()
        if m.impossible:
            return out^
        for id in range(len(self.live)):
            if not self.live[id]:
                continue
            var mask = 0
            for s in range(Self.N):
                if self._has_slot(s, id):
                    mask |= 1 << s
            if m.accepts(mask):
                out.append(Entity(id, self.gens[id] if id < len(self.gens) else 0))
        return out^

    def matching1[A: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = self._store[A]()
        for id in range(len(self.live)):
            if self.live[id] and sa[][id]:
                out.append(Entity(id, self.gens[id] if id < len(self.gens) else 0))
        return out^

    def matching2[A: ComponentType, B: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = self._store[A]()
        var sb = self._store[B]()
        for id in range(len(self.live)):
            if self.live[id] and sa[][id] and sb[][id]:
                out.append(Entity(id, self.gens[id] if id < len(self.gens) else 0))
        return out^

    def matching3[
        A: ComponentType, B: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        var out = List[Entity]()
        var sa = self._store[A]()
        var sb = self._store[B]()
        var sc = self._store[C]()
        for id in range(len(self.live)):
            if self.live[id] and sa[][id] and sb[][id] and sc[][id]:
                out.append(Entity(id, self.gens[id] if id < len(self.gens) else 0))
        return out^

    def storage_bytes(self) -> Int:
        """ROADMAP 17.79: bytes this backend holds in use (lengths x element
        sizes; list capacity slack and allocator overhead not counted, so a
        lower bound)."""
        var t = len(self.live) * size_of[Bool]()
        t += len(self.free_ids) * size_of[Int]() + len(self.gens) * size_of[Int]()
        comptime for i in range(Self.N):
            t += len(self._store[Self.CTs[i]]()[]) * size_of[Optional[Self.CTs[i]]]()
        return t

    def for_each2[
        A: ComponentType,
        B: ComponentType,
        F: def (mut A, B) -> None,
    ](mut self, func: F):
        # Optional-column storage: read a/b, run func on a local `a`, write it
        # back. No List[Entity] allocation (the actual win vs matching2 + get/set).
        var sa = self._store[A]()
        var sb = self._store[B]()
        for id in range(len(self.live)):
            if self.live[id] and sa[][id] and sb[][id]:
                var a = sa[][id].value()
                func(a, sb[][id].value())
                sa[][id] = Optional[A](a)

    def for_each3[
        A: ComponentType,
        B: ComponentType,
        C: ComponentType,
        F: def (mut A, B, C) -> None,
    ](mut self, func: F):
        var sa = self._store[A]()
        var sb = self._store[B]()
        var sc = self._store[C]()
        for id in range(len(self.live)):
            if self.live[id] and sa[][id] and sb[][id] and sc[][id]:
                var a = sa[][id].value()
                func(a, sb[][id].value(), sc[][id].value())
                sa[][id] = Optional[A](a)

