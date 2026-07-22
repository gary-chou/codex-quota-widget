import Foundation

/// UsageParser 将用量接口返回的原始 JSON 解析为界面可直接消费的额度窗口数组。
///
/// 解析策略（技术方案 §3.2、§3.7）：
/// - `primary_window` / `secondary_window` 任一为 `null` 或缺失都被跳过，不影响另一个窗口。
/// - 单个窗口内字段非法（例如 `used_percent` 非数值）只会跳过该窗口，不影响其他窗口。
/// - 顶层 JSON 结构损坏，或过滤后一个有效窗口都没有，则返回 `invalidUsageResponse`，
///   且错误信息中不包含响应原文，避免服务端返回内容被展示或记录。
public enum UsageParser {
    /// UsageParser.parse 解析响应数据，返回至少一个有效窗口；否则抛出 `UserFacingError.invalidUsageResponse`。
    public static func parse(_ data: Data) throws -> [QuotaWindow] {
        let response: RawUsageResponse
        do {
            response = try JSONDecoder().decode(RawUsageResponse.self, from: data)
        } catch {
            // 顶层结构损坏（例如根本不是合法 JSON）：不回显原始响应内容，只抛出语义化错误。
            throw UserFacingError.invalidUsageResponse
        }

        let rawWindows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow]
            .compactMap { $0 }

        // 逐个尝试构造 QuotaWindow；单个窗口校验失败（时长非法/百分比非数值）只跳过该窗口。
        let windows = rawWindows.compactMap { try? QuotaWindow(raw: $0) }

        guard !windows.isEmpty else {
            throw UserFacingError.invalidUsageResponse
        }
        return windows
    }
}
