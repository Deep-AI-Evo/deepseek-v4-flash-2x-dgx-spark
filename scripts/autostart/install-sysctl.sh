#!/usr/bin/env bash
# Root-only part of the hardening: install + apply vm.compaction_proactiveness=0.
# Run on EACH node (head and worker):
#   sudo bash install-sysctl.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
install -m 644 "$HERE/99-dsv4.conf" /etc/sysctl.d/99-dsv4.conf
sysctl --system
echo "vm.compaction_proactiveness = $(cat /proc/sys/vm/compaction_proactiveness) (expect 0)"
