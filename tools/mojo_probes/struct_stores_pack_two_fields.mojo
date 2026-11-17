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

@fieldwise_init
struct End(Pass):
    def record(self) -> Int:
        return 0

@fieldwise_init
struct Chain[P: Pass, R: Pass](Pass):
    var head: Self.P
    var rest: Self.R
    def record(self) -> Int:
        print(self.head.record(), end=" ")
        _ = self.rest.record()
        return 0

def main():
    var p = Chain(A(10), Chain(B(10), End()))
    print("ok", end=" ")
    _ = p.record()
    print()
