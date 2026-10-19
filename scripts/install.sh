#!/bin/bash
# 安装 Lid Awake：运行时 + App + 登录自启
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Application Support/lidawake"
APP_DST="$HOME/Applications/Lid Awake.app"
LABEL="io.github.han2233.lidawake.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "只支持 macOS。"
command -v xcrun >/dev/null 2>&1 || die "需要 Xcode Command Line Tools：xcode-select --install"
command -v clang >/dev/null 2>&1 || die "需要 clang：xcode-select --install"

echo "==> 1/4 安装 lidawake 运行时"
mkdir -p "$DEST"
rsync -a "$ROOT/third_party/lidawake/" "$DEST/"
chmod +x "$DEST/bin/lidawake" "$DEST/bin/lidtest"
clang -O2 -o "$DEST/bin/dispbright" "$DEST/src/dispbright.c" -framework CoreGraphics
"$DEST/bin/dispbright" >/dev/null || die "dispbright 编译成功但读不到亮度。"
echo "    $DEST"

echo "==> 2/4 构建 App"
"$ROOT/scripts/build.sh"

echo "==> 3/4 安装到 ~/Applications"
pkill -x LidAwake 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$ROOT/build/Lid Awake.app" "$APP_DST"
codesign --force --deep --sign - "$APP_DST" >/dev/null 2>&1 || true

echo "==> 4/4 注册登录自启"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/open</string>
    <string>$APP_DST</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST_EOF

if [ "${SKIP_LAUNCH:-0}" = "1" ]; then
  echo "    SKIP_LAUNCH=1，跳过 launchctl / open"
  echo "done (dry install into $HOME)"
  exit 0
fi

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_NUM" "$PLIST" || die "launchctl bootstrap 失败"
open "$APP_DST"

cat <<TXT

安装完成。

下一步：点 Dock 里的咖啡杯图标（或按 Control + Option + K），
首次会请求一次管理员授权，输入密码后即可免密开关。

日志：~/Library/Logs/lid-awake.log
卸载：$ROOT/scripts/uninstall.sh
TXT
