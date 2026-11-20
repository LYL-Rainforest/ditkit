#!/bin/bash
# 把 build/DitKit.app 打成定制拖拽式 DMG（软件图标水印背景 + 固定图标位置 + Applications 快捷方式）。
# 布局由 dmgbuild 直接写入 .DS_Store，不依赖 Finder AppleScript 权限。
# 产物：build/DitKit.dmg（不带版本号）；中间背景图与临时文件在成功后自动清理。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/DitKit.app"
VERSION="0.3.1"  # 仅备注；DMG 文件名不带版本号
VOLNAME="DitKit"
DMG="$BUILD/DitKit.dmg"
PYLIB="$BUILD/py"
SETTINGS="$ROOT/scripts/dmg-settings.py"

if [ ! -d "$APP" ]; then
    echo "错误：找不到 $APP，请先运行 scripts/build-app.sh" >&2
    exit 1
fi
if [ -d "/Volumes/$VOLNAME" ]; then
    hdiutil detach "/Volumes/$VOLNAME" -force > /dev/null || true
fi
mkdir -p "$BUILD"
rm -f "$DMG"

echo "==> [1/5] 生成 1x / 2x 背景图（软件图标半透明水印）"
RAW="$BUILD/background-raw.png"
BG1X="$BUILD/background-dmg.png"
BG2X="$BUILD/background-dmg@2x.png"
swift "$ROOT/scripts/make-background.swift" "$RAW" "$ROOT/macos/Resources/AppIcon.icns"
cp -f "$RAW" "$BG1X"
sips -z 400 660 "$BG1X" > /dev/null
sips -s dpiWidth 72 -s dpiHeight 72 "$BG1X" > /dev/null
cp -f "$RAW" "$BG2X"
sips -z 800 1320 "$BG2X" > /dev/null
sips -s dpiWidth 144 -s dpiHeight 144 "$BG2X" > /dev/null
echo "    $(sips -g pixelWidth -g pixelHeight "$BG1X" | tr '\n' ' ')"
echo "    $(sips -g pixelWidth -g pixelHeight "$BG2X" | tr '\n' ' ')"

echo "==> [2/5] 准备 dmgbuild（仅首次需要联网）"
if [ ! -d "$PYLIB/dmgbuild" ]; then
    python3 -m pip install --disable-pip-version-check --target "$PYLIB" dmgbuild > /dev/null
    echo "    已安装到 $PYLIB"
fi

echo "==> [3/5] 生成定制 DMG"
PYTHONPATH="$PYLIB" python3 -m dmgbuild -D "root=$ROOT" -s "$SETTINGS" "$VOLNAME" "$DMG"
codesign --force --sign - --timestamp=none "$DMG" > /dev/null 2>&1 || \
    echo "    提示：DMG 未做代码签名（不影响本机安装）"

echo "==> [4/5] 校验镜像与内容"
hdiutil verify "$DMG" | tail -2
CHECK="$(mktemp -d /tmp/ditkit-dmg-check.XXXXXX)"
hdiutil attach "$DMG" -mountpoint "$CHECK" -noautoopen -nobrowse > /dev/null
echo "    卷内容："
ls -a "$CHECK" | grep -E '^\.|DitKit|Applications' | sed 's/^/      /'
echo "    App 内可执行文件："
ls -l "$CHECK/DitKit.app/Contents/MacOS" | awk 'NR>1 {print "      " $9, $5 " bytes"}'
echo "    Applications 快捷方式：$(readlink "$CHECK/Applications")"
codesign --verify --deep --strict "$CHECK/DitKit.app" && echo "    App 签名：有效"
if [ -f "$CHECK/.DS_Store" ]; then
    echo "    Finder 布局：.DS_Store 已写入（$(stat -f%z "$CHECK/.DS_Store") bytes）"
else
    echo "    警告：缺少 .DS_Store" >&2
fi
hdiutil detach "$CHECK" > /dev/null
rmdir "$CHECK"

echo "==> [5/5] 产物与清理"
ls -lh "$DMG"
rm -f "$RAW" "$BG1X" "$BG2X"
echo "    已清理中间背景图（下次构建自动重建）"
echo "完成：$DMG"
