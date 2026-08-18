#!/usr/bin/env bash
# describe-pod-k8s.sh — 一键 describe pod（多 pod 选号）
#
# 选 pod → kubectl describe pod，快速看 Events、探针、挂载、QoS、node 等。
#
# 用法:
#   bash tools/k8s-quick/describe-pod-k8s.sh <pod-flag>
#   bash tools/k8s-quick/describe-pod-k8s.sh              # 列所有选
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash tools/k8s-quick/describe-pod-k8s.sh [<pod-flag>]"

FLAG="${1:-}"
[ "${1:-}" = "-h" ] && { print_usage; exit 0; }

line=$(select_pod "$FLAG") || exit 1
ns="${line%$'\t'*}"; pod="${line#*$'\t'}"
log_info "describe $pod (ns=$ns) —— 重点看 Events / 探针 / 挂载 / node"
exec kubectl describe pod -n "$ns" "$pod"
