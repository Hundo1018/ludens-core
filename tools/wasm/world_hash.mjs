// The reference scene (17.89): ground, ball, ten stacked boxes, NB extra spheres; prints the world hash.
//   node tools/wasm/world_hash.mjs build/ludens64.wasm [ticks=240] [NB=0]
// 12 bodies, 240 ticks -> 4624da7477e83eff on the no-FMA reference build (ROADMAP 17.89).
import { readFileSync } from "node:fs";
const hostPath = process.env.LUDENS_WASM_RT_HOST ?? new URL("../../../ludens-wasm-rt/ludens_wasm_rt/host.mjs", import.meta.url).pathname;
const { instantiate } = await import(hostPath);
const rt = await instantiate(readFileSync(process.argv[2]));
const e = rt.exports;
const ticks = Number(process.argv[3] ?? 240);
const nb = Number(process.argv[4] ?? 0);
const pp = e.mw_alloc(16n, 8n);
let rc = e.ld_world_create(1 / 60, 0, -9.81, 0, pp);
if (rc !== 0) throw new Error("ld_world_create " + rc);
const w = new BigUint64Array(rt.memory.buffer, Number(pp), 1)[0];
e.ld_body_add_box(w, 0, -0.5, 0, 20, 0.5, 20, 0, 1);
e.ld_body_add_sphere(w, 0, 5, 0, 0.5, 1, 0);
for (let i = 0; i < 10; i++) e.ld_body_add_box(w, 2, 0.5 + i * 1.0, 0, 0.5, 0.5, 0.5, 1, 0);
for (let k = 0; k < nb; k++) e.ld_body_add_sphere(w, -8 + (k % 16) * 1.1, 1 + Math.floor(k / 256) * 1.1, -8 + (Math.floor(k / 16) % 16) * 1.1, 0.5, 1, 0);
const t0 = process.hrtime.bigint();
rc = e.ld_world_step_ticks(w, ticks);
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
const hp = e.mw_alloc(8n, 8n);
e.ld_world_hash(w, hp);
const hash = new BigUint64Array(rt.memory.buffer, Number(hp), 1)[0];
console.log(`bodies ${12 + nb} ticks ${ticks} rc ${rc} ms/tick ${(ms / ticks).toFixed(4)}`);
console.log(`hash ${hash.toString(16).padStart(16, "0")}`);
e.ld_world_destroy(w);
