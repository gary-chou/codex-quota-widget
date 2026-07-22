#!/usr/bin/env bash
#
# build_app.sh 组装 Apple Silicon 原生的 CodexQuotaWidget.app，全程只依赖 SwiftPM 与
# Command Line Tools，不需要完整 Xcode 工程（结构化需求 §7、技术方案 §9.4.05）。
#
# 用法：scripts/build_app.sh [输出目录，默认 .build/app]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-${PACKAGE_ROOT}/.build/app}"

APP_NAME="CodexQuotaWidget"
BUNDLE_ID="com.codexquotawidget.app"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"

echo "==> 1/4 编译 release 版本可执行文件"
swift build --package-path "${PACKAGE_ROOT}" -c release --arch arm64

RELEASE_BINARY="${PACKAGE_ROOT}/.build/arm64-apple-macosx/release/${APP_NAME}"
if [[ ! -f "${RELEASE_BINARY}" ]]; then
  echo "错误：未找到编译产物 ${RELEASE_BINARY}" >&2
  exit 1
fi

echo "==> 2/4 组装 .app 包结构"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${RELEASE_BINARY}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${PACKAGE_ROOT}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "==> 3/4 对 .app 进行 ad-hoc 签名（本机无 Developer ID 证书，仅用于本地运行）"
# 包内只有单个可执行文件、无嵌套 bundle/framework，不需要（已弃用的）--deep 递归签名。
codesign --force --sign - "${APP_BUNDLE}"

echo "==> 4/4 校验签名与包结构"
codesign --verify --verbose "${APP_BUNDLE}"

echo ""
echo "构建完成：${APP_BUNDLE}"
echo "可执行 open \"${APP_BUNDLE}\" 启动应用（首次启动无 Dock 图标，请在菜单栏查找 Codex 图标）。"
