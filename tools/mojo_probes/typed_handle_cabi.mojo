# expect: compiled
# mode: shlib
# Typed ids: BodyId and JointId wrap one Int64 each; a function taking JointId rejects a BodyId at compile time, and
# the C ABI still passes plain integers.
@fieldwise_init
struct BodyId(Copyable, ImplicitlyCopyable, Movable):
    var raw: Int64


@fieldwise_init
struct JointId(Copyable, ImplicitlyCopyable, Movable):
    var raw: Int64


def remove_joint(j: JointId) -> Int64:
    return j.raw


def add_joint(a: BodyId, b: BodyId) -> JointId:
    return JointId(a.raw + b.raw)


@export
def ld_probe_joint(a: Int64, b: Int64) abi("C") -> Int64:
    var j = add_joint(BodyId(a), BodyId(b))
    return remove_joint(j)
