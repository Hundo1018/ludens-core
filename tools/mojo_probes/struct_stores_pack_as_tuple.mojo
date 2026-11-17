# expect: ok 10 20
# mode: run
trait Pass(Movable, Copyable, Deinitable):
    def record(self) -> Int: ...

@fieldwise_init
struct A(Pass):
    var v: Int
    def record(self) -> Int:
        return self.v

@fieldwise_init
struct B(Pass):
    var v: Int
    def record(self) -> Int:
        return self.v * 2

struct Pipeline[*Ps: Pass](Movable):
    var passes: Tuple[*Self.Ps]
    def __init__(out self, var passes: Tuple[*Self.Ps]):
        self.passes = passes^

    def record_all(self):
        comptime for i in range(len(Self.Ps)):
            print(self.passes[i].record(), end=" ")

def main():
    var p = Pipeline[A, B]((A(10), B(10)))
    print("ok", end=" ")
    p.record_all()
    print()
