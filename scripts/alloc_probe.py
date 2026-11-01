"""Steady-state allocations per step (ROADMAP 17.79).

Builds `benchmarks/probes/alloc_probe.mojo`, runs it with a small malloc
counter preloaded (`LD_PRELOAD`, C source below, compiled with `cc`;
malloc, calloc, realloc, the aligned forms, and the Mojo runtime's
`KGEN_CompilerRT_AlignedAlloc`, which is where `List` allocates -- it goes
to the runtime's tcmalloc, never through libc malloc), and
prints allocations per step for each scene: the probe drops a marker
(`sched_yield`, which the shim intercepts and answers by printing its
count) before and after a fixed number of warm steps.

    pixi run alloc-probe
    pixi run alloc-probe -- --sites serial   # + the top call sites of a scene
    pixi run alloc-probe -- --selftest   # parser check on synthetic output
"""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "benchmarks/probes/alloc_probe.mojo"

SHIM = r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stddef.h>
#include <stdatomic.h>
#include <execinfo.h>
static __thread int in_bt;
static atomic_long n_alloc;
/* call-site histogram for KGEN allocations (open addressing, racy but fine
   for a profile) */
#define SITES 4096
static void *site_pc[SITES];
static long site_n[SITES];
static void note(void *pc) {
    unsigned long h = ((unsigned long)pc >> 2) % SITES;
    for (int k = 0; k < SITES; k++) {
        unsigned long i = (h + k) % SITES;
        if (site_pc[i] == pc || site_pc[i] == 0) {
            site_pc[i] = pc;
            site_n[i]++;
            return;
        }
    }
}
static void *(*real_malloc)(size_t);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static int (*real_yield)(void);
static int (*real_pm)(void **, size_t, size_t);
static void *(*real_aa)(size_t, size_t);
static void *(*real_ma)(size_t, size_t);
static void *(*real_kgen)(long, long);
static char boot[4096];
static size_t boot_used;
static void init(void) {
    real_malloc = dlsym(RTLD_NEXT, "malloc");
    real_calloc = dlsym(RTLD_NEXT, "calloc");
    real_realloc = dlsym(RTLD_NEXT, "realloc");
    real_yield = dlsym(RTLD_NEXT, "sched_yield");
    real_pm = dlsym(RTLD_NEXT, "posix_memalign");
    real_aa = dlsym(RTLD_NEXT, "aligned_alloc");
    real_ma = dlsym(RTLD_NEXT, "memalign");
    real_kgen = dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedAlloc");
}
/* Mojo's own allocations (List and friends) go here, straight to the
   runtime's tcmalloc, never through libc malloc */
void *KGEN_CompilerRT_AlignedAlloc(long align, long size) {
    if (!real_kgen) init();
    atomic_fetch_add(&n_alloc, 1);
    /* the allocator is always reached through List._realloc / Dict growth:
       key the site by the frame above that (unwind-table backtrace; its
       first call may allocate, hence the guard) */
    if (!in_bt) {
        void *bt[4];
        in_bt = 1;
        int n = backtrace(bt, 4);
        in_bt = 0;
        note(n >= 3 ? bt[2] : __builtin_return_address(0));
    }
    return real_kgen(align, size);
}
int posix_memalign(void **p, size_t a, size_t n) {
    if (!real_pm) init();
    atomic_fetch_add(&n_alloc, 1);
    return real_pm(p, a, n);
}
void *aligned_alloc(size_t a, size_t n) {
    if (!real_aa) init();
    atomic_fetch_add(&n_alloc, 1);
    return real_aa(a, n);
}
void *memalign(size_t a, size_t n) {
    if (!real_ma) init();
    atomic_fetch_add(&n_alloc, 1);
    return real_ma(a, n);
}
void *malloc(size_t n) {
    if (!real_malloc) init();
    atomic_fetch_add(&n_alloc, 1);
    return real_malloc(n);
}
void *calloc(size_t a, size_t b) {
    if (!real_calloc) {
        /* dlsym itself may calloc: serve it from a static buffer */
        size_t n = (a * b + 15) & ~(size_t)15;
        void *p = boot + boot_used;
        boot_used += n;
        return p;
    }
    atomic_fetch_add(&n_alloc, 1);
    return real_calloc(a, b);
}
void *realloc(void *p, size_t n) {
    if (!real_realloc) init();
    atomic_fetch_add(&n_alloc, 1);
    return real_realloc(p, n);
}
int sched_yield(void) {
    if (!real_yield) init();
    printf("MARK %ld\n", atomic_load(&n_alloc));
    for (int i = 0; i < SITES; i++)
        if (site_pc[i]) {
            Dl_info di;
            long off = 0;
            const char *f = "?";
            if (dladdr(site_pc[i], &di) && di.dli_fbase) {
                off = (long)((char *)site_pc[i] - (char *)di.dli_fbase);
                f = di.dli_fname;
            }
            printf("SITE %s+0x%lx %ld\n", f, off, site_n[i]);
        }
    fflush(stdout);
    return 0;
}
"""


def sites(text, scene):
    """{pc: allocations between the two marks of `scene`}"""
    snaps = []
    cur = None
    snap = None
    for l in text.splitlines():
        if l.startswith("SCENE "):
            cur = l.split()[1]
        elif l.startswith("MARK "):
            snap = {}
            snaps.append((cur, snap))
        elif l.startswith("SITE ") and snap is not None:
            _, pc, n = l.split()
            snap[pc] = int(n)
    mine = [sn for name, sn in snaps if name == scene]
    if len(mine) < 2:
        return {}
    a, b = mine[0], mine[1]
    return {pc: b[pc] - a.get(pc, 0) for pc in b if b[pc] - a.get(pc, 0) > 0}


def parse(text):
    """[(scene, allocations between its two marks)], steps"""
    steps = 1
    out = []
    cur = None
    marks = []
    for l in text.splitlines():
        if l.startswith("STEPS "):
            steps = int(l.split()[1])
        elif l.startswith("SCENE "):
            cur = l.split()[1]
        elif l.startswith("MARK "):
            marks.append((cur, int(l.split()[1])))
    for i in range(0, len(marks) - 1, 2):
        out.append((marks[i][0], marks[i + 1][1] - marks[i][1]))
    return out, steps


def main():
    if "--selftest" in sys.argv:
        r, s = parse("STEPS 10\nSCENE a\nMARK 5\nSCENE a\nMARK 25\nSCENE b\nMARK 30\nSCENE b\nMARK 30\n")
        assert s == 10 and r == [("a", 20), ("b", 0)]
        print("alloc-probe selftest: 1 / 1")
        return
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, "shim.c")
        so = os.path.join(d, "shim.so")
        exe = os.path.join(d, "alloc")
        with open(c, "w") as f:
            f.write(SHIM)
        subprocess.run(["cc", "-O2", "-shared", "-fPIC", c, "-o", so, "-ldl"], check=True)
        cpu = ["--target-cpu", "x86-64"] if os.uname().machine == "x86_64" else []
        subprocess.run(["mojo", "build"] + cpu + ["-I", "build", PROBE, "-o", exe], cwd=ROOT, check=True)
        env = dict(os.environ, LD_PRELOAD=so)
        r = subprocess.run([exe], cwd=ROOT, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("alloc-probe: run failed: " + r.stderr[-300:])
        res, steps = parse(r.stdout)
        print("| scene | allocations per step |")
        print("|---|---:|")
        for name, n in res:
            print("| %s | %.1f |" % (name, n / steps))
        if "--sites" in sys.argv:
            scene = sys.argv[sys.argv.index("--sites") + 1]
            top = sorted(sites(r.stdout, scene).items(), key=lambda kv: -kv[1])[:15]
            names = []
            for pc, _ in top:
                f, off = pc.rsplit("+", 1)
                if f.endswith("/alloc") or f == exe:
                    out = subprocess.run(["addr2line", "-f", "-C", "-e", exe, off], capture_output=True, text=True).stdout.split("\n")
                    names.append(out[0])
                else:
                    names.append(os.path.basename(f) + "+" + off)
            print("\ntop allocation sites in '%s' (per step):" % scene)
            for (pc, n), fn in zip(top, names):
                print("  %7.1f  %s" % (n / steps, fn[:150]))


if __name__ == "__main__":
    main()
