#!/bin/bash
# 卸载 Lid Awake（含运行时与授权规则）
set -uo pipefail

LABEL="io.github.han2233.lidawake.menubar"
APP="$HOME/Applications/Lid Awake.app"
DEST="$HOME/Library/Application Support/lidawake"
UID_NUM="$(id -u)"

echo "==> 停止 App"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x LidAwake 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$APP"

echo "==> 恢复系统默认睡眠"
if [ -x "$DEST/bin/lidawake" ]; then
  "$DEST/bin/lidawake" normal 2>/dev/null || true
fi

echo "==> 停止 lidawake 守护进程"
launchctl bootout "gui/$UID_NUM/cc.openq.lidawake" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/cc.openq.lidawake.plist"

echo "==> 删除授权规则（需要一次管理员密码）"
sudo rm -f /etc/sudoers.d/lidawake || true

echo "==> 清理文件"
rm -rf "$DEST"
rm -rf "$HOME/.local/state/lidawake"

echo "已卸载。"
