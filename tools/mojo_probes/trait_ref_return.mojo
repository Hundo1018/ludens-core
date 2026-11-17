# expect: REJECTED
# mode: must-fail
# Mojo 1.2.0 refuses a `ref [self]` result in a trait method ("might expand to a RegisterPassable type"), so a
# StorageBackend.get_ref cannot be part of the trait.
trait Store:
    def slot(mut self, i: Int) -> ref [self] Int: ...


struct Vec(Store):
    var xs: List[Int]

    def __init__(out self):
        self.xs = [5, 9]

    def slot(mut self, i: Int) -> ref [self] Int:
        return self.xs[i]


def main():
    var v = Vec()
    print(v.slot(0))
