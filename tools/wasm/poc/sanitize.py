"""Rewrite Modular (LLVM 24git) textual IR so an older llc can parse it, retargeted to wasm.
usage: python3 -I sanitize.py in.ll out.ll [wasm32|wasm64]"""
import re, sys, struct

def _f(m):
    v = struct.unpack("f", struct.pack("f", float(m.group(2))))[0]
    return m.group(1) + "0x%016X" % struct.unpack("<Q", struct.pack("<d", v))[0]

FLT = re.compile(r"(\bfloat )([-+]?\d+\.\d+e[-+]\d+)")

src, dst = sys.argv[1], sys.argv[2]
arch = sys.argv[3] if len(sys.argv) > 3 else "wasm64"
DL = {"wasm64": "e-m:e-p:64:64-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20",
      "wasm32": "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"}[arch]
out = []
for line in open(src):
    if line.startswith("target datalayout"):
        line = f'target datalayout = "{DL}"\n'
    elif line.startswith("target triple"):
        line = f'target triple = "{arch}-unknown-unknown"\n'
    elif line.startswith("attributes #"):
        line = re.sub(r'"target-(cpu|features)"="[^"]*"', "", line)
        for a in ["nocreateundeforpoison"]:
            line = line.replace(a, "")
        line = re.sub(r"\{\s*\}", '{ "wasm-sanitized" }', line)
    line = re.sub(r"/\*.*?\*/", "", line)
    line = FLT.sub(_f, line)
    line = re.sub(r"getelementptr (inbounds )?((nusw|nuw) )+", r"getelementptr \1", line)
    line = re.sub(r"\bf0x([0-9A-Fa-f]{8})\b", lambda m: "0x%016X" % struct.unpack("<Q", struct.pack("<d", struct.unpack("<f", struct.pack("<I", int(m.group(1), 16)))[0]))[0], line)
    line = re.sub(r"\bf0x([0-9A-Fa-f]{16})\b", r"0x\1", line)
    if "float" in line and "double" not in line and "half" not in line:
        line = re.sub(r"(?<![\w.%@])([-+]?\d+\.\d+e[-+]\d+)", lambda m: "0x%016X" % struct.unpack("<Q", struct.pack("<d", struct.unpack("f", struct.pack("f", float(m.group(1))))[0]))[0], line)
    line = re.sub(r"(?<![\w%@])\+inf\b", "0x7FF0000000000000", line)
    line = re.sub(r"(?<![\w%@])-inf\b", "0xFFF0000000000000", line)
    line = re.sub(r"(?<![\w%@])\+qnan\b", "0x7FF8000000000000", line)
    line = line.replace("captures(none)", "nocapture")
    line = re.sub(r"captures\([^)]*\)", "", line)
    if "@llvm.lifetime." in line:
        continue
    # x86 MXCSR (from max.algorithm.parallelize FTZ guard): no wasm equivalent; probe-only stub
    m = re.match(r"\s*call void @llvm\.x86\.sse\.stmxcsr\(ptr (%\S+)\)", line)
    if m:
        line = f"  store i32 8064, ptr {m.group(1)}, align 4\n"
    if "@llvm.x86.sse.ldmxcsr" in line or line.startswith("declare void @llvm.x86.sse.stmxcsr"):
        continue
    line = line.replace("@llvm.stepvector.", "@llvm.experimental.stepvector.")
    # EXTRA
    out.append(line)
open(dst, "w").writelines(out)
