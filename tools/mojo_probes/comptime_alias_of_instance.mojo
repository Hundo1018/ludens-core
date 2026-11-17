# expect: ok 3
# mode: run
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

def make() -> CWorld:
    return CWorld()

def main():
    print("ok", make().b.size())
