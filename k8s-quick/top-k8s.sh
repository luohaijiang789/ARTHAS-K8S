#!/usr/bin/env bash
# top-k8s.sh — 节点 / pod 资源用量速览（kubectl top 封装）
#
# kubectl top 要装 metrics-server，没装会甩一堆 trace。本脚本先探 metrics API，
# 缺了就提示怎么装，不抛错。默认 nodes + pods 全 ns，--nodes/--pods 二选一或一起。
#
# 用法:
#   bash k8s-quick/top-k8s.sh              # nodes + pods(-A)
#   bash k8s-quick/top-k8s.sh <ns>         # pods 限指定 ns
#   bash k8s-quick/top-k8s.sh --nodes      # 只看节点
#   bash k8s-quick/top-k8s.sh --pods        # 只看 pod
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/top-k8s.sh [<ns>] [--nodes|--pods]"

NS=""; SHOW_NODES=0; SHOW_PODS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --nodes) SHOW_NODES=1; shift ;;
    --pods)  SHOW_PODS=1;  shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) NS="$1"; shift ;;
  esac
done
# 默认两者都看
[ "$SHOW_NODES" = 0 ] && [ "$SHOW_PODS" = 0 ] && { SHOW_NODES=1; SHOW_PODS=1; }

# 探测 metrics API（kubectl top 的前提；缺失通常是没装 metrics-server）
if ! kubectl api-resources 2>/dev/null | grep -qi 'metrics'; then
  log_error "集群无 metrics-server（metrics.k8s.io API 缺失），kubectl top 跑不了"
  log_warn "装一下: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  exit 1
fi

if [ "$SHOW_NODES" = 1 ]; then
  log_info "节点资源（CPU/MEM 含百分比）："
  kubectl top nodes 2>/dev/null || log_warn "取 nodes 用量失败"
  echo
fi

if [ "$SHOW_PODS" = 1 ]; then
  if [ -n "$NS" ]; then ns_args=(-n "$NS"); else ns_args=(-A); fi
  log_info "pod 资源（${NS:-全 ns}）："
  kubectl top pods "${ns_args[@]}" 2>/dev/null || log_warn "取 pods 用量失败"
fi
