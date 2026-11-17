# expect: ok 3
# mode: run
# A resource that must be released explicitly, owned by a pass that is itself linear; a pack of such passes closed in
# a comptime for.
struct Res(Movable, not Deinitable else "call release()"):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def release(deinit self) -> Int:
        return self.id


trait Pass(Movable):
    def close(deinit self) -> Int: ...


struct A(Pass, not Deinitable else "call close()"):
    var r: Res

    def __init__(out self, id: Int):
        self.r = Res(id)

    def close(deinit self) -> Int:
        return self.r^.release()


def close2[P: Pass, Q: Pass](var p: P, var q: Q) -> Int:
    return p^.close() + q^.close()


def main():
    print("ok", close2(A(1), A(2)))
