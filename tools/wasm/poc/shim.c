// Minimal freestanding runtime shim for Mojo-emitted IR on wasm64 (probe only).
// Allocator: first-fit free list over memory.grow pages. libm: host imports (NOT deterministic;
// production needs a bundled libm such as musl/wasi-libc compiled to wasm64).
typedef unsigned long size_t;
typedef long ssize_t;
typedef unsigned long long u64;
typedef unsigned __int128 u128;

#define IMPORT(name) __attribute__((import_module("env"), import_name(name)))
#define EXPORT(name) __attribute__((export_name(name)))

IMPORT("host_write") void host_write(int fd, const void *p, size_t n);
IMPORT("host_sinf") float host_sinf(float);
IMPORT("host_cosf") float host_cosf(float);
IMPORT("host_now_ns") long long host_now_ns(void);

extern unsigned char __heap_base;
static size_t heap_top;

typedef struct Hdr { size_t size; struct Hdr *next; } Hdr;  // size = payload bytes
static size_t live_bytes, live_allocs, peak_bytes;

static void *raw_alloc(size_t n) {
  if (!heap_top) heap_top = (size_t)&__heap_base;
  size_t cur = __builtin_wasm_memory_size(0) * 65536UL;
  if (heap_top + n > cur) {
    size_t need = (heap_top + n - cur + 65535) / 65536;
    if (__builtin_wasm_memory_grow(0, need) == (size_t)-1) __builtin_trap();
  }
  void *p = (void *)heap_top;
  heap_top += n;
  return p;
}

// AlignedAlloc(align, size): power-of-two size classes, every block 64-byte aligned,
// header (class) in the 64 bytes before the payload; O(1) alloc/free.
static Hdr *bins[48];
void *KGEN_CompilerRT_AlignedAlloc(size_t align, size_t size) {
  if (align > 64) __builtin_trap();
  int c = 4; while (((size_t)1 << c) < size) c++;
  size_t sz = (size_t)1 << c;
  Hdr *h = bins[c];
  if (h) { bins[c] = h->next; }
  else {
    size_t base = (size_t)raw_alloc(0);
    size_t payload = (base + 64 + 63) & ~(size_t)63;
    raw_alloc(payload + sz - base);
    h = (Hdr *)payload - 1;
  }
  h->size = (size_t)c;
  live_bytes += sz; live_allocs++;
  if (live_bytes > peak_bytes) peak_bytes = live_bytes;
  return h + 1;
}
void KGEN_CompilerRT_AlignedFree(void *p) {
  if (!p) return;
  Hdr *h = (Hdr *)p - 1;
  live_bytes -= (size_t)1 << h->size; live_allocs--;
  h->next = bins[h->size]; bins[h->size] = h;
}
EXPORT("shim_live_bytes") size_t shim_live_bytes(void) { return live_bytes; }
EXPORT("shim_peak_bytes") size_t shim_peak_bytes(void) { return peak_bytes; }
EXPORT("shim_heap_top") size_t shim_heap_top(void) { return heap_top; }
EXPORT("shim_alloc") void *shim_alloc(size_t n) { return KGEN_CompilerRT_AlignedAlloc(16, n); }

// diagnostics / tracing
int KGEN_CompilerRT_fprintf(void *f, const char *fmt, ...) {
  size_t n = 0; while (fmt[n]) n++;
  host_write(2, fmt, n);
  return (int)n;
}
long long KGEN_CompilerRT_GetStackTrace(void *p, long long n) { return 0; }
long long KGEN_CompilerRT_TracyIsEnabled(void) { return 0; }
long long KGEN_CompilerRT_TracyZoneBegin(void *s, long long n, int c) { return 0; }
void KGEN_CompilerRT_TracyZoneEnd(long long z) {}
long long KGEN_CompilerRT_NumPhysicalCores(void) { return 1; }
int KGEN_CompilerRT_AsyncRT_ParallelismLevel(void) { return 1; }

// AsyncRT (threads / device contexts): single-threaded wasm has none; trap if reached.
long long AsyncRT_DeviceContext_create(void *a, void *b, int c) { __builtin_trap(); }
void AsyncRT_DeviceContext_deviceApi(void *a, long long b) { __builtin_trap(); }
long long AsyncRT_DeviceContext_enqueueHostFunctionRange(long long a, void *b, void *c, void *d, long long e) { __builtin_trap(); }
long long AsyncRT_DeviceContext_getAttribute(void *a, long long b, int c) { __builtin_trap(); }
void AsyncRT_DeviceContext_release(long long a) { __builtin_trap(); }
void AsyncRT_DeviceContext_strfree(long long a) { __builtin_trap(); }
long long AsyncRT_DeviceContext_synchronize(long long a) { __builtin_trap(); }
void AsyncRT_DeviceContext_retain(long long a) { __builtin_trap(); }

// libc bits
ssize_t write(int fd, const void *p, size_t n) { host_write(fd, p, n); return (ssize_t)n; }
int dup(int fd) { return fd; }
void *fdopen(int fd, const char *m) { return (void *)(size_t)(fd + 1); }
int fflush(void *f) { return 0; }
int fclose(void *f) { return 0; }
unsigned long pthread_self(void) { return 1; }
struct timespec64 { long long tv_sec; long tv_nsec; };
int clock_gettime(int clk, struct timespec64 *ts) {
  long long ns = host_now_ns();
  ts->tv_sec = ns / 1000000000LL; ts->tv_nsec = ns % 1000000000LL;
  return 0;
}

// libm (subset the object imports)
static size_t n_trig, n_fma, n_minmax;
EXPORT("shim_n_trig") size_t shim_n_trig(void) { return n_trig; }
EXPORT("shim_n_fma") size_t shim_n_fma(void) { return n_fma; }
EXPORT("shim_n_minmax") size_t shim_n_minmax(void) { return n_minmax; }
float sinf(float x) { n_trig++; return host_sinf(x); }
float cosf(float x) { n_trig++; return host_cosf(x); }
float fmaxf(float a, float b) { n_minmax++; return __builtin_wasm_max_f32(a, b); }  // NaN semantics differ from C fmaxf
float fminf(float a, float b) { n_minmax++; return __builtin_wasm_min_f32(a, b); }
// fma without hardware fma: emulate via double for f32 (exact: 24+24 bits product fits in 53)
float fmaf(float a, float b, float c) { n_fma++; return (float)((double)a * (double)b + (double)c); }
double fma(double a, double b, double c) { n_fma++; return a * b + c; }  // NOT correctly rounded (probe)

// compiler-rt builtin: 128-bit multiply via 64x64 limbs
u128 __multi3(u128 a, u128 b) {
  u64 al = (u64)a, ah = (u64)(a >> 64), bl = (u64)b, bh = (u64)(b >> 64);
  u64 a0 = al & 0xffffffff, a1 = al >> 32, b0 = bl & 0xffffffff, b1 = bl >> 32;
  u64 p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  u64 mid = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff);
  u64 lo = (p00 & 0xffffffff) | (mid << 32);
  u64 hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32) + al * bh + ah * bl;
  return ((u128)hi << 64) | lo;
}

// introduced by opt -O3 (loop idiom recognition)
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
