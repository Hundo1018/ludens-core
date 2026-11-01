#!/usr/bin/env bash
# The wasm gate (ROADMAP 17.89 W2 / #74): the C-ABI as wasm64 must hash like the
# native reference build (`--target-cpu x86-64`, 17.89 floating-point policy c).
#   - tools/wasm/scenes.py: seven C-ABI scenes (raycast, ccd, saveload, nav, fracture, events, water),
#     native library vs wasmtime; one hash each, also recorded in tests/golden/wasm_scenes.txt
#   - tools/wasm/gate_entry.mojo: callbacks (system + contact subscriber) and a soft-body drop, run inside
#     the module on wasmtime and node vs the native build of the same entry
#   - tools/wasm/world_hash.mjs: the 12 / 1012 body worlds on node >= 24 vs the native reference binary
# A scene that comes out `nan` on either side is reported and not compared (the NaN payload is
# unspecified across hosts); everything else must be equal.
#   pixi run wasm-gate                  compare
#   pixi run wasm-gate -- --update      record the native hashes as the golden
set -euo pipefail
cd "$(dirname "$0")/.."
RT="$(cd "${LUDENS_WASM_RT:-../ludens-wasm-rt}" && pwd)"
export LUDENS_WASM_RT="$RT"
export LUDENS_WASM_RT_HOST="$RT/ludens_wasm_rt/host.mjs"
GOLDEN=tests/golden/wasm_scenes.txt
RTRUN=(pixi run --manifest-path "$RT/pixi.toml")
mkdir -p build

bash scripts/wasm.sh >/dev/null
bash scripts/wasm.sh --native >/dev/null
pixi run capi >/dev/null
# the scenes that need code inside the module (callbacks, soft body): tools/wasm/gate_entry.mojo
export LUDENS_WASM_ENTRY=tools/wasm/gate_entry.mojo LUDENS_WASM_EXPORT='gate_*'
bash scripts/wasm.sh build/gate.wasm >/dev/null
bash scripts/wasm.sh --native build/gate_ref >/dev/null
unset LUDENS_WASM_ENTRY LUDENS_WASM_EXPORT

python3 tools/wasm/scenes.py native build/libludens.so > build/wasm_scenes_native.txt
"${RTRUN[@]}" python tools/wasm/scenes.py wasm build/ludens64.wasm > build/wasm_scenes_wasmtime.txt
{
  ref=$(./build/ludens_ref)
  echo "world12x240 $(echo "$ref" | awk '/^hash12 /{print substr($2,3)}')"
  echo "world1012x120 $(echo "$ref" | awk '/^hash1012 /{print substr($2,3)}')"
} >> build/wasm_scenes_native.txt
./build/gate_ref | awk '{print $1, substr($2,3)}' >> build/wasm_scenes_native.txt
{
  echo "world12x240 $("${RTRUN[@]}" node tools/wasm/world_hash.mjs build/ludens64.wasm 240 0 | awk '/^hash /{print $2}')"
  echo "world1012x120 $("${RTRUN[@]}" node tools/wasm/world_hash.mjs build/ludens64.wasm 120 1000 | awk '/^hash /{print $2}')"
} > build/wasm_scenes_node.txt
"${RTRUN[@]}" node tools/wasm/gate_entry_run.mjs build/gate.wasm >> build/wasm_scenes_node.txt
"${RTRUN[@]}" python tools/wasm/gate_entry_run.py build/gate.wasm >> build/wasm_scenes_wasmtime.txt
# every node line must also equal the wasmtime line of the same scene
while read -r name h; do
  w=$(awk -v n="$name" '$1==n{print $2}' build/wasm_scenes_wasmtime.txt)
  [ -z "$w" ] || [ "$w" = "$h" ] || { echo "DIFF  $name node $h wasmtime $w"; nodefail=1; }
done < build/wasm_scenes_node.txt
awk 'NR==FNR{seen[$1]=1; next} !($1 in seen)' build/wasm_scenes_wasmtime.txt build/wasm_scenes_node.txt >> build/wasm_scenes_wasmtime.txt

fail=${nodefail:-0}
while read -r name h; do
  w=$(awk -v n="$name" '$1==n{print $2}' build/wasm_scenes_wasmtime.txt)
  if [ "$h" = nan ] || [ "$w" = nan ]; then echo "SKIP  $name (non-finite state: native $h, wasm $w)"
  elif [ "$h" = "$w" ]; then echo "SAME  $name $h"
  else echo "DIFF  $name native $h wasm $w"; fail=1; fi
done < build/wasm_scenes_native.txt

if [ "${1:-}" = "--update" ] && [ "$fail" -eq 0 ]; then
  cp build/wasm_scenes_native.txt "$GOLDEN"; echo "GOLDEN updated ($GOLDEN)"
elif ! diff -u "$GOLDEN" build/wasm_scenes_native.txt; then
  echo "golden: native hashes differ from $GOLDEN"; fail=1
fi
[ "$fail" -eq 0 ] && echo "WASM GATE PASS" || { echo "WASM GATE FAIL"; exit 1; }
