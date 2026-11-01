#!/usr/bin/env bash
# Run test files against the precompiled packages, optionally filtered by
# tier (docs/design/17.0b-test-tiers.md; docs/ARCHITECTURE.md S3). Each
# test's Suite.finish() exits non-zero on failure, so `set -e` stops the
# run at the first failing file.
#
# Usage: run_tests.sh [tier ...]
#   no args          -- every tests/test_*.mojo file, alphabetical
#   tier [tier ...]  -- only files declaring one of the given tiers, one
#                        tier at a time IN THE ORDER GIVEN (so
#                        `run_tests.sh unit component` runs every unit
#                        file, alphabetical, then every component file)
#
# Every file's header is validated up front -- regardless of which tiers
# this invocation will actually run -- so a file with no/invalid
# `# tier: <tier>` first line fails the run instead of silently vanishing
# from a filtered subset.
#
# `-D ASSERT=all` turns on std `debug_assert` (off by default -- see
# `diag/invariant.mojo`), so the suite runs with every invariant live: a real
# bug behind a `debug_assert` fails loudly here instead of silently passing
# in a build that never checks it.
#
# Every test compiles for one fixed CPU, `x86-64` (the baseline: no FMA; 17.89 / #75),
# unless LUDENS_TARGET_CPU says otherwise. The golden holds floats whose last
# digits depend on what the compiler targets: compiled for the host, an
# AVX-512 Xeon prints `Y-tree energy drift: 0.011868272829287659` where the
# machine that recorded the golden prints 0.011869547291799025. The CPU model
# matters, not just the ISA level: `x86-64-v3` and `haswell` still change
# test_mpm's last digits, `skylake` and `alderlake` reproduce every section.
# `skylake` runs on any AVX2 host (ROADMAP 17.81 cross-machine probe).
set -euo pipefail
cd "$(dirname "$0")/.."
# x86-64 pins x86-64 (above). Other architectures (linux-aarch64, osx-arm64;
# ROADMAP 17.76) compile for the host until each has a pinned target and its
# own golden file (scripts/agent_gate.sh picks the file per platform).
if [ -n "${LUDENS_TARGET_CPU:-}" ]; then
    TARGET_CPU="$LUDENS_TARGET_CPU"
elif [ "$(uname -m)" = "x86_64" ]; then
    TARGET_CPU=x86-64
else
    TARGET_CPU=""
fi
TARGET_FLAGS=()
[ -n "$TARGET_CPU" ] && TARGET_FLAGS=(--target-cpu "$TARGET_CPU")

VALID_TIERS="unit component integration system stress"

is_valid_tier() {
    case " $VALID_TIERS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# The declared tier word from a file's first line (override annotation, if
# any, is ignored), or empty if there is no `# tier: ...` first line at all.
tier_of() {
    local first
    first=$(head -n1 "$1")
    if [[ "$first" != "# tier: "* ]]; then
        return
    fi
    local rest="${first#\# tier: }"
    local tier
    read -r tier _ <<< "$rest"
    printf '%s' "$tier"
}

for t in "$@"; do
    if ! is_valid_tier "$t"; then
        echo "usage: run_tests.sh [unit|component|integration|system|stress ...]" >&2
        exit 1
    fi
done

declare -A TIER_OF
for t in tests/test_*.mojo; do
    tier=$(tier_of "$t")
    if [ -z "$tier" ] || ! is_valid_tier "$tier"; then
        echo "FAIL: $t has no valid '# tier: <tier>' first line (got: '${tier:-<none>}')" >&2
        exit 1
    fi
    TIER_OF["$t"]="$tier"
done

run_one() {
    echo "--- $1 ---"
    mojo run "${TARGET_FLAGS[@]}" -D ASSERT=all -I build "$1"
}

# The files to run, in order.
FILES=()
if [ "$#" -eq 0 ]; then
    FILES=(tests/test_*.mojo)
else
    for want in "$@"; do
        for t in tests/test_*.mojo; do
            if [ "${TIER_OF[$t]}" = "$want" ]; then
                FILES+=("$t")
            fi
        done
    done
fi

# LUDENS_TEST_JOBS=N (default 1) runs N files at once. Each file's output
# goes to its own buffer and the buffers are printed in the order above, so
# stdout is byte-identical to the sequential run; the first failing file in
# that order stops the printout with its exit code, as `set -e` does below.
# Most of a file's wall time is the `mojo run` compile, which is single-
# threaded, so N up to the core count cuts the suite time (17.81 CI budget).
# A file whose second line is `# run: alone` measures wall time (17.83):
# it runs after the parallel batch, one at a time, so the other jobs do
# not skew it (test_bench_ab failed once under 4 jobs plus a build).
JOBS="${LUDENS_TEST_JOBS:-1}"
if [ "$JOBS" -le 1 ]; then
    for t in "${FILES[@]}"; do
        run_one "$t"
    done
else
    OUT=build/test_out
    rm -rf "$OUT"
    mkdir -p "$OUT"
    export TARGET_FLAGS_STR="${TARGET_FLAGS[*]:-}"
    PAR=()
    ALONE=()
    for t in "${FILES[@]}"; do
        if [ "$(sed -n 2p "$t")" = "# run: alone" ]; then
            ALONE+=("$t")
        else
            PAR+=("$t")
        fi
    done
    ONE='f="$1"; o="$2/$(basename "$f").out"
        set +e
        echo "--- $f ---" > "$o"
        mojo run $TARGET_FLAGS_STR -D ASSERT=all -I build "$f" >> "$o" 2>&1
        echo $? > "$o.rc"
        exit 0'
    if [ "${#PAR[@]}" -gt 0 ]; then
        printf '%s\n' "${PAR[@]}" | xargs -P "$JOBS" -I{} bash -c "$ONE" _ {} "$OUT"
    fi
    for t in "${ALONE[@]}"; do
        bash -c "$ONE" _ "$t" "$OUT"
    done
    for t in "${FILES[@]}"; do
        o="$OUT/$(basename "$t").out"
        cat "$o"
        rc=$(cat "$o.rc")
        [ "$rc" -ne 0 ] && exit "$rc"
    done
fi
echo "all tests passed"
