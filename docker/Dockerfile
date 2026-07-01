# syntax=docker/dockerfile:1.7
#
# Interaction-Ready SDG workshop image (CDNA3 / gfx942) — self-contained.
#
# Layers on top of the RoboSmith base runtime image and bakes in everything the
# notebook needs, so the student container runs with NO -v code/data mounts and
# NO host-path assumptions (only the GPU devices + docker.sock at runtime).
#
# All sources come from public upstream via BuildKit named build-contexts that
# scripts/build.sh fills by cloning:
#   robosmith       -> github.com/ZJLi2013/RoboSmith        (Apache/MIT, open)
#   graspgen        -> github.com/NVlabs/GraspGen            (NVIDIA research/eval license!)
#   graspgenmodels  -> hf.co/adithyamurali/GraspGenModels    (NVIDIA research/eval license!)
#
# The GraspGen code + checkpoints are NVIDIA research/eval-licensed. They are
# fetched from official upstream at build time and are NOT redistributed by this
# repo. Building this image means you accept the GraspGen license. See README.
#
# Build (driven by scripts/build.sh; context = this repo root):
#   DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile -t robotsmith:workshop-gfx942 \
#     --build-context robosmith=<RoboSmith clone> \
#     --build-context graspgen=<GraspGen clone> \
#     --build-context graspgenmodels=<GraspGenModels clone> .
ARG BASE_IMAGE=robotsmith:gfx942-rocm6.4.3-genesis0.4.5
FROM ${BASE_IMAGE}

WORKDIR /workspace/robotsmith

# RoboSmith parts pinned to the workshop upstream ref (scenarios + demo assets +
# scripts the notebook drives). Overlaying scripts also keeps the checkpoint
# converter in lockstep with this ref instead of whatever the base baked.
COPY --from=robosmith scenarios ./scenarios
COPY --from=robosmith assets ./assets
COPY --from=robosmith scripts ./scripts

# GraspGen source (on PYTHONPATH; deps already in base) + official checkpoints.
# Only the Franka Panda weights are baked — not the unused (and likewise
# research-licensed) robotiq / suction checkpoints.
COPY --from=graspgen . /workspace/GraspGen
COPY --from=graspgenmodels checkpoints/graspgen_franka_panda_gen.pth \
     checkpoints/graspgen_franka_panda_dis.pth \
     checkpoints/graspgen_franka_panda.yml \
     /workspace/GraspGenModels/checkpoints/

# Convert the Franka gen+dis checkpoints to the spconv_rocm 3D weight layout.
# graspgen_wrapper.py auto-prefers the *_rocm.pth siblings when present, so the
# config yml needs no editing.
RUN python scripts/setup/_convert_spconv_ckpt.py \
      /workspace/GraspGenModels/checkpoints/graspgen_franka_panda_gen.pth \
      /workspace/GraspGenModels/checkpoints/graspgen_franka_panda_dis.pth

# Workshop content from THIS repo. Notebook at repo root so its relative paths
# (scenarios/, scripts/, workshop/videos/, output/) all resolve from the kernel
# cwd = /workspace/robotsmith.
COPY workshop_cdna3.ipynb ./workshop_cdna3.ipynb
COPY --from=rocrobo rocRobo/samples/media/demo_compare.mp4 \
     ./workshop/videos/rocrobo_compare.mp4

# Jupyter (not a base dep) + docker CLI so the notebook can `docker exec` the
# rocRobo sidecar without mounting the host docker binary.
RUN python -m pip install --no-cache-dir notebook ipykernel \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*

# All runtime config baked in (cloud deploy: no -e / -v / host-path needed).
ENV PYTHONPATH=/workspace/GraspGen:/workspace/robotsmith \
    GRASPGEN_CONFIG=/workspace/GraspGenModels/checkpoints/graspgen_franka_panda.yml \
    ROCROBO_BACKEND=1 \
    ROCROBO_CONTAINER=rocrobo_dev \
    ROCROBO_WORKDIR=/rocrobo \
    ROCROBO_PYTHONPATH=/rocrobo/rocRobo/core \
    ROCROBO_ASSETS=/rocrobo/pyroki/examples/assets

EXPOSE 8888

# ENTRYPOINT robotsmith-headless (xvfb wrapper) is inherited from the base image.
CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--port=8888", "--no-browser", \
     "--allow-root", "--notebook-dir=/workspace/robotsmith"]
