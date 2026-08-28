#!/usr/bin/env bash
# events-k8s.sh — 集群事件速览（按时间倒序，Warn/Error 着色）
#
# kubectl get events 默认列宽、排序乱、消息截断，不好扫"最近什么在报警"。
# 本脚本按 lastTimestamp 倒序，精简列（时间/类型/原因/对象/消息），
# Warning 黄、Error·Failed 红，--watch 跟随实时事件。
#
# 用法:
#   bash k8s-quick/events-k8s.sh            # 全 ns 最近事件（倒序）
#   bash k8s-quick/events-k8s.sh <ns>       # 指定 ns
#   bash k8s-quick/events-k8s.sh --watch   # 跟随（-w）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/events-k8s.sh [<ns>] [--watch]"

NS=""; WATCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --watch|-w) WATCH=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) NS="$1"; shift ;;
  esac
done

ns_args=()
if [ -n "$NS" ]; then ns_args=(-n "$NS"); else ns_args=(-A); fi

# 精简列：TIME TYPE REASON KIND NAME MSG（MSG 是 message，可能含空格，放最后）
cols='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,KIND:.involvedObject.kind,NAME:.involvedObject.name,MSG:.message'

# 着色 awk：按 TYPE（$2）染色——Warning 黄，Error/Failed 红；MSG 是 $6 起拼回
colorize() {
  awk '{
    msg=""; for(i=6;i<=NF;i++) msg=msg" "$i;
    if($2=="Warning") c="\033[33m";
    else if($2=="Error"||$3~/Fail/) c="\033[31m";
    else c="";
    printf "%s  %s%-9s\033[0m  %-22s  %-10s %-32s %s\n", $1, c, $2, $3, $4, $5, msg;
  }'
}

if [ "$WATCH" = 1 ]; then
  log_info "watching events in ${NS:-all ns}（Ctrl+C 退出）"
  # watch 是服务端流式，不能 sort-by；直接透传 + 着色
  exec kubectl get events "${ns_args[@]}" -w -o custom-columns="$cols" | colorize
fi

log_info "events in ${NS:-all ns}（按 lastTimestamp 倒序）"
kubectl get events "${ns_args[@]}" --sort-by=.lastTimestamp -o custom-columns="$cols" | colorize
