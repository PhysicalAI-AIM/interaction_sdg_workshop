#!/usr/bin/env bash
#
# Build the two self-contained workshop images from PUBLIC upstream only.
# Run on a gfx942 (MI300/MI325) node with: docker + BuildKit, git, git-lfs, internet.
#
# Everything is fetched from official upstream here — no host-path assumptions,
# no vendored copies. The only license gate is GraspGen:
#
#   GraspGen (NVlabs/GraspGen) and its checkpoints (hf.co/adithyamurali/
#   GraspGenModels) are NVIDIA research/eval-licensed. This script fetches them
#   from official upstream at build time and bakes them into a LOCAL image; it
#   does not redistribute them. By running this you accept the GraspGen license.
#
# Override any URL/ref via env vars if you mirror these repos.
set -euo pipefail

ROBOSMITH_URL=${ROBOSMITH_URL:-https://github.com/ZJLi2013/RoboSmith}
ROCROBO_URL=${ROCROBO_URL:-https://github.com/ZJLi2013/rocRobo}
GRASPGEN_URL=${GRASPGEN_URL:-https://github.com/NVlabs/GraspGen}
GRASPGENMODELS_URL=${GRASPGENMODELS_URL:-https://huggingface.co/adithyamurali/GraspGenModels}
ROBOSMITH_REF=${ROBOSMITH_REF:-main}
ROCROBO_REF=${ROCROBO_REF:-main}

BASE_IMAGE=${BASE_IMAGE:-robotsmith:gfx942-rocm6.4.3-genesis0.4.5}
WORKSHOP_IMAGE=${WORKSHOP_IMAGE:-robotsmith:workshop-gfx942}
ROCROBO_IMAGE=${ROCROBO_IMAGE:-rocrobo:workshop-gfx942}

HERE=$(cd "$(dirname "$0")/.." && pwd)   # repo root
WORK=${WORK:-$HERE/.build}
mkdir -p "$WORK"
export DOCKER_BUILDKIT=1

clone() {  # url dir [ref]
  local url=$1 dir=$2 ref=${3:-}
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --depth 1 origin "${ref:-HEAD}"
    [ -n "$ref" ] && git -C "$dir" checkout -q "$ref" || true
    git -C "$dir" pull --ff-only || true
  else
    git clone ${ref:+--branch "$ref"} --depth 1 "$url" "$dir"
  fi
}

echo "==> [1/5] clone open deps (RoboSmith, rocRobo)"
clone "$ROBOSMITH_URL" "$WORK/RoboSmith" "$ROBOSMITH_REF"
clone "$ROCROBO_URL"   "$WORK/rocRobo"   "$ROCROBO_REF"

echo "==> [2/5] clone GraspGen + checkpoints (NVIDIA research/eval license)"
clone "$GRASPGEN_URL" "$WORK/GraspGen"
if [ ! -f "$WORK/GraspGenModels/checkpoints/graspgen_franka_panda_gen.pth" ]; then
  git lfs install
  git clone "$GRASPGENMODELS_URL" "$WORK/GraspGenModels"
fi

echo "==> [3/5] base RoboSmith runtime image ($BASE_IMAGE)"
docker build -f "$WORK/RoboSmith/docker/Dockerfile.gfx942" \
  -t "$BASE_IMAGE" "$WORK/RoboSmith"

echo "==> [4/5] rocRobo sidecar image ($ROCROBO_IMAGE)"
docker build -f "$HERE/docker/Dockerfile.rocrobo" \
  -t "$ROCROBO_IMAGE" "$WORK/rocRobo"

echo "==> [5/5] RoboSmith workshop image ($WORKSHOP_IMAGE)"
docker build -f "$HERE/docker/Dockerfile" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$WORKSHOP_IMAGE" \
  --build-context "robosmith=$WORK/RoboSmith" \
  --build-context "graspgen=$WORK/GraspGen" \
  --build-context "graspgenmodels=$WORK/GraspGenModels" \
  "$HERE"

echo
echo "DONE."
echo "  workshop : $WORKSHOP_IMAGE"
echo "  sidecar  : $ROCROBO_IMAGE"
echo "Deploy: see README 'Deploy / Run'."
