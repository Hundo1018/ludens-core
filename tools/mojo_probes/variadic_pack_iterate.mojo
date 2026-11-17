# expect: ok 1 2 sum 3
# mode: run
trait Pass(Movable, Defaultable, Deinitable):
    comptime ID: Int
    def record(self) -> Int: ...

struct A(Pass):
    comptime ID = 1
    def __init__(out self):
        pass
    def record(self) -> Int:
        return 1

struct B(Pass):
    comptime ID = 2
    def __init__(out self):
        pass
    def record(self) -> Int:
        return 2

def run_all[*Ps: Pass]() -> Int:
    var s = 0
    comptime for i in range(len(Ps)):
        comptime P = Ps[i]
        print(P.ID, end=" ")
        s += P().record()
    return s

def main():
    print("ok", end=" ")
    var s = run_all[A, B]()
    print("sum", s)
