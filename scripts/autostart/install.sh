#!/usr/bin/env bash
# Install dspark-vllm user-level autostart on head + worker (no root required).
# - head:   dspark-vllm.service        (three-level self-healing start wrapper)
# - worker: dspark-vllm-worker.service (idempotent worker-container ensure)
# Requires: ssh dgx@<worker> passwordless, linger already enabled on both nodes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKER_SSH="dgx@18.18.11.2"

chmod +x "$HERE"/head/*.sh "$HERE"/worker/*.sh

# Head
mkdir -p ~/.config/systemd/user
install -m 644 "$HERE/head/dspark-vllm.service" ~/.config/systemd/user/dspark-vllm.service
systemctl --user daemon-reload
systemctl --user enable dspark-vllm.service

# Worker: sync this repo dir, then install the unit
ssh -o BatchMode=yes "$WORKER_SSH" 'mkdir -p ~/projects/dsv4-autostart ~/.config/systemd/user'
scp -q -r "$HERE/head" "$HERE/worker" "$HERE/sysctl" "$WORKER_SSH:~/projects/dsv4-autostart/"
# shellcheck disable=SC2087
ssh -o BatchMode=yes "$WORKER_SSH" <<'EOF'
set -euo pipefail
chmod +x ~/projects/dsv4-autostart/head/*.sh ~/projects/dsv4-autostart/worker/*.sh
install -m 644 ~/projects/dsv4-autostart/worker/dspark-vllm-worker.service ~/.config/systemd/user/dspark-vllm-worker.service
systemctl --user daemon-reload
systemctl --user enable dspark-vllm-worker.service
EOF

echo "Installed. Start now with:"
echo "  head:   systemctl --user start dspark-vllm.service"
echo "  worker: ssh $WORKER_SSH 'systemctl --user start dspark-vllm-worker.service'"
