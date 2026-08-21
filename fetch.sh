#!/usr/bin/env bash
# fetch.sh — download Arthas + multi-version JDKs, verify sha256, extract, emit MANIFEST.
# Sources chosen for speed from this network:
#   - Arthas dist zip: Aliyun maven mirror + maven central .sha256
#   - arthas-boot.jar: arthas.aliyun.com CDN（与 dist/arthas-boot.jar 交叉校验）
#   - JDKs: Tsinghua TUNA Adoptium mirror, sha256 from official Adoptium API (mirror content identical)
# Idempotent: re-run to refresh / verify existing downloads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
JDK_DIR="$ROOT/jdk"
ARTHAS_DIR="$ROOT/arthas"
DIST_DIR="$ARTHAS_DIR/dist"
CACHE="$ROOT/cache"
MANIFEST="$ROOT/MANIFEST.txt"
mkdir -p "$JDK_DIR" "$DIST_DIR" "$CACHE"

# ---- 依赖检查：一次性全检测，缺失的攒齐再提示一键安装（不再缺一个拦一次）----
DEPS=(curl jq tar unzip sha256sum awk readelf)
missing=()
for d in "${DEPS[@]}"; do
  command -v "$d" >/dev/null || missing+=("$d")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "❌ 缺失依赖: ${missing[*]}"
  echo ""
  # 识别发行版，给对应的一键安装命令（只打印，不自动执行——装包要 root 且改系统，你来决定）
  if [ -f /etc/os-release ]; then
    . /etc/os-release
  else
    ID="unknown"
  fi
  case "$ID" in
    debian|ubuntu)
      echo "一键安装（复制执行）："
      echo "  sudo apt-get update && sudo apt-get install -y ${missing[*]}"
      ;;
    euleros|centos|rhel|fedora|rocky|almalinux|anolis)
      # sha256sum 在 coreutils、readelf 在 binutils，EulerOS 源可能没有 jq（用静态二进制）
      yum_pkgs=()
      for m in "${missing[@]}"; do
        case "$m" in
          jq) echo "  ⚠ $ID 源常无 jq 包，下静态二进制：" ; echo "     curl -fsSL -o /usr/local/bin/jq https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 && chmod +x /usr/local/bin/jq" ;;
          sha256sum) yum_pkgs+=(coreutils) ;;
          readelf)   yum_pkgs+=(binutils) ;;
          *)         yum_pkgs+=("$m") ;;
        esac
      done
      if [ "${#yum_pkgs[@]}" -gt 0 ]; then
        echo "一键安装（复制执行）："
        echo "  sudo yum install -y ${yum_pkgs[*]}"
      fi
      ;;
    alpine)
      echo "一键安装（复制执行）："
      echo "  sudo apk add ${missing[*]}"
      ;;
    *)
      echo "请手动安装: ${missing[*]}"
      echo "  （apt-get / yum / apk 按你的发行版选；jq 可用静态二进制：https://github.com/jqlang/jq/releases/latest）"
      ;;
  esac
  echo ""
  echo "装完重跑: bash fetch.sh"
  exit 1
fi

# 动态获取最新 Arthas 版本（从 maven metadata）；可设 ARTHAS_VERSION 环境变量覆盖
AR_VERSION_DEFAULT="4.3.4"  # 后备默认版本
if [[ -n "${ARTHAS_VERSION:-}" ]]; then
  AR_VERSION="$ARTHAS_VERSION"
  echo "使用指定版本 (ARTHAS_VERSION): $AR_VERSION"
else
  AR_METADATA_URL="https://maven.aliyun.com/repository/public/com/taobao/arthas/arthas-packaging/maven-metadata.xml"
  AR_METADATA=$(curl -fsL --retry 2 "$AR_METADATA_URL" 2>/dev/null || true)
  AR_VERSION=$(echo "$AR_METADATA" | grep -oP '<release>\K[^<]+' | head -1)
  if [[ -z "$AR_VERSION" ]]; then
    echo "warn: 无法获取最新版本号，使用默认版本 $AR_VERSION_DEFAULT" >&2
    AR_VERSION="$AR_VERSION_DEFAULT"
  else
    echo "检测到最新 Arthas 版本: $AR_VERSION"
  fi
fi

AR_ZIP_URL="https://maven.aliyun.com/repository/public/com/taobao/arthas/arthas-packaging/${AR_VERSION}/arthas-packaging-${AR_VERSION}-bin.zip"
AR_ZIP_SHA_URL="https://repo1.maven.org/maven2/com/taobao/arthas/arthas-packaging/${AR_VERSION}/arthas-packaging-${AR_VERSION}-bin.zip.sha256"
AR_BOOT_URL="https://arthas.aliyun.com/arthas-boot.jar"
TUNA="https://mirrors.tuna.tsinghua.edu.cn/Adoptium"

dl() {  # url dest
  echo "  ↓ $(basename "$2")"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 -o "$2" "$1"
}

jdk_meta() {  # ver arch -> "ver\tlink\tsha\tname"
  local v="$1" arch="$2" json="$CACHE/jdk${v}-${arch}.json"
  local api="https://api.adoptium.net/v3/assets/feature_releases/$v/ga?os=linux&architecture=$arch&image_type=jdk&jvm_impl=hotspot&heap_size=normal&vendor=eclipse"
  if [[ ! -f "$json" ]]; then
    curl -s "$api" > "$json" || true
  fi
  # 校验 json 有效（#10：旧版不校验，API 限流/错误页会缓存中毒 → 后续 sha/link 全空 → 下错）
  if ! jq -e '.[0].binaries[0].package.link' "$json" >/dev/null 2>&1; then
    echo "  warn: jdk${v}-${arch} json 无效或限流，重新拉取" >&2
    rm -f "$json"
    curl -s "$api" > "$json" || true
    if ! jq -e '.[0].binaries[0].package.link' "$json" >/dev/null 2>&1; then
      echo "  error: jdk${v}-${arch} meta 仍无效，跳过" >&2
      return 1
    fi
  fi
  jq -r --arg arch "$arch" '.[0] | [.version_data.openjdk_version,
                 (.binaries[]|select(.os=="linux" and .architecture==$arch)|.package.link),
                 (.binaries[]|select(.os=="linux" and .architecture==$arch)|.package.checksum),
                 (.binaries[]|select(.os=="linux" and .architecture==$arch)|.package.name)] | @tsv' "$json"
}

# 列 TUNA 镜像目录里实际缓存的 .tar.gz 文件名（TUNA 常滞后官方，缓存旧 build，
# 文件名与 API latest 不同 → 直接拼 latest URL 会 404，需列目录找实际存在的 build）
tuna_list() {  # ver arch -> 文件名，每行一个
  curl -s "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$1/jdk/$2/linux/" 2>/dev/null \
    | grep -oE 'href="[^"]+\.tar\.gz"' | sed 's/href="//;s/"//'
}

# ELF 架构确认：校验下载的 JDK 二进制确实是目标架构
# （#23：旧版 aarch64 仅 sha256，无 ELF 确认；json 错乱下错架构包时 sha 会拦，但 ELF 是二次确认）
elf_arch_tag() {  # jdk_home -> x64/aarch64/unknown(...)
  local bin="$1/bin/java"
  [[ -f "$bin" ]] || { echo "unknown"; return; }
  local m
  m=$(readelf -h "$bin" 2>/dev/null | awk -F: '/^[[:space:]]*Machine:/{gsub(/^[[:space:]]+/,"",$2);print $2;exit}')
  case "$m" in
    "Advanced Micro Devices X86-64"|"x86-64") echo "x64" ;;
    "AArch64"|"aarch64") echo "aarch64" ;;
    *) echo "unknown($m)" ;;
  esac
}

# 集群 pod 架构分布探测（可选）：列 node/pod 按归一化架构(x64/aarch64)分布，
# 帮使用者判断实际要下哪个架构的 JDK，避免盲目 both 下全量。
# 归一化规则与 jdk-<v>-<arch> 目录名一致：amd64/x86_64→x64，arm64/aarch64→aarch64。
probe_k8s_arch() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "  （无 kubectl，跳过集群探测）"; return 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "  （kubectl 连不上集群，跳过——确认 ~/.kube/config 或当前 context）"; return 1
  fi
  local tmp; tmp=$(mktemp -d 2>/dev/null || mktemp -d -t arthas)
  if ! kubectl get nodes -o json >"$tmp/nodes.json" 2>/dev/null \
     || ! kubectl get pods -A -o json >"$tmp/pods.json" 2>/dev/null; then
    echo "  （列举 node/pod 失败，跳过探测）"; rm -rf "$tmp"; return 1
  fi
  # 节点名 → 归一化架构 的映射表
  local archmap
  archmap=$(jq -r '
    def norm: ascii_downcase |
      if   . == "amd64" or . == "x86_64" or . == "x64" then "x64"
      elif . == "arm64" or . == "aarch64"             then "aarch64"
      else . end;
    [.items[] | {key:.metadata.name, value:((.metadata.labels["kubernetes.io/arch"] // "unknown")|norm)}]
    | from_entries
  ' "$tmp/nodes.json" 2>/dev/null) || { rm -rf "$tmp"; echo "  （解析 node 架构失败，跳过）"; return 1; }

  echo "  节点架构分布:"
  jq -r '
    def norm: ascii_downcase |
      if   . == "amd64" or . == "x86_64" or . == "x64" then "x64"
      elif . == "arm64" or . == "aarch64"             then "aarch64"
      else . end;
    [.items[] | (.metadata.labels["kubernetes.io/arch"] // "unknown")|norm]
    | group_by(.) | map("\(length)\t\(.[0])")[]
  ' "$tmp/nodes.json" 2>/dev/null \
    | sort -rn | sed 's/^/    /' || true
  echo "  pod 按节点架构分布（pod 架构 = 其所在节点架构）:"
  jq --argjson na "$archmap" -r '
    [.items[] | (.spec.nodeName // "unknown") as $n | ($na[$n] // "unknown")]
    | group_by(.) | map("\(length)\t\(.[0])")[]
  ' "$tmp/pods.json" 2>/dev/null \
    | sort -rn | sed 's/^/    /' || true
  rm -rf "$tmp"
}

echo "===== Arthas ${AR_VERSION} ====="
echo "[1/10] arthas-packaging-${AR_VERSION}-bin.zip (Aliyun maven + sha256)"
# #12：sha 源失败时降级用缓存（旧版 set -e+pipefail 会直接退出，即使主 zip 已缓存）
AR_SHA=$(curl -fsL --retry 2 "$AR_ZIP_SHA_URL" 2>/dev/null | awk '{print $1}' || true)
if [[ -n "$AR_SHA" ]]; then
  if [[ -f "$CACHE/arthas-bin.zip" ]] && echo "$AR_SHA  $CACHE/arthas-bin.zip" | sha256sum -c - >/dev/null 2>&1; then
    echo "  cached (sha256 ok)"
  else
    rm -f "$CACHE/arthas-bin.zip"; dl "$AR_ZIP_URL" "$CACHE/arthas-bin.zip"
    echo "$AR_SHA  $CACHE/arthas-bin.zip" | sha256sum -c -
  fi
else
  if [[ -f "$CACHE/arthas-bin.zip" ]] && unzip -tq "$CACHE/arthas-bin.zip" >/dev/null 2>&1; then
    echo "  warn: sha 源不可达，复用已缓存 zip（unzip -t 完整性通过，未做 sha256 校验）"
  else
    dl "$AR_ZIP_URL" "$CACHE/arthas-bin.zip"
    echo "  warn: sha 源不可达，下载完成但未校验 sha256"
  fi
fi
ZIP_SHA="${AR_SHA:-N/A}"
rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"
unzip -q -o "$CACHE/arthas-bin.zip" -d "$DIST_DIR"
echo "  extracted -> arthas/dist/  sha=$ZIP_SHA"

echo "[2/10] arthas-boot.jar (CDN entry，与 dist/arthas-boot.jar 交叉校验)"
# #11：旧版只算 sha 写 MANIFEST、从不比对。CDN 不提供 .sha256，maven central 的
# arthas-boot artifact 与 CDN fat jar 可能不同构建、不可靠。改用与已校验 dist 里的
# arthas-boot.jar 字节比对（dist zip 的 sha256 已校验，其内文件可信）。
if [[ -f "$ARTHAS_DIR/arthas-boot.jar" && -f "$DIST_DIR/arthas-boot.jar" ]] \
   && cmp -s "$ARTHAS_DIR/arthas-boot.jar" "$DIST_DIR/arthas-boot.jar"; then
  echo "  cached (与 dist/arthas-boot.jar 字节一致)"
else
  dl "$AR_BOOT_URL" "$ARTHAS_DIR/arthas-boot.jar"
  if [[ -f "$DIST_DIR/arthas-boot.jar" ]] && ! cmp -s "$ARTHAS_DIR/arthas-boot.jar" "$DIST_DIR/arthas-boot.jar"; then
    echo "  ⚠ CDN boot.jar 与 dist/arthas-boot.jar 不一致（可能不同构建），已下载并记录实测 sha"
  fi
fi
BOOT_SHA=$(sha256sum "$ARTHAS_DIR/arthas-boot.jar" | awk '{print $1}')

echo "===== JDKs (Tsinghua TUNA Adoptium mirror) ====="
: > "$MANIFEST"
printf "arthas\tboot\t%s\t%s\n" "$AR_VERSION" "$BOOT_SHA" >> "$MANIFEST"
printf "arthas\tdist-zip\t%s\t%s\n" "$AR_VERSION" "$ZIP_SHA" >> "$MANIFEST"

# ---- 选 JDK 版本 + 架构（交互式；回车=全选/both）----
# 不必每次下全部 8 个 JDK（~1.6G）。操作节点常只关心特定架构/版本，按需下省时省地。
ALL_VERSIONS=(8 11 17 21)
echo "可选 JDK 版本: ${ALL_VERSIONS[*]}"
read -rp "输入要下的版本（空格分隔，回车=全选）: " vinput
if [ -z "$vinput" ]; then
  SEL_VERSIONS=("${ALL_VERSIONS[@]}")
else
  SEL_VERSIONS=()
  for v in $vinput; do
    case "$v" in 8|11|17|21) SEL_VERSIONS+=("$v") ;; *) echo "  忽略非法版本: $v" ;; esac
  done
  [ "${#SEL_VERSIONS[@]}" -eq 0 ] && { echo "无有效版本，退出"; exit 1; }
fi
# 选架构前可先探测集群 pod 架构分布，按实际分布决定下 x64 / aarch64 / both（而非盲目全量）
read -rp "探测集群 pod 架构分布以辅助选架构? [Y/n] " probe
case "${probe:-Y}" in
  y|Y|yes) probe_k8s_arch || true ;;
esac
read -rp "选架构 [1]x64 [2]aarch64 [3]both（回车=both）: " ainput
case "$ainput" in
  ""|3|both|BOTH)   SEL_ARCHS=(x64 aarch64) ;;
  1|x64|X64)        SEL_ARCHS=(x64) ;;
  2|aarch64|AARCH64) SEL_ARCHS=(aarch64) ;;
  *) echo "  无效输入，默认 both"; SEL_ARCHS=(x64 aarch64) ;;
esac
JDK_COUNT=$(( ${#SEL_VERSIONS[@]} * ${#SEL_ARCHS[@]} ))
TOTAL=$(( 2 + JDK_COUNT ))
echo "→ 将下载 JDK 版本: ${SEL_VERSIONS[*]}  架构: ${SEL_ARCHS[*]}  共 $JDK_COUNT 个"

i=3
for v in "${SEL_VERSIONS[@]}"; do
  for arch in "${SEL_ARCHS[@]}"; do
    IFS=$'\t' read -r ver link sha name <<<"$(jdk_meta "$v" "$arch" || true)"
    if [[ -z "$sha" ]]; then
      echo "  [$i/$TOTAL] JDK $v $arch meta 缺失，跳过"; i=$((i+1)); continue
    fi
    echo "[$i/$TOTAL] JDK $v  $ver  $arch"
    dest="$CACHE/$name"
    # 缓存命中（latest sha 校验通过）→ 跳过
    if [[ -f "$dest" ]] && echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
      echo "  cached (sha256 ok)"
    else
      # TUNA 镜像常滞后官方（缓存旧 build，sha 与 latest 不同）。先 HEAD 探测 latest 文件名是否在 TUNA。
      tuna_url="$TUNA/$v/jdk/$arch/linux/$name"
      tuna_code=$(curl -s -o /dev/null -w "%{http_code}" -I -L "$tuna_url" 2>/dev/null || echo 000)
      if [[ "$tuna_code" == "200" ]]; then
        # TUNA 已同步 latest → 直接快速下，校验 latest sha
        dl "$tuna_url" "$dest"
        if echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
          echo "  ✓ TUNA 镜像（与官方同步，快）"
        else
          echo "  ⚠ TUNA 文件 sha 与官方 latest 不符，转选源"; _choose=1
        fi
      else
        _choose=1   # TUNA 404/不可达 → 滞后，进选源
      fi
      if [[ "${_choose:-0}" == "1" ]]; then
        _choose=0
        # 列 TUNA 目录，按 API 数组新→旧取第一个也在 TUNA 的 build（其 sha 可从 API 查到 → 能校验）
        tuna_files=$(tuna_list "$v" "$arch")
        jsonf="$CACHE/jdk${v}-${arch}.json"
        pick_name=""; pick_ver=""; pick_sha=""
        if [[ -f "$jsonf" ]]; then
          while IFS=$'\t' read -r tname tver tsha; do
            [[ -z "$tname" ]] && continue
            if grep -qxF "$tname" <<<"$tuna_files"; then pick_name="$tname"; pick_ver="$tver"; pick_sha="$tsha"; break; fi
          done < <(jq -r --arg arch "$arch" '.[] | [(.binaries[]|select(.os=="linux" and .architecture==$arch)|.package.name), .version_data.openjdk_version, (.binaries[]|select(.os=="linux" and .architecture==$arch)|.package.checksum)] | @tsv' "$jsonf")
        fi
        if [[ -n "$pick_name" ]]; then
          # 重跑幂等：若旧 build 已缓存且 sha 通过，直接复用，不再提示/重下
          pick_dest="$CACHE/$pick_name"
          if [[ -f "$pick_dest" ]] && echo "$pick_sha  $pick_dest" | sha256sum -c - >/dev/null 2>&1; then
            echo "  cached (TUNA 旧 build $pick_ver，sha256 ok)"
            dest="$pick_dest"; ver="$pick_ver"; sha="$pick_sha"; name="$pick_name"
          else
          echo "  ⚠ TUNA 镜像滞后：缓存旧 build $pick_ver，官方最新 $ver（sha 不同）"
          echo "    [1] 官方 GitHub（最新 $ver，较慢，sha 已校验）"
          echo "    [2] TUNA 镜像（旧 $pick_ver，快，sha 可校验）"
          read -rp "  选源 [1/2，回车=2 快]: " sc
          case "${sc:-2}" in
            1) dl "$link" "$dest"; echo "$sha  $dest" | sha256sum -c - || { echo "  ❌ 官方 sha 校验失败"; exit 1; } ;;
            2)
              dest="$CACHE/$pick_name"
              dl "$TUNA/$v/jdk/$arch/linux/$pick_name" "$dest"
              echo "$pick_sha  $dest" | sha256sum -c - || { echo "  ❌ TUNA 旧 build sha 校验失败"; exit 1; }
              echo "  ✓ TUNA 旧 build $pick_ver（快，sha 已校验）"
              # 实际下的是旧 build，覆盖 ver/sha/name 让 MANIFEST 记录正确
              ver="$pick_ver"; sha="$pick_sha"; name="$pick_name"
              ;;
            *) echo "  无效输入，默认官方"; dl "$link" "$dest"; echo "$sha  $dest" | sha256sum -c - || exit 1 ;;
          esac
          fi
        else
          # TUNA 列目录失败或无匹配旧 build → 直接官方
          echo "  TUNA 不可用/无匹配旧 build，走官方 GitHub（较慢）"
          dl "$link" "$dest"; echo "$sha  $dest" | sha256sum -c - || { echo "  ❌ 官方 sha 校验失败"; exit 1; }
        fi
      fi
    fi
    target="$JDK_DIR/jdk-${v}-${arch}"
    rm -rf "$target"; mkdir -p "$target"
    tar -xzf "$dest" --strip-components=1 -C "$target"
    # ELF 架构确认 + x64 本机跑 java -version；aarch64 本机非 arm 用 ELF 确认
    elf_tag=$(elf_arch_tag "$target")
    if [[ "$arch" == "x64" ]]; then
      jver="$("$target/bin/java" -version 2>&1 | head -1)"
      echo "  -> $target  $jver  elf=$elf_tag"
    else
      echo "  -> $target  (aarch64, sha256 ok, elf=$elf_tag)"
    fi
    [[ "$elf_tag" == "$arch" ]] || echo "  ⚠ ELF 架构($elf_tag) ≠ 预期($arch)，请核查"
    printf "jdk\t%s\t%s\t%s\t%s\t%s\n" "$v" "$arch" "$ver" "$sha" "$name" >> "$MANIFEST"
    i=$((i+1))
  done
done

# 清理早期无 arch 后缀的旧 json（现版用 jdk<v>-<arch>.json）#24
for f in "$CACHE"/jdk8.json "$CACHE"/jdk11.json "$CACHE"/jdk17.json "$CACHE"/jdk21.json; do
  [[ -f "$f" ]] && rm -f "$f" && echo "  cleaned legacy $(basename "$f")"
done

echo "===== DONE ====="
echo "--- MANIFEST ---"; cat "$MANIFEST"
echo "--- VERIFY (x64 java -version; aarch64 ELF 架构确认) ---"
for v in "${SEL_VERSIONS[@]}"; do
  case " ${SEL_ARCHS[*]} " in *" x64 "*)
    printf "jdk-%-2s-x64     " "$v"; "$JDK_DIR/jdk-${v}-x64/bin/java" -version 2>&1 | head -1 ;;
  esac
done
for v in "${SEL_VERSIONS[@]}"; do
  case " ${SEL_ARCHS[*]} " in *" aarch64 "*)
    printf "jdk-%-2s-aarch64  " "$v"; [ -d "$JDK_DIR/jdk-${v}-aarch64" ] && echo "present (sha256+ELF verified)" || echo "MISSING" ;;
  esac
done
echo "--- arthas dist contents ---"; ls "$DIST_DIR" | head -20
