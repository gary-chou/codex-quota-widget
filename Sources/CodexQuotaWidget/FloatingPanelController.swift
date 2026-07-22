import AppKit
import SwiftUI
import CodexQuotaCore

/// FloatingPanelController 管理可选的悬浮窗：无焦点、深色圆角卡片（结构化需求 §3.3）。
///
/// 使用 `.nonactivatingPanel` 保证悬浮窗不抢占键盘焦点；关闭按钮只修改偏好并隐藏面板，不退出应用；
/// 窗口位置在移动后写回 `PreferencesStore`，重启后据此恢复。
@MainActor
public final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let hostingController: NSHostingController<FloatingCardView>
    private let preferences: PreferencesStore
    private weak var viewModel: AppViewModel?

    public init(viewModel: AppViewModel, preferences: PreferencesStore) {
        self.viewModel = viewModel
        self.preferences = preferences

        hostingController = NSHostingController(rootView: FloatingCardView(snapshot: nil, onClose: {}))

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentViewController = hostingController
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        if let savedFrame = preferences.floatingFrame {
            panel.setFrame(savedFrame, display: false)
        }

        super.init()

        panel.delegate = self
        hostingController.rootView = FloatingCardView(snapshot: nil, onClose: { [weak self] in
            self?.hide()
        })
    }

    /// FloatingPanelController.setVisible 显示或隐藏悬浮窗，并用最新快照刷新其内容。
    public func setVisible(_ visible: Bool, snapshot: QuotaSnapshot?) {
        hostingController.rootView = FloatingCardView(snapshot: snapshot, onClose: { [weak self] in
            self?.hide()
        })

        if visible {
            if let savedFrame = preferences.floatingFrame {
                panel.setFrame(savedFrame, display: false)
            }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// 关闭按钮的行为：只更新偏好（`floatingVisible = false`）并隐藏窗口，不调用 `NSApp.terminate`。
    private func hide() {
        preferences.floatingVisible = false
        viewModel?.isFloatingVisible = false
        panel.orderOut(nil)
    }

    public func windowDidMove(_ notification: Notification) {
        preferences.floatingFrame = panel.frame
    }

    public func windowDidResize(_ notification: Notification) {
        preferences.floatingFrame = panel.frame
    }
}
