#!/usr/bin/env bash
# status-k8s.sh — pod 状态速览（全 ns 或指定 ns，按状态着色高亮异常）
#
# 比 kubectl get po -A 更友好：Running 灰、非 Running 彩色高亮（Failed/Error/CrashLoopBackOff 红，
# Pending 黄），底部汇总各状态计数。快速扫「哪些 pod 不健康」。
#
# 用法:
#   bash k8s-quick/status-k8s.sh              # 全 ns
#   bash k8s-quick/status-k8s.sh <ns>         # 指定 ns
#   bash k8s-quick/status-k8s.sh <ns> --wide  # 含 IP/NODE（-o wide）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/status-k8s.sh [<ns>] [--wide]"

NS=""; WIDE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --wide) WIDE=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) NS="$1"; shift ;;
  esac
done

# 汇总：kubectl get po + 按状态着色
get_cmd=(kubectl get po)
[ -n "$NS" ] && get_cmd+=(-n "$NS") || get_cmd+=(-A)
[ "$WIDE" = 1 ] && get_cmd+=(-o wide)

# 取数据（jsonpath 便于着色），列：ns pod ready status restarts age
fields='{.metadata.namespace},{.metadata.name},{.status.containerStatuses[0].ready},{.status.phase},{.status.containerStatuses[0].restartCount},{.metadata.creationTimestamp}'
raw=$("${get_cmd[@]}" -o jsonpath="{range .items[*]}${fields}{\"\\n\"}{end}" 2>/dev/null)
[ -z "$raw" ] && { log_error "取不到 pod（集群不可达或 ns 不存在？）"; exit 1; }

# 表头
printf "%-12s %-40s %-6s %-10s %-8s %-8s\n" NS POD READY STATUS RESTARTS AGE
printf '%.0s-' {1..90}; echo

# 状态→颜色
declare -A color
color[Running]=$'\033[0m'        # 默认（灰白）
color[Pending]=$'\033[33m'       # 黄
color[Failed]=$'\033[31m'        # 红
color[Unknown]=$'\033[35m'       # 紫
RST=$'\033[0m'

now=$(date +%s)
declare -A stat_count
while IFS=, read -r ns pod ready status restarts ts; do
  [ -z "$pod" ] && continue
  # ready 字段可能为空（pod 还没 containerStatus）
  [ -z "$ready" ] && ready="-"
  # 年龄换算
  age="-"
  if [ -n "$ts" ]; then
    age_s=$(( now - $(date -d "$ts" +%s 2>/dev/null || echo "$now") ))
    if [ "$age_s" -ge 86400 ]; then age="$((age_s/86400))d"
    elif [ "$age_s" -ge 3600 ]; then age="$((age_s/3600))h"
    else age="$((age_s/60))m"; fi
  fi
  c="${color[$status]:-$RST}"
  # 异常状态额外检查 CrashLoopBackOff（在 containerStatuses.state.waiting.reason）
  printf "%-12s %-40s %-6s ${c}%-10s${RST} %-8s %-8s\n" "$ns" "$pod" "$ready" "$status" "$restarts" "$age"
  stat_count[$status]=$(( ${stat_count[$status]:-0} + 1 ))
done <<< "$raw"

# 汇总
echo
printf "汇总: "
for s in Running Pending Failed Unknown; do
  [ -n "${stat_count[$s]:-}" ] && printf "%s=%s  " "$s" "${stat_count[$s]}"
done
echo
non_running=$(( $(printf '%s' "${stat_count[@]}" | tr ' ' '+' | bc 2>/dev/null) - ${stat_count[Running]:-0} ))
[ "$non_running" -gt 0 ] && log_warn "有 $non_running 个非 Running pod——用 logs-pod/describe-pod 排查"
