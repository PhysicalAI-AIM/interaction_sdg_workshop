#!/usr/bin/env bash
# Launch rocRobo warm serve inside the all-in-one container (no docker exec).
#
# Uses the system python3.12 + a bundled JAX site-packages tree copied from the
# rocRobo build stage, with ROCm 7.2 libs isolated under /opt/rocm-jax.
set -euo pipefail

export ROCROBO_ASSETS="${ROCROBO_ASSETS:-/rocrobo/pyroki/examples/assets}"
export PYTHONPATH="/rocrobo/pyroki/src:${ROCROBO_PYTHONPATH:-/rocrobo/rocRobo/core}:/opt/rocrobo/lib/python3.12/dist-packages"
export XLA_PYTHON_CLIENT_PREALLOCATE="${XLA_PYTHON_CLIENT_PREALLOCATE:-false}"
export AMD_COMGR_NAMESPACE="${AMD_COMGR_NAMESPACE:-1}"

WORKDIR="${ROCROBO_WORKDIR:-/rocrobo}"
cd "$WORKDIR"

# Persist XLA compiled executables to disk so the multi-minute first-call JIT is
# paid ONCE *ever* (not per fresh serve / per scenario run). Each scenario run
# spawns a new serve, so without this every run recompiles from scratch — the
# original workshop slowdown / motion-planning timeouts. MIN_*=0 caches even
# quick/small compiles so the warm cache is never partial. Cache lives in the
# container's writable layer (no bind mount in the all-in-one image), which is
# enough to amortise across the serves within a single container run.
export JAX_COMPILATION_CACHE_DIR="${ROCROBO_JAX_CACHE:-$WORKDIR/.jax_cache}"
export JAX_PERSISTENT_CACHE_MIN_COMPILE_TIME_SECS="${JAX_PERSISTENT_CACHE_MIN_COMPILE_TIME_SECS:-0}"
export JAX_PERSISTENT_CACHE_MIN_ENTRY_SIZE_BYTES="${JAX_PERSISTENT_CACHE_MIN_ENTRY_SIZE_BYTES:-0}"
mkdir -p "$JAX_COMPILATION_CACHE_DIR" || true

PY="${ROCROBO_PYTHON:-/usr/bin/python3.12}"
if [ ! -x "$PY" ]; then
  echo "rocrobo-serve-local: python not found at $PY" >&2
  exit 1
fi

if [ -d /opt/rocm-jax/lib ]; then
  export LD_LIBRARY_PATH="/opt/rocm-jax/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

exec "$PY" -u -m rocrobo.serve --serve
