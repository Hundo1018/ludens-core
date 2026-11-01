"""Build-time options of the scheduler package (ROADMAP 17.89 W1)."""

from std.sys.defines import get_defined_bool

# `-D LUDENS_SERIAL=True` (the wasm build): every fan-out except DISPATCH_HOST runs on the
# calling thread, so `parallelize`, the async runtime, work stealing and MXCSR setup never
# reach the IR. Results are bit-identical by the dispatch contract (`test_dispatch`).
comptime SERIAL_ONLY = get_defined_bool["LUDENS_SERIAL", False]()
