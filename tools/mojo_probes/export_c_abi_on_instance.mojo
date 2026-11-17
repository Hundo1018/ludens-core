# expect: ok
# mode: shlib
from std.memory import UnsafePointer

trait Backend(Movable, Defaultable, Deinitable):
    def size(self) -> Int: ...

struct Small(Backend):
    var n: Int
    def __init__(out self):
        self.n = 3
    def size(self) -> Int:
        return self.n

struct World[B: Backend](Movable):
    var b: Self.B
    def __init__(out self):
        self.b = Self.B()

comptime CWorld = World[Small]

@export
def ld_probe_size(n: Int) abi("C") -> Int:
    var w = CWorld()
    return w.b.size() + n
