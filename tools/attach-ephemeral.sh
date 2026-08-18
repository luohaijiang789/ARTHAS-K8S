#!/usr/bin/env bash
# attach-ephemeral.sh — 路径 C：kubectl debug ephemeral container 模式 attach arthas
#
# 适用：distroless（无 shell）/ JRE-only（无 attach API）/ readOnlyRootFS 等
#      加固 pod。probe-k8s.sh 判定为 ephemeral-container* 的走这条。
#
# 不依赖预制调试镜像：起一个最小基础镜像的临时容器，kubectl cp 把匹配版本的
# JDK + arthas dist 传进去跑。process namespace 共享后能看到目标 java 进程并 attach。
#
# 用法:
#   bash tools/attach-ephemeral.sh <pod-flag>
#   bash tools/attach-ephemeral.sh <pod-flag> --image=debian:bookworm-slim  # 须 glibc 系（默认即此）
#   bash tools/attach-ephemeral.sh <pod-flag> --jdk=17              # 强制 JDK 版本，跳过自动探测
#   bash tools/attach-ephemeral.sh <pod-flag> --container=sidecar   # 多容器 pod 指定目标容器
#
# 依赖: kubectl、tar、本机 tools/jdk（bash tools/fetch.sh 装好）、K8s >=1.25
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JDK_DIR="$ROOT/tools/jdk"
ARTHAS_DIST_DIR="$ROOT/tools/arthas/dist"
ARTHAS_DIST_TAR="$ROOT/tools/cache/arthas-dist.tar.gz"

# 临时容器基础镜像：必须是 glibc 系（Temurin/OpenJDK 是 glibc 链接的）。
#   busybox(scratch 无 libc) / alpine(musl) 都跑不了 → "libdl.so.2 not found"。
#   debian:bookworm-slim 实测可用；缺 unzip（第 2 道版本探测需要），下方探测前装。
BASE_IMAGE="debian:bookworm-slim"

log_info()  { printf "\033[34m%s\033[0m\n" "$*"; }
log_warn()  { printf "\033[33m%s\033[0m\n" "$*"; }
log_error() { printf "\033[31m%s\033[0m\n" "$*"; }

command -v kubectl >/dev/null || { log_error "kubectl not found"; exit 1; }
command -v tar    >/dev/null || { log_error "tar not found"; exit 1; }
[ -d "$JDK_DIR" ]         || { log_error "tools/jdk missing, run: bash tools/fetch.sh"; exit 1; }
[ -d "$ARTHAS_DIST_DIR" ] || { log_error "arthas dist missing, run: bash tools/fetch.sh"; exit 1; }

# ---- 源比 tar 新则重新打包（fetch 升级后不会复用旧 tar）----
repack_if_stale() {  # tar  srcdir  inner_path
  local t="$1" src="$2" inner="$3"
  if [ ! -f "$t" ] || [ -n "$(find "$src" -newer "$t" 2>/dev/null | head -1)" ]; then
    log_info "packing $(basename "$t") ..."
    tar -czf "$t" -C "$(dirname "$src")" "$inner"
  fi
}
repack_if_stale "$ARTHAS_DIST_TAR" "$ARTHAS_DIST_DIR" "dist"

# ---- 解析参数 ----
FORCE_JDK=""; FORCE_CONTAINER=""; FLAG=""
for a in "$@"; do
  case "$a" in
    --image=*)     BASE_IMAGE="${a#*=}" ;;
    --jdk=*)       FORCE_JDK="${a#*=}" ;;
    --container=*) FORCE_CONTAINER="${a#*=}" ;;
    --*) echo "unknown option: $a"; exit 1 ;;
    *) FLAG="$a" ;;
  esac
done
[ -z "$FLAG" ] && { echo 'usage: bash tools/attach-ephemeral.sh [--image=IMG] [--jdk=8|11|17|21] [--container=NAME] <pod-flag>'; exit 1; }
if [ -n "$FORCE_JDK" ]; then
  case "$FORCE_JDK" in 8|11|17|21) ;; *) log_error "--jdk 仅支持 8/11/17/21"; exit 1;; esac
fi

# ---- 选 pod（awk 取列 + index 子串匹配 ns/pod 名，避免误命中 NODE/IP）----
mapfile -t pods < <(kubectl get po -A -o wide \
  | awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"{print $1"\t"$2}')
[ "${#pods[@]}" -eq 0 ] && { log_error "no running pod matched: $FLAG"; exit 1; }
if [ "${#pods[@]}" -eq 1 ]; then idx=0
else
  i=0
  while [ "$i" -lt "${#pods[@]}" ]; do echo "$((i+1)): ${pods[$i]}"; i=$((i+1)); done
  read -p "select pod (1-${#pods[@]}): " idx
  case "$idx" in ''|*[!0-9]*) echo "index error: not a number"; exit 1;; esac
  if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#pods[@]}" ]; then echo "index error: out of range (1-${#pods[@]})"; exit 1; fi
  idx=$((idx-1))
fi
# tab 分隔取 ns/pod，不受 IFS 空格影响（修旧版 IFS=$'\n' 下 set -- 不分词的 bug）
ns="${pods[$idx]%$'\t'*}"; pod="${pods[$idx]#*$'\t'}"
log_info "target pod: $pod  ns: $ns"

# ---- 目标容器名（--target 需要，共享 process ns）----
if [ -n "$FORCE_CONTAINER" ]; then
  target_container="$FORCE_CONTAINER"
else
  target_container=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null)
fi
[ -z "$target_container" ] && { log_error "无法获取目标容器名（多容器 pod 用 --container= 指定）"; exit 1; }
log_info "target container: $target_container（process namespace 共享源）"

# ---- 清理说明 ----
# K8s 不允许 patch 删除 spec.ephemeralContainers（Forbidden，不在可变字段列表），
# 故 ephemeral 容器无法原地清除——只能 kubectl delete pod 重建。
# agent 在目标 JVM（不在 ephemeral），ephemeral 销毁≠agent 清理：
#   - 退出 arthas 控制台前输 stop → 卸载 agent（推荐）
#   - 忘了 stop：bash tools/stop-arthas.sh（路径 A 标记）或 kubectl delete pod 重建
# 这里只在会话异常退出时提示，不做无效 patch。
EPHE_CREATED=0
cleanup_ephe() {
  [ "$EPHE_CREATED" = "1" ] || return
  log_warn "ephemeral 容器 $EPHE_ACTUAL 已保留（K8s 不支持原地删除 spec.ephemeralContainers）"
  log_warn "彻底清理：kubectl delete pod -n $ns $pod（Deployment 自动重建）"
  log_warn "若忘了 stop 卸载 agent：重跑本脚本 attach 后输 stop，或直接 delete pod"
}
trap cleanup_ephe EXIT

# ---- 起临时容器（sleep 保活；--attach=false 便于随后 kubectl cp）----
log_info "launching ephemeral container (image=$BASE_IMAGE, target=$target_container)..."
# sleep 3600 保活（coreutils/busybox applet 都有 sleep）。
# 注意 --image 必须是 glibc 系（debian/ubuntu/temurin 基），busybox/alpine 跑不了 Temurin JDK。
kubectl debug -n "$ns" "$pod" \
  --image="$BASE_IMAGE" \
  --target="$target_container" \
  --profile=sysadmin \
  --attach=false \
  -- sleep 3600 2>&1 | head -20

# 取本次创建的 ephemeral 容器名：kubectl debug 追加到数组末尾，故取 [-1]。
# （用 [0] 在有历史残留时会取错容器——K8s 不允许删 spec.ephemeralContainers，残留会累积。）
# 短重试：debug 返回与 spec 同步间有窄窗口，刚返回时 [-1] 偶发取空。
EPHE_ACTUAL=""
for _ in 1 2 3 4 5; do
  EPHE_ACTUAL=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.ephemeralContainers[-1].name}' 2>/dev/null)
  [ -n "$EPHE_ACTUAL" ] && break
  sleep 1
done
[ -z "$EPHE_ACTUAL" ] && { log_error "ephemeral 容器未创建（可能被准入拦截或镜像拉取失败）"; exit 1; }
EPHE_CREATED=1
log_info "ephemeral container name: $EPHE_ACTUAL"

# 等 ephemeral 容器进入 Running（kubectl cp 需要）。
# 用 EPHE_ACTUAL 名字定位（pod 可能已有历史 ephemeral 残留，按索引 [0] 会取错容器）。
for _ in 1 2 3 4 5 6 7 8 9 10 15 20 25 30; do
  state=$(kubectl get pod -n "$ns" "$pod" -o \
    jsonpath='{range .status.ephemeralContainerStatuses[*]}{.name}={.state.running}{","}{end}' 2>/dev/null)
  echo "$state" | tr ',' '\n' | grep -q "^${EPHE_ACTUAL}=.*running" && break
  sleep 1
done

# 基镜像若是 debian:bookworm-slim（默认），缺 unzip（第 2 道版本探测需要），装上。
# 幂等：已有 unzip 则跳过。约 1-2s。非 glibc 镜像（用户 --image=busybox/alpine）跳过——
# 但那类镜像跑不了 glibc JDK，会在跑 arthas 时报 libdl.so.2 缺失。
if ! kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- sh -c 'command -v unzip >/dev/null 2>&1' 2>/dev/null; then
  kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- sh -c \
    'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq unzip >/dev/null 2>&1 || true' 2>/dev/null
fi

# ---- 探测目标架构（节点 arch label 最可靠，兜底 uname）----
node=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
arch=""
if [ -n "$node" ]; then
  arch=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}' 2>/dev/null)
fi
if [ -z "$arch" ]; then
  raw_arch=$(kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- uname -m 2>/dev/null || echo "")
  case "$raw_arch" in aarch64|arm64) arch="aarch64" ;; x86_64|amd64) arch="x64" ;; esac
fi
case "$arch" in
  amd64|x86_64)  arch="x64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) log_warn "无法识别目标架构（node label 和 uname 都失败），默认 x64"; arch="x64" ;;
esac
log_info "target arch: $arch  (node: ${node:-unknown})"

# ---- 探测目标 JVM 版本（三道探测，逐道降级）----
# 1) /proc/<pid>/root/<javahome>/release  —— 最可靠，纯文本，不执行 java（完整 JDK/JRE 有）
# 2) 目标 jar 里首个 .class 的 major version —— jlink 定制运行时无 release 时的兜底
#    （纯读文件不执行 java，跨容器不依赖目标动态库）。major: 52=8 55=11 61=17 65=21
# 3) 直接跑目标 bin -version  —— 最后兜底，临时容器缺目标 libjli 时常失败
# 三道都失败 → 默认 jdk-17（打 FALLBACK 日志，建议 --jdk= 强制）
tgt_raw=$(kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- sh -c '
  for p in /proc/[0-9]*; do
    c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
    case "$c" in
      *java*)
        case "$c" in *arthas-boot.jar*) continue ;; esac
        pid=$(basename "$p"); set -- $c; bin=$1
        jh=$(dirname "$(dirname "$bin")")
        rel="/proc/$pid/root$jh/release"
        # 探测 1：release 文件
        if [ -f "$rel" ]; then echo "REL:"; cat "$rel"; exit 0; fi
        # 探测 2：从 -jar/-cp 取目标 jar，unzip 首个 class 读 major version
        #         默认 debian:bookworm-slim 探测前已装 unzip；-p 提取到 stdout 不落盘
        for a in $c; do
          case "$a" in
            *.jar)
              # -cp 可能有多个 jar 取首个；-jar 是主 jar
              jpath="/proc/$pid/root$a"
              [ -f "$jpath" ] || jpath="/proc/$pid/root$(pwd)$a"
              [ -f "$jpath" ] || continue
              fc=$(unzip -Z1 "$jpath" 2>/dev/null | grep "\.class$" | head -1)
              [ -z "$fc" ] && continue
              mj=$(unzip -p "$jpath" "$fc" 2>/dev/null | od -An -tu1 -j6 -N2 2>/dev/null | awk "{print \$1*256+\$2}")
              case "$mj" in
                52) echo "MAJOR:8"; exit 0 ;;
                55) echo "MAJOR:11"; exit 0 ;;
                61) echo "MAJOR:17"; exit 0 ;;
                65) echo "MAJOR:21"; exit 0 ;;
              esac
              ;;
          esac
        done
        # 探测 3：直接跑 bin -version
        "$bin" -version 2>&1 | head -1; exit 0 ;;
    esac
  done
  echo "UNKNOWN"
' 2>/dev/null)
# 解析三道探测的标记行
case "$tgt_raw" in
  REL:*)   tgt_major=$(printf '%s\n' "$tgt_raw" | tail -n +2 | awk -F= '/^JAVA_VERSION=/{gsub(/"/,"",$2);print $2;exit}')
           [ -z "$tgt_major" ] && tgt_major=$(printf '%s\n' "$tgt_raw" | tail -n +2 | head -1)
           log_info "target JVM: $tgt_major  (via release 文件)" ;;
  MAJOR:*) tgt_major=$(printf '%s\n' "$tgt_raw" | sed -n 's/^MAJOR://p')
           log_info "target JVM: jdk $tgt_major  (via class major version, 无 release 文件)" ;;
  *)       tgt_major=$(printf '%s\n' "$tgt_raw" | head -1)
           [ -n "$tgt_major" ] && [ "$tgt_major" != "UNKNOWN" ] && \
             log_info "target JVM: $tgt_major  (via bin -version)" ;;
esac

if [ -n "$FORCE_JDK" ]; then
  use_jdk="$FORCE_JDK"; log_info "using forced JDK: $use_jdk"
else
  case "$tgt_major" in
    *1.8*|*8u*|*8.0*|8)  use_jdk=8 ;;
    *11.*|11)            use_jdk=11 ;;
    *17.*|17)            use_jdk=17 ;;
    *21.*|21)            use_jdk=21 ;;
    *) log_warn "版本探测失败（三道均未识别，tgt='$tgt_major'），FALLBACK 默认 jdk-17；若 attach 失败请用 --jdk=8|11|17|21 强制"; use_jdk=17 ;;
  esac
  log_info "selected local JDK: $use_jdk"
fi

# 校验本地有对应版本+架构 JDK（移到选定版本后，修旧版只校验 jdk-17 的错位）
if [ ! -d "$JDK_DIR/jdk-${use_jdk}-${arch}" ]; then
  log_error "本地缺少 jdk-${use_jdk}-${arch}，请重跑 bash tools/fetch.sh 下双架构 JDK"
  exit 1
fi

# ---- 传 arthas dist ----
# kubectl cp dest 写法："$pod:/tmp/<file>" -c "$EPHE_ACTUAL"
#   错误写法 "$pod":"$EPHE_ACTUAL":/tmp/... 会被 kubectl 当成 pod=path（path 含冒号），cp 失败。
log_info "cp arthas dist -> ephemeral..."
kubectl cp "$ARTHAS_DIST_TAR" -n "$ns" "$pod:/tmp/arthas-dist.tar.gz" -c "$EPHE_ACTUAL"

# ---- 传匹配架构+版本的 JDK ----
JDK_TAR="$ROOT/tools/cache/jdk-${use_jdk}-${arch}.tar.gz"
repack_if_stale "$JDK_TAR" "$JDK_DIR/jdk-${use_jdk}-${arch}" "jdk-${use_jdk}-${arch}"
log_info "cp jdk-$use_jdk-$arch -> ephemeral..."
kubectl cp "$JDK_TAR" -n "$ns" "$pod:/tmp/jdk.tar.gz" -c "$EPHE_ACTUAL"

# ---- 在临时容器里解压 + 跑 arthas-boot attach 目标 pid ----
# 多人协作：随机端口 + 标记文件自动复用（不用提前商量端口）
#   首个用户：标记不存在 → 随机端口起 agent → 写标记到目标容器 rootFS
#   后续用户：标记存在 → 读记录端口 attach → arthas 检测已有 agent 自动复用
# 标记文件写在目标容器 rootFS（/proc/<pid>/root/tmp/），所有临时容器经此路径可读
# （pod 内共享网络 ns，agent 端口在 pod 网络空间，临时容器连 127.0.0.1:port 即目标 agent）
# arthas 4.3.4 同一 JVM 只能一个 agent，同 pod 多人复用同一 agent（各 session 独立）。
# 退出用 stop 卸载 agent（路径 C：agent 在目标 JVM，ephemeral 销毁≠agent 清理）。

# 外层探测目标 pid + 端口（外层 bash 有 RANDOM，不依赖容器内 awk strtonum）
TARGET_PID=$(kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- sh -c '
  for p in /proc/[0-9]*; do
    c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
    case "$c" in *java*) case "$c" in *arthas-boot.jar*) continue ;; esac
              basename "$p"; break ;; esac
  done
' 2>/dev/null | head -1)
[ -z "$TARGET_PID" ] && { log_error "未找到目标 java pid"; exit 1; }
log_info "target pid: $TARGET_PID"

# 标记文件在目标容器 rootFS（跨临时容器持久）
PORT_FILE="/tmp/arthas-port-$TARGET_PID"
PORT=$(kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- sh -c "cat /proc/$TARGET_PID/root$PORT_FILE 2>/dev/null" 2>/dev/null)
if [ -n "$PORT" ]; then
  log_info "reuse arthas agent on port $PORT（已有 agent，自动复用）"
else
  PORT=$(( (RANDOM % 10000) + 20000 ))
  log_info "new arthas agent on random port $PORT（首次）"
fi

log_info "starting arthas in ephemeral container..."
log_warn "⚠ 退出 arthas 请输入 stop（非 Ctrl+C/quit/exit）——agent 在目标 JVM，ephemeral 销毁不会卸载它"

kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -it -- sh -c '
  set -e
  cd /tmp
  tar -zxf arthas-dist.tar.gz
  tar -zxf jdk.tar.gz
  JAVA=/tmp/jdk-'"$use_jdk"'-'"$arch"'/bin/java
  exec "$JAVA" -jar /tmp/dist/arthas-boot.jar --telnet-port='"$PORT"' --http-port=-1 '"$TARGET_PID"'
'

# 首次起 agent 成功后写标记（标记不存在才写，记录本次端口供后续用户复用）
kubectl exec -n "$ns" "$pod" -c "$EPHE_ACTUAL" -- sh -c \
  "[ -f /proc/$TARGET_PID/root$PORT_FILE ] || echo $PORT > /proc/$TARGET_PID/root$PORT_FILE" 2>/dev/null || true

log_info "arthas session ended."
log_warn "彻底清理 agent + 标记：bash tools/stop-arthas.sh '$FLAG'（释放增强、删标记文件）"
