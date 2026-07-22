import AppKit

// 应用入口：菜单栏常驻应用，无 Dock 图标（结构化需求 §3.1）。
// `NSApp.setActivationPolicy(.accessory)` 在 AppDelegate 中再次设置，确保 `swift run` 直接启动
// 与打包后的 `.app`（依赖 Info.plist 的 LSUIElement）行为一致。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
