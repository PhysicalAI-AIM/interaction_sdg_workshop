#!/usr/bin/env bash
#
# Build the all-in-one workshop image (single container, no docker.sock).
#
# Produces: robotsmith:workshop-gfx942-allinone
#
# Same upstream clones as build.sh; also builds the RoboSmith base image when
# missing. GraspGen license gate applies — see README.
set -euo pipefail

ROBOSMITH_URL=${ROBOSMITH_URL:-https://github.com/ZJLi2013/RoboSmith}
ROCROBO_URL=${ROCROBO_URL:-https://github.com/ZJLi2013/rocRobo}
GRASPGEN_URL=${GRASPGEN_URL:-https://github.com/NVlabs/GraspGen}
GRASPGENMODELS_URL=${GRASPGENMODELS_URL:-https://huggingface.co/adithyamurali/GraspGenModels}
ROBOSMITH_REF=${ROBOSMITH_REF:-main}
ROCROBO_REF=${ROCROBO_REF:-main}

BASE_IMAGE=${BASE_IMAGE:-robotsmith:gfx942-rocm6.4.3-genesis0.4.5}
ALLINONE_IMAGE=${ALLINONE_IMAGE:-robotsmith:workshop-gfx942-allinone}
ROCROBO_BASE=${ROCROBO_BASE:-rocm/jax:rocm7.2.4-jax0.8.2-py3.12}

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$HERE/.build}
mkdir -p "$WORK"
export DOCKER_BUILDKIT=1

clone() {
  local url=$1 dir=$2 ref=${3:-}
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --depth 1 origin "${ref:-HEAD}"
    [ -n "$ref" ] && git -C "$dir" checkout -q "$ref" || true
    git -C "$dir" pull --ff-only || true
  else
    git clone ${ref:+--branch "$ref"} --depth 1 "$url" "$dir"
  fi
}

init_rocrobo() {
  git -C "$WORK/rocRobo" submodule update --init --recursive
}

prepare_robosmith() {
  # Upstream Dockerfile.gfx942 COPY tests/ but the public tree may omit it.
  mkdir -p "$WORK/RoboSmith/tests"
}

echo "==> [1/4] clone upstream (RoboSmith, rocRobo)"
clone "$ROBOSMITH_URL" "$WORK/RoboSmith" "$ROBOSMITH_REF"
clone "$ROCROBO_URL"   "$WORK/rocRobo"   "$ROCROBO_REF"
init_rocrobo
prepare_robosmith

echo "==> [2/4] clone GraspGen + checkpoints (NVIDIA research/eval license)"
clone "$GRASPGEN_URL" "$WORK/GraspGen"
if [ ! -f "$WORK/GraspGenModels/checkpoints/graspgen_franka_panda_gen.pth" ]; then
  git lfs install
  git clone "$GRASPGENMODELS_URL" "$WORK/GraspGenModels"
fi

echo "==> [3/4] base RoboSmith runtime ($BASE_IMAGE)"
if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  docker build -f "$WORK/RoboSmith/docker/Dockerfile.gfx942" \
    -t "$BASE_IMAGE" "$WORK/RoboSmith"
else
  echo "    (base image already present, skipping)"
fi

echo "==> [4/4] all-in-one workshop image ($ALLINONE_IMAGE)"
docker build -f "$HERE/docker/Dockerfile.allinone" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "ROCROBO_BASE=$ROCROBO_BASE" \
  -t "$ALLINONE_IMAGE" \
  --build-context "robosmith=$WORK/RoboSmith" \
  --build-context "rocrobo=$WORK/rocRobo" \
  --build-context "graspgen=$WORK/GraspGen" \
  --build-context "graspgenmodels=$WORK/GraspGenModels" \
  "$HERE"

echo
echo "DONE."
echo "  all-in-one : $ALLINONE_IMAGE"
echo
echo "Run (single container, no docker.sock):"
cat <<EOF

  docker rm -f workshop_allinone 2>/dev/null || true
  docker run -d --name workshop_allinone -p 8888:8888 \\
    --device=/dev/kfd --device=/dev/dri --group-add video \\
    --security-opt seccomp=unconfined --ipc=host --shm-size=24g \\
    -e HIP_VISIBLE_DEVICES=0 \\
    $ALLINONE_IMAGE

EOF
