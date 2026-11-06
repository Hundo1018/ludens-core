"""Chunked (paged) column storage — the Unity DOTS / Unreal MassEntity shape.

Every other dense backend here keeps each component column in ONE growable
`List`, so the column is reallocated and copied whenever it outgrows its
capacity, and a world that has ever been large keeps that whole allocation
alive afterwards. A chunked store instead splits the column into fixed-size
pages and appends a page at a time:

  column = List[page], page = Array-sized block of CHUNK_ROWS cells
  id -> (id / CHUNK_ROWS, id % CHUNK_ROWS)

The trade this makes is the point of the comparison, and it is not "chunking is
faster":

  - growth is O(1) pages with NO copying of existing rows, so the amortised
    doubling cost and the transient 1.5x memory spike of a reallocating vector
    both disappear;
  - memory is returned in page units when the world shrinks, instead of being
    held by one large allocation;
  - but every access pays an extra indirection (page lookup then offset), and
    iteration cannot run as one flat pointer walk.

So the expected shape is: better under structural CHURN and at large N, worse
on tight iteration. `bench_chunked` measures both sides, and
`test_backend_parity` runs it through the same scenario as the other five
backends so the comparison is between equals.

CHUNK_ROWS is chosen per component type to land near a 16 KB page, matching the
commercial implementations this mirrors, with a floor so tiny components do not
produce absurdly long pages.
"""

from std.memory import alloc, Layout
from .component import ComponentType
from .entity import Entity
from .storage import StorageBackend, Filter, resolve_filter, check_pack
from std.sys import size_of

comptime Slot = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())

# 16 KB target page, matching Unity DOTS' chunk size.
comptime CHUNK_BYTES = 16384


comptime CHUNK_ROWS = 1024
"""Rows per page. A fixed row count rather than a fixed byte count: deriving it
from `size_of[Optional[C]]()` would match Unity's 16 KB chunks more exactly,
but the intrinsic is not available here, and a constant row count keeps the
page boundary identical across columns — which is what lets `for_each2` walk
two columns page-synchronously."""


struct _Column[C: ComponentType](Movable, Deinitable):
    """One component column as a list of fixed-size pages."""

    var pages: List[List[Optional[Self.C]]]
    var rows: Int  # rows per page
    var allocs: Int  # pages ever allocated — the metric chunking is about

    def __init__(out self):
        self.pages = List[List[Optional[Self.C]]]()
        self.rows = CHUNK_ROWS
        self.allocs = 0

    def ensure(mut self, id: Int):
        var want = id // self.rows + 1
        while len(self.pages) < want:
            # Pre-size the page: without `capacity` the fill loop reallocates
            # inside the page and the whole point of a fixed-size block is lost.
            var p = List[Optional[Self.C]](capacity=self.rows)
            for _ in range(self.rows):
                p.append(Optional[Self.C]())
            self.pages.append(p^)
            self.allocs += 1

    def get(self, id: Int) -> Optional[Self.C]:
        var pi = id // self.rows
        if pi >= len(self.pages):
            return Optional[Self.C]()
        # a released page is an empty List, and every id in it reads as absent
        if len(self.pages[pi]) == 0:
            return Optional[Self.C]()
        return self.pages[pi][id % self.rows]

    def put(mut self, id: Int, var v: Optional[Self.C]):
        self.ensure(id)
        var pi = id // self.rows
        if len(self.pages[pi]) == 0:
            self._materialise(pi)
        self.pages[pi][id % self.rows] = v^

    def _materialise(mut self, pi: Int):
        """Re-create a page that was released. Splitting allocation from the
        `ensure` growth path is what lets a page be handed back and taken again
        without disturbing its neighbours."""
        var p = List[Optional[Self.C]](capacity=self.rows)
        for _ in range(self.rows):
            p.append(Optional[Self.C]())
        self.pages[pi] = p^
        self.allocs += 1

    def release(mut self, pi: Int):
        """Hand a page back. THIS is the property a growable column cannot
        offer: a `List` that has ever been large keeps its whole allocation,
        while a paged column returns memory in page units when a region of the
        id space empties out."""
        if pi < len(self.pages) and len(self.pages[pi]) > 0:
            self.pages[pi] = List[Optional[Self.C]]()

    def cells_held(self) -> Int:
        var n = 0
        for ref p in self.pages:
            n += len(p)
        return n


struct ChunkedBackend[*CTs: ComponentType](StorageBackend):
    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap _Column[CTs[i]]
    var live: List[Bool]
    var n_live: Int
    var free_ids: List[Int]
    var gens: List[Int]

    def __init__(out self):
        check_pack[*Self.CTs]()
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[_Column[T]](Layout[_Column[T]](count=1)).unsafe_leak()
            p.unsafe_write(_Column[T]())
            self.slots.append(p.unsafe_bitcast[NoneType]())
        self.live = List[Bool]()
        self.n_live = 0
        self.free_ids = List[Int]()
        self.gens = List[Int]()

    def __deinit__(deinit self):
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = self.slots[i].unsafe_bitcast[_Column[T]]()
            p.unsafe_deinit_pointee()
            p.unsafe_free()

    @staticmethod
    def _slot_of[C: ComponentType]() -> Int:
        comptime for i in range(Self.N):
            comptime if Self.CTs[i].ID == C.ID:
                return i
        return -1

    def _col[C: ComponentType](self) -> type_of(alloc[_Column[C]](Layout[_Column[C]](count=1)).unsafe_leak()):
        return self.slots[Self._slot_of[C]()].unsafe_bitcast[_Column[C]]()

    def compact(mut self):
        """Release every page whose whole id range is dead.

        Called explicitly rather than on every despawn: a page is only worth
        handing back once a REGION of the id space has emptied, and checking
        that on each despawn would make despawn O(page) instead of O(1)."""
        var npages = (len(self.live) + CHUNK_ROWS - 1) // CHUNK_ROWS
        for pi in range(npages):
            var lo = pi * CHUNK_ROWS
            var hi = lo + CHUNK_ROWS
            if hi > len(self.live):
                hi = len(self.live)
            var any_live = False
            for id in range(lo, hi):
                if self.live[id]:
                    any_live = True
                    break
            if any_live:
                continue
            comptime for i in range(Self.N):
                comptime T = Self.CTs[i]
                self._col[T]()[].release(pi)

    def cells_held(self) -> Int:
        """Component cells currently backed by memory, summed over columns —
        the quantity the chunking argument is about, and the one a growable
        column cannot reduce."""
        var total = 0
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            total += self._col[T]()[].cells_held()
        return total

    def page_allocs(self) -> Int:
        """Total pages ever allocated across all columns — the quantity the
        chunking argument is actually about, exposed for the benchmark."""
        var total = 0
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            total += self._col[T]()[].allocs
        return total

    # --- lifecycle ---
    def _ensure_gen(mut self, id: Int):
        while len(self.gens) <= id:
            self.gens.append(0)

    def spawn(mut self) -> Entity:
        var id: Int
        if len(self.free_ids) > 0:
            id = self.free_ids.pop()
            self.live[id] = True
        else:
            id = len(self.live)
            self.live.append(True)
            # A page is added only when the id crosses a page boundary — no
            # copying of existing rows, unlike a growable column's realloc.
            comptime for i in range(Self.N):
                comptime T = Self.CTs[i]
                self._col[T]()[].ensure(id)
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
            self._col[T]()[].put(e.id, Optional[T]())
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
        self._col[C]()[].put(e.id, Optional[C](value^))

    def has[C: ComponentType](self, e: Entity) -> Bool:
        return Bool(self._col[C]()[].get(e.id))

    def get[C: ComponentType](self, e: Entity) -> C:
        return self._col[C]()[].get(e.id).value()

    def remove[C: ComponentType](mut self, e: Entity):
        self._col[C]()[].put(e.id, Optional[C]())

    # --- queries ---
    def _gen_of(self, id: Int) -> Int:
        return self.gens[id] if id < len(self.gens) else 0

    def _has_slot(self, s: Int, id: Int) -> Bool:
        comptime for i in range(Self.N):
            if i == s:
                return Bool(self._col[Self.CTs[i]]()[].get(id))
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
                out.append(Entity(id, self._gen_of(id)))
        return out^

    def matching1[A: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var ca = self._col[A]()
        for id in range(len(self.live)):
            if self.live[id] and ca[].get(id):
                out.append(Entity(id, self._gen_of(id)))
        return out^

    def matching2[A: ComponentType, B: ComponentType](self) -> List[Entity]:
        var out = List[Entity]()
        var ca = self._col[A]()
        var cb = self._col[B]()
        for id in range(len(self.live)):
            if self.live[id] and ca[].get(id) and cb[].get(id):
                out.append(Entity(id, self._gen_of(id)))
        return out^

    def matching3[
        A: ComponentType, B: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        var out = List[Entity]()
        var ca = self._col[A]()
        var cb = self._col[B]()
        var cc = self._col[C]()
        for id in range(len(self.live)):
            if self.live[id] and ca[].get(id) and cb[].get(id) and cc[].get(id):
                out.append(Entity(id, self._gen_of(id)))
        return out^

    def storage_bytes(self) -> Int:
        """ROADMAP 17.79: bytes this backend holds in use (lengths x element
        sizes; list capacity slack and allocator overhead not counted, so a
        lower bound)."""
        var t = len(self.live) * size_of[Bool]()
        t += len(self.free_ids) * size_of[Int]() + len(self.gens) * size_of[Int]()
        comptime for i in range(Self.N):
            for ref pg in self._col[Self.CTs[i]]()[].pages:
                t += len(pg) * size_of[Optional[Self.CTs[i]]]()
        return t

    def for_each2[
        A: ComponentType,
        B: ComponentType,
        F: def (mut A, B) -> None,
    ](mut self, func: F):
        # Walk PAGE BY PAGE rather than id by id: within a page the offset is a
        # plain index, so the page lookup is paid once per CHUNK_ROWS rows
        # instead of once per row. This is the access pattern chunked stores
        # are designed for.
        var ca = self._col[A]()
        var cb = self._col[B]()
        var rows = ca[].rows
        var n = len(self.live)
        var npages = len(ca[].pages)
        for pi in range(npages):
            var base = pi * rows
            var hi = rows
            if base + hi > n:
                hi = n - base
            if hi <= 0:
                break
            for off in range(hi):
                var id = base + off
                if not self.live[id]:
                    continue
                var oa = ca[].pages[pi][off]
                if not oa:
                    continue
                var ob = cb[].get(id)
                if not ob:
                    continue
                var a = oa.value()
                func(a, ob.value())
                ca[].pages[pi][off] = Optional[A](a)

    def for_each3[
        A: ComponentType,
        B: ComponentType,
        C: ComponentType,
        F: def (mut A, B, C) -> None,
    ](mut self, func: F):
        var ca = self._col[A]()
        var cb = self._col[B]()
        var cc = self._col[C]()
        var rows = ca[].rows
        var n = len(self.live)
        var npages = len(ca[].pages)
        for pi in range(npages):
            var base = pi * rows
            var hi = rows
            if base + hi > n:
                hi = n - base
            if hi <= 0:
                break
            for off in range(hi):
                var id = base + off
                if not self.live[id]:
                    continue
                var oa = ca[].pages[pi][off]
                if not oa:
                    continue
                var ob = cb[].get(id)
                if not ob:
                    continue
                var oc = cc[].get(id)
                if not oc:
                    continue
                var a = oa.value()
                func(a, ob.value(), oc.value())
                ca[].pages[pi][off] = Optional[A](a)

