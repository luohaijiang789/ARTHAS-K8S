#!/usr/bin/env bash
# exec-pod-k8s.sh — 一键进入 pod 的交互式 shell
#
# 选 pod（关键字匹配 Running，多 pod 选号）→ 自动探测可用 shell（bash→sh→ash）→ exec -it 进去。
# 多容器 pod 默认 containers[0]，可用 -c 指定。
#
# 用法:
#   bash k8s-quick/exec-pod-k8s.sh              # 列所有 Running pod 选
#   bash k8s-quick/exec-pod-k8s.sh <pod-flag>   # 关键字匹配（服务名/app 标签片段）
#   bash k8s-quick/exec-pod-k8s.sh <pod-flag> -c <container>
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/exec-pod-k8s.sh [<pod-flag>] [-c <container>]"

FLAG=""; FORCE_C=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) FORCE_C="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) FLAG="$1"; shift ;;
  esac
done

line=$(select_pod "$FLAG") || exit 1
ns="${line%$'\t'*}"; pod="${line#*$'\t'}"
log_info "pod: $pod  ns: $ns"

# 目标容器
if [ -n "$FORCE_C" ]; then
  c="$FORCE_C"
else
  c=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null)
fi
[ -z "$c" ] && { log_error "无法获取容器名（多容器 pod 用 -c 指定）"; exit 1; }

# 多容器提醒
n=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers | length}' 2>/dev/null)
[ "${n:-1}" -gt 1 ] && log_warn "多容器 pod（$n 个），进 containers[0]=$c；其他用 -c <name>"

# 探测可用 shell：bash → sh → ash（distroless 无 shell 会失败，提示用 logs-pod 或 arthas 路径 C）
shell=$(kubectl exec -n "$ns" "$pod" -c "$c" -- sh -c 'command -v bash || command -v sh || command -v ash' 2>/dev/null | head -1)
if [ -z "$shell" ]; then
  log_error "容器内无 shell（distroless？）—— exec 进不去"
  log_warn "看日志: bash k8s-quick/logs-pod-k8s.sh '$FLAG'"
  log_warn "排查 java: bash probe-k8s.sh '$FLAG'（arthas 路径 C 可 attach distroless）"
  exit 1
fi
log_info "shell: $shell  （按 Ctrl+D 或 exit 退出）"
exec kubectl exec -it -n "$ns" "$pod" -c "$c" -- "$shell"
