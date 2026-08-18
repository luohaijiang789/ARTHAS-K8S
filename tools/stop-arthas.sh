#!/usr/bin/env bash
# stop-arthas.sh — 清理目标 pod 残留的 arthas agent
#
# arthas 异常退出（Ctrl+C / quit / ssh 断 / 路径 C 临时容器销毁但 agent 在目标 JVM）
# 后，agent 可能残留在目标 JVM，占 3658 端口导致下次 attach 报 "port already in use"。
# 本脚本 attach 后非交互发 stop 命令（-c stop）卸载残留 agent。
#
# 用法: bash tools/stop-arthas.sh <pod-flag>
#
# 仅处理容器有 java 的 pod（路径 A 残留，最常见场景）。容器无 java（distroless /
# JRE-only）的残留走 attach-ephemeral.sh attach 后手动 stop，或重启 pod。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTHAS_DIST_DIR="$ROOT/tools/arthas/dist"
ARTHAS_TAR="$ROOT/tools/cache/arthas-dist.tar.gz"

log_error() { printf "\033[31m %s \033[0m\n" "$1"; }
log_info()  { printf "\033[34m %s \033[0m\n" "$1"; }
log_warn()  { printf "\033[33m %s \033[0m\n" "$1"; }

command -v kubectl >/dev/null || { log_error "kubectl not found"; exit 1; }
command -v tar    >/dev/null || { log_error "tar not found"; exit 1; }
[ -d "$ARTHAS_DIST_DIR" ] || { log_error "arthas dist missing, run: bash tools/fetch.sh"; exit 1; }

[ -z "${1:-}" ] && { echo 'usage: bash tools/stop-arthas.sh <pod-flag>'; exit 1; }
FLAG="$1"

# 选 pod（awk 取列 + index 子串匹配 ns/pod 名）
mapfile -t pods < <(kubectl get po -A -o wide \
  | awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"{print $1"\t"$2}')
[ "${#pods[@]}" -eq 0 ] && { log_error "no running pod matched: $FLAG"; exit 1; }
if [ "${#pods[@]}" -eq 1 ]; then idx=0
else
  i=0
  while [ "$i" -lt "${#pods[@]}" ]; do echo "$((i+1)): ${pods[$i]}"; i=$((i+1)); done
  read -p "select pod (1-${#pods[@]}): " idx
  case "$idx" in ''|*[!0-9]*) echo "index error"; exit 1;; esac
  if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#pods[@]}" ]; then echo "index error (1-${#pods[@]})"; exit 1; fi
  idx=$((idx-1))
fi
ns="${pods[$idx]%$'\t'*}"; podname="${pods[$idx]#*$'\t'}"
log_info "target pod: $podname  ns: $ns"

# 清理容器内 /tmp 残留
cleanup_tmp() {
  kubectl exec -n "$ns" "$podname" -- sh -c 'rm -f /tmp/arthas-dist.tar.gz 2>/dev/null || true' 2>/dev/null
}
trap cleanup_tmp EXIT

# 探测容器 java（command -v，不在 PATH 则 /proc 找）
container_java=$(kubectl exec -n "$ns" "$podname" -- sh -c 'command -v java 2>/dev/null || true' 2>/dev/null || true)
if [ -z "$container_java" ]; then
  container_java=$(kubectl exec -n "$ns" "$podname" -- sh -c '
    for p in /proc/[0-9]*; do
      c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
      case "$c" in *java*) set -- $c; printf "%s" "$1"; break ;; esac
    done
  ' 2>/dev/null || true)
fi

if [ -z "$container_java" ]; then
  log_error "容器无 java（distroless/JRE-only），本脚本（路径 A 风格）无法清理"
  log_warn "请走: bash tools/attach-ephemeral.sh '$FLAG'  attach 后输入 stop；或 kubectl delete pod -n $ns $podname 重建"
  exit 1
fi

# 传 arthas dist（stop 需要 arthas-boot.jar）
if [ ! -f "$ARTHAS_TAR" ] || [ -n "$(find "$ARTHAS_DIST_DIR" -newer "$ARTHAS_TAR" 2>/dev/null | head -1)" ]; then
  tar -czf "$ARTHAS_TAR" -C "$ROOT/tools/arthas" dist
fi
kubectl cp "$ARTHAS_TAR" -n "$ns" "$podname:/tmp/arthas-dist.tar.gz" 2>/dev/null
kubectl exec -n "$ns" "$podname" -- tar -zxf /tmp/arthas-dist.tar.gz -C /tmp/ 2>/dev/null

# 找目标 java pid（arthas-boot 本次启动前，/proc 里 java 进程即目标 java）
target_pid=$(kubectl exec -n "$ns" "$podname" -- sh -c '
  for p in /proc/[0-9]*; do
    c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
    case "$c" in *java*) basename "$p"; break ;; esac
  done
' 2>/dev/null | head -1)

if [ -z "$target_pid" ]; then
  log_error "未找到目标 java 进程"
  exit 1
fi
log_info "target pid: $target_pid  → 发 stop 卸载 arthas agent"

# 读标记文件拿 agent 端口（随机端口方案：agent 不在默认 3658）
PORT_FILE="/tmp/arthas-port-$target_pid"
PORT=$(kubectl exec -n "$ns" "$podname" -- sh -c "cat $PORT_FILE 2>/dev/null" 2>/dev/null)
if [ -n "$PORT" ]; then
  log_info "agent port: $PORT（从标记文件读）"
  PORT_ARG="--telnet-port=$PORT"
else
  log_info "无标记文件，尝试默认端口 3658"
  PORT_ARG=""
fi

# 非交互：arthas-boot --telnet-port=$PORT -c stop <pid>
# attach 同一 JVM → arthas 检测已有 agent（skip attach）→ 连该端口 → stop 卸载
kubectl exec -n "$ns" "$podname" -- "$container_java" \
  -jar /tmp/dist/arthas-boot.jar $PORT_ARG -c stop "$target_pid" 2>&1 | tail -20

# 清理标记文件（agent 已卸载，标记失效）
kubectl exec -n "$ns" "$podname" -- sh -c "rm -f $PORT_FILE" 2>/dev/null || true
log_info "stop 已发送 + 标记文件已删。若仍残留：重启 pod: kubectl delete pod -n $ns $podname"
