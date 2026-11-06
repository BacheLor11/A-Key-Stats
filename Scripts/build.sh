#!/usr/bin/env bash
# 打包 A-Key-Stats.app：SwiftPM 编译 + 手工组 bundle（不依赖 Xcode 工程）
#
# 签名说明：输入监控权限绑定在签名身份上。用固定的 Apple Development 证书签名，
# 重新编译后授权一般还在；用 ad-hoc（-）每次构建都会掉授权。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="A-Key-Stats"
EXEC_NAME="AKeyStats"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

mkdir -p "$BUILD_DIR"

echo "▸ 编译 (release)…"
swift build -c release --disable-sandbox

echo "▸ 组装 ${APP} …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -f "$BUILD_DIR/AppIcon.icns" ]; then
    cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 插件形态：放进 Contents/PlugIns，A-Kit 装工具时会把它软链到自己的插件目录。
# 软链而不是拷贝，所以 app 一更新插件跟着更新，版本不会错位。
# 这里自己组 bundle（不调 A-Kit 的脚本），仓库之间不互相依赖。
echo "▸ 组装插件 (Contents/PlugIns)…"
PLUGIN="$APP/Contents/PlugIns/AKeyStats.akitplugin"
rm -rf "$PLUGIN"
mkdir -p "$PLUGIN/Contents/MacOS" "$PLUGIN/Contents/Resources"
cp ".build/release/libAKeyPlugin.dylib" "$PLUGIN/Contents/MacOS/AKeyStats"
chmod +x "$PLUGIN/Contents/MacOS/AKeyStats"
cat > "$PLUGIN/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleIdentifier</key><string>com.aibao.AKeyStats</string>
    <key>CFBundleName</key><string>A-Key-Stats</string>
    <key>CFBundleExecutable</key><string>AKeyStats</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>AKPluginIdentifier</key><string>com.aibao.AKeyStats</string>
    <key>AKPluginDisplayName</key><string>A-Key-Stats</string>
    <key>AKPluginABIVersion</key><integer>1</integer>
</dict>
</plist>
PLIST

echo "▸ 签名…"
# 优先用环境变量指定的身份；否则找第一张可用的 Apple Development 证书；再不行才 ad-hoc
if [ -z "${CODESIGN_ID:-}" ]; then
    # 用 SHA-1 而不是名字：同名证书可能有好几张（含已吊销的），按名字会 ambiguous
    CODESIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -v CSSMERR | grep 'Apple Development' | head -1 | awk '{print $2}' || true)
fi
if [ -n "${CODESIGN_ID:-}" ] && [ "$CODESIGN_ID" != "-" ]; then
    if codesign --force --options runtime --sign "$CODESIGN_ID" "$APP" 2>/dev/null; then
        echo "  · 已签名：${CODESIGN_ID}（输入监控授权可跨构建保留）"
    else
        echo "  ! 用该证书签名失败，退回 ad-hoc（每次重建都要重新授权）"
        codesign --force --deep --sign - "$APP"
    fi
else
    codesign --force --deep --sign - "$APP"
    echo "  · ad-hoc 签名（每次重建都要重新授权输入监控）"
fi

if [ "${1:-}" = "--release" ]; then
    echo "▸ 打包 zip…"
    rm -f "$BUILD_DIR/$APP_NAME-$VERSION.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD_DIR/$APP_NAME-$VERSION.zip"
    shasum -a 256 "$BUILD_DIR/$APP_NAME-$VERSION.zip" | awk '{print "  sha256:", $1}'
fi

if [ "${1:-}" = "--install" ] || [ "${2:-}" = "--install" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "▸ 安装到 ${DEST}…"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    sleep 0.6
    rm -rf "$DEST/$APP_NAME.app"
    /usr/bin/ditto "$APP" "$DEST/$APP_NAME.app"
    /usr/bin/xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true
    echo "✓ 完成：${DEST}/${APP_NAME}.app"
else
    echo "✓ 完成：${APP}"
fi
