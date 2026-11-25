// node side of the wasm platform probe (scripts/wasm_probe_platform.py). One JSON spec in, one JSON result out:
//   node tools/wasm/platform_node.mjs '{"mode":"scene","wasm":"...","nb":1000,"ticks":120,"reps":7}'
//   node tools/wasm/platform_node.mjs '{"mode":"multi","engine":"...","game":"...","link":"direct"|"js",...}'
// The engine goes through ludens-wasm-rt's host.mjs. The game module is instantiated here by hand: host.mjs wraps
// every import in a JS guard, which would turn the direct wasm-to-wasm link into a JS call.
import { readFileSync } from "node:fs";
const hostPath = process.env.LUDENS_WASM_RT_HOST ?? new URL("../../../ludens-wasm-rt/ludens_wasm_rt/host.mjs", import.meta.url).pathname;
const { instantiate } = await import(hostPath);
const spec = JSON.parse(process.argv[2]);
const now = () => Number(process.hrtime.bigint()) / 1e6;  // ms

async function engine(path) {
  const bytes = readFileSync(path);
  let t0 = now();
  const mod = await WebAssembly.compile(bytes);
  const compile_ms = now() - t0;
  t0 = now();
  void mod;
  const rt = await instantiate(bytes);
  const instantiate_ms = now() - t0;  // compile again + instantiate: host.mjs takes bytes
  return { rt, compile_ms, instantiate_ms };
}

function scene(e, mem, nb, ticks) {
  const pp = e.mw_alloc(16n, 8n);
  if (e.ld_world_create(1 / 60, 0, -9.81, 0, pp) !== 0) throw new Error("ld_world_create");
  const w = new BigUint64Array(mem().buffer, Number(pp), 1)[0];
  e.ld_body_add_box(w, 0, -0.5, 0, 20, 0.5, 20, 0, 1);
  e.ld_body_add_sphere(w, 0, 5, 0, 0.5, 1, 0);
  for (let i = 0; i < 10; i++) e.ld_body_add_box(w, 2, 0.5 + i * 1.0, 0, 0.5, 0.5, 0.5, 1, 0);
  for (let k = 0; k < nb; k++) e.ld_body_add_sphere(w, -8 + (k % 16) * 1.1, 1 + Math.floor(k / 256) * 1.1, -8 + (Math.floor(k / 16) % 16) * 1.1, 0.5, 1, 0);
  const t0 = now();
  const rc = e.ld_world_step_ticks(w, ticks);
  const ms = (now() - t0) / ticks;
  if (rc !== ticks) throw new Error("ld_world_step_ticks " + rc);
  const hp = e.mw_alloc(8n, 8n);
  e.ld_world_hash(w, hp);
  const hash = new BigUint64Array(mem().buffer, Number(hp), 1)[0].toString(16).padStart(16, "0");
  e.ld_world_destroy(w);
  e.mw_free(pp);
  e.mw_free(hp);
  return { ms, hash };
}

const hex = (h) => BigInt.asUintN(64, h).toString(16).padStart(16, "0");
const out = { node: process.version, v8: process.versions.v8 };
if (spec.mode === "scene") {
  const { rt, compile_ms, instantiate_ms } = await engine(spec.wasm);
  Object.assign(out, { compile_ms, instantiate_ms, ms_per_tick: [], hash: [] });
  for (let r = 0; r < spec.reps; r++) {
    const s = scene(rt.exports, () => rt.memory, spec.nb, spec.ticks);
    out.ms_per_tick.push(s.ms);
    if (!out.hash.includes(s.hash)) out.hash.push(s.hash);
  }
} else {
  const { rt } = await engine(spec.engine);
  const e = rt.exports;
  const gbytes = readFileSync(spec.game);
  let t0 = now();
  const gmod = await WebAssembly.compile(gbytes);
  out.game_compile_ms = now() - t0;
  const env = {
    host_write: () => {},
    host_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
  };
  // a fixed-arity JS forwarder per import (what a hand-written JS glue function looks like)
  const forward = (f) => {
    switch (f.length) {
      case 0: return () => f();
      case 1: return (a) => f(a);
      case 2: return (a, b) => f(a, b);
      case 3: return (a, b, c) => f(a, b, c);
      case 7: return (a, b, c, d, g, h, i) => f(a, b, c, d, g, h, i);
      case 8: return (a, b, c, d, g, h, i, j) => f(a, b, c, d, g, h, i, j);
      case 9: return (a, b, c, d, g, h, i, j, k) => f(a, b, c, d, g, h, i, j, k);
      default: return (...a) => f(...a);
    }
  };
  out.imports = [];
  for (const imp of WebAssembly.Module.imports(gmod)) {
    if (imp.module !== "env" || imp.name in env) continue;
    const f = e[imp.name];
    if (typeof f !== "function") throw new Error("engine does not export " + imp.name);
    env[imp.name] = spec.link === "direct" ? f : forward(f);
    out.imports.push(imp.name);
  }
  t0 = now();
  const g = (await WebAssembly.instantiate(gmod, { env })).exports;
  out.game_instantiate_ms = now() - t0;
  const runs = (fn, arg, k) => {
    const ms = [], hs = [];
    for (let r = 0; r < k; r++) {
      const t = now();
      const h = hex(fn(arg));
      ms.push((now() - t) / spec.ticks);
      if (!hs.includes(h)) hs.push(h);
    }
    return [ms, hs];
  };
  [out.game_ms_per_tick, out.game_hash] = runs(g.game_run, spec.ticks, spec.reps + 1);
  const n = BigInt(spec.link === "direct" ? spec.calls : spec.calls_slow);
  out.n = Number(n); out.calls_s = []; out.spin_s = [];
  for (let r = 0; r <= spec.reps; r++) {
    t0 = now(); g.game_calls(n); const c = (now() - t0) / 1e3;
    t0 = now(); g.game_spin(n); const sp = (now() - t0) / 1e3;
    if (r > 0) { out.calls_s.push(c); out.spin_s.push(sp); }
  }
  if (spec.inproc) {
    out.inproc_n = spec.calls; out.inproc_calls_s = [];
    for (let r = 0; r <= spec.reps; r++) {
      t0 = now(); e.pp_calls_inproc(BigInt(spec.calls)); const c = (now() - t0) / 1e3;
      if (r > 0) out.inproc_calls_s.push(c);
    }
    [out.inproc_ms_per_tick, out.inproc_hash] = runs(e.pp_game_run, spec.ticks, spec.reps + 1);
  }
}
console.log(JSON.stringify(out));
