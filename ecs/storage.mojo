"""The swappable storage interface.

`World[B: StorageBackend]` is written once against this trait; choosing
`SparseSetBackend[...]` vs `ArchetypeBackend[...]` swaps the storage strategy with
zero changes to game code. The trait deliberately uses *value*-returning
accessors (`get` returns a copy, `set` takes a value): backends keep their data
behind type-erased pointers, and leaking such a pointer across statements would
let the backend be destroyed early (see the heterogeneous-storage notes).

Queries are exposed as fixed-arity `matching1/2/3` returning the matching
entities; the caller iterates them and reads/writes components via `get`/`set`.
"""

from .entity import Entity
from .component import ComponentType


@fieldwise_init
struct Record(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Where an entity lives. The archetype backend uses both fields; the
    sparse-set backend only needs liveness so it stores the generation in `row`."""

    var archetype: Int
    var row: Int


struct Filter(Copyable, Movable):
    """A query by component ID (ROADMAP 17.77).

    Matches entities that have every `with_` type, none of the `without`
    types, and -- when any are given -- at least one of the `any` types.
    Built by chaining:

        Filter().with_[Pos]().with_[Vel]().without[Disabled]()

    A `with_` type that the world's component pack lacks matches nothing; a
    `without` / `any` type it lacks is ignored. Each backend evaluates it
    natively (`StorageBackend.select`)."""

    var with_ids: List[Int]
    var without_ids: List[Int]
    var any_ids: List[Int]

    def __init__(out self):
        self.with_ids = List[Int]()
        self.without_ids = List[Int]()
        self.any_ids = List[Int]()

    def with_[C: ComponentType](var self) -> Self:
        self.with_ids.append(C.ID)
        return self^

    def without[C: ComponentType](var self) -> Self:
        self.without_ids.append(C.ID)
        return self^

    def any[C: ComponentType](var self) -> Self:
        self.any_ids.append(C.ID)
        return self^


@fieldwise_init
struct SlotMask(Copyable, ImplicitlyCopyable, Movable):
    """A `Filter` resolved against one component pack: slot bitmasks.
    `impossible` is set when a `with_` type is not in the pack."""

    var with_bits: Int
    var without_bits: Int
    var any_bits: Int
    var impossible: Bool

    def accepts(self, mask: Int) -> Bool:
        """Does a presence mask (bit i = has slot i) pass the filter?"""
        if self.impossible or (mask & self.with_bits) != self.with_bits:
            return False
        if (mask & self.without_bits) != 0:
            return False
        return self.any_bits == 0 or (mask & self.any_bits) != 0


def resolve_filter[*CTs: ComponentType](f: Filter) -> SlotMask:
    """Map `f`'s component IDs to slot bits of the pack `CTs`."""
    var m = SlotMask(0, 0, 0, False)
    for k in range(len(f.with_ids)):
        var s = _slot_of_id[*CTs](f.with_ids[k])
        if s < 0:
            m.impossible = True
        else:
            m.with_bits |= 1 << s
    for k in range(len(f.without_ids)):
        var s = _slot_of_id[*CTs](f.without_ids[k])
        if s >= 0:
            m.without_bits |= 1 << s
    for k in range(len(f.any_ids)):
        var s = _slot_of_id[*CTs](f.any_ids[k])
        if s >= 0:
            m.any_bits |= 1 << s
    return m


def _slot_of_id[*CTs: ComponentType](id: Int) -> Int:
    comptime for i in range(len(CTs)):
        if CTs[i].ID == id:
            return i
    return -1


def check_pack[*CTs: ComponentType]():
    """Compile-time guard every backend runs (17.77): component IDs in a pack
    must be distinct, and a pack holds at most 63 types (slot bitmasks are
    `Int`)."""
    comptime assert len(CTs) <= 63, "ecs: a component pack holds at most 63 types"
    comptime for i in range(len(CTs)):
        comptime for j in range(i + 1, len(CTs)):
            comptime assert CTs[i].ID != CTs[j].ID, "ecs: duplicate component ID in a pack"


trait StorageBackend(Defaultable, Movable, Deinitable):
    # lifecycle
    def spawn(mut self) -> Entity: ...
    def despawn(mut self, e: Entity): ...
    def respawn(mut self, e: Entity) -> Bool: ...
    def is_alive(self, e: Entity) -> Bool: ...
    def entity_count(self) -> Int: ...

    # typed component access (generic methods — the impl maps C.ID to a slot)
    def set[C: ComponentType](mut self, e: Entity, var value: C): ...
    def has[C: ComponentType](self, e: Entity) -> Bool: ...
    def get[C: ComponentType](self, e: Entity) -> C: ...
    def remove[C: ComponentType](mut self, e: Entity): ...

    # queries: entities possessing all of the given components
    def matching1[A: ComponentType](self) -> List[Entity]: ...
    def matching2[A: ComponentType, B: ComponentType](self) -> List[Entity]: ...
    def matching3[
        A: ComponentType, B: ComponentType, C: ComponentType
    ](self) -> List[Entity]: ...

    # ROADMAP 17.77: entities passing `f` (with / without / any), evaluated
    # natively by each backend; ascending entity id is NOT promised (each
    # backend returns its own iteration order, as matching1/2/3 do).
    def select(self, f: Filter) -> List[Entity]: ...

    # ROADMAP 17.79: bytes held in use (a lower bound: no capacity slack).
    def storage_bytes(self) -> Int: ...

    # zero-allocation iteration: invoke `func(mut a, b)` for every entity that has
    # both A and B, passing mutable/read refs straight into storage (no per-frame
    # `List[Entity]`, no per-access entity-index lookup). See `World.for_each2`.
    def for_each2[
        A: ComponentType,
        B: ComponentType,
        F: def (mut A, B) -> None,
    ](mut self, func: F): ...

    # ROADMAP 17.77: the same over three components (func(mut a, b, c)).
    def for_each3[
        A: ComponentType,
        B: ComponentType,
        C: ComponentType,
        F: def (mut A, B, C) -> None,
    ](mut self, func: F): ...
