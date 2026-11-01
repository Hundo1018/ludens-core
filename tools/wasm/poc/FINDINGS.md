# ludens-engine -> WebAssembly: measured findings (2026-11-01)

Scratch dir: `/tmp/claude-1000/-home-hundo-Projects-ludens-engine/68ab9e99-cb9b-4c86-9f4a-d3749ebd3085/scratchpad/wasm/`
Repo at 7cb300a, Mojo 1.2.0 / modular 26.7.0, build/*.mojoc from Oct 12 (not rebuilt). No repo files edited.

## TL;DR

The **whole C-ABI** (`embed/capi.mojo`, 50 `ld_*` exports, rigid-body world with Lists, broadphase,
solver, scheduler) compiles to a **wasm64** module that links and runs under wasmtime 50 and node 24,
and reproduces the native **baseline x86-64 (no FMA)** build **bit-for-bit** (world hash equal) once the
module gets the same `sinf`/`cosf` as native. No Modular support needed for this route; it needs
an external LLVM >= 23 (conda-forge `llvm-tools`/`lld`/`clang` 23.1.4), a ~150-line C runtime shim,
and 3 textual IR fixes.

Scope of the claim: (a) **link closure** is complete for the full ABI (no `--allow-undefined`; libm
surface = 6 symbols); (b) **behavioural** parity is shown only for box/sphere rigid-body scenes via
`ld_world_step_ticks` up to 1012 bodies. CCD, soft bodies, nav, raycast, save/load, capture and host
callbacks were linked but not exercised. The probe-only `fma` shim was never called
(`libm calls trig 190518 fma 0 minmax 9386621` at 1012 bodies).

**Policy conflict (roadmap decision):** the project pins x86-64 to `skylake` (FMA) for tests/goldens
(`scripts/run_tests.sh` TARGET_CPU=skylake; ARCHITECTURE §6; `flag_policy.py` R2), and `pixi run capi`
builds for the host CPU (alderlake, FMA). wasm (no FMA) matches only the `--target-cpu x86-64`
baseline, which ARCHITECTURE §6 documents as drifting from skylake. So either wasm gets its own golden
(like aarch64/macOS), or the parity reference becomes a no-FMA build / FMA contraction is disabled.
The IR above was emitted for the host (alderlake); emitting with explicit target flags is advised
(may also shrink host-width vectors like `<32 x i8>` -- unverified).

## 1. IR of a non-leaf entry point

`pixi run mojo build --emit llvm -I build -o capi.ll embed/capi.mojo` (17.6 s, 42 MB unoptimized IR,
846 defined functions). Header: `target triple = "x86_64-unknown-linux-gnu"`, every attribute group
carries `"target-cpu"="alderlake"` + AVX2/FMA feature list.

External (non-intrinsic) declares: **24** (files: `declares.txt`)

| group | symbols |
|---|---|
| Mojo runtime alloc | `KGEN_CompilerRT_AlignedAlloc(i64 align, i64 size)`, `KGEN_CompilerRT_AlignedFree(ptr)` |
| Mojo runtime diag | `KGEN_CompilerRT_fprintf(i64 FILE*, ptr, ...)`, `KGEN_CompilerRT_GetStackTrace(ptr,i64)`, `KGEN_CompilerRT_Tracy{IsEnabled,ZoneBegin,ZoneEnd}` |
| threads / pool | `KGEN_CompilerRT_NumPhysicalCores`, `KGEN_CompilerRT_AsyncRT_ParallelismLevel`, `AsyncRT_DeviceContext_{create,retain,release,deviceApi,enqueueHostFunctionRange,synchronize,getAttribute,strfree}` (from `max.algorithm.parallelize` via `scheduler/dispatch.mojo`, `scheduler/workstealing.mojo`) |
| libc | `write`, `dup`, `fdopen`, `fflush`, `fclose`, `clock_gettime`, `pthread_self` (capi thread binding) |

Intrinsics: 51 distinct; two are x86-only: `llvm.x86.sse.stmxcsr` / `ldmxcsr` (FTZ/DAZ guard inside
`max.algorithm.parallelize`; not engine source). After codegen the wasm object additionally needs
libm `sinf cosf fmaf fma fminf fmaxf` (llc lowers `llvm.sin/cos/fma/minnum/maxnum` to libcalls),
compiler-rt `__multi3` (i128 mul), and after `opt -O3` also `strlen` (loop idiom).
Final undefined set in `capi64.o`: 32 symbols (`undef64.txt`).

## 2. Does an external llc accept Modular's IR?

Modular's LLVM is **24.0.0git** (`.pixi/envs/default/lib/liblldb24.0.0git.so`, `lld --version` = LLD 24.0.0).
Its in-tree LLVM has **no WebAssembly codegen** (lld binary has X86/AArch64/NVPTX/AMDGPU/RISCV passes,
no WebAssembly ISel), but the bundled `.pixi/envs/default/bin/lld -flavor wasm` **is a working wasm-ld 24**.

### LLVM 18 (/usr/bin/llc) -- parses only after 9 textual rewrites (`sanitize.py`)
Errors in order (each fixed, then the next appeared):
1. `error: expected type` -- `@llvm.is.fpclass.f32(float %56, /* (zero sub norm) */ i32 504)` (inline comments)
2. `floating point constant invalid for type` -- `store float 1.000000e-01` (shortest-decimal float literals)
3. `expected '(' in constantexpr` -- `getelementptr inbounds nuw (...)`
4. `expected value token` -- `fmul contract float %0, f0x4B000000` (new `f0x` hex-float syntax, also 16-digit double form)
5. `floating point constant invalid for type` -- `fcmp ole float %59, 1.000000e-30`
6. `expected value token` -- `+inf`, `-inf`, `+qnan` literals
7. `expected ')'` -- `ptr captures(none)`; also `llvm.lifetime.*` now 1-arg (dropped)
8. `attribute group has no attributes` (after stripping target attrs) + `nocreateundeforpoison`
9. silent: `llvm.stepvector` renamed (18 = `llvm.experimental.stepvector`) -> shows up as an *undefined symbol*, not an error
Then ISel: `LLVM ERROR: Cannot select: intrinsic %llvm.x86.sse.stmxcsr` (stubbed), then
`WebAssembly 'tail-call' feature not enabled` (AsyncRT coroutine `musttail`; fix `-mattr=+tail-call`).
Result: 3.4 MB wasm64 object in 11.4 s. **But** objects from llc 18 cannot be linked by the bundled
wasm-ld 24 into a valid module: wasm-ld 24 emits a **table64** for `-mwasm64` while llc 18 emits i32
`call_indirect` indices -> wasmtime: `type mismatch: expected i64, found i32` in `capi::_run_phase`
(the host-callback call_indirect). Lesson: **llc and wasm-ld must be the same LLVM major.**

### LLVM 23.1.4 (conda-forge, installed into scratch via `pixi exec`, PIXI_CACHE_DIR in scratch) -- clean
Only needs (`retarget.py`): triple+datalayout swap, strip `target-cpu`/`target-features` (fill empty
attribute groups), stub `llvm.x86.sse.{st,ld}mxcsr` (92 lines). No syntax down-conversion.
`opt -O3` 9 s, `llc -O3 -mattr=+tail-call,+simd128,+bulk-memory,+nontrapping-fptoint,+sign-ext,+mutable-globals` ok.
NOTE: `--emit llvm` is *unoptimized* IR; skipping `opt` gives ~2x slower wasm (0.87 vs 0.42 ms/tick).

## 3. Runtime shim + link + run

`shim.c` (freestanding C, clang 23 `--target=wasm64-unknown-unknown -nostdlib -fno-builtin -ffp-contract=off`):
- `KGEN_CompilerRT_AlignedAlloc/Free`: power-of-two size classes over `memory.grow`, 64-B aligned (O(1); a first-fit list was the first try)
- diag/Tracy/stack trace: no-ops; `write`/`fprintf` -> host import `host_write`
- `NumPhysicalCores` = `ParallelismLevel` = 1; all `AsyncRT_*` = `__builtin_trap()` (never reached in any run below)
- `clock_gettime` -> host import; `pthread_self` = 1
- libm: `sinf/cosf` -> host import (see determinism); `fminf/fmaxf` = wasm `f32.min/max` (WRONG NaN/±0 semantics vs C; harmless here, must fix); `fmaf` via double (double rounding), `fma` non-fused (probe only)
- `__multi3`, `strlen` hand-written.
Exact signatures must match the IR declares (wasm-ld turns mismatches into trapping stubs, with only a warning).

Link: `wasm-ld -mwasm64 --no-entry --export=ld_* ... --export-memory -O2 --gc-sections capi64_O3.o shim64_23.o`
-> `ludens64_O3.wasm` **1,381,304 B** (323,426 B gzip -9), 4 imports (`env.host_write/host_now_ns/host_sinf/host_cosf`).
SIMD: Vec3 is `<4 x float>` (49,985 uses in IR) -> maps 1:1 to `f32x4` (15,746 f32x4 ops in the module).

### Runs (scene: static ground box, 1 sphere, 10-box stack [+ NB spheres], dt 1/60, `ld_world_step_ticks`)

| runtime | result |
|---|---|
| node 22.23.3 (V8 12.4, memory64 on by default) | `CompileError: invalid table elements limits flags` -- no table64 support -> node 22 could not run the wasm64 modules produced by LLD 24 / LLVM 23 (older LLVM untested) |
| node 24.22.1 (no flags) | runs; hashes equal wasmtime with the same trig |
| wasmtime 50.0.1 (pip, `wasm_memory64=True`) | runs |

Bit-exactness vs native (`mojo build --emit shared-lib embed/capi.mojo` into scratch; ctypes runner):

| scene | ticks | native alderlake (FMA) | native `--target-cpu x86-64` | wasm64 O3 |
|---|---:|---|---|---|
| 12 bodies | 240 | `0b54cefb78d616c8` | `4624da7477e83eff` | `4624da7477e83eff` |
| 12 bodies | 2400 | -- | `22ed109549a3b1a7` | `22ed109549a3b1a7` |
| 62 / 212 / 512 bodies | 120 | -- | equal | equal (512: 59,954 trig calls via host Math) |
| 1012 bodies | 120 | -- | `8603cbbd2a58fce7` | `27240daf65efad83` with JS/Python `Math.sin`; **`8603cbbd2a58fce7` with glibc `sinf/cosf` as the host import** |

=> wasm reproduces the no-FMA native build exactly; the only divergence found was libm. FMA on native
changes bits (consistent with fp-probe 17.76). Cross-platform determinism therefore requires
(a) a no-FMA native reference build (or wasm relaxed-simd FMA never used) and (b) **one sin/cos
implementation shared by both sides** (engine-owned Mojo polynomial, or the same libm compiled in).

Timing, single core (`taskset -c 2`), ms/tick:

| scene | native x86-64 baseline | wasmtime 50 (Cranelift) | node 24 (V8) |
|---|---:|---:|---:|
| 12 bodies, 120 ticks | 0.127 | 0.554 | -- |
| 12 bodies, 2400 ticks (unpinned) | 0.031 | 0.095 | 0.066 |
| 1012 bodies, 120 ticks | 6.18 | 25.76 (4.2x) | 9.31 (1.5x) |
Unpinned native at 1012 bodies: 6.35 ms (parallel pool gives little at this size). memory64 needs
explicit bounds checks (no guard-page trick), part of the wasmtime gap.

### wasm32 attempt -- unsound
Same IR with a 32-bit datalayout links and even ran (unoptimized: same hash, 0.447 ms/tick), but
after `opt -O3` the module shrinks 3.4 MB -> 95 KB and `ld_world_create` hits `unreachable`.
Consistent with sizes/offsets baked with host 64-bit pointers at Mojo compile time making the IR UB
under a 32-bit layout (not root-caused). Side note for the main session: the repo's separate
aarch64/macOS goldens may diverge for the same two reasons (FMA, libm trig) -- unchecked. **Retargeted host IR is wasm64-only.** wasm32 needs Mojo itself to lower for wasm32.

## 4. Mojo upstream status (primary sources)

- modular/modular #4729 "Enable wasm32/64 Target in Mojo's Internal LLVM" -- OPEN since 2025-06-01, label `bug_feature_triaged`; no staff commitment. A commenter (2026-04-07) points to a community pipeline.
- modular/modular #5367 "Native WebAssembly (WASM) Support for Mojo" -- OPEN since 2025-09-26, `Team: Mojo Compiler`, triaged; comments from community (owenhilyard: JIT reduces the need; 2026-09-03 a wasi:webgpu champion offers help). No roadmap date.
- #19 (WASM and WASI, 2023) and #3 (WebGPU/Wasm) closed as "not on immediate roadmap" (Mogball; lattner: "quite well set up to do this architecturally").
- mojolang.org/docs/roadmap (Version 1.2.0): no mention of wasm; only "Expand platform support: Supporting new types of hardware" (Phase 2, not started).
- Forum "At what stage will something like WASM be considered?" (2025-03): no plans; blockers named = runtime pieces missing even with the backend on, WASI/component churn, async.
- Community: noverby/noverby `mojo/wasm/web/justfile` uses the same route we measured: `mojo build --emit llvm` -> sed (drop lifetime, `nocreateundeforpoison`, target-cpu/features, empty attr groups) -> `llc --mtriple=wasm64-wasi` -> `wasm-ld -mwasm64 --allow-undefined --export-all`, TS host runtime supplies imports. Independent confirmation that wasm64 is the practical target.
- `mojo build --help` (1.2.0) lists emit targets amdgpu/host/metal/nvptx only.

## 5. Constraints

- **memory64 in browsers**: Chrome/Edge 133+ (2025-02), Firefox 134+ (2025-01); **Safari: not shipped** (WebKit bug 300538 still NEW, last comment 2026-02-28 "only remaining Phase 5 feature"). Node 22 lacks table64; Node >= 24 works. wasmtime: config flag.
- **SIMD**: wasm SIMD128 only. Mojo's Vec3 = `SIMD[f32,4]` fits exactly; anything sized by host `simd_width_of` (AVX2 = 8 f32; `<32 x i8>` 392 uses) is legalised into 2 x v128 -- correct but not tuned. Relaxed-SIMD FMA would break bit parity; keep off.
- **Threads**: module is single-threaded; AsyncRT never called because ParallelismLevel=1, but nothing guarantees that statically. Need a compile-time `DISPATCH_SERIAL` (or `DISPATCH_HOST` into Web Workers / wasi-threads) build for wasm. Browser threads need SharedArrayBuffer => COOP/COEP headers; wasi-threads is still a proposal (wasmtime has it experimental). `DISPATCH_HOST` already exists in `scheduler/dispatch.mojo` and maps naturally onto a JS worker pool.
- **GPU**: Mojo emits PTX/AMDGPU/Metal only; no WGSL/SPIR-V for WebGPU. GPU paths must be compiled out (they already skip without `has_accelerator`, but the code is still in the IR: `AsyncRT_DeviceContext_*` imports).
- **FTZ/DAZ**: x86 MXCSR guard from `parallelize` has no wasm meaning (wasm floats are IEEE, no FTZ); stubbed.
- **libm**: must be bundled and identical on all hosts for determinism (shown above).
- Toolchain coupling: Modular's IR is LLVM 24git; external llc must be new enough to parse it (23.1.4 ok, 18 needs rewrites) and wasm-ld must match llc's major.

## 6. Recommended layered route

1. **Now (no Modular dependency)** -- `pixi run wasm` pipeline: `mojo build --emit llvm embed/capi.mojo` -> `retarget.py` -> conda-forge LLVM 23 `opt -O3` / `llc` (wasm64) -> shim.c (+ bundled libm) -> `wasm-ld -mwasm64`. Pin `llvm-tools/lld/clang` in a separate pixi feature/env. Gate: wasm64 world hash == native `--target-cpu x86-64` hash on the parity scenes (node 24 + wasmtime).
   Engine prerequisites: engine-owned `sin/cos` (or vendored libm used by native too); a wasm build flag selecting `DISPATCH_SERIAL`/`DISPATCH_HOST` so `parallelize`/AsyncRT/MXCSR drop out of the IR; correct `fminf/fmaxf` semantics.
2. **Near** -- JS/TS host package (browser Chrome/Firefox + Node >= 24 + Deno) and WASI host (wasmtime); Web Worker pool via `DISPATCH_HOST`. Safari waits on memory64.
3. **Waits on Modular** -- wasm32 (Safari, smaller/faster: needs Mojo to lower with 32-bit pointers), native `--target-triple wasm*`, WebGPU (no WGSL/SPIR-V emission), official runtime (AlignedAlloc etc.) for wasm.

## Files
- `capi.ll` (42 MB host IR), `declares.txt`, `intrinsics.txt`, `undef64.txt`
- `sanitize.py` (LLVM 18 down-conversion), `retarget.py` (LLVM 23 minimal retarget)
- `shim.c`, `shim32.c`; `ludens64_O3.wasm` (final), `ludens64.wasm` (llc18+lld24, broken table64), `ludens32*.wasm`
- `run64.py` / `run64_big.py` (wasmtime), `run64.mjs` / `run64_big.mjs` (node), `run_native.py` / `run_native_big.py` (ctypes)
- `libludens_native.so`, `libludens_x8664.so`; LLVM 23 tools at `pixi-cache/cached-envs-v0/8c52270d00cf4d9e/bin/`
