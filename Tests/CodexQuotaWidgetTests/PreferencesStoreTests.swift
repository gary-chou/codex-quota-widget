import Testing
import Foundation
@testable import CodexQuotaWidget

/// 覆盖测试用例.md TC-04-03「悬浮窗偏好」中可单测的部分：`floatingFrame` 的序列化/反序列化，
/// 以及悬浮窗开关的持久化，验证“开关和位置可保留”这一验收点在存储层的正确性。
struct PreferencesStoreTests {

    @Test("TC-04-03 正向：floatingFrame 写入后可原样读回（round-trip）")
    func floatingFrameRoundTrips() {
        let store = PreferencesStore(storage: FakePreferencesStorage())
        let frame = CGRect(x: 10, y: 20.5, width: 200, height: 120)

        store.floatingFrame = frame

        #expect(store.floatingFrame == frame)
    }

    @Test("TC-04-03 正向：floatingVisible 开关写入后可原样读回")
    func floatingVisibleRoundTrips() {
        let store = PreferencesStore(storage: FakePreferencesStorage())

        #expect(store.floatingVisible == false) // 默认关闭（结构化需求 §3.3）

        store.floatingVisible = true
        #expect(store.floatingVisible == true)

        store.floatingVisible = false
        #expect(store.floatingVisible == false)
    }

    @Test("TC-04-03 边界：未设置过 floatingFrame 时返回 nil")
    func floatingFrameDefaultsToNilWhenNeverSet() {
        let store = PreferencesStore(storage: FakePreferencesStorage())

        #expect(store.floatingFrame == nil)
    }

    @Test("TC-04-03 边界：写入 nil 会清除已保存的 floatingFrame")
    func settingNilClearsFloatingFrame() {
        let store = PreferencesStore(storage: FakePreferencesStorage())
        store.floatingFrame = CGRect(x: 1, y: 2, width: 3, height: 4)

        store.floatingFrame = nil

        #expect(store.floatingFrame == nil)
    }

    @Test("TC-04-03 边界：底层存储中字段数量不为 4（parts.count != 4）时容错返回 nil，不崩溃")
    func malformedStoredStringWithWrongPartCountFallsBackToNil() {
        let storage = FakePreferencesStorage()
        // 直接写入一个字段数量不为 4 的畸形字符串，模拟旧版本残留数据或外部篡改。
        storage.set("10,20,30", forKey: "com.codexquotawidget.preferences.floatingFrame")
        let store = PreferencesStore(storage: storage)

        #expect(store.floatingFrame == nil)
    }

    @Test("TC-04-03 边界：底层存储中含非数值字段时容错返回 nil，不崩溃")
    func malformedStoredStringWithNonNumericPartFallsBackToNil() {
        let storage = FakePreferencesStorage()
        storage.set("10,20,not-a-number,40", forKey: "com.codexquotawidget.preferences.floatingFrame")
        let store = PreferencesStore(storage: storage)

        #expect(store.floatingFrame == nil)
    }
}
