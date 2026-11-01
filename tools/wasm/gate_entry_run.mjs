// Run tools/wasm/gate_entry.mojo's exported scenes on node >= 24: node gate_entry_run.mjs build/gate.wasm
import { readFileSync } from "node:fs";
const hostPath = process.env.LUDENS_WASM_RT_HOST ?? new URL("../../../ludens-wasm-rt/ludens_wasm_rt/host.mjs", import.meta.url).pathname;
const { instantiate } = await import(hostPath);
const rt = await instantiate(readFileSync(process.argv[2]));
for (const name of ["callback", "soft"]) {
  console.log(name, BigInt.asUintN(64, rt.exports["gate_" + name]()).toString(16).padStart(16, "0"));
}
