"""Run tools/wasm/gate_entry.mojo's exported scenes on wasmtime: gate_entry_run.py build/gate.wasm"""
import os
import sys
from pathlib import Path

rt_root = Path(os.environ.get("LUDENS_WASM_RT", Path(__file__).resolve().parents[3] / "ludens-wasm-rt"))
sys.path.insert(0, str(rt_root / "tests"))
from wasmtime_host import Rt  # noqa: E402

rt = Rt(Path(sys.argv[1]))
for name in ("callback", "soft"):
    print(name, format(rt.call("gate_" + name) & 0xFFFFFFFFFFFFFFFF, "016x"))
