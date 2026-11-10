"""A tiny test harness for ludens-core.

This nightly has no `mojo test` command and no `testing` stdlib module, so each
test file is a normal program: build a `Suite`, run checks, then call `finish()`.
`finish()` raises on any failure, giving a non-zero exit so a `&&`-chained pixi
`test` task stops at the first failing file.

Usage:
    from harness.runner import Suite

    def main() raises:
        var s = Suite("my_module")
        s.check(1 + 1 == 2, "arithmetic")
        s.eq(2 + 2, 4, "addition")
        s.finish()

Device-dependent checks (GPU parity halves that only run under
`has_accelerator()`) go after `s.begin_device()`. They count separately and
their output carries a `[device]` tag, which the golden gate drops, so the
recorded golden is the same on hosts with and without an accelerator. Print
device-only measurements as `"  [device] ..."`; mark the skipped half with
`s.skip_device(reason)`.

Randomised tests take their seed from `fuzz_seed(default)`: the default
normally, `LUDENS_SEED` when set, so `pixi run fuzz` can sweep a seed range
over the same checks and print the seed that broke one (ROADMAP 17.82).
"""

from std.os import getenv

comptime DEVICE_TAG = "[device]"


def fuzz_seed(default: UInt64) -> UInt64:
    """`default`, or the value of `LUDENS_SEED` when that is set to an
    integer. An override is printed so a failing run names its seed."""
    var v = getenv("LUDENS_SEED")
    if v == "":
        return default
    try:
        var seed = UInt64(atol(v))
        print("  [seed] LUDENS_SEED =", seed)
        return seed
    except:
        return default


struct Suite(Movable):
    var name: String
    var passed: Int
    var failed: Int
    var device_passed: Int
    var device_failed: Int
    var in_device: Bool

    def __init__(out self, name: String):
        self.name = name
        self.passed = 0
        self.failed = 0
        self.device_passed = 0
        self.device_failed = 0
        self.in_device = False

    def begin_device(mut self):
        """Every later check is device-dependent (see the module docstring)."""
        self.in_device = True

    def skip_device(self, reason: String):
        print("  " + DEVICE_TAG + " skipped:", reason)

    def _tally(mut self, cond: Bool, label: String):
        if self.in_device:
            if cond:
                self.device_passed += 1
            else:
                self.device_failed += 1
                print("  [FAIL]", DEVICE_TAG, self.name, "-", label)
        elif cond:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", self.name, "-", label)

    def check(mut self, cond: Bool, label: String):
        self._tally(cond, label)

    def eqi(mut self, got: Int, want: Int, label: String):
        self._tally(got == want, label + " (got " + String(got) + " want " + String(want) + ")")

    def almost(
        mut self,
        got: Float64,
        want: Float64,
        label: String,
        tol: Float64 = 1e-5,
    ):
        var d = got - want
        if d < 0:
            d = -d
        self.check(d <= tol, label + " (got " + String(got) + " want " + String(want) + ")")

    def finish(self) raises:
        var dtotal = self.device_passed + self.device_failed
        if dtotal > 0:
            if self.device_failed == 0:
                print("  " + DEVICE_TAG, self.name, "-", String(self.device_passed), "/", String(dtotal), "device checks")
            else:
                print("[FAIL]", DEVICE_TAG, self.name, "-", String(self.device_failed), "of", String(dtotal), "device checks failed")
        var total = self.passed + self.failed
        if self.failed == 0 and self.device_failed == 0:
            print("[PASS]", self.name, "-", String(self.passed), "/", String(total), "checks")
        else:
            print("[FAIL]", self.name, "-", String(self.failed), "of", String(total), "checks failed")
            raise Error("test suite failed: " + self.name)
