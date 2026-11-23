#!/usr/bin/env bash
# The one gate command for agents and humans. Runs the whole suite in the
# FOREGROUND (a backgrounded run that gets killed leaves an agent waiting
# forever), then prints a fixed-format summary computed by the tested
# tools/golden.mojo instead of an ad-hoc grep, and compares against the
# golden output file section by file section.
#
#   scripts/agent_gate.sh                  gate: suite + summary + golden compare
#   scripts/agent_gate.sh --update-golden  gate, then record this run as golden
#   scripts/agent_gate.sh --selftest       test the gate's own tools first
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# One golden per platform (ROADMAP 17.76): linux x86-64 keeps the original
# file; any other OS / architecture reads test_stdout.<os>-<arch>.txt, which
# `--update-golden` creates there on first record.
PLAT="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
if [ "$PLAT" = "linux-x86_64" ]; then
  GOLDEN=tests/golden/test_stdout.txt
else
  GOLDEN=tests/golden/test_stdout.$PLAT.txt
fi
LOG=build/agent_gate.log
mkdir -p build

if [ "${1:-}" = "--selftest" ]; then
  bash scripts/golden.sh selftest && bash scripts/arch.sh selftest && pixi run doclint -- --selftest \
    && pixi run orphans -- --selftest && pixi run perf -- selftest && pixi run symcov -- --selftest \
    && python3 scripts/gen_bindings.py --selftest && python3 scripts/flag_policy.py --selftest
  exit $?
fi

# Suite budget: ~1800 s was exceeded once the suite passed ~190 files (2026-10-12).
GATE_TIMEOUT="${GATE_TIMEOUT:-3600}"
timeout "$GATE_TIMEOUT" pixi run test > "$LOG" 2>&1
rc=$?
[ $rc -eq 124 ] && echo "SUITE  TIMEOUT after $GATE_TIMEOUT s (log: $LOG)"
bash scripts/golden.sh summary "$LOG"; srow=$?
if [ "${1:-}" = "--update-golden" ] && [ $rc -eq 0 ] && [ $srow -eq 0 ]; then
  bash scripts/golden.sh normalize "$LOG" > "$GOLDEN"
  echo "GOLDEN updated ($(wc -l < "$GOLDEN") lines)"; grow=0
elif [ ! -f "$GOLDEN" ]; then
  echo "GOLDEN missing for $PLAT ($GOLDEN): record one with --update-golden"; grow=1
else
  bash scripts/golden.sh compare "$GOLDEN" "$LOG"; grow=$?
fi
if [ $rc -eq 0 ] && [ $srow -eq 0 ] && [ $grow -eq 0 ]; then
  echo "GATE   PASS  (log: $LOG)"; exit 0
fi
echo "GATE   FAIL  (suite exit $rc; log: $LOG)"; exit 1
