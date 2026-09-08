import AppKit
import Combine
import Foundation
import CodexQuotaCore

/// AppViewModel 是应用状态的唯一事实来源，负责防重刷新、保留旧数据与偏好开关的双向绑定。
///
/// 所有对外可观察属性的变更都发生在主线程（`@MainActor`），满足“UI 状态变更在主线程完成”的约束。
@MainActor
public final class AppViewModel: ObservableObject {
    /// 当前界面状态：loading/idle/failed，均可能携带最近一次成功的快照。
    @Published public private(set) var state: ViewState = .loading(nil)
    /// 悬浮窗是否显示，双向绑定到 `PreferencesStore`。
    @Published public var isFloatingVisible: Bool {
        didSet { preferences.floatingVisible = isFloatingVisible }
    }
    /// 开机启动开关；初始值以系统真实状态为准，不使用 UserDefaults 冒充（技术方案 §3.6）。
    @Published public private(set) var isLoginItemEnabled: Bool
    /// 开机启动操作失败时的可重试错误说明；成功后自动清空。
    @Published public private(set) var loginItemErrorMessage: String?

    private let coordinator: QuotaRefreshCoordinator
    private let scheduler: RefreshScheduler
    private let preferences: PreferencesStore
    private let loginItemController: LoginItemControlling
    private var isRefreshing = false

    public init(
        coordinator: QuotaRefreshCoordinator,
        scheduler: RefreshScheduler = RefreshScheduler(),
        preferences: PreferencesStore,
        loginItemController: LoginItemControlling
    ) {
        self.coordinator = coordinator
        self.scheduler = scheduler
        self.preferences = preferences
        self.loginItemController = loginItemController
        self.isFloatingVisible = preferences.floatingVisible
        self.isLoginItemEnabled = loginItemController.isEnabled
    }

    /// AppViewModel.start 启动定时刷新（内部常量：默认 300 秒一次），启动后立即执行首次刷新。
    public func start(refreshInterval: Duration = .seconds(300)) {
        Task { [scheduler] in
            await scheduler.start(interval: refreshInterval) { [weak self] in
                await self?.refresh(force: false)
            }
        }
    }

    /// AppViewModel.refresh 发起一次刷新。
    ///
    /// 重入防护对手动（`force: true`，例如 Command-R 或点击刷新按钮）与定时触发一视同仁：
    /// 刷新进行中时任何新的调用都直接返回，确保底层 transport 在同一时刻只有一个请求在途
    /// （测试用例 TC-02-06 要求“transport 总调用数=1”）。`force` 保留用于区分调用来源，
    /// 便于未来在不违反防重约束的前提下扩展节流策略。
    public func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        state = .loading(state.snapshot)
        let outcome = await coordinator.refresh()

        switch outcome {
        case .success(let snapshot):
            state = .idle(snapshot)
        case .failure(let error):
            // 失败时保留最近一次成功快照，仅更新错误信息（TC-02-04）。
            state = .failed(state.snapshot, error)
        }
    }

    /// 是否正在刷新，供界面禁用重复点击的刷新按钮。
    public var isRefreshInFlight: Bool { isRefreshing }

    /// AppViewModel.setLoginItemEnabled 尝试切换开机启动；失败时恢复为系统真实状态并展示错误。
    public func setLoginItemEnabled(_ enabled: Bool) {
        do {
            try loginItemController.setEnabled(enabled)
            isLoginItemEnabled = loginItemController.isEnabled
            loginItemErrorMessage = nil
        } catch {
            // 恢复为切换前的系统真实状态，而不是简单地取反，避免和实际注册结果不一致。
            isLoginItemEnabled = loginItemController.isEnabled
            loginItemErrorMessage = "开机启动设置失败，请重试。"
        }
    }
}

/// AppDelegate 负责应用生命周期：创建状态项、弹出面板与悬浮窗，并发起首次刷新。
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var floatingPanelController: FloatingPanelController?
    private var viewModel: AppViewModel?
    private var cancellables: Set<AnyCancellable> = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Dock 图标常驻菜单栏（结构化需求 §3.1）；Info.plist 中 LSUIElement 用于打包后的 .app，
        // 这里同时以编程方式设置，保证通过 `swift run` 直接启动时行为一致。
        NSApp.setActivationPolicy(.accessory)

        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let coordinator = QuotaRefreshCoordinator(
            appServerClient: CodexAppServerClient(),
            authStore: FileAuthStore(codexHome: codexHome),
            usageClient: UsageClient(),
            tokenReader: JSONLRecentTokenReader(sessionsRoot: codexHome.appendingPathComponent("sessions"))
        )
        let preferences = PreferencesStore()
        let loginItemController: LoginItemControlling = SMLoginItemController()

        let viewModel = AppViewModel(
            coordinator: coordinator,
            preferences: preferences,
            loginItemController: loginItemController
        )
        self.viewModel = viewModel

        let statusItemController = StatusItemController(viewModel: viewModel)
        self.statusItemController = statusItemController

        let floatingPanelController = FloatingPanelController(viewModel: viewModel, preferences: preferences)
        self.floatingPanelController = floatingPanelController

        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak statusItemController] state in
                statusItemController?.render(state: state)
            }
            .store(in: &cancellables)

        viewModel.$isFloatingVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak floatingPanelController, weak viewModel] visible in
                // 弱捕获 viewModel：强捕获会与 AppDelegate -> viewModel -> Combine 发布者
                // -> 订阅闭包之间形成保留环，导致视图模型和面板控制器无法释放。
                floatingPanelController?.setVisible(visible, snapshot: viewModel?.state.snapshot)
            }
            .store(in: &cancellables)

        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak floatingPanelController, weak viewModel] state in
                guard let viewModel else { return }
                floatingPanelController?.setVisible(viewModel.isFloatingVisible, snapshot: state.snapshot)
            }
            .store(in: &cancellables)

        viewModel.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        cancellables.removeAll()
    }
}
