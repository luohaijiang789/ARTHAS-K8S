#!/usr/bin/env bash
# _lib.sh — k8s-quick 脚本公共函数（pod 选择、日志、依赖检查）
# 被 exec-pod/logs-pod/describe-pod 等 source，避免 6 份重复代码。
# 不直接执行：若被 bash 直接跑，打印用法。
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && { echo "_lib.sh 是公共库，被其他脚本 source 用，不直接执行"; exit 0; }

# 依赖：kubectl 必须有；jq 可选（部分脚本用）
command -v kubectl >/dev/null || { echo "kubectl not found in PATH"; exit 1; }

# ---- 日志 ----
log_info()  { printf "\033[34m%s\033[0m\n" "$*"; }
log_warn()  { printf "\033[33m%s\033[0m\n" "$*"; }
log_error() { printf "\033[31m%s\033[0m\n" "$*"; }

# ---- 用法打印（各脚本调 select_pod 前先 set 自己的 USAGE）----
print_usage() { echo "usage: $USAGE"; }

# ---- 选 pod：关键字匹配 Running pod，多 pod 选号 ----
#   用法：select_pod <flag>  → 输出 "ns\tpod" 到 stdout，无匹配 exit 1
#   沿用 probe-k8s.sh 的 awk index 匹配（避免旧版 grep 误命中 NODE/IP）
#   FLAG 为空时列出所有 Running pod 供选
select_pod() {
  local flag="${1:-}"
  local pods
  if [ -z "$flag" ]; then
    mapfile -t pods < <(kubectl get po -A -o wide | awk 'NR>1 && $4=="Running"{print $1"\t"$2}')
  else
    mapfile -t pods < <(kubectl get po -A -o wide \
      | awk -v f="$flag" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"{print $1"\t"$2}')
  fi
  [ "${#pods[@]}" -eq 0 ] && { log_error "no running pod matched: ${flag:-(空)}"; return 1; }

  if [ "${#pods[@]}" -eq 1 ]; then
    printf '%s\t%s\n' "${pods[0]%$'\t'*}" "${pods[0]#*$'\t'}"
    return 0
  fi
  # 多 pod：列号选
  local i=0 idx
  while [ "$i" -lt "${#pods[@]}" ]; do echo "$((i+1)): ${pods[$i]}"; i=$((i+1)); done
  read -p "select pod (1-${#pods[@]}): " idx
  case "$idx" in ''|*[!0-9]*) log_error "index error: not a number"; return 1;; esac
  if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#pods[@]}" ]; then log_error "index out of range (1-${#pods[@]})"; return 1; fi
  idx=$((idx-1))
  printf '%s\t%s\n' "${pods[$idx]%$'\t'*}" "${pods[$idx]#*$'\t'}"
}

# ---- 选 ns：无参则列所有 ns 让选，有参直接用 ----
select_ns() {
  local flag="${1:-}"
  if [ -z "$flag" ]; then
    kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers
    return 0
  fi
  # 模糊匹配
  kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers | grep -i "$flag" | head -1
}
