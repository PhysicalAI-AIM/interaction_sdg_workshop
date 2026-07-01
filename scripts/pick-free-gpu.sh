#!/usr/bin/env bash
# Pick the least-used AMD GPU (0-based index).
# Honors HIP_VISIBLE_DEVICES when already set to a single GPU.
# Usage: GPU=$(scripts/pick-free-gpu.sh)
set -euo pipefail

if [ -n "${HIP_VISIBLE_DEVICES:-}" ]; then
  echo "${HIP_VISIBLE_DEVICES%%,*}"
  exit 0
fi

EXCLUDE="${WORKSHOP_EXCLUDE_GPUS:-}"

smi_out=$(rocm-smi --showmeminfo vram --showpids 2>/dev/null || true)
if [ -z "$smi_out" ]; then
  echo 0
  exit 0
fi

python3 - "$smi_out" "$EXCLUDE" <<'PY'
import re, sys

text, exclude_s = sys.argv[1], sys.argv[2]
exclude = {int(x) for x in exclude_s.split(",") if x.strip().isdigit()}

vram = {}
for m in re.finditer(r"GPU\[(\d+)\][^\n]*\nGPU\[\1\][^\n]*Used Memory \(B\): (\d+)", text):
    vram[int(m.group(1))] = int(m.group(2))
if not vram:
    for m in re.finditer(r"GPU\[(\d+)\].*Used Memory \(B\): (\d+)", text):
        vram[int(m.group(1))] = int(m.group(2))

busy = set()
for line in text.splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[0].isdigit() and parts[2].isdigit():
        busy.add(int(parts[2]))

gpus = sorted(vram.keys() or [0, 1, 2, 3])
candidates = [g for g in gpus if g not in exclude]
if not candidates:
    candidates = gpus

def score(g):
    used = vram.get(g, 0)
    # ~13MB baseline VRAM on idle MI210; treat >64MB as actively used
    heavy = g in busy or used > 64 * 1024 * 1024
    return (heavy, used, g)

print(min(candidates, key=score))
PY
