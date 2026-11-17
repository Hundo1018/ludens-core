# expect: ok fn base() {}
# mode: run
struct Material[SRC: StaticString]:
    @staticmethod
    def source() -> String:
        return String(Self.SRC)

def main():
    print("ok", Material["fn base() {}"].source())
