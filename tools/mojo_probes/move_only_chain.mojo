# expect: ok 11 21
# mode: run
# The fallback if a Tuple field needs Copyable: passes nested as Chain[head, rest], move-only.
trait Pass(Movable, Deinitable):
    def prepare(mut self): ...
    def record(self): ...


struct A(Pass):
    var v: Int
    var owned: List[Int]

    def __init__(out self, v: Int):
        self.v = v
        self.owned = List[Int]()

    def prepare(mut self):
        self.v += 1

    def record(self):
        print(self.v, end=" ")


struct B(Pass):
    var v: Int
    var owned: List[Int]

    def __init__(out self, v: Int):
        self.v = v
        self.owned = List[Int]()

    def prepare(mut self):
        self.v += 1

    def record(self):
        print(self.v + 10, end=" ")


struct End(Pass):
    def __init__(out self):
        pass

    def prepare(mut self):
        pass

    def record(self):
        pass


struct Chain[P: Pass, R: Pass](Pass):
    var head: Self.P
    var rest: Self.R

    def __init__(out self, var head: Self.P, var rest: Self.R):
        self.head = head^
        self.rest = rest^

    def prepare(mut self):
        self.head.prepare()
        self.rest.prepare()

    def record(self):
        self.head.record()
        self.rest.record()


def main():
    var p = Chain(A(10), Chain(B(10), End()))
    p.prepare()
    print("ok", end=" ")
    p.record()
    print()
