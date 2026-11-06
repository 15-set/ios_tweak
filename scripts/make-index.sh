#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO_URL="${REPO_URL:-https://15-set.github.io/ios_tweak/}"; mkdir -p debs
command -v apt-ftparchive >/dev/null 2>&1 || { echo "缺少 apt-ftparchive"; exit 1; }
DEBS_ABS="$ROOT/debs"
if apt-ftparchive packages "$DEBS_ABS" >/dev/null 2>&1; then
  apt-ftparchive packages "$DEBS_ABS" | sed "s#^Filename: .*/#Filename: debs/#" > Packages
else
  SCAN="$(mktemp -d)/debs"; mkdir -p "$SCAN"; cp -f "$DEBS_ABS"/*.deb "$SCAN"/ 2>/dev/null || true
  apt-ftparchive packages "$SCAN" | sed "s#^Filename: .*/#Filename: debs/#" > Packages
fi
# 注意：脚本开启了 set -e，可选的 override 步骤必须用 if 包裹，
# 否则没有 overrides.json 时 [ -f ] 返回 1 会让整个脚本提前退出，
# 导致 Packages.gz / Release 停留在旧状态，源刷新时报哈希不匹配。
if [ -f overrides.json ] && command -v python3 >/dev/null 2>&1; then
  python3 scripts/apply-overrides.py || echo "(override 应用跳过)"
fi
# 分类：sections.json 里 keep 的保留，按 orig 匹配 deb 原始分区名，
# 认领不到的一律归入兜底分类「插件」，绝不输出「～其它」这类历史分区名
# 必须在 apply-overrides.py 之后跑（那边可能改 Name/Description），在 gzip 之前跑
if [ -f sections.json ] && command -v python3 >/dev/null 2>&1; then
  echo "分类配置: $(head -c 300 sections.json)"
  if ! python3 scripts/apply-sections.py; then
    echo "(分类合并失败，Packages 保持原样；请检查 scripts/apply-sections.py)"
  fi
fi
# gzip 必须紧跟 Packages 生成之后，且要确保产物是最新的
rm -f Packages.gz
gzip -9 -c Packages > Packages.gz
gen_hashes(){ local alg="$1"; shift; local f; for f in "$@"; do [ -f "$f" ] || continue;
  local size; size=$(wc -c < "$f" | tr -d ' '); local h;
  case "$alg" in md5) h=$(md5sum "$f"|awk '{print $1}');; sha256) h=$(sha256sum "$f"|awk '{print $1}');; esac
  printf ' %s  %s %s\n' "$h" "$size" "$f"; done; }
{ echo "Origin: 15"; echo "Label: 15"; echo "Suite: stable"; echo "Version: 1.0";
  echo "Codename: ios"; echo "Architectures: iphoneos-arm64 iphoneos-arm64e"; echo "Components: main";
  echo "Description: 15"; echo "Support: $REPO_URL";
  # Icon 必须写绝对地址：Sileo/Zebra 只认 Release 里的 Icon 行，不会自己去找 CydiaIcon.png
  echo "Icon: ${REPO_URL%/}/CydiaIcon.png";
  echo "MD5Sum:"; gen_hashes md5 Packages Packages.gz; echo "SHA256:"; gen_hashes sha256 Packages Packages.gz; } > Release
echo "索引完成: $(grep -c '^Package:' Packages) 个包"