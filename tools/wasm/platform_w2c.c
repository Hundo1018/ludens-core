/* wasm2c side of the wasm platform probe (scripts/wasm_probe_platform.py, --aot).
 *
 * The capi wasm64 module goes through wasm2c (WABT) into C, which is compiled with clang -O3 together with this
 * host and wasm2c's runtime (wasm-rt-impl.c, wasm-rt-mem-impl.c): an LLVM ahead-of-time build of the same .wasm.
 * The generated header is included as "module.h" (wasm2c -n ludens: symbols w2c_ludens_*).
 *
 *     ./w2c_scene NB TICKS REPS      ->  one JSON line: {"ms_per_tick": [...], "hash": [...]}
 *
 * Same scene as platform_node.mjs / platform_wasmtime.py (scene()): ground box, one sphere, a 10-box stack, then NB
 * spheres on a 16 x 16 grid, ld_world_step_ticks(TICKS) timed with CLOCK_MONOTONIC, then ld_world_hash.
 * The module's only imports are env.host_write and env.host_now_ns (read off the generated header).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "module.h"

struct w2c_env {
  int unused;
};

static u64 mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (u64)ts.tv_sec * 1000000000ull + (u64)ts.tv_nsec;
}

u64 w2c_env_host_now_ns(struct w2c_env* env) {
  (void)env;
  return mono_ns() & 0x7fffffffffffffffull;
}

static w2c_ludens* g_inst;

void w2c_env_host_write(struct w2c_env* env, u32 fd, u64 ptr, u64 n) {
  (void)env;
  wasm_rt_memory_t* mem = w2c_ludens_memory(g_inst);
  if (ptr + n <= mem->size) {
    ssize_t r = write(fd == 2 ? 2 : 1, mem->data + ptr, (size_t)n);
    (void)r;
  }
}

static u64 rd64(w2c_ludens* m, u64 addr) {
  u64 v;
  memcpy(&v, w2c_ludens_memory(m)->data + addr, 8);
  return v;
}

int main(int argc, char** argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s NB TICKS REPS\n", argv[0]);
    return 2;
  }
  int nb = atoi(argv[1]), ticks = atoi(argv[2]), reps = atoi(argv[3]);
  wasm_rt_init();
  static w2c_ludens inst;
  struct w2c_env env = {0};
  g_inst = &inst;
  wasm2c_ludens_instantiate(&inst, &env);
  w2c_ludens* m = &inst;
  u64 hashes[64];
  int nh = 0;
  printf("{\"ms_per_tick\": [");
  for (int r = 0; r < reps; r++) {
    u64 pp = w2c_ludens_mw_alloc(m, 16, 8);
    if (w2c_ludens_ld_world_create(m, 1.0 / 60.0, 0.0f, -9.81f, 0.0f, pp) != 0) {
      fprintf(stderr, "ld_world_create failed\n");
      return 1;
    }
    u64 w = rd64(m, pp);
    w2c_ludens_ld_body_add_box(m, w, 0.0f, -0.5f, 0.0f, 20.0f, 0.5f, 20.0f, 0.0f, 1);
    w2c_ludens_ld_body_add_sphere(m, w, 0.0f, 5.0f, 0.0f, 0.5f, 1.0f, 0);
    for (int i = 0; i < 10; i++)
      w2c_ludens_ld_body_add_box(m, w, 2.0f, (float)(0.5 + i * 1.0), 0.0f, 0.5f, 0.5f, 0.5f, 1.0f, 0);
    for (int k = 0; k < nb; k++)
      w2c_ludens_ld_body_add_sphere(m, w, (float)(-8 + (k % 16) * 1.1), (float)(1 + (k / 256) * 1.1),
                                    (float)(-8 + ((k / 16) % 16) * 1.1), 0.5f, 1.0f, 0);
    u64 t0 = mono_ns();
    u32 rc = w2c_ludens_ld_world_step_ticks(m, w, (u32)ticks);
    u64 t1 = mono_ns();
    if (rc != (u32)ticks) {
      fprintf(stderr, "ld_world_step_ticks returned %u\n", rc);
      return 1;
    }
    printf("%s%.6f", r ? ", " : "", (double)(t1 - t0) / 1e6 / ticks);
    u64 hp = w2c_ludens_mw_alloc(m, 8, 8);
    w2c_ludens_ld_world_hash(m, w, hp);
    u64 h = rd64(m, hp);
    int seen = 0;
    for (int j = 0; j < nh; j++) seen |= hashes[j] == h;
    if (!seen && nh < 64) hashes[nh++] = h;
    w2c_ludens_ld_world_destroy(m, w);
    w2c_ludens_mw_free(m, pp);
    w2c_ludens_mw_free(m, hp);
  }
  printf("], \"hash\": [");
  for (int j = 0; j < nh; j++) printf("%s\"%016llx\"", j ? ", " : "", (unsigned long long)hashes[j]);
  printf("]}\n");
  wasm2c_ludens_free(m);
  wasm_rt_free();
  return 0;
}
