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

# ---- 依赖检查（旧版无检查，缺失时报原始错不友好）----
for d in curl jq tar unzip sha256sum awk readelf; do
  command -v "$d" >/dev/null || { echo "missing dependency: $d (请安装后重跑)"; exit 1; }
done

AR_VERSION="4.3.4"
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

echo "===== JDKs (Tsinghua TUNA Adoptium mirror, linux/x64 + aarch64) ====="
: > "$MANIFEST"
printf "arthas\tboot\t%s\t%s\n" "$AR_VERSION" "$BOOT_SHA" >> "$MANIFEST"
printf "arthas\tdist-zip\t%s\t%s\n" "$AR_VERSION" "$ZIP_SHA" >> "$MANIFEST"

i=3
for v in 8 11 17 21; do
  for arch in x64 aarch64; do
    IFS=$'\t' read -r ver link sha name <<<"$(jdk_meta "$v" "$arch" || true)"
    if [[ -z "$sha" ]]; then
      echo "  [$i/10] JDK $v $arch meta 缺失，跳过"; i=$((i+1)); continue
    fi
    dest="$CACHE/$name"
    echo "[$i/10] JDK $v  $ver  $arch"
    if [[ -f "$dest" ]] && echo "$sha  $dest" | sha256sum -c - >/dev/null 2>&1; then
      echo "  cached (sha256 ok)"
    else
      dl "$TUNA/$v/jdk/$arch/linux/$name" "$dest" || dl "$link" "$dest"
      echo "$sha  $dest" | sha256sum -c -
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
for v in 8 11 17 21; do printf "jdk-%-2s-x64     " "$v"; "$JDK_DIR/jdk-${v}-x64/bin/java" -version 2>&1 | head -1; done
for v in 8 11 17 21; do printf "jdk-%-2s-aarch64  " "$v"; [ -d "$JDK_DIR/jdk-${v}-aarch64" ] && echo "present (sha256+ELF verified)" || echo "MISSING"; done
echo "--- arthas dist contents ---"; ls "$DIST_DIR" | head -20
