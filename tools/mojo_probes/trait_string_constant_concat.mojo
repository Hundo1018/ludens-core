# expect: ok fn shade() -> f32 { return 1.0; }|fn light() -> f32 { return 2.0; }
# mode: run
trait Hook:
    comptime WGSL: StaticString

struct Shade(Hook):
    comptime WGSL: StaticString = "fn shade() -> f32 { return 1.0; }"

struct Light(Hook):
    comptime WGSL: StaticString = "fn light() -> f32 { return 2.0; }"

def assemble[*Hs: Hook]() -> String:
    var s = String()
    comptime for i in range(len(Hs)):
        if i > 0:
            s += "|"
        s += Hs[i].WGSL
    return s^

def main():
    print("ok", assemble[Shade, Light]())
