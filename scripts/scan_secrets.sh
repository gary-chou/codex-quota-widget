#!/usr/bin/env bash
#
# scan_secrets.sh 对构建产物与（可选的）测试输出做假 token/cookie 字符串扫描，
# 对应测试用例.md TC-03-04「凭据泄露扫描」：命中任意假值即判定失败并以非 0 退出，
# 可直接接入 CI。
#
# 扫描的假值清单从 Tests/CodexQuotaCoreTests/TestSupport.swift 与
# Tests/CodexQuotaWidgetTests/TestSupport.swift 中形如 `let fakeXxx = "..."` 的声明自动提取，
# 新增假值 fixture 时无需修改本脚本。
#
# 用法：scripts/scan_secrets.sh [测试输出日志路径，可选]
#   scripts/scan_secrets.sh
#   CPLUS_INCLUDE_PATH="$(xcrun --sdk macosx --show-sdk-path)/usr/include/c++/v1" \
#     swift test --package-path . 2>&1 | tee /tmp/codex-quota-widget-test-output.log
#   scripts/scan_secrets.sh /tmp/codex-quota-widget-test-output.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FIXTURE_FILES=(
  "${PACKAGE_ROOT}/Tests/CodexQuotaCoreTests/TestSupport.swift"
  "${PACKAGE_ROOT}/Tests/CodexQuotaWidgetTests/TestSupport.swift"
)

FAKE_VALUES_FILE="$(mktemp)"
trap 'rm -f "${FAKE_VALUES_FILE}"' EXIT

echo "==> 1/3 从测试替身文件中提取假 token/cookie 字面量清单"
for file in "${FIXTURE_FILES[@]}"; do
  if [[ ! -f "${file}" ]]; then
    echo "警告：未找到测试替身文件 ${file}，跳过" >&2
    continue
  fi
  # 匹配形如 `let fakeXxx = "..."` 的声明，提取双引号内的字面量本体。
  grep -oE 'let fake[A-Za-z0-9_]* = "[^"]*"' "${file}" \
    | sed -E 's/^let fake[A-Za-z0-9_]* = "(.*)"$/\1/' \
    >> "${FAKE_VALUES_FILE}"
done

if [[ ! -s "${FAKE_VALUES_FILE}" ]]; then
  echo "错误：未能从测试替身文件中提取到任何假值，扫描清单为空，视为配置错误。" >&2
  exit 1
fi

FAKE_VALUE_COUNT="$(wc -l < "${FAKE_VALUES_FILE}" | tr -d ' ')"
echo "    待扫描假值数量：${FAKE_VALUE_COUNT}"

echo "==> 2/3 收集扫描目标（release 二进制 / .app 包 / 可选的测试输出日志）"
SCAN_TARGETS=()
for candidate in \
  "${PACKAGE_ROOT}/.build/app" \
  "${PACKAGE_ROOT}/.build/release" \
  "${PACKAGE_ROOT}/.build/arm64-apple-macosx/release"
do
  [[ -d "${candidate}" ]] && SCAN_TARGETS+=("${candidate}")
done

TEST_LOG="${1:-}"
if [[ -n "${TEST_LOG}" ]]; then
  if [[ -f "${TEST_LOG}" ]]; then
    SCAN_TARGETS+=("${TEST_LOG}")
  else
    echo "错误：指定的测试输出日志不存在：${TEST_LOG}" >&2
    exit 1
  fi
fi

if [[ ${#SCAN_TARGETS[@]} -eq 0 ]]; then
  echo "警告：未找到任何构建产物（.build/app、.build/release 等），请先运行 build_app.sh。" >&2
  exit 0
fi

# 说明：不直接扫描 package_dmg.sh 产出的压缩 DMG（UDZO 格式经过压缩，原始字符串检索
# 不可靠）；DMG 的内容来自 .build/app，已在上面的扫描目标中覆盖。
echo "    扫描目标：${SCAN_TARGETS[*]}"

echo "==> 3/3 逐一比对假值是否出现在构建产物或测试输出中"
FOUND=0
while IFS= read -r fake_value; do
  [[ -z "${fake_value}" ]] && continue
  for target in "${SCAN_TARGETS[@]}"; do
    if grep -R -a -F -l -- "${fake_value}" "${target}" > /dev/null 2>&1; then
      echo "命中：假值出现在 ${target} 下：${fake_value}" >&2
      FOUND=1
    fi
  done
done < "${FAKE_VALUES_FILE}"

if [[ "${FOUND}" -ne 0 ]]; then
  echo "" >&2
  echo "扫描失败：构建产物/测试输出中命中了测试假值，存在隐私泄露风险，请检查。" >&2
  exit 1
fi

echo ""
echo "扫描通过：构建产物与测试输出中未发现任何假 token/cookie 值（命中数=0）。"
