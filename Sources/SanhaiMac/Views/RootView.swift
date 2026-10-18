import SwiftUI

// MARK: - 根视图

/// 应用主框架：左侧栏 + 内容区。
///
/// 用 `NavigationSplitView` 而不是 `NavigationStack` ——
/// 这是 macOS 和 iOS 最明显的观感差异：
/// macOS 上应该有**常驻的三栏结构**（侧栏 / 内容 / 详情），
/// 而不是 iOS 那种"一层压一层"的导航栈。
/// 把 iOS 的 `NavigationStack` 直接搬到 macOS 会显得像一个放大的手机应用。
struct RootView: View {

    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            // MARK: 侧栏
            sidebar
        } detail: {
            // MARK: 内容区
            content
        }
        .navigationSplitViewStyle(.balanced)   // macOS 默认观感，比 .prominent 更稳
    }

    // MARK: 侧栏

    private var sidebar: some View {
        List(selection: Binding<SidebarSection?>(
            // 显式标注泛型参数为 Optional 是必须的：List 的 selection 要的是
            // `Binding<SidebarSection?>`。如果靠推断，get 返回非可选的 SidebarSection
            // 而 set 收 Optional，编译器会推出 `Binding<SidebarSection>`，
            // 结果和 List 期望的类型对不上 —— 这类错误在长表达式里很难看出来。
            get: { store.section },
            set: { if let v = $0 { store.select(v) } }
        )) {
            Section("浏览") {
                ForEach(SidebarSection.allCases) { s in
                    // macOS 上列表项的图标 + 标题是这个组合，
                    // 不是 iOS 那种"大标题 + 左滑手势"
                    Label(s.title, systemImage: s.systemImage)
                        .tag(s)
                }
            }

            Section("站点") {
                // 侧栏底部显示站点概况：让用户随时知道自己在连哪个站，
                // 不用切到设置页去确认
                LabeledContent("地址") {
                    Text(settings.baseURLString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // 站点地址可能很长，允许截断而不是把侧栏撑变形
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.baseURLString)
                }
                LabeledContent("令牌") {
                    Text(settings.token.isEmpty ? "未设置" : "已设置")
                        .font(.caption)
                        .foregroundStyle(settings.token.isEmpty ? Color.orange : Color.green)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        switch store.section {
        case .problems:
            ProblemListView()
        case .records:
            RecordListView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - 三态视图（加载中 / 空 / 错误）

/// 通用的「三态」占位视图。
///
/// 抽出来是因为空状态在这类客户端里出现频率极高：
/// 现在站点上勋章和提交记录**本来就是空的**，
/// 所以"没数据"不是异常情况，而是常态，必须被认真对待 ——
/// 空白界面（什么都不显示）在这种时候是最糟的表现：
/// 用户无法区分"没有数据"和"程序坏了"。
struct StatePlaceholder: View {

    enum Kind {
        case empty      // 请求成功，但没有内容
        case error(String)
        case loading    // 首次加载（还没有任何数据可显示）

        /// 只有 loading 态不给操作按钮（已经有进度指示了，再摆个「重新加载」是多余的）。
        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    let kind: Kind
    var title: String
    var message: String
    var retryTitle: String = "重新加载"
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                Text(title).font(.headline)
                // 不用固定高度占位：让内容居中在可用空间里，
                // 这样窗口拉伸时不会显得"内容飘在某个角落"

            case .empty:
                Image(systemName: "tray")
                    .font(.system(size: 34))
                    // 语义色，跟随系统深色模式自动变浅
                    .foregroundStyle(.tertiary)
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

            case .error(let e):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(title).font(.headline)
                Text(e)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // 允许换行 + 滚动：错误信息可能是站点返回的一长串 HTML
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }

            // 加载中已经有转圈了，就不要再摆一个按钮出来；
            // 空态和错误态才给重试 —— 每个按钮都该有存在的理由。
            if !kind.isLoading, let onRetry {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// 顶部的细进度条：刷新时保留旧数据，用它表示"正在更新"。
///
/// 不做成遮挡内容的遮罩层 —— 遮挡会让用户暂时读不了列表，
/// 而列表内容在刷新期间其实完全有效。
struct TopProgressBar: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            // 2pt 高的细条，不用 ProgressView 转圈：
            // 转圈放在工具栏会跳来跳去，细条更克制
            ProgressView()
                .progressViewStyle(.linear)
                .frame(height: 2)
        }
    }
}

// MARK: - 时间格式化

enum Fmt {
    /// 毫秒 → 人类可读。
    /// 站点给的 memory 单位是 KB（Hydro 惯例），除以 1024 得到 MB。
    static func duration(ms: Int) -> String {
        guard ms > 0 else { return "-" }
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.2f s", Double(ms) / 1000)
    }

    static func memory(kb: Int) -> String {
        guard kb > 0 else { return "-" }
        if kb < 1024 { return "\(kb) KB" }
        if kb < 1024 * 1024 { return String(format: "%.1f MB", Double(kb) / 1024) }
        return String(format: "%.2f GB", Double(kb) / 1024 / 1024)
    }

    /// 时间戳 → 本地时间。
    /// 站点给的是秒级时间戳（Model 里已统一成 Double）。
    static func date(_ t: Double?) -> String {
        guard let t, t > 0 else { return "-" }
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current      // 用当前时区，教练看的是自己的当地时间
        return f.string(from: d)
    }
}