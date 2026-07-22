import AppKit
import SwiftUI
import CodexQuotaCore

/// PopoverView 是点击菜单栏图标后弹出的详情面板（结构化需求 §3.2）。
///
/// 展示每个额度窗口、最近 Token、最近刷新时间，并提供手动刷新、悬浮窗开关、开机启动开关与退出入口。
public struct PopoverView: View {
    @ObservedObject private var viewModel: AppViewModel

    public init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let snapshot = viewModel.state.snapshot {
                ForEach(snapshot.windows) { window in
                    QuotaCardView(window: window)
                }
                TokenSummaryView(result: snapshot.recentTokens)
                Text("最近刷新：\(Self.formattedDate(snapshot.refreshedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .loading = viewModel.state {
                Text("正在加载额度…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if case .failed(_, let error) = viewModel.state {
                ErrorBannerView(error: error) {
                    Task { await viewModel.refresh(force: true) }
                }
            }

            Divider()

            Toggle("显示悬浮窗", isOn: $viewModel.isFloatingVisible)
                .accessibilityHint("开启后在屏幕上显示常驻的额度卡片")

            Toggle("开机启动", isOn: Binding(
                get: { viewModel.isLoginItemEnabled },
                set: { viewModel.setLoginItemEnabled($0) }
            ))
            if let message = viewModel.loginItemErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("退出 Codex 额度") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Text("Codex 额度")
                .font(.headline)
            Spacer()
            Button {
                Task { await viewModel.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("刷新额度")
            .disabled(viewModel.isRefreshInFlight)
        }
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

/// QuotaCardView 展示单个额度窗口的剩余/已用百分比、窗口时长与重置时间。
public struct QuotaCardView: View {
    let window: QuotaWindow

    public init(window: QuotaWindow) {
        self.window = window
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.kind.displayLabel)
                    .font(.subheadline).bold()
                Spacer()
                Text("剩余 \(Int(window.remainingPercent.rounded()))%")
                    .font(.subheadline)
            }
            ProgressView(value: window.usedPercent, total: 100)
                .accessibilityLabel("\(window.kind.displayLabel) 已用 \(Int(window.usedPercent.rounded()))%")
            if let resetAt = window.resetAt {
                Text("重置时间：\(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// TokenSummaryView 展示最近任务 Token 计数；无数据时显示明确空状态（结构化需求 §3.2）。
public struct TokenSummaryView: View {
    let result: RecentTokenResult

    public init(result: RecentTokenResult) {
        self.result = result
    }

    public var body: some View {
        HStack {
            Text("最近任务 Token")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            switch result {
            case .value(let count):
                Text("\(count)")
                    .font(.caption).bold()
            case .unavailable:
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// ErrorBannerView 展示可理解的错误说明与重试入口，不展示任何服务端响应原文。
public struct ErrorBannerView: View {
    let error: UserFacingError
    let onRetry: () -> Void

    public init(error: UserFacingError, onRetry: @escaping () -> Void) {
        self.error = error
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.userMessage)
                .font(.caption)
                .foregroundStyle(.red)
            if error.isRetryable {
                Button("重试", action: onRetry)
                    .font(.caption)
            }
        }
        .padding(8)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// FloatingCardView 是悬浮窗展示的深色紧凑卡片，只显示核心余量与重置时间（结构化需求 §3.3）。
public struct FloatingCardView: View {
    let snapshot: QuotaSnapshot?
    let onClose: () -> Void

    public init(snapshot: QuotaSnapshot?, onClose: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityLabel("关闭悬浮窗")
            }
            if let snapshot, let tightest = snapshot.tightestWindow {
                Text("\(tightest.kind.displayLabel) 剩余 \(Int(tightest.remainingPercent.rounded()))%")
                    .font(.title3).bold()
                    .foregroundStyle(.white)
                if let resetAt = tightest.resetAt {
                    Text("重置：\(resetAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text("暂无数据")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(14)
        .frame(width: 200)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
    }
}
