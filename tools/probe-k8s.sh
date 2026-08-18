#!/usr/bin/env bash
# probe-k8s.sh — 摸底目标 pod 的加固情况，判断 arthas attach 走哪条路径
#
# 企业级加固环境下，attach-k8s.sh 的"用容器 java"假设常不成立：
#   distroless 无 shell、JRE-only 无 attach API、readOnlyRootFS、非 root、禁 attach 参数...
# 本脚本对每个候选 pod 探测 6 个条件，输出 attach 路径建议 + 批量清单。
#
# 用法:
#   bash tools/probe-k8s.sh <pod-flag>           # 摸底匹配的 pod
#   bash tools/probe-k8s.sh <pod-flag> --all     # 含非 Running
#   bash tools/probe-k8s.sh --csv <pod-flag>     # CSV 清单（可排序筛选）
set -uo pipefail

log_info()  { printf "\033[34m%s\033[0m\n" "$*"; }
log_warn()  { printf "\033[33m%s\033[0m\n" "$*"; }
log_error() { printf "\033[31m%s\033[0m\n" "$*"; }

command -v kubectl >/dev/null || { log_error "kubectl not found"; exit 1; }
command -v jq     >/dev/null || { log_error "jq not found"; exit 1; }

CSV=0; ALL=0; FLAG=""
for a in "$@"; do
  case "$a" in
    --csv) CSV=1 ;;
    --all) ALL=1 ;;
    *) FLAG="$a" ;;
  esac
done
[ -z "$FLAG" ] && { echo 'usage: bash tools/probe-k8s.sh [--csv] [--all] <pod-flag>'; exit 1; }

# 取候选 pod：awk 取列 + index 子串匹配 ns/pod 名（避免旧版 grep 误命中 NODE/IP）
if [ "$ALL" -eq 1 ]; then
  mapfile -t pods < <(kubectl get po -A -o wide | awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)){print $1"\t"$2}')
else
  mapfile -t pods < <(kubectl get po -A -o wide | awk -v f="$FLAG" 'NR>1 && (index($2,f)||index($1,f)) && $4=="Running"{print $1"\t"$2}')
fi
[ "${#pods[@]}" -eq 0 ] && { log_error "no pod matched: $FLAG"; exit 1; }

probe_one() {  # ns pod -> 6 探测结果（路径写入全局 PROBE_PATH）
  local ns="$1" pod="$2"
  local has_shell java_path java_kind rootfs attach_param ephemeral_ok n_containers mainc
  local spec_json

  # 一次 get pod -o json，用 jq 提取所有 spec 字段（减少 round-trip；旧版每字段一次 kubectl）
  spec_json=$(kubectl get pod -n "$ns" "$pod" -o json 2>/dev/null || echo "{}")
  n_containers=$(printf '%s' "$spec_json" | jq -r '.spec.containers | length' 2>/dev/null)
  mainc=$(printf '%s' "$spec_json" | jq -r '.spec.containers[0].name // empty' 2>/dev/null)
  rootfs=$(printf '%s' "$spec_json" | jq -r '.spec.containers[0].securityContext.readOnlyRootFilesystem // "false(未设)"')
  local ranon runas
  ranon=$(printf '%s' "$spec_json" | jq -r '.spec.containers[0].securityContext.runAsNonRoot // "未设"')
  runas=$(printf '%s' "$spec_json" | jq -r '.spec.containers[0].securityContext.runAsUser // "未设"')
  local cmd args
  cmd=$(printf '%s' "$spec_json" | jq -r '.spec.containers[0].command // [] | join(" ")')
  args=$(printf '%s' "$spec_json" | jq -r '.spec.containers[0].args // [] | join(" ")')

  # 1+2) 合并一次 exec 探测：shell + java 二进制 + JDK/JRE（旧版分 3 次 exec）
  local out
  out=$(kubectl exec -n "$ns" "$pod" -c "$mainc" -- sh -c '
    sh_path=$(command -v bash sh ash 2>/dev/null | head -1)
    [ -n "$sh_path" ] && echo "shell=$sh_path" || echo "shell=no"
    java_path=$(command -v java 2>/dev/null)
    if [ -z "$java_path" ]; then
      for p in /proc/[0-9]*; do
        c=$(tr "\0" " " <"$p/cmdline" 2>/dev/null)
        case "$c" in *java*) set -- $c; java_path=$1; break ;; esac
      done
    fi
    if [ -z "$java_path" ]; then echo "java_kind=none"; exit 0; fi
    echo "java_path=$java_path"
    real=$(readlink -f "$java_path" 2>/dev/null || echo "$java_path")
    jh=$(dirname "$(dirname "$real")")
    if [ -f "$jh/lib/tools.jar" ]; then echo "java_kind=JDK8"
    elif ls "$jh/bin" 2>/dev/null | grep -qE "^(jcmd|jstack|jmap)$"; then echo "java_kind=JDK9plus"
    else echo "java_kind=JRE"
    fi
  ' 2>/dev/null || true)
  local shell_line
  shell_line=$(printf '%s\n' "$out" | sed -n 's/^shell=//p')
  has_shell=$([ -n "$shell_line" ] && [ "$shell_line" != "no" ] && echo yes || echo no)
  java_path=$(printf '%s\n' "$out" | sed -n 's/^java_path=//p')
  java_kind=$(printf '%s\n' "$out" | sed -n 's/^java_kind=//p')
  [ -z "$java_kind" ] && [ -n "$java_path" ] && java_kind="unknown"
  [ -z "$java_path" ] && java_kind="none"

  # 3) readOnlyRootFS（已从 spec 读）
  # 4) runAs（已从 spec 读）
  # 5) 禁 attach 参数
  attach_param="ok"
  if echo "$cmd $args" | grep -q "DisableAttachMechanism"; then
    attach_param="DISABLED(-XX:+DisableAttachMechanism)"
  fi

  # 6) ephemeral 是否允许：试探性创建（带 --profile=sysadmin，与实战 attach-ephemeral 一致）
  #    安全化：若 pod 已有 ephemeral 容器则跳过试探（旧版无脑 remove 整个数组会误删他人会话）
  local pre_ephe
  pre_ephe=$(printf '%s' "$spec_json" | jq -r '.spec.ephemeralContainers // [] | length' 2>/dev/null)
  ephemeral_ok="unknown"
  if [ "$pre_ephe" != "0" ]; then
    ephemeral_ok="skip(已有 $pre_ephe 个 ephemeral，未试探避免误伤)"
  elif kubectl debug -n "$ns" "$pod" --image=busybox:1.36 --target="$mainc" --profile=sysadmin --attach=false -- sh -c 'true' 2>/dev/null; then
    ephemeral_ok="yes"
    # pre_ephe=0 已保证数组原本为空，remove 整个数组只删本次试探产生的
    kubectl patch pod -n "$ns" "$pod" --type=json -p='[{"op":"remove","path":"/spec/ephemeralContainers"}]' 2>/dev/null || true
  else
    ephemeral_ok="no(可能被 admission 禁)"
  fi

  # ---- 选路 ----
  local path
  if [ "$has_shell" = "no" ]; then
    if [ "$ephemeral_ok" = "yes" ]; then path="ephemeral-container"
    else path="blocked(无 shell 且 ephemeral 被禁，需重启改镜像)"; fi
  elif [ "$java_kind" = "JRE" ] || [ "$java_kind" = "none" ]; then
    if [ "$ephemeral_ok" = "yes" ]; then path="ephemeral-container(传 JDK 进 debug 容器)"
    else path="blocked(JRE-only 且 ephemeral 被禁，需重启换 JDK 或改参数)"; fi
  elif [ "$attach_param" != "ok" ]; then
    path="blocked(应用层禁 attach，需重启去掉参数)"
  else
    path="exec-direct(容器 java 跑 arthas-boot)"
  fi
  PROBE_PATH="$path"

  if [ "$CSV" -eq 1 ]; then
    printf '%s,%s,%s,%s,%s,%s,%s/%s,%s,%s,%s\n' \
      "$ns" "$pod" "$has_shell" "$java_kind" "$java_path" "$rootfs" "$ranon" "$runas" "$attach_param" "$ephemeral_ok" "$path"
  else
    echo "────────────────────────────────────────"
    log_info "pod: $pod  ns: $ns  containers: ${n_containers:-?}"
    if [ "${n_containers:-0}" -gt 1 ] 2>/dev/null; then
      log_warn "  多容器 pod，仅探 containers[0] ($mainc)，sidecar 需 attach 时 -c/--container= 指定"
    fi
    echo "  shell:         $has_shell"
    echo "  java:          $java_kind  ($java_path)"
    echo "  readOnlyRootFS:$rootfs"
    echo "  runAs:         nonRoot=$ranon  uid=$runas"
    echo "  attach参数:    $attach_param"
    echo "  ephemeral:     $ephemeral_ok"
    log_warn "  → 建议路径: $path"
  fi
}

if [ "$CSV" -eq 1 ]; then
  echo "namespace,pod,shell,java_kind,java_path,readOnlyRootFS,runAs,attach_param,ephemeral,path"
fi
paths=()
for line in "${pods[@]}"; do
  IFS=$'\t' read -r ns pod <<<"$line"
  probe_one "$ns" "$pod"
  paths+=("$PROBE_PATH")
done
echo "────────────────────────────────────────"
log_info "汇总: 共 ${#pods[@]} 个 pod。路径分布:"
if [ "$CSV" -eq 0 ]; then
  printf '%s\n' "${paths[@]}" | sort | uniq -c | sed 's/^/  /'
fi
log_info "下一步: path=exec-direct → attach-k8s.sh；path=ephemeral* → attach-ephemeral.sh；path=blocked → 协调重启。"
