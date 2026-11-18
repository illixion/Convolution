#!/usr/bin/env bash
# Copies the gateway and engine workers to the GPU host and (re)starts the
# gateway service. Engine environments are built separately by each engine's
# install.sh (long; run once). Usage: Gen3DServer/deploy.sh [host]
set -euo pipefail
HOST=${1:-ixion@100.70.201.117}
BIND=${GEN3D_BIND:-100.70.201.117}
PORT=${GEN3D_PORT:-8787}
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=${GEN3D_SSH:-ssh}   # e.g. "ssh -o ControlPath=..." to reuse an open session

rsync -a --delete --exclude '__pycache__' -e "$SSH" \
  "$HERE/gateway" "$HERE/engines" "$HERE/engines.json" "$HOST:/opt/gen3d/src/"

$SSH "$HOST" BIND="$BIND" PORT="$PORT" bash -s <<'EOF'
set -euo pipefail
cd /opt/gen3d
[ -x envs/gateway/bin/python ] || bin/uv venv -q -p 3.12 envs/gateway
bin/uv pip install -q -p envs/gateway/bin/python fastapi 'uvicorn[standard]' python-multipart httpx pillow
sudo tee /etc/systemd/system/gen3d-gateway.service >/dev/null <<UNIT
[Unit]
Description=gen3d image-to-3D gateway
After=network-online.target tailscaled.service ollama.service
Wants=network-online.target

[Service]
User=ixion
WorkingDirectory=/opt/gen3d/src/gateway
Environment=GEN3D_ROOT=/opt/gen3d
ExecStart=/opt/gen3d/envs/gateway/bin/python -m uvicorn gateway:app --host $BIND --port $PORT
Restart=on-failure
RestartSec=5
KillMode=mixed
TimeoutStopSec=40

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable -q gen3d-gateway
sudo systemctl restart gen3d-gateway
sleep 2
systemctl is-active gen3d-gateway
EOF
