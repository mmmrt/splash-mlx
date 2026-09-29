#!/bin/zsh
# SplashMLX 构建脚本
#  1) 编译 makeicons.swift，生成菜单栏三态图标 + 应用图标(AppIcon.icns)
#  2) 编译 main.swift 成常驻菜单栏的 .app（无窗口、无 Dock 图标）
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/SplashMLX.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
OBJ_DIR="$SRC_DIR/.build"
SDK="$(xcrun --show-sdk-path)"

# 先退掉正在运行的实例，再重建。
# 原因：对一个**正在运行**的 .app 执行 rm -rf 时，macOS 会把整个 bundle 挪进废纸篓，
# 而旧进程继续从废纸篓里那份二进制运行 —— 结果就是"代码改了、也重新构建了、菜单栏却毫无变化"，
# 而且从 ~/Applications 完全看不出异常（那里确实是新的）。pkill 一次就不会踩。
#
# **必须连托管的引擎服务一起停**：pkill App 本体不会杀掉它 spawn 的引擎子进程，
# 那些进程会被 launchd 收养（ppid=1）继续抱着几十 GB 内存和端口不放 —— 菜单栏图标没了、
# 服务还在裸奔，重新打开 App 就会看到 "port held by an external process"。
#
# 引擎不止一层子进程，所以要**递归**杀整棵树：
#   splash: /opt/homebrew/bin/splash(wrapper) → python server.py → engine/splash serve-native
#   mlx-serve: 单进程（但保持同一套逻辑，不区分引擎）
# 只杀一层（pkill -P）会漏掉孙进程，留下仍然占着端口的残留。
descendants() {           # 递归收集某 pid 的全部后代，输出按"子在前、父在后"顺序便于逐个 TERM
  local parent=$1 child
  for child in $(pgrep -P "$parent" 2>/dev/null || true); do
    descendants "$child"
    echo "$child"
  done
}

stop_managed_engine() {
  local pidf="$HOME/Library/Application Support/SplashMLX/splash-mlx.pid"
  [ -f "$pidf" ] || return 0
  local pid
  # set -e + pipefail 下命令替换失败会中断整个构建，这里显式兜底
  pid=$(cat "$pidf" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$pid" ] || { /bin/rm -f "$pidf"; return 0; }

  local tree
  tree="$(descendants "$pid" | tr '\n' ' ')"
  echo "[0/7] stop the managed engine (pid $pid${tree:+, children $tree}) so it does not survive as an orphan"

  # 先子后父：父进程被杀后就没机会带走子进程，子进程会变孤儿
  local p
  for p in $tree $pid; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 2
  # 大模型卸载可能来不及响应 SIGTERM，升级 SIGKILL 兜底
  for p in $tree $pid; do
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  done
  /bin/rm -f "$pidf"
}
stop_managed_engine

if pgrep -f "$APP_DIR/Contents/MacOS/" >/dev/null 2>&1; then
  echo "[0/7] quit the running instance (otherwise the old bundle ends up in the Trash)"
  pkill -f "$APP_DIR/Contents/MacOS/" 2>/dev/null || true
  sleep 1
fi

echo "[1/7] clean previous build"
rm -rf "$OBJ_DIR" "$APP_DIR"
mkdir -p "$OBJ_DIR" "$BIN_DIR" "$RES_DIR"

echo "[2/7] compile icon generator"
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -o "$OBJ_DIR/makeicons" "$SRC_DIR/makeicons.swift"

echo "[3/7] generate icons"
"$OBJ_DIR/makeicons" "$OBJ_DIR" | sed 's/^/      /'
iconutil -c icns "$OBJ_DIR/AppIcon.iconset" -o "$RES_DIR/AppIcon.icns"
cp "$OBJ_DIR"/menubar_*.png "$RES_DIR/"

echo "[4/7] compile main app (AppKit)"
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -o "$BIN_DIR/SplashMLX" "$SRC_DIR/main.swift"

echo "[5/7] assemble .app bundle"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$BIN_DIR/SplashMLX"

echo "[6/7] clear quarantine + ad-hoc sign"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
codesign --force --sign - --deep "$APP_DIR" 2>/dev/null || \
  echo "      codesign skipped (app still runs locally)"

echo "[7/7] clean intermediates"
rm -rf "$OBJ_DIR"

echo
echo "✅ Build complete: $APP_DIR"
echo "   resources: $(ls "$RES_DIR" | wc -l | tr -d ' ') files"
echo "   launch: open ~/Applications/SplashMLX.app"
