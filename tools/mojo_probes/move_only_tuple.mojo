# expect: ok 11 21
# mode: run
# Real passes own GPU handles: Movable but not Copyable. A pack of them stored as one Tuple field, each mutated.
trait Pass(Movable, Deinitable):
    def prepare(mut self): ...
    def record(self) -> Int: ...


struct A(Pass):
    var v: Int
    var owned: List[Int]

    def __init__(out self, v: Int):
        self.v = v
        self.owned = List[Int]()

    def prepare(mut self):
        self.v += 1
        self.owned.append(self.v)

    def record(self) -> Int:
        return self.v


struct B(Pass):
    var v: Int
    var owned: List[Int]

    def __init__(out self, v: Int):
        self.v = v
        self.owned = List[Int]()

    def prepare(mut self):
        self.v += 1

    def record(self) -> Int:
        return self.v + 10


struct Pipeline[*Ps: Pass](Movable):
    var passes: Tuple[*Self.Ps]

    def __init__(out self, var passes: Tuple[*Self.Ps]):
        self.passes = passes^

    def frame(mut self):
        comptime for i in range(len(Self.Ps)):
            self.passes[i].prepare()
        comptime for i in range(len(Self.Ps)):
            print(self.passes[i].record(), end=" ")


def main():
    var p = Pipeline[A, B]((A(10), B(10)))
    print("ok", end=" ")
    p.frame()
    print()
