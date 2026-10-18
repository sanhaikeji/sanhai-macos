import Foundation
import SwiftUI

// MARK: - 加载状态

/// 一个数据区域的加载状态。
///
/// ⚠️ 为什么要单独把这个抽出来，而不是用 `items.isEmpty` 判断：
///    「空」在 OJ 客户端里至少有三个完全不同的含义 ——
///    1. 还没请求
///    2. 请求中
///    3. 请求完了，确实一条都没有
///    只看数组是否为空，这三种状态会渲染成同一个空白界面，
///    用户看到"列表是空的"其实是"还没加载"。
///    现在站点上勋章和提交记录**本来就是空的**，
///    这三种如果分不清，界面在"有数据"和"出错"时看着都对，
///    唯独在真实用户遇到的"没数据"场景下全是错的。
enum LoadState: Equatable {
    case idle        // 还没请求过
    case loading     // 请求中（保留旧数据，避免刷新时闪一下空白）
    case loaded      // 请求成功（可能 0 条，见 isEmpty）
    case failed(String)

    var isLoading: Bool { self == .loading }

    var errorMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }

    var hasError: Bool { errorMessage != nil }
}

// MARK: - 侧栏分区

/// 侧栏里的一页。只有题库、评测、设置三页。
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case problems, records, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .problems: return "题库"
        case .records: return "评测"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .problems: return "list.bullet.rectangle"   // macOS SF Symbols 名，不是 iOS 那套
        case .records: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - 数据仓库

/// 全局数据仓库。
///
/// 用一个 `@MainActor ObservableObject` 统管两页数据，
/// 而不是每页各自 `@StateObject` + 各自 `ApiClient`：
///   - 侧栏切页时数据不丢（切回题库不用重新拉）
///   - 刷新一条命令能让两页同时刷新
///   - 设置变更（比如换了站点地址）能一处生效
@MainActor
final class DataStore: ObservableObject {

    // MARK: 题库

    @Published private(set) var problems: [Problem] = []
    @Published private(set) var problemState: LoadState = .idle
    @Published var problemSearch: String = ""

    // MARK: 评测

    @Published private(set) var records: [Record] = []
    @Published private(set) var recordState: LoadState = .idle
    @Published private(set) var recordPage: Int = 1
    @Published private(set) var canViewAll: Bool = false

    /// 筛选：只看某题 / 只看 AC。
    @Published var recordPidFilter: String = ""
    @Published var recordOnlyAC: Bool = false

    /// 选中的一条提交的详情。
    @Published var selectedRecord: RecordDetail?
    @Published private(set) var detailState: LoadState = .idle

    // MARK: 全局

    @Published var section: SidebarSection = .problems

    private var api = ApiClient()
    private var settings: AppSettings?

    /// 计算属性：当前是否有任何一处正在加载。用于禁用刷新按钮。
    var isLoading: Bool {
        problemState.isLoading || recordState.isLoading || detailState.isLoading
    }

    /// 把设置对象交给仓库。
    /// 用方法而不是 init 注入，是因为 `AppSettings.shared` 是全局单例，
    /// 在 `SanhaiMacApp` 的属性初始化器里就把它当依赖注入进来，
    /// 会让「谁持有设置」这件事变得不清楚。这里显式挂一次，之后统一从这里取。
    func attach(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - 搜索（纯本地过滤）

    /// 按关键字过滤题目。
    /// 纯本地过滤而不是每次输入都发请求：题库规模不大，
    /// 每次按键打一次接口既慢又会给站点添麻烦。
    var filteredProblems: [Problem] {
        let q = problemSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return problems }
        return problems.filter {
            $0.pid.localizedCaseInsensitiveContains(q)
                || $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - 取数据

    /// 刷新全部（对应 ⌘R）。
    func refreshAll() async {
        guard let settings, settings.isConfigured else { return }
        async let p: Void = loadProblems()
        async let r: Void = loadRecords(resetPage: true)
        _ = await (p, r)
    }

    func select(_ s: SidebarSection) {
        section = s
        // 首次进入某页时才加载，避免启动就打三个接口。
        // 注意用 .idle 判断而不是数组是否为空 —— 空数组可能意味着"确实没有数据"，
        // 那种情况下切回来又会重新拉一遍，白白浪费。
        if s == .problems, problemState == .idle { Task { await loadProblems() } }
        if s == .records, recordState == .idle { Task { await loadRecords(resetPage: true) } }
    }

    func loadProblems() async {
        guard let settings else { return }
        guard settings.isConfigured else {
            problemState = .failed(ApiClient.APIError.notConfigured.localizedDescription)
            return
        }

        // 刷新时保留旧数据：直接把列表清空会让界面在等网络的几秒里变成"没有题目"，
        // 用户会以为题目被删了。改为保留 + 顶部显示进度。
        problemState = .loading
        do {
            problems = try await api.fetchProblems(baseURL: settings.baseURL,
                                                   token: settings.token)
            problemState = .loaded
        } catch {
            problemState = .failed(Self.describe(error))
        }
    }

    func loadRecords(resetPage: Bool) async {
        guard let settings else { return }
        guard settings.isConfigured else {
            recordState = .failed(ApiClient.APIError.notConfigured.localizedDescription)
            return
        }

        if resetPage { recordPage = 1 }

        recordState = .loading
        do {
            let resp = try await api.fetchRecords(
                baseURL: settings.baseURL,
                token: settings.token,
                pid: recordPidFilter.isEmpty ? nil : recordPidFilter,
                status: recordOnlyAC ? 1 : nil,     // 只筛 AC → status=1
                page: recordPage,
                limit: settings.pageSize
            )
            records = resp.records
            canViewAll = resp.canViewAll
            recordState = .loaded
        } catch {
            recordState = .failed(Self.describe(error))
        }
    }

    func nextPage() async {
        guard let settings else { return }
        // 用"本页是否取满"判断还有没有下一页，比依赖站点给不给 count 更稳
        guard records.count >= settings.pageSize else { return }
        recordPage += 1
        await loadRecords(resetPage: false)
    }

    func previousPage() async {
        guard recordPage > 1 else { return }
        recordPage -= 1
        await loadRecords(resetPage: false)
    }

    /// 载入单条提交的详情（含代码）。
    func loadDetail(rid: String) async {
        guard let settings else { return }
        detailState = .loading
        selectedRecord = nil
        do {
            selectedRecord = try await api.fetchRecordDetail(baseURL: settings.baseURL,
                                                             token: settings.token,
                                                             rid: rid)
            detailState = .loaded
        } catch {
            detailState = .failed(Self.describe(error))
        }
    }

    func clearDetail() {
        selectedRecord = nil
        detailState = .idle
    }

    /// 设置页「测试连接」用。
    func testConnection() async -> String {
        guard let settings else { return "设置还没初始化" }
        do {
            let n = try await api.ping(baseURL: settings.baseURL, token: settings.token)
            return "连接成功，站点返回 \(n) 道题目。"
        } catch {
            return Self.describe(error)
        }
    }

    /// 把错误统一翻译成一句话。
    /// 直接把 `Error` 显示出来会出现 "(null)" 或一坨英文异常名，用户完全无法行动。
    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription {
            return d
        }
        if let e = error as? ApiClient.APIError, let d = e.errorDescription {
            return d
        }
        return error.localizedDescription
    }
}