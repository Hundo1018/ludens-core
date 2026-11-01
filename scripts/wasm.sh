#!/usr/bin/env bash
# Build the C-ABI as a wasm64 module through ludens-wasm-rt (ROADMAP 17.89 W0).
#   pixi run wasm [out.wasm]       -> build/ludens64.wasm
#   LUDENS_WASM_RT=/path/to/ludens-wasm-rt   (default: ../ludens-wasm-rt)
# The driver's own pixi env supplies LLVM 23 / lld / node 24; the engine's mojo (the one the
# build/*.mojoc packages were made with) is put in front of its PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
RT="${LUDENS_WASM_RT:-../ludens-wasm-rt}"
OUT="${1:-build/ludens64.wasm}"
[ -f "$RT/pixi.toml" ] || { echo "wasm: ludens-wasm-rt not found at $RT (set LUDENS_WASM_RT)" >&2; exit 1; }
shim="$(mktemp -d)"
trap 'rm -rf "$shim"' EXIT
printf '#!/usr/bin/env bash\nexec pixi run --manifest-path "%s/pixi.toml" mojo "$@"\n' "$PWD" > "$shim/mojo"
chmod +x "$shim/mojo"
pixi run --manifest-path "$RT/pixi.toml" bash -c \
  "PATH='$shim':\$PATH python3 -m ludens_wasm_rt.build_wasm --lib . embed/capi.mojo -I build -o '$OUT' --export 'ld_*'"
