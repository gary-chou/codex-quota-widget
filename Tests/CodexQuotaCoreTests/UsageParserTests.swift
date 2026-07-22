import Testing
import Foundation
@testable import CodexQuotaCore

/// 覆盖测试用例.md §2.1「额度解析与归类」TC-01-01 至 TC-01-05。
struct UsageParserTests {

    @Test("TC-01-01 单个 7d 窗口/正向：secondary=null 不崩溃，remaining=100")
    func singleSevenDayWindowWithNullSecondary() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1700000000},"secondary_window":null}}
        """.data(using: .utf8)!

        let windows = try UsageParser.parse(json)

        #expect(windows.count == 1)
        #expect(windows[0].kind == .sevenDay)
        #expect(windows[0].remainingPercent == 100)
        #expect(windows[0].resetAt != nil)
    }

    @Test("TC-01-02 5h + 7d/正向：不受主次位置影响")
    func fiveHourAndSevenDayWindowsRegardlessOfPosition() throws {
        // 正常位置：primary=5h, secondary=7d。
        let normal = """
        {"rate_limit":{
            "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1700000000},
            "secondary_window":{"used_percent":60,"limit_window_seconds":604800,"reset_at":1700100000}
        }}
        """.data(using: .utf8)!

        // 位置互换：primary=7d, secondary=5h，结果应完全一致，证明不依赖主次位置。
        let swapped = """
        {"rate_limit":{
            "primary_window":{"used_percent":60,"limit_window_seconds":604800,"reset_at":1700100000},
            "secondary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1700000000}
        }}
        """.data(using: .utf8)!

        for json in [normal, swapped] {
            let windows = try UsageParser.parse(json)
            #expect(windows.count == 2)

            let fiveHour = try #require(windows.first { $0.kind == .fiveHour })
            #expect(fiveHour.remainingPercent == 75)

            let sevenDay = try #require(windows.first { $0.kind == .sevenDay })
            #expect(sevenDay.remainingPercent == 40)
        }
    }

    @Test("TC-01-03 未知时长/边界：作为 custom 窗口输出，不丢弃")
    func unknownDurationWindowIsKeptAsCustom() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":33.5,"limit_window_seconds":86400,"reset_at":null},"secondary_window":null}}
        """.data(using: .utf8)!

        let windows = try UsageParser.parse(json)

        #expect(windows.count == 1)
        #expect(windows[0].kind == .custom(seconds: 86400))
        #expect(windows[0].kind.displayLabel == "1d")
        #expect(windows[0].remainingPercent == 66.5)
    }

    @Test("TC-01-04a 越界窗口/异常：used=-10 夹到 0，额外字段不影响解析")
    func negativeUsedPercentIsClampedToZero() throws {
        let json = """
        {"rate_limit":{
            "primary_window":{"used_percent":-10,"limit_window_seconds":18000,"reset_at":1700000000,"unexpected_field":"ignored"},
            "secondary_window":{"used_percent":50,"limit_window_seconds":604800,"reset_at":1700000000}
        }}
        """.data(using: .utf8)!

        let windows = try UsageParser.parse(json)

        #expect(windows.count == 2)
        let fiveHour = try #require(windows.first { $0.kind == .fiveHour })
        #expect(fiveHour.usedPercent == 0)
        #expect(fiveHour.remainingPercent == 100)
    }

    @Test("TC-01-04b 越界窗口/异常：used=130 夹到 100")
    func overOneHundredUsedPercentIsClampedToOneHundred() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":130,"limit_window_seconds":604800,"reset_at":null},"secondary_window":null}}
        """.data(using: .utf8)!

        let windows = try UsageParser.parse(json)

        #expect(windows.count == 1)
        #expect(windows[0].usedPercent == 100)
        #expect(windows[0].remainingPercent == 0)
    }

    @Test("TC-01-04c 损坏窗口/异常：used 非数值时跳过该窗口，有效窗口仍输出")
    func nonNumericUsedPercentWindowIsSkipped() throws {
        let json = """
        {"rate_limit":{
            "primary_window":{"used_percent":"not-a-number","limit_window_seconds":18000,"reset_at":null},
            "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":null}
        }}
        """.data(using: .utf8)!

        let windows = try UsageParser.parse(json)

        #expect(windows.count == 1)
        #expect(windows[0].kind == .sevenDay)
        #expect(windows[0].remainingPercent == 90)
    }

    @Test("TC-01-05 无有效窗口/异常：两窗口均为 null 返回 invalidUsageResponse，且错误不含响应原文")
    func noValidWindowsThrowsInvalidUsageResponse() {
        let json = """
        {"rate_limit":{"primary_window":null,"secondary_window":null}}
        """.data(using: .utf8)!

        #expect(throws: UserFacingError.invalidUsageResponse) {
            try UsageParser.parse(json)
        }
    }

    @Test("TC-01-05b 顶层结构损坏/异常：非法 JSON 同样返回 invalidUsageResponse")
    func malformedTopLevelJSONThrowsInvalidUsageResponse() {
        let json = "not a json document".data(using: .utf8)!

        #expect(throws: UserFacingError.invalidUsageResponse) {
            try UsageParser.parse(json)
        }
    }

    @Test("兼容性/边界：兼容 rate_limits/primary/secondary + window_minutes/resets_at 命名变体")
    func alternateFieldNamingSchemaIsAlsoParsed() throws {
        // 部分 Codex 内部事件流以复数容器 rate_limits、窗口键 primary/secondary、
        // 分钟制 window_minutes 与 resets_at 表达同一份额度信息；与技术方案 §3.2 约定的命名并存，
        // 验证解析层对该命名变体同样宽容（示例时间戳为占位符，非真实数据）。
        let placeholderResetEpochSeconds: Double = 2_000_000_000
        let json = """
        {"rate_limits":{
            "primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":\(placeholderResetEpochSeconds)},
            "secondary":null
        }}
        """.data(using: .utf8)!

        let windows = try UsageParser.parse(json)

        #expect(windows.count == 1)
        #expect(windows[0].kind == .sevenDay)
        #expect(windows[0].usedPercent == 12.0)
        #expect(windows[0].remainingPercent == 88.0)
        #expect(windows[0].resetAt == Date(timeIntervalSince1970: placeholderResetEpochSeconds))
    }
}
