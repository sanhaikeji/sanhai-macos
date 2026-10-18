import SwiftUI
import AppKit

// MARK: - App 入口

/// 应用入口。
///
/// 关键点：`@main` + `WindowGroup` 是 macOS 上的标准 SwiftUI App 生命周期。
/// 不要在 App 里做重活（读磁盘、发网络请求）——
/// 启动阶段做这些会让窗口出现前有一段白屏，是 macOS 上最常见的「卡启动」原因。
@main
struct SanhaiMacApp: App {

    /// 必须显式声明，否则下面的 AppDelegate 根本不会被调用。
    /// 这是 SwiftUI App 生命周期里最容易漏掉的一步：写了 delegate 却没接上，
    /// 表现为"代码明明在这里跑，怎么什么效果都没有"。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = DataStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                .onAppear { store.attach(settings: settings) }
        }
        .windowToolbarStyle(.unified)   // macOS 原生观感的关键：统一工具栏样式
        .commands {
            // 命令菜单。macOS 用户习惯用菜单做刷新（⌘R），而不是点工具栏按钮 ——
            // 这是把 iOS 交互直接搬过来最容易露馅的地方。
            CommandGroup(replacing: .newItem) {
                Button("刷新全部") {
                    Task { await store.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(store.isLoading)
            }

            CommandMenu("视图") {
                Button("题库") { store.select(.problems) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("评测") { store.select(.records) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("设置") { store.select(.settings) }
                    .keyboardShortcut(",", modifiers: .command)   // ⌘, 是 macOS 打开设置的通用约定
            }
        }
    }
}

/// 处理必须在 AppKit 层做的事。
///
/// 现在只做一件：退出前把令牌同步到安全存储。
/// 场景是用户输入令牌后直接 ⌘Q —— 那时没有「保存」按钮被点到，
/// 如果只在输入时异步落盘，有概率丢。
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillTerminate(_ notification: Notification) {
        // 退出回调不一定在主线程，用 DispatchQueue.main.sync 回到主线程。
        // 这里刻意用 sync 而不是 assumeIsolated：后者要 macOS 14，
        // 而本工程最低支持 13。
        // 也刻意不做网络请求：退出时等网络会让 ⌘Q 之后进程还挂几秒，
        // 用户会以为应用没退干净。
        if Thread.isMainThread {
            flushToken()
        } else {
            DispatchQueue.main.sync { flushToken() }
        }
    }

    private func flushToken() {
        let s = AppSettings.shared
        guard !s.token.isEmpty else { return }
        // 只在"钥匙串里还没有"时补写，避免每次退出都去动钥匙串
        if (try? TokenStore.read()) == nil {
            s.saveTokenSecurely()
        }
    }
}