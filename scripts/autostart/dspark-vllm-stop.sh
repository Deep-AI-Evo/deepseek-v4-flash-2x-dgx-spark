#!/usr/bin/env bash
# DSpark vLLM stop wrapper (idempotent; stops head + worker containers).
# Head node. Adapted from maliubiao/dgx-spark-2-deepseek-flash-0731 for user systemd.
set -uo pipefail

REPO="/home/dgx/projects/dspark-recipe"

if ! docker info >/dev/null 2>&1; then
  if [ -z "${DSPARK_SG:-}" ] && id -nG dgx | grep -qw docker; then
    export DSPARK_SG=1
    exec sg docker -c "$(printf '%q ' "$0" "$@")"
  fi
fi

if [ ! -x "$REPO/stop-deepseek-v4-flash-dspark.sh" ]; then
  echo "stop script missing: $REPO/stop-deepseek-v4-flash-dspark.sh" >&2
  exit 1
fi

cd "$REPO" || exit 1
exec ./stop-deepseek-v4-flash-dspark.sh
