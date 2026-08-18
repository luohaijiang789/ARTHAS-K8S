#!/usr/bin/env bash
# attach-k8s.sh — 路径 A：kubectl exec 模式 attach arthas 到 K8s Java pod
#
# 适用：probe-k8s.sh 判定 exec-direct 的 pod（有 shell + JDK + 未禁 attach + rootFS 可写）。
# 升级自旧版（arthas 3.6.9 + 单一 huaweijdk8u272）：
#   - arthas 4.3.4（tools/arthas/dist，完整离线 jar）
#   - 自动匹配目标 JVM 版本：优先用容器内 java 跑 arthas-boot（传输 ~17M，非 ~100M+）
#   - 容器 java 不在 PATH 时，从 /proc/<pid>/cmdline 找 java 二进制路径
#   - fallback：容器无 java（JRE-only/java 不在 PATH）时传匹配版本+架构 JDK 进去跑
#   - distroless（无 shell）→ 报错提示走路径 C ephemeral
#   - 用 sh -c 探测（兼容 alpine/busybox 等无 bash 容器）；退出清理 /tmp 残留
#
# 用法: bash tools/attach-k8s.sh <pod-flag>
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTHAS_DIST_DIR="$ROOT/tools/arthas/dist"
ARTHAS_TAR="$ROOT/tools/cache/arthas-dist.tar.gz"
TMP_IN_POD="/tmp/arthas-dist.tar.gz"   # 容器内落点，退出时清理

log_error() { printf "\033[31m %s \033[0m\n" "$1"; }
log_info()  { printf "\033[34m %s \033[0m\n" "$1"; }

command -v kubectl >/dev/null || { log_error "kubectl not found in PATH"; exit 1; }
command -v tar    >/dev/null || { log_error "tar not found"; exit 1; }
[ -d "$ARTHAS_DIST_DIR" ] || { log_error "arthas dist missing, run: bash tools/fetch.sh"; exit 1; }

# 不强制 root：kubectl 靠 kubeconfig（普通用户 ~/.kube/config），sudo 反而丢失 KUBECONFIG
# 连错集群。旧版强制 root 是历史遗留（旧脚本用 huaweijdk 需 root 挂载），现已无此需要。
# （路径 C attach-ephemeral.sh 也不要求 root，两脚本一致。）

if [ -z "${1:-}" ]; then echo 'please unique k8s pod flag'; exit 1; fi
FLAG="$1"

# ---- 交互式选 pod（awk 取列 + index 子串匹配 ns/pod，避免误命中 NODE/IP）----
mapfile -t pods < <(kubectl get po -A -o wide \
  | awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"{print $1"\t"$2}')
[ "${#pods[@]}" -eq 0 ] && { log_error "no running pod matched: $FLAG"; exit 1; }

if [ "${#pods[@]}" -eq 1 ]; then idx=0
else
  i=0
  while [ "$i" -lt "${#pods[@]}" ]; do echo "$((i+1)): ${pods[$i]}"; i=$((i+1)); done
  read -p "select the pod to jmp to (1-${#pods[@]}): " idx
  case "$idx" in ''|*[!0-9]*) echo "select pod index error, please input (1-${#pods[@]})"; exit 1;; esac
  if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#pods[@]}" ]; then echo "select pod index error, please input (1-${#pods[@]})"; exit 1; fi
  idx=$((idx-1))
fi
ns="${pods[$idx]%$'\t'*}"; podname="${pods[$idx]#*$'\t'}"
log_info "jmp pod: $podname; namespace: $ns"

# ---- 架构识别（fallback 选本地 JDK 用）----
plat=$(kubectl exec -n "$ns" "$podname" -- uname -m 2>/dev/null || echo unknown)
case "$plat" in
  x86_64|amd64) arch="x64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *) arch="x64"; log_info "arch=$plat 未识别，按 x64 处理" ;;
esac
log_info "arch: $arch"

# ---- 清理容器内 /tmp 残留（退出时）----
cleanup_tmp() {
  kubectl exec -n "$ns" "$podname" -- sh -c 'rm -f /tmp/arthas-dist.tar.gz /tmp/jdk-fallback.tar.gz 2>/dev/null || true' 2>/dev/null
}
trap cleanup_tmp EXIT

# ---- 探测容器内 java（用 sh -c，兼容 alpine/busybox 等无 bash 容器）----
# 1) 优先 command -v java（在 PATH）
container_java=$(kubectl exec -n "$ns" "$podname" -- sh -c 'command -v java 2>/dev/null || true' 2>/dev/null || true)
# 2) 不在 PATH → 从 /proc 找 java 进程的二进制路径
if [ -z "$container_java" ]; then
  container_java=$(kubectl exec -n "$ns" "$podname" -- sh -c '
    for p in /proc/[0-9]*; do
      c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
      case "$c" in *java*) set -- $c; printf "%s" "$1"; break ;; esac
    done
  ' 2>/dev/null || true)
fi

# ---- 传输 arthas dist（源比 tar 新则重新打包，避免复用旧版本）----
if [ ! -f "$ARTHAS_TAR" ] || [ -n "$(find "$ARTHAS_DIST_DIR" -newer "$ARTHAS_TAR" 2>/dev/null | head -1)" ]; then
  log_info "packing arthas-dist.tar.gz ..."
  tar -czf "$ARTHAS_TAR" -C "$ROOT/tools/arthas" dist
fi
log_info "uploading arthas dist (~17M) -> $podname:$TMP_IN_POD"
kubectl cp "$ARTHAS_TAR" -n "$ns" "$podname:$TMP_IN_POD"
kubectl exec -n "$ns" "$podname" -- tar -zxf "$TMP_IN_POD" -C /tmp/
ARTHAS_HOME_IN_POD="/tmp/dist"

# ---- 选 java 跑 arthas-boot ----
if [ -n "$container_java" ]; then
  jver=$(kubectl exec -n "$ns" "$podname" -- "$container_java" -version 2>&1 | head -1)
  log_info "using container java: $container_java  ($jver)"
  RUN_JAVA="$container_java"
else
  # 容器无 java 在 PATH：JRE-only（无 attach API）或 java 不在 PATH
  # fallback：传匹配本地 JDK 进去跑。版本探测三道降级：
  #   1) release 文件  2) 目标 jar class major version  3) 跑 bin -version
  #   失败默认 17（打 FALLBACK 日志）。容器有 shell 能跑 sh，故探测在容器内做。
  log_info "container java 不在 PATH，fallback：探测版本 + 传匹配本地 JDK"
  tgt_ver=$(kubectl exec -n "$ns" "$podname" -- sh -c '
    for p in /proc/[0-9]*; do
      c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
      case "$c" in *java*)
        set -- $c; bin=$1; pid=$(basename "$p")
        jh=$(dirname "$(dirname "$bin")")
        # 探测 1：release
        rel="${jh:+$jh/}release"
        [ -z "$jh" ] && rel=""
        if [ -n "$rel" ] && [ -f "$rel" ]; then echo "REL:"; cat "$rel"; exit 0; fi
        # 探测 2：class major version
        for a in $c; do
          case "$a" in
            *.jar)
              [ -f "$a" ] || continue
              fc=$(unzip -Z1 "$a" 2>/dev/null | grep "\.class$" | head -1)
              [ -z "$fc" ] && continue
              mj=$(unzip -p "$a" "$fc" 2>/dev/null | od -An -tu1 -j6 -N2 2>/dev/null | awk "{print \$1*256+\$2}")
              case "$mj" in 52) echo "MAJOR:8"; exit 0;; 55) echo "MAJOR:11"; exit 0;; 61) echo "MAJOR:17"; exit 0;; 65) echo "MAJOR:21"; exit 0;; esac
              ;;
          esac
        done
        # 探测 3：bin -version
        "$bin" -version 2>&1 | head -1; exit 0 ;;
      esac
    done; echo UNKNOWN' 2>/dev/null)
  # 解析三道标记
  case "$tgt_ver" in
    REL:*)   tv=$(printf '%s\n' "$tgt_ver" | tail -n +2 | awk -F= '/^JAVA_VERSION=/{gsub(/"/,"",$2);print $2;exit}')
             [ -z "$tv" ] && tv=$(printf '%s\n' "$tgt_ver" | tail -n +2 | head -1) ;;
    MAJOR:*) tv=$(printf '%s\n' "$tgt_ver" | sed -n 's/^MAJOR://p') ;;
    *)       tv=$(printf '%s\n' "$tgt_ver" | head -1) ;;
  esac
  case "$tv" in
    *"1.8"*|*"8u"*|*"8."*|8)  jv=8 ;;
    *"11."*|11)               jv=11 ;;
    *"17."*|17)               jv=17 ;;
    *"21."*|21)               jv=21 ;;
    *) log_warn "版本探测失败（tgt='$tv'），FALLBACK 默认 jdk-17；attach 失败请用路径 C 或 --jdk= 强制"; jv=17 ;;
  esac
  JDK_TAR="$ROOT/tools/cache/jdk-${jv}-${arch}.tar.gz"
  if [ ! -f "$JDK_TAR" ] || [ -n "$(find "$ROOT/tools/jdk/jdk-${jv}-${arch}" -newer "$JDK_TAR" 2>/dev/null | head -1)" ]; then
    log_info "packing jdk-$jv-$arch.tar.gz ..."
    tar -czf "$JDK_TAR" -C "$ROOT/tools/jdk" "jdk-${jv}-${arch}"
  fi
  log_info "cp jdk-$jv-$arch -> pod (fallback)"
  kubectl cp "$JDK_TAR" -n "$ns" "$podname:/tmp/jdk-fallback.tar.gz"
  kubectl exec -n "$ns" "$podname" -- tar -zxf /tmp/jdk-fallback.tar.gz -C /tmp/
  RUN_JAVA="/tmp/jdk-${jv}-${arch}/bin/java"
  log_info "fallback JDK: $RUN_JAVA"
fi

# ---- 运行 arthas ----
log_info "starting arthas-boot (dist at $ARTHAS_HOME_IN_POD)..."
kubectl exec -it -n "$ns" "$podname" -- "$RUN_JAVA" \
  -jar "$ARTHAS_HOME_IN_POD/arthas-boot.jar"
