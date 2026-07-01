#!/usr/bin/env bash
# Print SSH tunnel instructions for Jupyter in workshop_allinone.
# Run on the REMOTE server; execute the printed ssh -L command on your LOCAL laptop.
set -euo pipefail

CONTAINER=${CONTAINER:-workshop_allinone}
LOCAL_PORT=${LOCAL_PORT:-8888}
REMOTE_PORT=${REMOTE_PORT:-8888}

TOKEN=$(docker logs "$CONTAINER" 2>&1 | grep -oP 'token=\K[a-f0-9]+' | head -1)
if [ -z "$TOKEN" ]; then
  TOKEN=$(docker exec "$CONTAINER" jupyter notebook list 2>/dev/null | grep -oP 'token=\K[a-f0-9]+' | head -1)
fi

HOST=$(hostname -f 2>/dev/null || hostname)
USER=$(whoami)

cat <<EOF
Jupyter is running in Docker container: $CONTAINER
Remote port: $REMOTE_PORT  |  Notebook: /workspace/robotsmith

=== On your LOCAL machine (new terminal), run: ===

  ssh -N -L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT} ${USER}@${HOST}

Keep that terminal open. Then open in your local browser:

  http://127.0.0.1:${LOCAL_PORT}/tree?token=${TOKEN}

Open notebook: workshop_cdna3.ipynb (or workshop_cdna3_en.ipynb)

=== If you already have an SSH session to this host ===

  ssh -N -L ${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT} \${USER}@\${HOST_FROM_YOUR_SSH_CONFIG}

Or add to ~/.ssh/config on your laptop:

  Host workshop-jupyter
    HostName ${HOST}
    User ${USER}
    LocalForward ${LOCAL_PORT} 127.0.0.1:${REMOTE_PORT}

Then: ssh -N workshop-jupyter

EOF
