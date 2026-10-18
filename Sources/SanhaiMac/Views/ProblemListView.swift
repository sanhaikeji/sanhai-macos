import SwiftUI
import AppKit   // NSWorkspace（打开浏览器）、NSPasteboard（复制题号）在 AppKit 里

// MARK: - 题库页

/// 题库页：题目列表 + 搜索。
///
/// 结构是 `NavigationSplitView` 里的 detail 区，
/// 因为只有两页内容、没有"主从两级浏览"，再套一层列表-详情是过度设计。
struct ProblemListView: View {

    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            TopProgressBar(isLoading: store.problemState.isLoading)
            content
        }
        .navigationTitle("题库")
        .toolbar {
            ToolbarItemGroup {
                // macOS 的搜索是放在工具栏里的（⌘F 也能唤起），
                // 不是 iOS 那种从屏幕顶部滑下来的搜索条
                searchField
                    .frame(minWidth: 180, idealWidth: 240)

                Button {
                    Task { await store.loadProblems() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重新从站点拉取题目（⌘R）")
                .disabled(store.problemState.isLoading)
            }
        }
    }

    // MARK: 内容（三态）

    @ViewBuilder
    private var content: some View {
        switch store.problemState {
        case .idle:
            // 还没请求过：给一个明确的入口，而不是干等着。
            // 注意不自动请求，是因为设置可能还没填（没令牌），
            // 自动请求只会立刻弹一个 401。
            StatePlaceholder(
                kind: .empty,
                title: "还没加载题库",
                message: "点击「加载题目」从站点拉取题目列表。\n如果还没填令牌，请先到「设置」里配置站点地址和令牌。",
                retryTitle: "加载题目",
                onRetry: { Task { await store.loadProblems() } }
            )

        case .loading where store.problems.isEmpty:
            // 首次加载：还没有任何旧数据可显示，只能给转圈
            StatePlaceholder(kind: .loading, title: "正在加载题目…", message: "")

        case .failed(let msg):
            StatePlaceholder(
                kind: .error(msg),
                title: "题目加载失败",
                message: "",
                onRetry: { Task { await store.loadProblems() } }
            )

        case .loading, .loaded:
            listBody
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let items = store.filteredProblems

        if items.isEmpty {
            // 请求成功但一条都没有 —— 这和"还没加载"是两回事，
            // 必须区分：站点的题库为空是真实存在的情况，空白界面会让人以为程序坏了
            StatePlaceholder(
                kind: .empty,
                title: store.problemSearch.isEmpty ? "站点上没有题目" : "没有匹配的题目",
                message: store.problemSearch.isEmpty
                    ? "接口返回了一个空列表。可能是站点题库确实是空的，也可能是令牌权限范围有限。"
                    : "换个关键字再试试。搜索是在已加载的 \(store.problems.count) 道题里本地过滤的。",
                retryTitle: "重新加载",
                onRetry: { Task { await store.loadProblems() } }
            )
        } else {
            List {
                Section {
                    ForEach(items) { p in
                        row(p)
                    }
                } header: {
                    // 表头显示数量：一句话就能确认"数据对不对"，
                    // 比用户自己数一遍行数快得多
                    Text("共 \(items.count) 道题"
                         + (items.count == store.problems.count ? "" : "（已从 \(store.problems.count) 道中筛选）"))
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: 行

    private func row(_ p: Problem) -> some View {
        HStack(spacing: 12) {
            Text(p.pid)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                // 定宽并右对齐：一列 pid 对齐之后才好扫读，
                // 不然长短不一的题号会像锯齿一样
                .frame(minWidth: 70, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(p.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if p.hidden == true {
                    // 「隐藏题」对教练是个有用信息：看得到但不能提交
                    Text("已隐藏（不可提交）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            difficultyBadge(p)
        }
        .padding(.vertical, 3)
        // 整行可点：macOS 用户的预期是点哪里都能选中，
        // 不是只有点文字那一小块
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = p.fullURL(baseURL: settings.baseURL) {
                NSWorkspace.shared.open(url)
            }
        }
        .contextMenu {
            Button("在浏览器中打开题面") {
                if let url = p.fullURL(baseURL: settings.baseURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("只看这道题的提交") {
                store.recordPidFilter = p.pid
                store.select(.records)
                Task { await store.loadRecords(resetPage: true) }
            }
            Button("复制题号") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.pid, forType: .string)
            }
        }
    }

    /// 难度标签。
    ///
    /// ⚠️ 0 是「未评定」，显示成"未评定"而不是 0 星。
    ///    如果把 0 当成"最简单"，未评定的题会全部挤到难度榜最前面，
    ///    那是把"没有数据"伪装成了"数据很极端"。
    @ViewBuilder
    private func difficultyBadge(_ p: Problem) -> some View {
        if p.isDifficultyUnrated {
            Text("未评定")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                // 用描边而不是填充：未评定是"弱信息"，
                // 填充色会让它看起来像有确切结论
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        } else {
            Text("\(p.difficulty)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(difficultyColor(p.difficulty).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(difficultyColor(p.difficulty))
        }
    }

    /// 难度配色。用语义化的系统色，跟随深色模式自动适配。
    private func difficultyColor(_ d: Int) -> Color {
        switch d {
        case 1, 2: return .green
        case 3, 4: return .teal
        case 5, 6: return .orange
        case 7, 8: return .red
        default: return .purple
        }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索题号或标题", text: $store.problemSearch)
                .textFieldStyle(.plain)
                // 即时筛选：本地过滤不需要防抖，也不需要等网络
                .frame(height: 18)
            if !store.problemSearch.isEmpty {
                Button {
                    store.problemSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}