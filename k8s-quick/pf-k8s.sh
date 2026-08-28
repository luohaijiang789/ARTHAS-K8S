#!/usr/bin/env bash
# pf-k8s.sh — 一键 port-forward pod 端口到本地
#
# 选 pod → 自动取声明的 containerPort（多端口选号）→ kubectl port-forward。
# 声明无端口的 pod（端口只由启动参数决定，如 Spring 的 --server.port）用 --port 手动指定。
# 多容器 pod 默认取 containers[0] 的端口，-c 指定其他容器用于列举端口。
#
# 用法:
#   bash k8s-quick/pf-k8s.sh <pod-flag>                  # 自动取端口，本地端口=容器端口
#   bash k8s-quick/pf-k8s.sh <pod-flag> --port 8080       # pod 未声明端口时手动指定容器端口
#   bash k8s-quick/pf-k8s.sh <pod-flag> --local 18080     # 本地端口（默认=容器端口）
#   bash k8s-quick/pf-k8s.sh <pod-flag> -c sidecar --port 9090
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/pf-k8s.sh <pod-flag> [--port N] [--local N] [-c <container>]"

FLAG=""; FORCE_C=""; PORT=""; LOCAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c)      FORCE_C="$2"; shift 2 ;;
    --port)  PORT="$2";   shift 2 ;;
    --local) LOCAL="$2";  shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) FLAG="$1"; shift ;;
  esac
done
[ -z "$FLAG" ] && { print_usage; exit 1; }

line=$(select_pod "$FLAG") || exit 1
ns="${line%$'\t'*}"; pod="${line#*$'\t'}"

# 容器：默认 containers[0]（与 exec-pod 一致），-c 仅用于选哪个容器的端口来列举
if [ -n "$FORCE_C" ]; then c="$FORCE_C"
else c=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null); fi
[ -z "$c" ] && { log_error "无法获取容器名（多容器 pod 用 -c 指定）"; exit 1; }

if [ -n "$PORT" ]; then
  cport="$PORT"
else
  # 该容器声明的 containerPort（jsonpath 取，逗号分隔，去尾逗号）
  ports_raw=$(kubectl get pod -n "$ns" "$pod" \
    -o jsonpath="{range .spec.containers[?(@.name=='$c')].ports[*]}{.containerPort}{','}{end}" 2>/dev/null)
  IFS=',' read -ra cports <<<"${ports_raw%,}"
  if [ "${#cports[@]}" -eq 0 ] || [ -z "${cports[0]}" ]; then
    log_error "容器 $c 未声明端口（端口由启动参数决定？）—— 用 --port <port> 手动指定"
    exit 1
  elif [ "${#cports[@]}" -eq 1 ]; then
    cport="${cports[0]}"
  else
    log_info "容器 $c 声明了多个端口，选一个："
    i=0
    while [ "$i" -lt "${#cports[@]}" ]; do echo "$((i+1)): ${cports[$i]}" >&2; i=$((i+1)); done
    read -p "select port (1-${#cports[@]}): " idx
    case "$idx" in ''|*[!0-9]*) log_error "index error: not a number" >&2; exit 1;; esac
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#cports[@]}" ]; then log_error "out of range (1-${#cports[@]})" >&2; exit 1; fi
    cport="${cports[$((idx-1))]}"
  fi
fi

lport="${LOCAL:-$cport}"
log_info "forward $pod (ns=$ns): localhost:$lport -> pod:$cport  （Ctrl+C 退出）"
# port-forward 按 pod 端口解析容器，不传 -c（容器从端口隐式确定）
exec kubectl port-forward -n "$ns" "$pod" "$lport:$cport"
