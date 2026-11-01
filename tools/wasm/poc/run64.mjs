// node --experimental-wasm-memory64 run64.mjs ludens64.wasm
import { readFileSync } from "node:fs";
const bytes = readFileSync(process.argv[2]);
let mem;
const env = {
  host_write: (fd, p, n) => process.stderr.write(Buffer.from(mem.buffer, Number(p), Number(n))),
  host_sinf: (x) => Math.fround(Math.sin(x)),
  host_cosf: (x) => Math.fround(Math.cos(x)),
  host_now_ns: () => process.hrtime.bigint(),
};
const { instance } = await WebAssembly.instantiate(bytes, { env });
const e = instance.exports;
mem = e.memory;
const B = (x) => BigInt(x);
console.log("abi", (e.ld_abi_version() >>> 16) + "." + (e.ld_abi_version() & 0xffff));
const pp = e.shim_alloc(16n);
let rc = e.ld_world_create(1 / 60, 0, -9.81, 0, pp);
const w = new BigUint64Array(mem.buffer, Number(pp), 1)[0];
console.log("world_create rc", rc, "handle", w);
const ground = e.ld_body_add_box(w, 0, -0.5, 0, 20, 0.5, 20, 0, 1);
const ball = e.ld_body_add_sphere(w, 0, 5, 0, 0.5, 1, 0);
const boxes = [];
for (let i = 0; i < 10; i++) boxes.push(e.ld_body_add_box(w, 2, 0.5 + i * 1.0, 0, 0.5, 0.5, 0.5, 1, 0));
console.log("bodies", e.ld_world_body_count(w), "ground", ground, "ball", ball);
const N = Number(process.argv[3] ?? 240);
const t0 = process.hrtime.bigint();
rc = e.ld_world_step_ticks(w, N);
const t1 = process.hrtime.bigint();
console.log("step_ticks rc", rc, "ticks", N, "ms/tick", (Number(t1 - t0) / 1e6 / N).toFixed(4));
const out = e.shim_alloc(64n);
for (const [name, b] of [["ball", ball], ["box9", boxes[9]]]) {
  rc = e.ld_body_get_state(w, b, out);
  const f = new Float32Array(mem.buffer, Number(out), 13);
  const u = new Uint32Array(mem.buffer, Number(out), 13);
  console.log(name, "rc", rc, "pos", [f[0], f[1], f[2]].map((x) => x.toFixed(6)).join(","), "bits", [...u.slice(0, 7)].map((x) => x.toString(16)).join(" "));
}
const hp = e.shim_alloc(8n);
rc = e.ld_world_hash(w, hp);
console.log("hash rc", rc, new BigUint64Array(mem.buffer, Number(hp), 1)[0].toString(16));
console.log("live_bytes", e.shim_live_bytes(), "peak_bytes", e.shim_peak_bytes(), "heap_top", e.shim_heap_top(), "mem_pages", mem.buffer.byteLength / 65536);
rc = e.ld_world_destroy(w);
console.log("destroy rc", rc, "live_bytes_after", e.shim_live_bytes());
