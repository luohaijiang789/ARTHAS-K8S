#!/usr/bin/env bash
# clean-failed-k8s.sh — 批量清理 Failed / Evicted / CrashLoopBackOff 死 pod
#
# 这些 pod 占用 etcd 元数据、污染 kubectl get po 输出，通常无保留价值。
# 默认只清 Failed + Evicted（最安全），--all 含其他非 Running（Pending 保留——可能正在拉镜像）。
# 删前列出要删的，确认后才删（--yes 跳过确认）。
#
# 用法:
#   bash k8s-quick/clean-failed-k8s.sh                 # 清 Failed + Evicted（确认）
#   bash k8s-quick/clean-failed-k8s.sh <ns>            # 指定 ns
#   bash k8s-quick/clean-failed-k8s.sh --yes           # 跳过确认
#   bash k8s-quick/clean-failed-k8s.sh --dry-run       # 只看不删
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash k8s-quick/clean-failed-k8s.sh [<ns>] [--yes] [--dry-run]"

NS=""; YES=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) NS="$1"; shift ;;
  esac
done

# 取 Failed / Evicted pod（Evicted 是 phase Failed + reason Evicted）
get_cmd=(kubectl get po)
[ -n "$NS" ] && get_cmd+=(-n "$NS") || get_cmd+=(-A)

mapfile -t dead < <("${get_cmd[@]}" -o json \
  | jq -r '.items[] | select(.status.phase=="Failed") | [.metadata.namespace, .metadata.name, (.status.reason // "Failed")] | @tsv' 2>/dev/null)
[ "${#dead[@]}" -eq 0 ] && { log_info "无 Failed/Evicted pod 需清理 ✓"; exit 0; }

log_warn "待清理 ${#dead[@]} 个 Failed/Evicted pod："
for line in "${dead[@]}"; do
  IFS=$'\t' read -r ns pod reason <<<"$line"
  printf "  %s/%s  [%s]\n" "$ns" "$pod" "$reason"
done
echo

[ "$DRY" = 1 ] && { log_info "--dry-run：仅列出，不删除"; exit 0; }

if [ "$YES" != 1 ]; then
  read -p "确认删除以上 ${#dead[@]} 个 pod？(y/N) " ans
  case "$ans" in y|Y|yes) ;; *) log_info "已取消"; exit 0;; esac
fi

ok=0; fail=0
for line in "${dead[@]}"; do
  IFS=$'\t' read -r ns pod reason <<<"$line"
  if kubectl delete pod -n "$ns" "$pod" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1)); log_error "删除失败: $ns/$pod"
  fi
done
log_info "完成：删除 $ok 个，失败 $fail 个"
[ "$fail" -gt 0 ] && log_warn "失败的可能是 Finalizer 卡住——用 describe-pod-k8s.sh 看原因"
