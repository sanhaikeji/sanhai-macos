import SwiftUI
import AppKit   // NSWorkspace（打开浏览器）在 AppKit 里，SwiftUI 不转发它

// MARK: - 评测页

/// 评测页：提交记录列表 + 详情。
///
/// 用两级 `NavigationSplitView`（列表 | 详情）而不是单层：
/// 看代码和看列表在 macOS 上是并排的两个任务，
/// 挤到一个导航栈里就得反复来回切，这是 iOS 布局直接搬过来最难受的地方。
struct RecordListView: View {

    @EnvironmentObject private var store: DataStore
    @EnvironmentObject private var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            list
                .navigationTitle("评测")
                .toolbar { listToolbar }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: 左：列表

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            TopProgressBar(isLoading: store.recordState.isLoading)
            filterBar

            switch store.recordState {
            case .idle:
                StatePlaceholder(
                    kind: .empty,
                    title: "还没加载提交记录",
                    message: "点击「加载记录」从站点拉取。",
                    retryTitle: "加载记录",
                    onRetry: { Task { await store.loadRecords(resetPage: true) } }
                )

            case .loading where store.records.isEmpty:
                StatePlaceholder(kind: .loading, title: "正在加载提交记录…", message: "")

            case .failed(let msg):
                StatePlaceholder(
                    kind: .error(msg),
                    title: "提交记录加载失败",
                    message: "",
                    onRetry: { Task { await store.loadRecords(resetPage: true) } }
                )

            case .loading, .loaded:
                if store.records.isEmpty {
                    // 空列表要给出"为什么空"的可能解释，但**不能**断言是权限问题。
                    // 站点没给这个信号，界面上的任何"你没有权限"都是我们自己编的。
                    StatePlaceholder(
                        kind: .empty,
                        title: "没有提交记录",
                        message: emptyReason,
                        retryTitle: "重新加载",
                        onRetry: { Task { await store.loadRecords(resetPage: true) } }
                    )
                } else {
                    recordTable
                }
            }
        }
    }

    /// 空状态的解释文案。
    /// 只陈述**我们确实知道**的事实（当前带了什么筛选条件），
    /// 不猜测服务端为什么没给数据。
    private var emptyReason: String {
        var parts: [String] = ["接口返回了 0 条记录。"]
        var filters: [String] = []
        if !store.recordPidFilter.isEmpty { filters.append("题号 \(store.recordPidFilter)") }
        if store.recordOnlyAC { filters.append("只看 AC") }
        if !filters.isEmpty {
            parts.append("当前筛选条件：" + filters.joined(separator: "、") + "。")
            parts.append("可以取消筛选再看看。")
        } else {
            parts.append("可能这个账号还没有提交过，或者筛选条件太窄。")
        }
        return parts.joined(separator: "\n")
    }

    private var recordTable: some View {
        VStack(spacing: 0) {
            List(selection: Binding<String?>(
                // 泛型参数要显式标成 String?：List 的 selection 是可选值绑定，
                // 靠推断时 get 返回 `store.selectedRecord?.rid`（Optional）而
                // set 也收 Optional，恰好一致；但显式写出来更不容易在后续改动中改错。
                get: { store.selectedRecord?.rid },
                set: { rid in
                    if let rid { Task { await store.loadDetail(rid: rid) } }
                    else { store.clearDetail() }
                }
            )) {
                Section {
                    ForEach(store.records) { r in
                        recordRow(r)
                            .tag(r.rid)
                    }
                } header: {
                    HStack {
                        Text("共 \(store.records.count) 条（第 \(store.recordPage) 页）")
                        Spacer()
                        // canViewAll 只是「接口这次有没有可能返回别人的记录」的事实，
                        // 不做成任何形式的权限断言，只是安静地显示。
                        if store.canViewAll {
                            Text("含全部可见用户")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            paginationBar
        }
    }

    private func recordRow(_ r: Record) -> some View {
        HStack(spacing: 10) {
            statusPill(r)

            VStack(alignment: .leading, spacing: 1) {
                Text("题号 \(r.pid)")
                    .font(.callout.monospacedDigit())
                HStack(spacing: 6) {
                    Text(r.lang)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(Fmt.date(r.at))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // 评测中的记录不带耗时（还没跑完），显示个短横线比显示 "0 ms" 诚实
                    Text("· \(Fmt.duration(ms: r.time))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            if r.score > 0 {
                Text("\(r.score) 分")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// 状态徽章。
    /// 颜色表达"这题过得怎么样"，语义色跟随深色模式自动调整对比度。
    @ViewBuilder
    private func statusPill(_ r: Record) -> some View {
        let c = tintColor(r.statusTint)
        if r.isPending {
            // 评测中：转圈而不是静态徽章，让"还在动"这件事是可见的
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text(r.statusText)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
        } else {
            Text(r.statusText)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(c)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(c.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 52, alignment: .leading)
        }
    }

    private func tintColor(_ t: StatusTint) -> Color {
        switch t {
        case .success: return .green
        case .failure: return .red
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    private var paginationBar: some View {
        HStack {
            Button {
                Task { await store.previousPage() }
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(store.recordPage <= 1 || store.recordState.isLoading)

            Spacer()

            Text("第 \(store.recordPage) 页")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { await store.nextPage() }
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            // 「本页没取满」就是没有下一页了 —— 不依赖服务端给不给总数
            .disabled(store.records.count < settings.pageSize || store.recordState.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary)
    }

    // MARK: 筛选条

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("按题号筛选", text: $store.recordPidFilter)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .frame(minWidth: 120)
                .onSubmit { Task { await store.loadRecords(resetPage: true) } }

            Toggle("只看 AC", isOn: $store.recordOnlyAC)
                .toggleStyle(.checkbox)     // macOS 上 checkbox 比 iOS 的 switch 更合适
                .font(.callout)
                // 刻意用单参数 onChange（旧签名）而不是 `{ _, _ in }` 的双参数版本：
                // 双参数版本要 macOS 14，而本工程最低支持 13，用了会在 13 上编译不过。
                .onChange(of: store.recordOnlyAC) { _ in
                    Task { await store.loadRecords(resetPage: true) }
                }

            if !store.recordPidFilter.isEmpty || store.recordOnlyAC {
                Button("清除筛选") {
                    store.recordPidFilter = ""
                    store.recordOnlyAC = false
                    Task { await store.loadRecords(resetPage: true) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary)
    }

    @ToolbarContentBuilder
    private var listToolbar: some View {
        ToolbarItemGroup {
            Button {
                Task { await store.loadRecords(resetPage: true) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("重新拉取提交记录（⌘R）")
            .disabled(store.recordState.isLoading)
        }
    }

    // MARK: 右：详情

    @ViewBuilder
    private var detail: some View {
        switch store.detailState {
        case .idle:
            StatePlaceholder(
                kind: .empty,
                title: "没有选中提交",
                message: "在左边点一条提交，这里会显示代码、编译输出和测试用例。",
                onRetry: nil
            )
        case .loading:
            StatePlaceholder(kind: .loading, title: "正在加载详情…", message: "")
        case .failed(let msg):
            StatePlaceholder(kind: .error(msg), title: "详情加载失败", message: "", onRetry: nil)
        case .loaded:
            if let d = store.selectedRecord {
                RecordDetailView(detail: d)
            } else {
                StatePlaceholder(
                    kind: .empty,
                    title: "没有选中提交",
                    message: "在左边点一条提交，这里会显示代码、编译输出和测试用例。",
                    onRetry: nil
                )
            }
        }
    }
}

// MARK: - 提交详情

/// 单条提交的详情：元信息 + 代码 + 编译输出 + 用例。
struct RecordDetailView: View {

    let detail: RecordDetail

    @State private var tab: Tab = .code

    enum Tab: String, CaseIterable, Identifiable {
        case code, compiler, cases
        var id: String { rawValue }
        var title: String {
            switch self {
            case .code: return "代码"
            case .compiler: return "编译输出"
            case .cases: return "测试用例"
            }
        }
        var systemImage: String {
            switch self {
            case .code: return "curlybraces"
            case .compiler: return "wrench.and.screwdriver"
            case .cases: return "checklist"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            picker
            Divider()
            body(for: tab)
        }
        .navigationTitle("提交 \(detail.rid)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(detail.statusText)
                    .font(.callout.monospaced().weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(statusColor)

                Text(detail.lang).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let url = settingsBaseURL?.appendingPathComponent("record/\(detail.rid)") {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("在浏览器中查看", systemImage: "safari")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            HStack(spacing: 14) {
                metric("题号", detail.pid)
                metric("用户", detail.uid)
                metric("耗时", Fmt.duration(ms: detail.time))
                metric("内存", Fmt.memory(kb: detail.memory))
                metric("得分", detail.score > 0 ? "\(detail.score)" : "-")
            }
        }
        .padding(12)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).lineLimit(1)
        }
    }

    private var statusColor: Color {
        if detail.isAC { return .green }
        if detail.status == 0 { return .secondary }
        if detail.status == 7 { return .orange }
        return .red
    }

    private var settingsBaseURL: URL? {
        // 详情页只用来拼一个"浏览器打开"的链接，拿不到设置时就隐藏按钮，不报错
        UserDefaults.standard.string(forKey: "sanhai.baseURL").flatMap { URL(string: $0) }
    }

    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { t in
                Label(t.title, systemImage: t.systemImage).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var body(for tab: Tab) -> some View {
        switch tab {
        case .code:
            if detail.code.isEmpty {
                // ⚠️ 代码为空有**两种**可能：有权限但确实没代码（如站点裁剪），
                //    或者没有权限看这份代码。接口不给区分信号，
                //    所以这里**不写**"你没有权限查看代码"——
                //    那是编出来的事实。两种情况都说得通，文案保持中性。
                emptyPane(icon: "curlybraces",
                          title: "没有可显示的代码",
                          message: "这份提交的代码内容是空的。")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(detail.code)
                        // 等宽字体 + 不换行：代码靠对齐读，
                        // 强制折行会把缩进结构破坏掉
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)   // 允许选中复制 —— 看代码的人十有八九要复制
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .compiler:
            if detail.compilerTexts.isEmpty {
                emptyPane(icon: "checkmark.seal",
                          title: "没有编译输出",
                          message: "编译通过时站点通常不会返回任何输出，这里是正常情况。")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(detail.compilerTexts.enumerated()), id: \.offset) { i, t in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("编译器 \(i + 1)").font(.caption).foregroundStyle(.secondary)
                                Text(t)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(12)
                }
            }

        case .cases:
            if detail.testCases.isEmpty {
                emptyPane(icon: "checklist",
                          title: "没有测试用例数据",
                          message: "站点没有返回用例明细（部分配置下不开放这个字段）。")
            } else {
                List {
                    Section("共 \(detail.testCases.count) 个用例") {
                        ForEach(detail.testCases, id: \.id) { c in
                            HStack(spacing: 10) {
                                Text("#\(c.id)").font(.callout.monospacedDigit())
                                    .frame(width: 44, alignment: .trailing)
                                caseStatus(c)
                                Spacer()
                                Text(Fmt.duration(ms: c.time ?? 0))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func caseStatus(_ c: TestCase) -> some View {
        if let st = c.status {
            // 用例级状态同样按 Hydro 约定：1=AC
            let passed = st == 1
            Label(passed ? "通过" : "失败 (\(Record.statusText(for: st)))",
                  systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(passed ? Color.green : Color.red)
        } else {
            Text("无状态").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyPane(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout).fontWeight(.medium)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}