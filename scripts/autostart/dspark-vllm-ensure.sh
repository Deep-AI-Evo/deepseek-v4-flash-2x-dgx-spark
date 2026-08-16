#!/usr/bin/env bash
# Ensure the DSpark vLLM worker container exists and is running.
# Worker node. Adapted from maliubiao/dgx-spark-2-deepseek-flash-0731 for user systemd,
# with the same env resolution as the upstream start script (util profile, host IP).
set -uo pipefail

PROJECT="deepseek-v4-flash"
SERVICE="vllm-dspark"
REPO="/home/dgx/projects/dspark-recipe"

if ! docker info >/dev/null 2>&1; then
  if [ -z "${DSPARK_SG:-}" ] && id -nG dgx | grep -qw docker; then
    export DSPARK_SG=1
    exec sg docker -c "$(printf '%q ' "$0" "$@")"
  fi
fi

for _ in $(seq 1 90); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null 2>&1 || { echo "docker daemon not ready" >&2; exit 1; }

CONTAINER="$PROJECT-$SERVICE-1"
if docker ps --format "{{.Names}}" | grep -qx "$CONTAINER"; then
  echo "worker container $CONTAINER already running."
  exit 0
fi

if [ ! -f "$REPO/docker-compose.dspark.yml" ] || [ ! -f "$REPO/.env.dspark" ]; then
  echo "worker compose/env missing in $REPO" >&2
  exit 1
fi

cd "$REPO" || exit 1
set -a
# shellcheck disable=SC1091
source .env.dspark
set +a

# Same resolution as start-deepseek-v4-flash-dspark.sh: vision flag picks the util profile.
if [ "${ENABLE_VL_SIDECAR:-0}" = "1" ]; then
  GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION_VISION:-0.80}"
else
  GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION_TEXT:-0.835}"
fi
HF_CACHE="${WORKER_HF_CACHE:-${HF_CACHE:-$HOME/.cache/huggingface}}"
VLLM_HOST_IP="${WORKER_VLLM_HOST_IP:-${VLLM_HOST_IP:-}}"

echo "Starting worker container $CONTAINER..."
NODE_RANK=1 HEADLESS=1 \
  HF_CACHE="$HF_CACHE" \
  VLLM_HOST_IP="$VLLM_HOST_IP" \
  GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" \
  DSPARK_MODEL="${DSPARK_MODEL_OFFICIAL:-deepseek-ai/DeepSeek-V4-Flash-0731}" \
  DSPARK_REVISION="${DSPARK_REVISION:-}" \
  COMPOSE_DISABLE_ENV_FILE=1 \
  docker compose -p "$PROJECT" --env-file .env.dspark -f docker-compose.dspark.yml up -d "$SERVICE"
