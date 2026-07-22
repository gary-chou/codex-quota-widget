import AppKit
import SwiftUI
import CodexQuotaCore

/// StatusItemController 管理菜单栏图标文字与点击后弹出的详情面板。
///
/// 菜单栏优先展示剩余比例最低（最紧张）的窗口（结构化需求 §3.1，测试用例 TC-04-01）；
/// 首次加载或无任何历史快照时使用不具误导性的占位文案（TC-04-02）。
@MainActor
public final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    public init(viewModel: AppViewModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(viewModel: viewModel))

        super.init()

        statusItem.button?.title = Self.title(for: .loading(nil))
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopoverAction(_:))
        statusItem.button?.setAccessibilityLabel("Codex 额度")
    }

    /// StatusItemController.render 依据最新界面状态刷新菜单栏文案。
    public func render(state: ViewState) {
        statusItem.button?.title = Self.title(for: state)
    }

    @objc private func togglePopoverAction(_ sender: Any?) {
        togglePopover()
    }

    /// StatusItemController.togglePopover 显示或隐藏详情面板。
    public func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// StatusItemController.title 依据界面状态计算菜单栏文案：
    /// 有快照时显示“NN%”（取剩余比例最低的窗口）；
    /// 无快照时，loading 显示“--”，failed 显示“!”。
    /// 菜单栏保持最紧凑形态，应用归属通过 accessibility label 与详情面板表达。
    public static func title(for state: ViewState) -> String {
        if let snapshot = state.snapshot, let tightest = snapshot.tightestWindow {
            let rounded = Int(tightest.remainingPercent.rounded())
            return "\(rounded)%"
        }
        switch state {
        case .loading:
            return "--"
        case .idle:
            return "--"
        case .failed:
            return "!"
        }
    }
}
