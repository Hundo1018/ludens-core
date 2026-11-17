# expect: ok 7
# mode: run
trait Backend(Movable, Defaultable, Deinitable):
    def size(self) -> Int: ...

struct Small(Backend):
    var n: Int
    def __init__(out self):
        self.n = 7
    def size(self) -> Int:
        return self.n

struct World[B: Backend](Movable):
    var b: Self.B
    def __init__(out self):
        self.b = Self.B()

def count[B: Backend](w: World[B]) -> Int:
    return w.b.size()

def main():
    var w = World[Small]()
    print("ok", count(w))
