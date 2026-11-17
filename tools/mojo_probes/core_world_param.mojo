# expect: compiled
# mode: core-shlib
# The host world over the real ecs.StorageBackend: a default backend, two instances (sparse set, archetype), one alias
# exported through the C ABI, built as a shared library.
from ecs.component import ComponentType
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.world import World


@fieldwise_init
struct Hp(ComponentType):
    comptime ID = 1
    var v: Int


@fieldwise_init
struct Tag(ComponentType):
    comptime ID = 2
    var v: Int


struct HostWorld[B: StorageBackend = SparseSetBackend[Hp, Tag]](Movable):
    var reg: World[Self.B]
    var ticks: Int

    def __init__(out self):
        self.reg = World[Self.B]()
        self.ticks = 0

    def spawn_hp(mut self, hp: Int) -> Int:
        var e = self.reg.spawn()
        self.reg.set[Hp](e, Hp(hp))
        return self.reg.entity_count()


comptime CWorld = HostWorld[]
comptime ArchWorld = HostWorld[ArchetypeBackend[Hp, Tag]]


@export
def ld_probe_spawn(hp: Int) abi("C") -> Int:
    var w = CWorld()
    var a = ArchWorld()
    return w.spawn_hp(hp) + a.spawn_hp(hp)
