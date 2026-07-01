#!/usr/bin/env bash
# Autoloop: validate all-in-one image end-to-end.
#   bash scripts/autoloop.sh 2>&1 | tee .build/autoloop.log
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD_LOG="$HERE/.build/autoloop.log"
STATUS="$HERE/.build/AUTOLOOP_STATUS.md"
ALLINONE_IMAGE=${ALLINONE_IMAGE:-robotsmith:workshop-gfx942-allinone}
CONTAINER=${CONTAINER:-workshop_allinone}
PORT=${PORT:-8888}
FORCE_REBUILD=${FORCE_REBUILD:-0}
RUN_HERO=${RUN_HERO:-1}
RUN_SUPPORTER=${RUN_SUPPORTER:-1}

mkdir -p "$HERE/.build"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$BUILD_LOG"; }

write_status() {
  cat > "$STATUS" <<EOF
# Autoloop Status

**Updated:** $(date -Iseconds)

$1
EOF
}

# ---------------------------------------------------------------------------
# Phase 0: Build (optional)
# ---------------------------------------------------------------------------
if [ "$FORCE_REBUILD" = "1" ] || ! docker image inspect "$ALLINONE_IMAGE" >/dev/null 2>&1; then
  log "Phase 0: building $ALLINONE_IMAGE"
  bash "$HERE/scripts/build-allinone.sh" 2>&1 | tee -a "$BUILD_LOG"
else
  log "Phase 0: skip build — $ALLINONE_IMAGE present"
fi

# ---------------------------------------------------------------------------
# Phase 1: Run container (all GPUs visible; per-job picks a free card)
# ---------------------------------------------------------------------------
PICK_GPU_SCRIPT="$HERE/scripts/pick-free-gpu.sh"

log "Phase 1: start container $CONTAINER (all GPUs; set HIP_VISIBLE_DEVICES to pin)"
docker rm -f "$CONTAINER" 2>/dev/null || true
RUN_ARGS=(
  -d --name "$CONTAINER" -p "${PORT}:8888"
  --device=/dev/kfd --device=/dev/dri --group-add video
  --security-opt seccomp=unconfined --ipc=host --shm-size=24g
)
if [ -n "${HIP_VISIBLE_DEVICES:-}" ]; then
  RUN_ARGS+=(-e "HIP_VISIBLE_DEVICES=$HIP_VISIBLE_DEVICES")
  log "Phase 1: container pinned to GPU $HIP_VISIBLE_DEVICES"
fi
docker run "${RUN_ARGS[@]}" "$ALLINONE_IMAGE"
sleep 12

# ---------------------------------------------------------------------------
# Phase 2: Smoke
# ---------------------------------------------------------------------------
log "Phase 2: smoke tests"
SMOKE="$HERE/.build/smoke-results.txt"
{
  echo "=== torch GPU ==="
  docker exec "$CONTAINER" python -c "
import torch, os
print('torch', torch.__version__)
print('cuda', torch.cuda.is_available())
if torch.cuda.is_available(): print('device', torch.cuda.get_device_name(0))
print('ROCROBO_LAUNCH', os.environ.get('ROCROBO_LAUNCH'))
"

  echo "=== bundled assets ==="
  docker exec "$CONTAINER" bash -c '
for f in \
  /rocrobo/rocRobo/core/rocrobo/serve.py \
  /usr/local/bin/rocrobo-serve-local \
  /opt/rocrobo/lib/python3.12/dist-packages/jax/__init__.py \
  /workspace/GraspGenModels/checkpoints/graspgen_franka_panda_gen_rocm.pth \
  /workspace/robotsmith/scenarios/pick_place_into_drawer.py; do
  test -e "$f" && echo "ok $f" || echo "MISSING $f"
done
'

  echo "=== jupyter ==="
  docker exec "$CONTAINER" curl -sf -o /dev/null -w "http %{http_code}\n" http://127.0.0.1:8888/ || echo "jupyter_fail"

  echo "=== RocRoboBackend (local subprocess) ==="
  docker exec "$CONTAINER" timeout 360 python -c "
from robotsmith.motion.rocrobo_backend import get_serve_client
c = get_serve_client()
resp = c.request({'op': 'solve_ik', 'pos': [0.5, 0.0, 0.3], 'quat': [0, 1, 0, 0], 'world': []})
print('backend_ok', 'q' in resp, 'ok=', resp.get('ok'))
"

} | tee "$SMOKE"

# ---------------------------------------------------------------------------
# Phase 3: Snapshot (fast visual sanity)
# ---------------------------------------------------------------------------
log "Phase 3: snapshot scenario"
docker exec -w /workspace/robotsmith "$CONTAINER" \
  timeout 1200 python scripts/datagen/snapshot_scenario.py \
    --scenario scenarios/pick_place_into_drawer.py \
    --out output/autoloop_snapshot \
    --seed 42 2>&1 | tee -a "$BUILD_LOG" || log "snapshot: failed"

# ---------------------------------------------------------------------------
# Phase 4: Datagen scenarios
# ---------------------------------------------------------------------------
run_datagen() {
  local scenario=$1 out=$2 timeout_s=${3:-1800}
  local gpu="${DATAGEN_GPU:-}"
  if [ -z "$gpu" ] && [ -x "$PICK_GPU_SCRIPT" ]; then
    gpu=$("$PICK_GPU_SCRIPT")
  fi
  log "Phase 4: datagen $scenario -> $out (timeout ${timeout_s}s, GPU=${gpu:-default})"
  docker exec -w /workspace/robotsmith ${gpu:+-e HIP_VISIBLE_DEVICES="$gpu"} "$CONTAINER" \
    timeout "$timeout_s" python scripts/datagen/run_generated_scenario.py \
      --scenario "$scenario" \
      --output-dir "$out" \
      --n-episodes 1 --seed 42 \
      --grasp-planner auto --smoke \
    2>&1 | tee -a "$BUILD_LOG" && log "datagen OK: $scenario" || log "datagen FAIL: $scenario"
}

run_datagen scenarios/pick_one_of_three.py output/autoloop_pick_three 1200

if [ "$RUN_SUPPORTER" = "1" ]; then
  run_datagen scenarios/pick_place_onto_supporter.py output/autoloop_supporter 2400
fi

if [ "$RUN_HERO" = "1" ]; then
  run_datagen scenarios/pick_place_into_drawer.py output/autoloop_hero_drawer 7200
fi

# ---------------------------------------------------------------------------
# Phase 5: Collect outputs
# ---------------------------------------------------------------------------
log "Phase 5: collect outputs"
docker exec "$CONTAINER" find /workspace/robotsmith/output -name '*.mp4' -o -name 'scenario_run_summary.json' 2>/dev/null \
  | tee "$HERE/.build/autoloop-artifacts.txt" || true

SUMMARY=$(cat <<EOF
## Image
- \`$ALLINONE_IMAGE\` $(docker images "$ALLINONE_IMAGE" --format '{{.Size}}' 2>/dev/null || echo n/a)

## Container
- \`$CONTAINER\` $(docker ps --filter name="$CONTAINER" --format '{{.Status}}' 2>/dev/null || echo not running)

## Smoke
\`\`\`
$(tail -20 "$SMOKE" 2>/dev/null || echo n/a)
\`\`\`

## Generated artifacts
\`\`\`
$(cat "$HERE/.build/autoloop-artifacts.txt" 2>/dev/null || echo none)
\`\`\`

## Full log
- \`.build/autoloop.log\`
EOF
)
write_status "$SUMMARY"
log "Autoloop complete — see $STATUS"
