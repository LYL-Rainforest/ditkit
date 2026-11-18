#!/bin/bash
# 编译 Go 后端 + SwiftUI 前端，组装成自带 ditkitd 与 smartctl 的独立 DitKit.app。
# 产物：build/ditkitd、build/DitKit.app（构建产物统一放 build/，不污染项目根目录）。
# 内嵌的 smartctl 只依赖系统库（IOKit/CoreFoundation），因此安装后无需 Homebrew 或联网。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/DitKit.app"
VERSION="0.3.0"
BUNDLE_ID="cn.rainforest.ditkit"

mkdir -p "$BUILD"

# 定位构建机上的 smartctl（解析符号链接，拿到 Cellar 里的真实文件与许可证）。
SMARTCTL="$(command -v smartctl || true)"
if [ -z "$SMARTCTL" ]; then
    echo "错误：构建机未找到 smartctl，请先执行 brew install smartmontools" >&2
    exit 1
fi
SMARTCTL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SMARTCTL")"
LICENSE_SRC="$(dirname "$(dirname "$SMARTCTL")")/COPYING"

echo "==> [1/6] 编译 Go 后端 ditkitd"
go build -C "$ROOT" -o "$BUILD/ditkitd" ./cmd/ditkitd

echo "==> [2/6] 编译 Swift release"
swift build --package-path "$ROOT/macos" -c release --disable-sandbox
BIN="$(swift build --package-path "$ROOT/macos" -c release --disable-sandbox --show-bin-path 2>/dev/null | tail -1)"

echo "==> [3/6] 组装 App bundle：$APP"
rm -rf "$APP/Contents"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ThirdPartyLicenses" \
    "$APP/Contents/Resources/zh_CN.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
# AppKit 依据 .lproj 目录 + CFBundleLocalizations 选择中文本地化，标准菜单项才会显示中文。
# 系统 AppKit 自带 zh_CN.lproj，SwiftUI 常用 zh-Hans，两个标识都声明最稳妥。
printf '/* DitKit 仅提供简体中文界面 */\n' > "$APP/Contents/Resources/zh_CN.lproj/Localizable.strings"
printf '/* DitKit 仅提供简体中文界面 */\n' > "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp -f "$BIN/DitKit" "$APP/Contents/MacOS/DitKit"
cp -f "$BUILD/ditkitd" "$APP/Contents/MacOS/ditkitd"
cp -f "$SMARTCTL" "$APP/Contents/MacOS/smartctl"
chmod +x "$APP/Contents/MacOS/DitKit" "$APP/Contents/MacOS/ditkitd" "$APP/Contents/MacOS/smartctl"
cp -f "$ROOT/macos/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# smartmontools 以 GPL-2.0 发布，随二进制分发需附许可证与源码获取信息。
if [ -f "$LICENSE_SRC" ]; then
    cp -f "$LICENSE_SRC" "$APP/Contents/Resources/ThirdPartyLicenses/smartmontools-COPYING.txt"
else
    echo "    警告：未找到 smartmontools 的 COPYING 文件" >&2
fi
SMARTCTL_VERSION="$("$SMARTCTL" --version 2>/dev/null | grep -E '^smartctl' | head -1 || echo 'smartctl')"
printf '%s\n' \
    "本产品内含 smartmontools 的 smartctl 命令行程序（${SMARTCTL_VERSION}）。" \
    "许可证：GPL-2.0-or-later，全文见同目录 smartmontools-COPYING.txt。" \
    "源码获取：https://www.smartmontools.org/ 或 https://github.com/smartmontools/smartmontools" \
    "对应二进制未经修改，直接取自 Homebrew 安装的 smartmontools 7.5。" \
    > "$APP/Contents/Resources/ThirdPartyLicenses/smartmontools-SOURCE.txt"

printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key>
  <array><string>zh_CN</string><string>zh-Hans</string></array>
  <key>CFBundleDisplayName</key><string>DitKit</string>
  <key>CFBundleExecutable</key><string>DitKit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>DitKit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "==> [4/6] ad-hoc 签名（先签内嵌可执行文件，再签整个 bundle）"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/ditkitd"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/smartctl"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -3

echo "==> [5/6] 校验：在不含 Homebrew 的 PATH 下确认内嵌 smartctl 可用"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$APP/Contents/MacOS/ditkitd" -version 2>&1 | head -3

echo "==> [6/6] 产物信息"
echo "    版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "    架构：$(lipo -archs "$APP/Contents/MacOS/DitKit") / 后端 $(lipo -archs "$APP/Contents/MacOS/ditkitd") / smartctl $(lipo -archs "$APP/Contents/MacOS/smartctl")"
echo "    内嵌后端：$("$APP/Contents/MacOS/ditkitd" -version 2>/dev/null || echo '无法执行')"
echo "    内嵌 smartctl：$("$APP/Contents/MacOS/smartctl" --version 2>/dev/null | head -1 || echo '无法执行')"
echo "完成：$APP"
