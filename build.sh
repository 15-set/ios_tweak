#!/usr/bin/env bash
# Insulation-Mod 一键构建/打包脚本（在 Linux 或 WSL 中运行）
#
# 用法:
#   ./build.sh                 # 默认 rootless（palera1n / Dopamine, iOS 15+）
#   THEOS_PACKAGE_SCHEME=rootful   ./build.sh
#   THEOS_PACKAGE_SCHEME=roothide  ./build.sh
#
# 前置依赖见 CHANGES.md「构建与打包」一节。若文件是 CRLF（从 Windows 拷入）：
#   sed -i 's/\r$//' build.sh && chmod +x build.sh

set -euo pipefail

SCHEME="${THEOS_PACKAGE_SCHEME:-rootless}"
export THEOS="${THEOS:-$HOME/theos}"
cd "$(dirname "$0")"

echo "== 1/5 检查工具链 =="
missing=0
for c in make clang ldid dpkg-deb; do
    if command -v "$c" >/dev/null 2>&1; then
        echo "  OK   $c -> $(command -v "$c")"
    else
        echo "  MISS $c"; missing=1
    fi
done
[ -d "$THEOS/lib" ] || { echo "  MISS theos ($THEOS)"; missing=1; }
if ls "$THEOS"/sdks/iPhoneOS*.sdk >/dev/null 2>&1; then
    echo "  OK   SDK -> $(ls -d "$THEOS"/sdks/iPhoneOS*.sdk | tail -1)"
else
    echo "  MISS iPhoneOS SDK ($THEOS/sdks)"; missing=1
fi
command -v plistutil >/dev/null 2>&1 || echo "  WARN 无 plistutil（insulation.plist 为 ASCII 格式，theos 需要它转二进制）"
[ "$missing" -eq 0 ] || { echo "工具链不完整，终止。"; exit 1; }

echo "== 2/5 make clean =="
make clean THEOS_PACKAGE_SCHEME="$SCHEME"

echo "== 3/5 编译 =="
make -j"$(nproc)" THEOS_PACKAGE_SCHEME="$SCHEME" DEBUG=0 \
     messages=yes 2>&1 | tee /tmp/insulation-build.log

echo "== 4/5 打包 =="
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME="$SCHEME"

echo "== 5/5 校验产物 =="
deb="$(ls -t packages/*.deb 2>/dev/null | head -1)"
[ -n "$deb" ] || { echo "未生成 .deb"; exit 1; }
echo "产物: $(realpath "$deb")  大小: $(du -h "$deb" | cut -f1)"
echo "--- dpkg-deb -I ---"
dpkg-deb -I "$deb"
echo "--- dpkg-deb -c ---"
dpkg-deb -c "$deb"
