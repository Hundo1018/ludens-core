#!/usr/bin/env bash
# Compile every GPU test and bench for an explicit accelerator architecture
# (default sm_86) without running it. On a host with no GPU, `mojo run` of a
# GPU program skips its device half (or fails to pick an architecture), so
# device code would otherwise go uncompiled; this builds the kernels for real
# and fails on any compile error. ROADMAP 17.17.
#
#   pixi run gpu-compile            # sm_86
#   pixi run gpu-compile -- gfx942  # another target
set -euo pipefail
cd "$(dirname "$0")/.."
ACCEL="${1:-sm_86}"
OUT=$(mktemp -d)
trap 'rm -rf -- "$OUT"' EXIT
fail=0
n=0
for f in tests/test_gpu_*.mojo tests/test_lbm_gpu.mojo tests/test_vbd_cloth.mojo benchmarks/bench_gpu_*.mojo benchmarks/bench_lbm_gpu.mojo benchmarks/bench_vbd_cloth.mojo; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    if mojo build --target-accelerator "$ACCEL" -D ASSERT=all -I build -o "$OUT/$(basename "$f" .mojo)" "$f" > "$OUT/log" 2>&1; then
        echo "ok    $f"
    else
        echo "FAIL  $f"
        { grep -v warning "$OUT/log" | grep -B2 -A8 error || tail -20 "$OUT/log"; } | head -30
        fail=$((fail + 1))
    fi
done
echo "gpu-compile ($ACCEL): $((n - fail)) / $n built"
[ "$fail" -eq 0 ]
