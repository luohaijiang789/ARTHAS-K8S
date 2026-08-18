#!/usr/bin/env bash
# logs-pod-k8s.sh — 一键看 pod 日志（借鉴 kubetail：多 pod 同时 tail）
#
# 选 pod（关键字匹配，多 pod 选号或 --all 全选）→ kubectl logs -f 跟随。
#   --all     匹配的所有 pod 同时 tail（每行前缀 pod 名）
#   --prev    看上一次崩溃的日志（pod 重启过时有用）
#   -c <name> 多容器 pod 指定容器
#   --tail N  只看最后 N 行（默认全程跟随）
#
# 用法:
#   bash k8s-quick/logs-pod-k8s.sh <pod-flag>            # 单 pod 跟随
#   bash k8s-quick/logs-pod-k8s.sh <pod-flag> --all      # 所有匹配 pod 同时 tail
#   bash k8s-quick/logs-pod-k8s.sh <pod-flag> --prev     # 上次崩溃日志
#   bash k8s-quick/logs-pod-k8s.sh <pod-flag> --tail 100 -c app
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/logs-pod-k8s.sh <pod-flag> [--all] [--prev] [--tail N] [--no-follow] [-c <container>]"

FLAG=""; ALL=0; PREV=0; TAIL=""; NOFOLLOW=0; FORCE_C=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all)  ALL=1; shift ;;
    --prev) PREV=1; shift ;;
    --tail) TAIL="$2"; shift 2 ;;
    --no-follow) NOFOLLOW=1; shift ;;
    -c)     FORCE_C="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) FLAG="$1"; shift ;;
  esac
done
[ -z "$FLAG" ] && { print_usage; exit 1; }

# 收集匹配的 pod（支持 --all 多个）
mapfile -t pods < <(kubectl get po -A -o wide \
  | awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"{print $1"\t"$2}')
[ "${#pods[@]}" -eq 0 ] && { log_error "no running pod matched: $FLAG"; exit 1; }

# 选哪些 pod
if [ "$ALL" -eq 1 ] || [ "${#pods[@]}" -eq 1 ]; then
  sel=("${pods[@]}")
else
  i=0
  while [ "$i" -lt "${#pods[@]}" ]; do echo "$((i+1)): ${pods[$i]}"; i=$((i+1)); done
  read -p "select pod (1-${#pods[@]}, or a=all): " idx
  if [ "$idx" = "a" ] || [ "$idx" = "all" ]; then
    sel=("${pods[@]}")
  else
    case "$idx" in ''|*[!0-9]*) log_error "index error"; exit 1;; esac
    sel=("${pods[$((idx-1))]}")
  fi
fi

# 公共参数
LOG_ARGS=()
[ "$PREV" = 1 ] && LOG_ARGS+=(--previous)
[ -n "$TAIL" ] && LOG_ARGS+=(--tail "$TAIL")

# 单 pod：logs（默认 -f 跟随，--no-follow 只显示一次）
if [ "${#sel[@]}" -eq 1 ]; then
  line="${sel[0]}"; ns="${line%$'\t'*}"; pod="${line#*$'\t'}"
  c="${FORCE_C:-$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null)}"
  FOLLOW=(-f)
  [ "$NOFOLLOW" = 1 ] && FOLLOW=()
  mode="follow"; [ "$NOFOLLOW" = 1 ] && mode="no-follow"
  tags=""
  [ "$PREV" = 1 ] && tags="$tags [previous]"
  [ -n "$TAIL" ] && tags="$tags tail=$TAIL"
  [ "$NOFOLLOW" = 1 ] && tags="$tags (done)"
  log_info "logs $mode $pod (ns=$ns, c=$c)$tags"
  if [ "$NOFOLLOW" = 1 ]; then
    kubectl logs -n "$ns" "$pod" -c "$c" "${LOG_ARGS[@]}"
  else
    log_info "Ctrl+C 退出"
    exec kubectl logs -f -n "$ns" "$pod" -c "$c" "${LOG_ARGS[@]}"
  fi
fi

# 多 pod：借鉴 kubetail，每 pod 一个 kubectl logs -f，前缀 pod 短名，合并输出
log_info "tailing ${#sel[@]} pods (Ctrl+C 退出)："
pids=()
for line in "${sel[@]}"; do
  ns="${line%$'\t'*}"; pod="${line#*$'\t'}"
  c="${FORCE_C:-$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null)}"
  # pod 短名前缀（去前缀 hash），awk 加颜色前缀
  short=$(echo "$pod" | sed 's/-[a-f0-9]\{9,\}$//; s/-[a-f0-9]\{9,\}-[a-z0-9]\{5\}$//')
  kubectl logs -f -n "$ns" "$pod" -c "$c" "${LOG_ARGS[@]}" 2>&1 \
    | awk -v p="$short" '{ printf "\033[36m[%s]\033[0m %s\n", p, $0 }' &
  pids+=($!)
done
trap 'kill ${pids[@]} 2>/dev/null' INT TERM EXIT
wait
