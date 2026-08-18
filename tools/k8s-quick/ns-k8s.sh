#!/usr/bin/env bash
# ns-k8s.sh — namespace 列出 / 切换当前默认 ns
#
# 切换：写 kubectl 的 ns context（kubectl config set-context --current --namespace=<ns>），
# 之后裸 kubectl 命令默认用该 ns，省得每次 -n。比 alias 更稳（跨终端生效）。
#
# 用法:
#   bash tools/k8s-quick/ns-k8s.sh                 # 列所有 ns
#   bash tools/k8s-quick/ns-k8s.sh <ns>            # 切换当前 ns
#   bash tools/k8s-quick/ns-k8s.sh <关键字>        # 模糊匹配切（如 kube 取 kube-system）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"
USAGE="bash tools/k8s-quick/ns-k8s.sh [<ns|关键字>]"

FLAG="${1:-}"

if [ -z "$FLAG" ]; then
  # 列所有 ns + 标记当前
  cur=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  log_info "当前 ns: ${cur:-(未设)}  —— 所有 ns："
  kubectl get ns -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp --no-headers \
    | awk -v c="$cur" '{ if($1==c) printf "  \033[32m* %s\033[0m  %s  %s\n", $1, $2, $3; else printf "    %s  %s  %s\n", $1, $2, $3 }'
  exit 0
fi

# 精确匹配优先，否则模糊
target=$(kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers | grep -ix "$FLAG" | head -1)
[ -z "$target" ] && target=$(kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers | grep -i "$FLAG" | head -1)
[ -z "$target" ] && { log_error "无匹配 ns: $FLAG"; kubectl get ns -o custom-columns=NAME:.metadata.name --no-headers | head; exit 1; }

kubectl config set-context --current --namespace="$target" >/dev/null 2>&1 \
  && log_info "当前 ns 切换为: $target（裸 kubectl 命令默认用此 ns）" \
  || { log_error "切换失败（kubeconfig 只读？）"; exit 1; }
