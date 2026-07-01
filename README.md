# interaction_sdg_workshop

**Real2Sim for Embodied Data Generation** — *Generating Interaction-Ready Data for
Long-Horizon Articulated Manipulation*. Live Jupyter workshop for **AAI Day 2026**.

Single hardware path: **AMD CDNA3 (MI300 / MI325, `gfx942`)**. Scope is **data
generation only** — declare a long-horizon articulated task with Code-as-Policy
(`open → pick → place → close`, a drawer), plan collision-free motion with rocRobo,
and emit an interaction-ready LeRobot dataset. No training / eval here.

This repo is **glue only**: a notebook, two Dockerfiles, and a build script. Every
heavy dependency is fetched from its official upstream at build time — nothing is
vendored or hard-coded to a local path, so the images deploy cleanly to the cloud.

---

## Dependency provenance (boundary)

| Dependency | Source | License | Baked by |
|---|---|---|---|
| RoboSmith (SDG engine, CAP, scenarios, assets) | `github.com/ZJLi2013/RoboSmith` | open | base + workshop image |
| rocRobo (collision-free motion) | `github.com/ZJLi2013/rocRobo` | open | sidecar image **or** all-inone image |
| spconv_rocm (ROCm sparse-conv for GraspGen) | `github.com/ZJLi2013/spconv_rocm` | open | base image |
| Genesis 0.4.5 (pinned), LeRobot 0.4.4 | PyPI / GitHub | open | base image |
| Base runtime | `rocm/pytorch:rocm6.4.3_…_pytorch_2.6.0` | open | base image |
| **GraspGen (learned grasp)** | `github.com/NVlabs/GraspGen` | **NVIDIA research/eval only** | workshop image |
| **GraspGen checkpoints** | `hf.co/adithyamurali/GraspGenModels` | **NVIDIA research/eval only** | workshop image |

> ⚠️ **GraspGen license.** Every `pick` in this workshop uses the learned grasp
> planner; in RoboSmith the grasp strategy is `{learned (GraspGen), none}` with no
> analytic fallback, so **GraspGen is a hard dependency**. GraspGen and its
> checkpoints are **NVIDIA research/eval-licensed** (not commercial). `build.sh`
> fetches them from official upstream at build time and bakes them into a *local*
> image — this repo does **not** redistribute them. Building/using the workshop
> image means you accept the GraspGen license. This is the workshop's one
> non-open boundary; everything else is open ROCm.

---

## Layout

```
interaction_sdg_workshop/
├── README.md
├── workshop_cdna3.ipynb       ← the live notebook (gen-only)
├── docker/
│   ├── Dockerfile             ← RoboSmith workshop image (FROM base; bakes repo+GraspGen+ckpt)
│   ├── Dockerfile.allinone    ← ★ single-image deploy (no docker.sock / sidecar)
│   ├── Dockerfile.rocrobo     ← rocRobo motion sidecar image (bakes rocRobo source)
│   ├── rocrobo-serve-local.sh ← all-in-one: spawn warm serve subprocess
│   └── patches/rocrobo_backend.py
├── scripts/
│   ├── build.sh               ← clones all upstream + builds the 3 images
│   └── build-allinone.sh      ← ★ builds one self-contained image
├── videos/rocrobo_compare.mp4 ← collision-blind vs -aware clip (notebook §4)
└── images/                    ← inspection fallbacks
```

---

## All-in-one deploy (recommended for MLOps)

For platforms that should not mount `docker.sock` (K8S, managed notebook, batch
Job), use the **single-image** path. RoboSmith (torch) and rocRobo (jax) still
run as **separate processes** inside one container — only the orchestration
changes (`ROCROBO_LAUNCH=local` subprocess instead of `docker exec`).

```bash
bash scripts/build-allinone.sh
```

Produces one image: `robotsmith:workshop-gfx942-allinone`

```bash
docker rm -f workshop_allinone 2>/dev/null || true
docker run -d --name workshop_allinone -p 8888:8888 \
  --device=/dev/kfd --device=/dev/dri --group-add video \
  --security-opt seccomp=unconfined --ipc=host --shm-size=24g \
  -e HIP_VISIBLE_DEVICES=0 \
  robotsmith:workshop-gfx942-allinone
```

Baked in: RoboSmith scenarios/assets/scripts, GraspGen + checkpoints, rocRobo
source, bundled JAX python prefix (`/opt/rocrobo`), notebook, compare video.
**No runtime mounts** (GPU devices only).

### Autoloop validation

After build, run the full smoke + datagen suite:

```bash
bash scripts/autoloop.sh 2>&1 | tee .build/autoloop.log
# status summary: .build/AUTOLOOP_STATUS.md
```

| | Two-container (`build.sh`) | All-in-one (`build-allinone.sh`) |
|---|---|---|
| Images | 3 (base + workshop + sidecar) | 2 (base + allinone) |
| `docker.sock` | required | **not needed** |
| rocRobo launch | `docker exec` sidecar | local subprocess |
| Image size | smaller per image | larger (~+jax stack) |

> The all-in-one image copies a ROCm 7.2 JAX prefix to `/opt/rocm-jax` and only
> exposes it to the rocRobo serve subprocess, so torch keeps the gfx942-pinned
> ROCm 6.4 stack. Validate on target MI300/MI325 hardware before production rollout.

---

## Teacher / Admin Setup (two-container workshop)

Prereqs on a `gfx942` node: `docker` (BuildKit), `git`, `git-lfs`, internet.

### 1. Build the images (one command)

```bash
bash scripts/build.sh
```

It clones RoboSmith / rocRobo / GraspGen + downloads the GraspGen checkpoints into
`./.build/`, then builds three images:

- `robotsmith:gfx942-rocm6.4.3-genesis0.4.5` — base runtime (RoboSmith `docker/Dockerfile.gfx942`)
- `robotsmith:workshop-gfx942` — workshop image: repo + scenarios + assets + GraspGen
  source + rocm-converted checkpoints + notebook + compare video, all baked in
- `rocrobo:workshop-gfx942` — rocRobo motion sidecar, source baked in

> The base image pins the gfx942-validated old stack (ROCm 6.4.3 + Genesis 0.4.5,
> `HSA_OVERRIDE_GFX_VERSION=9.4.2`) because Genesis 1.0 segfaults on gfx942's
> collision-kernel codegen. The GraspGen Franka checkpoints are converted to the
> spconv_rocm 3D layout during the build; the loader auto-prefers the `*_rocm.pth`
> siblings, so no config editing is needed.

### 2. Deploy / Run (no code/data mounts)

```bash
# 2a. rocRobo sidecar (source already in the image — no -v)
docker rm -f rocrobo_dev 2>/dev/null || true
docker run -d --name rocrobo_dev \
  --device=/dev/kfd --device=/dev/dri --group-add video --ipc=host \
  -e AMD_COMGR_NAMESPACE=1 -e HIP_VISIBLE_DEVICES=0 \
  -e XLA_PYTHON_CLIENT_PREALLOCATE=false \
  rocrobo:workshop-gfx942 sleep infinity

# warmup smoke (first jax load)
docker exec -i -w /rocrobo \
  -e PYTHONPATH=/rocrobo/rocRobo/core \
  -e ROCROBO_ASSETS=/rocrobo/pyroki/examples/assets \
  rocrobo_dev python -u -c "import rocrobo; print('rocrobo_ok')"

# 2b. RoboSmith + Jupyter (student entry). All env baked in; only docker.sock
#     is mounted so the notebook can `docker exec` the sidecar.
docker rm -f workshop_drawer 2>/dev/null || true
docker run -d --name workshop_drawer -p 8888:8888 \
  --device=/dev/kfd --device=/dev/dri --group-add video \
  --security-opt seccomp=unconfined --ipc=host --shm-size=24g \
  -e HIP_VISIBLE_DEVICES=0 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  robotsmith:workshop-gfx942
```

> **The only runtime mount is `docker.sock`** (fixed, well-known path — consistent
> across hosts). It's required because jax (rocRobo) and torch (RoboSmith) cannot
> share one process, so the notebook drives the sidecar via `docker exec`. If your
> cloud forbids container access to the docker daemon, the orchestrator must place
> both containers on one host and allow the socket. There are **no** code/data or
> host-path mounts.

---

## Student Quick Start

1. Open `workshop_cdna3.ipynb` (it sits at the working dir root inside the image).
2. Run cells in order — the image has everything pre-installed; outputs land in `output/`.

Notebook flow: env check → Real2Sim assets → CAP declare → why rocRobo → live
generate one episode → open the result → swap a scenario / edit one CAP line →
takeaway.

---

## Notes

- This workshop pairs with an earlier, independent AMD ROCm SDG workshop
  (`github.com/AMD-AIM/Robot_synthetic_data_generation_workshop`) that covered
  rigid pick → SDG → train → eval. That is a separate event; no shared state.
- Pin a specific commit for a reproducible build via `ROBOSMITH_REF` / `ROCROBO_REF`
  env vars to `scripts/build.sh`.
