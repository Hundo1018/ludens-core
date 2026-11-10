#!/usr/bin/env bash
# Precompile every ludens-core package into build/*.mojoc, in dependency order.
# This nightly only resolves cross-file imports through precompiled .mojoc on the
# -I path (source dirs are not searched), so packages must be built before tests.
#
# Outputs are staged OUTSIDE the -I path and moved in only when complete: the
# compiler creates the output file before resolving imports (observed on
# 1.0.0b3.dev2026071805), so a package whose own absolute self-imports resolve
# through -I would otherwise find its half-written (or stale) .mojoc.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build build/.stage

pc() {
  rm -f "build/$1.mojoc"
  mojo precompile "$1" -I build -o "build/.stage/$1.mojoc"
  mv "build/.stage/$1.mojoc" "build/$1.mojoc"
}

pc diag
pc harness
pc geometry
pc numerics
pc fluid
pc procedural
pc spatial
pc ecs
pc scheduler
pc nav
pc collision
pc physics
pc ai
pc gameplay
pc oop
pc embed

echo "build: all packages precompiled into build/"
