# expect: ok 3 5
# mode: run
# A method that exists only for some values of a struct parameter (where clause on a comptime Int).
struct Grid[D: Int]:
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def cells(self) -> Int:
        return self.n

    def depth(self) -> Int where Self.D == 3:
        return self.n + 2


def main():
    print("ok", Grid[2](3).cells(), Grid[3](3).depth())
