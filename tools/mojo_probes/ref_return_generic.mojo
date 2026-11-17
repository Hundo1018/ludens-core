# expect: ok 5 6
# mode: run
# A method returning a reference to a list element (origin spelled as the element, `ref [self.xs[i]]`), reached through
# a generic owner and written through. A trait cannot declare such a method: see trait_ref_return.
trait Store(Movable, Defaultable, Deinitable):
    def bump(mut self, i: Int): ...


struct Vec(Store):
    var xs: List[Int]

    def __init__(out self):
        self.xs = [5, 9]

    def slot(mut self, i: Int) -> ref [self.xs[i]] Int:
        return self.xs[i]

    def bump(mut self, i: Int):
        self.slot(i) += 1


struct World[B: Store](Movable):
    var b: Self.B

    def __init__(out self):
        self.b = Self.B()

    def store(mut self) -> ref [self.b] Self.B:
        return self.b


def main():
    var w = World[Vec]()
    var before = w.store().slot(0)
    w.store().bump(0)
    print("ok", before, w.b.xs[0])
