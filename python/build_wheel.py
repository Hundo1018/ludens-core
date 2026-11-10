#!/usr/bin/env python3
"""Build the `ludens` wheel (ROADMAP 17.21).

    pixi run wheel                      # -> build/dist/ludens-<ver>-py3-none-linux_<machine>.whl
    python3 python/build_wheel.py --out DIR [--lib PATH]

Steps:
1. `mojo build --emit shared-lib` of embed/capi.mojo into the staging dir
   (or take a prebuilt library with --lib).
2. Bundle every shared library it loads that does not come from the system
   (`ldd` paths outside /lib, /lib64, /usr/lib): the Mojo runtime and the
   C++ runtime it was built with (the runtime needs GLIBCXX_3.4.30, newer
   than some host distributions ship). They already carry an `$ORIGIN`
   RPATH. Copies are stripped of debug sections when `strip` exists.
3. Rewrite libludens.so's RUNPATH (which the Mojo linker points at the build
   machine's toolchain directory) to `$ORIGIN`, in place. No patchelf needed:
   the new string is shorter, so it is written over the old one and padded
   with NULs.
4. Write a py3-none-linux_<machine> wheel (x86_64 or aarch64, the build
   machine's; zip + METADATA / WHEEL / RECORD). The package is pure ctypes,
   so the wheel works with any CPython 3.8+.

Linux only: steps 2 and 3 are ELF / `ldd` work. On another OS (macOS) it
exits with a message naming that, instead of failing inside `ldd`
(ROADMAP 17.76).

The wheel carries LICENSE-MIT, LICENSE-APACHE and NOTICE in its dist-info;
NOTICE records the terms the bundled Mojo / MAX runtime is redistributed
under (ROADMAP 17.81).
"""

import argparse
import base64
import platform
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYSTEM_DIRS = ("/lib/", "/lib64/", "/usr/lib/", "/usr/lib64/")
PT_LOAD, PT_DYNAMIC = 1, 2
DT_NULL, DT_NEEDED, DT_STRTAB, DT_SONAME, DT_RPATH, DT_RUNPATH = 0, 1, 5, 14, 15, 29


def read_version():
    src = open(os.path.join(ROOT, "python", "ludens", "__init__.py")).read()
    return re.search(r'__version__ = "([^"]+)"', src).group(1)


def set_runpath_origin(path):
    """Replace DT_RUNPATH / DT_RPATH of an ELF64 little-endian file with `$ORIGIN`."""
    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("%s: not an ELF64 little-endian file" % path)
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    loads, dyn = [], None
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from("<IIQQQQ", data, off)
        if p_type == PT_LOAD:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == PT_DYNAMIC:
            dyn = (p_offset, p_filesz)
    if dyn is None:
        raise SystemExit("%s: no PT_DYNAMIC" % path)
    entries = []
    for k in range(dyn[1] // 16):
        tag, val = struct.unpack_from("<qQ", data, dyn[0] + 16 * k)
        if tag == DT_NULL:
            break
        entries.append((tag, val))
    strtab_vaddr = next(v for t, v in entries if t == DT_STRTAB)
    strtab = next(off + (strtab_vaddr - va) for va, off, sz in loads if va <= strtab_vaddr < va + sz)
    patched = 0
    for tag, val in entries:
        if tag not in (DT_RUNPATH, DT_RPATH):
            continue
        start = strtab + val
        end = data.index(b"\x00", start)
        new = b"$ORIGIN"
        if end - start < len(new):
            raise SystemExit("%s: RUNPATH shorter than $ORIGIN" % path)
        for t2, v2 in entries:
            if t2 in (DT_NEEDED, DT_SONAME) and val < v2 < val + (end - start):
                raise SystemExit("%s: another dynamic string shares the RUNPATH bytes" % path)
        data[start:end] = new + b"\x00" * (end - start - len(new))
        patched += 1
    if not patched:
        raise SystemExit("%s: no RUNPATH / RPATH entry" % path)
    open(path, "wb").write(bytes(data))


def bundled_deps(lib):
    out = subprocess.run(["ldd", lib], capture_output=True, text=True, check=True).stdout
    deps = []
    for line in out.splitlines():
        m = re.match(r"\s*(\S+) => (/\S+)", line)
        if m and not m.group(2).startswith(SYSTEM_DIRS):
            deps.append((m.group(1), m.group(2)))
        elif "not found" in line:
            raise SystemExit("ldd: unresolved dependency: " + line.strip())
    return deps


def record_line(arc, payload):
    digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).rstrip(b"=").decode()
    return "%s,sha256=%s,%d" % (arc, digest, len(payload))


LINUX_ONLY = "build_wheel: Linux only (ldd + ELF RUNPATH rewrite); no wheel for "


def build(out_dir, prebuilt=None):
    if not sys.platform.startswith("linux"):
        raise SystemExit(LINUX_ONLY + sys.platform)
    version = read_version()
    stage = tempfile.mkdtemp(prefix="ludens_wheel_")
    pkg = os.path.join(stage, "ludens")
    shutil.copytree(os.path.join(ROOT, "python", "ludens"), pkg, ignore=shutil.ignore_patterns("__pycache__", "*.so"))
    lib = os.path.join(pkg, "libludens.so")
    if prebuilt:
        shutil.copy2(prebuilt, lib)
    else:
        subprocess.run(["mojo", "build", "--emit", "shared-lib", *(["--target-cpu", "x86-64"] if os.uname().machine == "x86_64" else []), "-I", "build", "-o", lib, "embed/capi.mojo"], cwd=ROOT, check=True)
    for name, src in bundled_deps(lib):
        dst = os.path.join(pkg, name)
        shutil.copy2(os.path.realpath(src), dst)
        if shutil.which("strip"):
            # debug sections only: the toolchain's libstdc++ is 24 MB unstripped, 2.8 MB stripped
            subprocess.run(["strip", "--strip-unneeded", dst], check=True)
    set_runpath_origin(lib)

    dist = "ludens-%s.dist-info" % version
    meta = (
        "Metadata-Version: 2.1\nName: ludens\nVersion: %s\n"
        "Summary: Python bindings for ludens-core (ctypes over the frozen C-ABI)\n"
        "Requires-Python: >=3.8\n"
        "License: MIT OR Apache-2.0\n" % version
    )
    tag = "py3-none-linux_" + platform.machine()
    wheel_meta = "Wheel-Version: 1.0\nGenerator: ludens build_wheel.py\nRoot-Is-Purelib: false\nTag: %s\n" % tag
    os.makedirs(out_dir, exist_ok=True)
    whl = os.path.join(out_dir, "ludens-%s-%s.whl" % (version, tag))
    records = []
    with zipfile.ZipFile(whl, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(pkg)):
            full = os.path.join(pkg, name)
            payload = open(full, "rb").read()
            info = zipfile.ZipInfo("ludens/" + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = (0o755 if name.endswith(".so") else 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, payload)
            records.append(record_line("ludens/" + name, payload))
        for lic in ("LICENSE-MIT", "LICENSE-APACHE", "NOTICE"):
            payload = open(os.path.join(ROOT, lic), "rb").read()
            z.writestr(dist + "/" + lic, payload)
            records.append(record_line(dist + "/" + lic, payload))
        for name, text in (("METADATA", meta), ("WHEEL", wheel_meta)):
            payload = text.encode()
            z.writestr(dist + "/" + name, payload)
            records.append(record_line(dist + "/" + name, payload))
        records.append(dist + "/RECORD,,")
        z.writestr(dist + "/RECORD", "\n".join(records) + "\n")
    shutil.rmtree(stage)
    return whl


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "dist"))
    ap.add_argument("--lib", default=None, help="prebuilt libludens.so instead of building one")
    a = ap.parse_args()
    print(build(a.out, a.lib))


if __name__ == "__main__":
    sys.exit(main())
