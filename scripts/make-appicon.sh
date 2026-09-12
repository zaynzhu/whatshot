#!/bin/zsh

# 生成 WhatShot 应用图标：先用 Swift 脚本渲染 1024px 主图，再打包成 AppIcon.icns
# 用法: scripts/make-appicon.sh [--preview-only]

set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPOSITORY_DIR=${SCRIPT_DIR:h}
ICON_DIR="$REPOSITORY_DIR/scripts/appicon"
PNG_DIR="$ICON_DIR/png"
SWIFT_SRC="$ICON_DIR/render_icon.swift"
PREVIEW_PNG="$ICON_DIR/icon_1024.png"

mkdir -p "$PNG_DIR"

# Swift 渲染脚本若不存在则报错（源文件随仓库维护）
[[ -f "$SWIFT_SRC" ]] || { print "缺少 $SWIFT_SRC" >&2; exit 1 }

# 1) 渲染 1024px 主图
swift "$SWIFT_SRC" "$PREVIEW_PNG"

if [[ "${1:-}" == "--preview-only" ]]; then
  print "Preview: $PREVIEW_PNG"
  exit 0
fi

# 2) 缩放出 iconset 各尺寸
ICONSET_DIR="/tmp/whatshot-icon.$$.iconset"
mkdir -p "$ICONSET_DIR"
trap 'rm -rf "$ICONSET_DIR"' EXIT

sips -z 16 16     "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32 32     "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64 64     "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256 256   "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512 512   "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$PREVIEW_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

# 3) 打包 icns
iconutil -c icns "$ICONSET_DIR" -o "$ICON_DIR/AppIcon.icns"
print "ICNS: $ICON_DIR/AppIcon.icns"