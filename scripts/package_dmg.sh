#!/usr/bin/env bash
#
# package_dmg.sh 基于 build_app.sh 产出的 .app，用 hdiutil 生成本地安装用的只读 DMG 镜像。
#
# 用法：scripts/package_dmg.sh [输出目录，默认 .build/dist]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-${PACKAGE_ROOT}/.build/dist}"

APP_NAME="CodexQuotaWidget"
APP_BUNDLE="${PACKAGE_ROOT}/.build/app/${APP_NAME}.app"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}.dmg"
STAGING_DIR="${OUTPUT_DIR}/dmg-staging"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "==> 未找到 ${APP_BUNDLE}，先执行 build_app.sh"
  "${SCRIPT_DIR}/build_app.sh"
fi

echo "==> 1/3 准备打包目录"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> 2/3 生成 DMG（如已存在旧文件先删除）"
mkdir -p "${OUTPUT_DIR}"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

echo "==> 3/3 清理临时目录"
rm -rf "${STAGING_DIR}"

echo ""
echo "打包完成：${DMG_PATH}"
