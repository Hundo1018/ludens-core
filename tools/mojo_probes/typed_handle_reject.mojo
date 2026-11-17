# expect: REJECTED
# mode: must-fail
# Passing a BodyId where a JointId is wanted must not compile.
@fieldwise_init
struct BodyId(Copyable, ImplicitlyCopyable, Movable):
    var raw: Int64


@fieldwise_init
struct JointId(Copyable, ImplicitlyCopyable, Movable):
    var raw: Int64


def remove_joint(j: JointId) -> Int64:
    return j.raw


def main():
    print(remove_joint(BodyId(3)))
