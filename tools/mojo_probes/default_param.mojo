# expect: ok 3
# mode: run
trait Backend(Movable, Defaultable, Deinitable):
    def size(self) -> Int: ...

@fieldwise_init
struct Small(Backend):
    var n: Int
    def __init__(out self):
        self.n = 3
    def size(self) -> Int:
        return self.n

struct World[B: Backend = Small](Movable):
    var b: Self.B
    def __init__(out self):
        self.b = Self.B()

def main():
    var w = World()          # B defaulted
    print("ok", w.b.size())
