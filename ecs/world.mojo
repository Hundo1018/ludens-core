"""The world: entities + components over a swappable storage backend.

`World[B: StorageBackend]` is the only type game code touches. Pick the backend
at instantiation:

    var w = World[SparseSetBackend[Position, Velocity]]()
    # ...identical code...
    var w = World[ArchetypeBackend[Position, Velocity]]()

All methods forward to the backend, so swapping `B` changes the storage strategy
without touching any logic. Queries return the matching entities; iterate them
and read/write components with `get`/`set`.

Architecture audit F14 (docs/audits/2026-09-27-architecture.md): every backend's
`get`/`set`/`has`/`remove` indexes storage by `Entity.id` alone and never checks
`Entity.gen`, so a stale handle (an old copy of an `Entity` whose id has since
been despawned and recycled) silently aliases whatever now occupies that id --
contradicting entity.mojo's own contract that "a stale copy can be detected as
dead". `ecs.pool` makes stale handles routine (an entity cycles between
acquired and pool-released many times over its life), so the four accessors
below now `debug_assert(is_alive(e))` before forwarding: a stale handle
terminates loudly under `-D ASSERT=all` (`pixi run test`) instead of silently
reading/writing the wrong entity's data, at zero cost in a release build.
`try_get` is the raising counterpart for a call site where a stale handle is
caller input to validate (ARCHITECTURE.md §2's "invalid input" row) rather than
an engine-internal invariant to assert.
"""

from std.collections import Dict
from .storage import StorageBackend, Filter
from .entity import Entity
from .component import ComponentType


struct World[B: StorageBackend](Movable, Deinitable):
    var backend: Self.B
    # ROADMAP 17.77 change detection (off until `track_changes`): the world
    # tick, and per component ID the tick at which each entity id last had
    # that component set / added (-1 = never since its spawn).
    var tracking: Bool
    var tick: Int
    var set_tick: List[List[Int]]
    var add_tick: List[List[Int]]
    # Per component ID, every `set` in order (entity, tick) for the last
    # `window` ticks, so `changed` / `added` cost O(writes), not O(matches).
    var log_e: List[List[Entity]]
    var log_t: List[List[Int]]
    var window: Int
    # ROADMAP 17.77 resources: one reserved entity holds them as components.
    var res: Entity
    var has_res: Bool

    def __init__(out self):
        self.backend = Self.B()
        self.tracking = False
        self.tick = 0
        self.set_tick = List[List[Int]]()
        self.add_tick = List[List[Int]]()
        self.log_e = List[List[Entity]]()
        self.log_t = List[List[Int]]()
        self.window = 8
        self.res = Entity(-1, -1)
        self.has_res = False

    # --- lifecycle ---
    def spawn(mut self) -> Entity:
        return self.backend.spawn()

    def despawn(mut self, e: Entity):
        if self.tracking and self.backend.is_alive(e):
            # a recycled id must not inherit its previous occupant's ticks
            for c in range(len(self.set_tick)):
                if e.id < len(self.set_tick[c]):
                    self.set_tick[c][e.id] = -1
                    self.add_tick[c][e.id] = -1
        self.backend.despawn(e)

    def respawn(mut self, e: Entity) -> Bool:
        """Bring a despawned entity back with the same id and generation (undo of a delete). Only while its id has
        not been reused by a later spawn; its components are not restored. False when it cannot be brought back."""
        return self.backend.respawn(e)

    def is_alive(self, e: Entity) -> Bool:
        return self.backend.is_alive(e)

    def entity_count(self) -> Int:
        return self.backend.entity_count()

    # --- components ---
    def set[C: ComponentType](mut self, e: Entity, var value: C):
        debug_assert(self.backend.is_alive(e), "World.set: stale or dead entity handle")
        if self.tracking:
            self._stamp(C.ID, e, not self.backend.has[C](e))
        self.backend.set[C](e, value^)

    # --- change detection (ROADMAP 17.77) ---
    def track_changes(mut self, window: Int = 8):
        """Start recording `set` / add ticks. Writes made through
        `for_each2` (in place, no `set`) are not seen; call `mark_changed`.
        `changed` / `added` for a `since` within the last `window` ticks
        read the write log (O(writes)); older ones scan every match."""
        self.tracking = True
        self.window = max(window, 1)
        if self.tick == 0:
            self.tick = 1

    def advance_tick(mut self) -> Int:
        """Start a new frame; returns the new tick. `changed[C](since)`
        with `since` = a tick returned earlier reports writes from then on.
        Log entries older than the window are dropped here."""
        self.tick += 1
        var keep = self.tick - self.window
        for c in range(len(self.log_t)):
            var n = len(self.log_t[c])
            if n > 0 and self.log_t[c][0] < keep:
                var k = 0
                while k < n and self.log_t[c][k] < keep:
                    k += 1
                var ne = List[Entity](capacity=n - k)
                var nt = List[Int](capacity=n - k)
                for q in range(k, n):
                    ne.append(self.log_e[c][q])
                    nt.append(self.log_t[c][q])
                self.log_e[c] = ne^
                self.log_t[c] = nt^
        return self.tick

    def _stamp(mut self, cid: Int, e: Entity, added: Bool):
        var id = e.id
        while len(self.set_tick) <= cid:
            self.set_tick.append(List[Int]())
            self.add_tick.append(List[Int]())
            self.log_e.append(List[Entity]())
            self.log_t.append(List[Int]())
        while len(self.set_tick[cid]) <= id:
            self.set_tick[cid].append(-1)
            self.add_tick[cid].append(-1)
        self.set_tick[cid][id] = self.tick
        if added:
            self.add_tick[cid][id] = self.tick
        self.log_e[cid].append(e)
        self.log_t[cid].append(self.tick)

    def mark_changed[C: ComponentType](mut self, e: Entity):
        if self.tracking:
            self._stamp(C.ID, e, False)

    def _since(self, table: List[List[Int]], cid: Int, id: Int, since: Int) -> Bool:
        return cid < len(table) and id < len(table[cid]) and table[cid][id] >= since

    def _from_log[C: ComponentType](self, since: Int, adds: Bool) -> List[Entity]:
        var out = List[Entity]()
        var cid = C.ID
        if cid >= len(self.log_t):
            return out^
        var seen = Dict[Int, Bool]()
        var n = len(self.log_t[cid])
        var k = n
        while k > 0 and self.log_t[cid][k - 1] >= since:
            k -= 1
        for q in range(k, n):
            var e = self.log_e[cid][q]
            if e.id in seen or not self.backend.is_alive(e) or not self.backend.has[C](e):
                continue
            var hit = self._since(self.add_tick, cid, e.id, since) if adds else self._since(self.set_tick, cid, e.id, since)
            if hit:
                seen[e.id] = True
                out.append(e)
        return out^

    def changed[C: ComponentType](self, since: Int) -> List[Entity]:
        """Entities holding C whose C was set at tick >= `since`."""
        if since > self.tick - self.window:
            return self._from_log[C](since, False)
        var out = List[Entity]()
        var all = self.backend.matching1[C]()
        for k in range(len(all)):
            if self._since(self.set_tick, C.ID, all[k].id, since):
                out.append(all[k])
        return out^

    def added[C: ComponentType](self, since: Int) -> List[Entity]:
        """Entities that gained C at tick >= `since` (and still hold it)."""
        if since > self.tick - self.window:
            return self._from_log[C](since, True)
        var out = List[Entity]()
        var all = self.backend.matching1[C]()
        for k in range(len(all)):
            if self._since(self.add_tick, C.ID, all[k].id, since):
                out.append(all[k])
        return out^

    # --- resources (ROADMAP 17.77) ---
    def set_resource[C: ComponentType](mut self, var value: C):
        """Store the world's single value of type C (a component on one
        reserved entity, spawned on first use: it counts in `entity_count`
        and appears in queries over C)."""
        if not self.has_res:
            self.res = self.backend.spawn()
            self.has_res = True
        var r = self.res
        self.set[C](r, value^)

    def has_resource[C: ComponentType](self) -> Bool:
        return self.has_res and self.backend.has[C](self.res)

    def resource[C: ComponentType](self) raises -> C:
        if not self.has_resource[C]():
            raise Error("World.resource: no resource of this type")
        return self.backend.get[C](self.res)

    def has[C: ComponentType](self, e: Entity) -> Bool:
        debug_assert(self.backend.is_alive(e), "World.has: stale or dead entity handle")
        return self.backend.has[C](e)

    def get[C: ComponentType](self, e: Entity) -> C:
        debug_assert(self.backend.is_alive(e), "World.get: stale or dead entity handle")
        return self.backend.get[C](e)

    def remove[C: ComponentType](mut self, e: Entity):
        debug_assert(self.backend.is_alive(e), "World.remove: stale or dead entity handle")
        if self.tracking and C.ID < len(self.add_tick) and e.id < len(self.add_tick[C.ID]):
            self.add_tick[C.ID][e.id] = -1
            self.set_tick[C.ID][e.id] = -1
        self.backend.remove[C](e)

    def try_get[C: ComponentType](self, e: Entity) raises -> C:
        """Raising counterpart to `get` (F14): a stale/dead handle at a public
        API boundary is caller input, not an engine invariant, so this raises
        instead of terminating -- for callers (like `ecs.pool`) that want to
        recover rather than crash."""
        if not self.backend.is_alive(e):
            raise Error("World.try_get: stale or dead entity handle")
        return self.backend.get[C](e)

    # --- spawn helpers ---
    def spawn1[A: ComponentType](mut self, a: A) -> Entity:
        var e = self.spawn()
        self.set[A](e, a)
        return e

    def spawn2[A: ComponentType, B2: ComponentType](mut self, a: A, b: B2) -> Entity:
        var e = self.spawn()
        self.set[A](e, a)
        self.set[B2](e, b)
        return e

    # --- queries ---
    def select(self, f: Filter) -> List[Entity]:
        """ROADMAP 17.77: with / without / any filter, native per backend."""
        return self.backend.select(f)

    def query1[A: ComponentType](self) -> List[Entity]:
        return self.backend.matching1[A]()

    def query2[A: ComponentType, B2: ComponentType](self) -> List[Entity]:
        return self.backend.matching2[A, B2]()

    def query3[
        A: ComponentType, B2: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        return self.backend.matching3[A, B2, C]()

    # --- zero-allocation iteration ---
    def for_each2[
        A: ComponentType,
        B2: ComponentType,
        F: def (mut A, B2) -> None,
    ](mut self, func: F):
        """Run `func(mut a, b)` over every entity with both A and B — no per-frame
        `List[Entity]`, no per-access lookup. The fast replacement for the
        `query2` + `get`/`set` handle loop; works on every backend."""
        self.backend.for_each2[A, B2](func)

    def storage_bytes(self) -> Int:
        """ROADMAP 17.79: bytes the storage backend holds in use (lengths x
        element sizes, a lower bound; the change-tracking journal is not
        counted)."""
        return self.backend.storage_bytes()

    def for_each3[
        A: ComponentType,
        B2: ComponentType,
        C2: ComponentType,
        F: def (mut A, B2, C2) -> None,
    ](mut self, func: F):
        """ROADMAP 17.77: `for_each2` over three components -- `func(mut a,
        b, c)` for every entity with A, B and C, no per-frame list; every
        backend (archetype column-direct, bitset word AND, sparse / reactive
        driven by the smallest store, chunked page walk, naive scan)."""
        self.backend.for_each3[A, B2, C2](func)
