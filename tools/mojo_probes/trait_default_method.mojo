# expect: ok 0 7
# mode: run
# A trait method with a body is the default; an implementation may omit it or override it.
trait Panel:
    def dock(self) -> Int:
        return 0


struct Plain(Panel):
    def __init__(out self):
        pass


struct Right(Panel):
    def __init__(out self):
        pass

    def dock(self) -> Int:
        return 7


def main():
    print("ok", Plain().dock(), Right().dock())
