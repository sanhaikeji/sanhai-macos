import Foundation

// MARK: - 题目

/// 题目模型。
///
/// ⚠️ 关于 `pid`：站点上 pid 既可能是数字（`1001`）也可能是字符串（`P1001`、甚至 `atcoder-abc001_a` 这类 slug）。
///    所以**必须**用 `String` 接，并且在解析时容错（见 `init(from:)`）。
///    如果这里声明成 `Int`，遇到字符串 pid 会直接让整个 /problems 解析失败 —— 表现是"列表空了"，
///    很容易误判成"账号没数据"，很难查。
struct Problem: Identifiable, Hashable, Codable {

    /// 站点上的题号，用字符串统一承接数字与字符串两种形态。
    let pid: String
    let title: String

    /// 难度 0~10。
    ///
    /// ⚠️ **0 的语义是"站点未评定"，不是"最简单"**。
    ///    所以界面上必须显示成「未评定」/「-」之类的占位，
    ///    绝不能显示成 0 星或者排进难度榜的最前排 —— 那是把"没有数据"说成"数据很极端"。
    let difficulty: Int

    /// 题面地址（相对站点根），可选。
    let url: String?

    /// 题目是否已停止接收提交（站点若有此字段）。
    let hidden: Bool?

    var id: String { pid }

    /// 难度是否为站点未评定。
    var isDifficultyUnrated: Bool { difficulty == 0 }

    /// 供界面直接显示的中文难度文案。
    var difficultyText: String {
        isDifficultyUnrated ? "未评定" : "难度 \(difficulty)"
    }

    /// 题目详情页地址。
    ///
    /// 站点有时给绝对 URL，有时只给一个相对路径。这里只负责把站点给的 `url` 解析出来；
    /// 相对路径需要拼 baseURL，属于「当前站点是哪个」的知识，交给调用方（视图层）
    /// 用 `Problem.fullURL(baseURL:)` 拼。
    ///
    /// 刻意**不**在模型层直接引用全局设置（`AppSettings.shared`）：
/// 一是把「数据模型」和「运行时配置」耦合在了一起，
/// 二是模型可能被后台解析任务使用，不该假设任何运行时上下文。
/// 需要完整地址的调用方自己传 `baseURL` 进来。
    var problemURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        // scheme 非空说明已经是绝对地址，直接用；否则留给调用方拼 base
        guard let u = URL(string: url), u.scheme != nil else { return nil }
        return u
    }

    /// 完整的题面地址。`baseURL` 由调用方提供（AppSettings 的当前站点）。
    func fullURL(baseURL: URL?) -> URL? {
        if let absolute = problemURL { return absolute }
        guard let baseURL else { return nil }
        if let url, !url.isEmpty {
            // 相对路径：用 appendingPathComponent 而不是字符串拼接，
            // 拼接遇到中文/空格 pid 会生成非法 URL。
            return baseURL.appendingPathComponent(url)
        }
        // 没有 url 字段时按 Hydro 惯例拼 /p/<pid>
        return baseURL
            .appendingPathComponent("p")
            .appendingPathComponent(pid)
    }

    /// 手动实现解码，而不是直接用 `Codable` 合成：
    /// 站点字段类型并不稳定（pid 数字/字符串、difficulty 数字/字符串/null 都有可能），
    /// 容错必须写在解码器里。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // pid：数字或字符串都接
        if let s = try? c.decode(String.self, forKey: .pid), !s.isEmpty {
            pid = s
        } else if let i = try? c.decode(Int.self, forKey: .pid) {
            pid = String(i)
        } else {
            // 单个条目解析不了就抛出去，由上层的「宽松数组解码」负责丢弃这一条。
            // 之所以不在这里直接兜成空字符串：空 pid 会让选中态、拼题面 URL、筛记录全乱，
            // 与其留一条脏数据，不如整条丢掉。
            throw DecodingError.dataCorruptedError(forKey: .pid, in: c,
                                                   debugDescription: "题目缺少可用的 pid")
        }

        // title 可能叫 title，也可能叫 name（不同 Hydro 版本字段名有差异），做个兜底。
        // ⚠️ 兜底用的 `name` **不能**放进 CodingKeys：CodingKeys 里的每个 case 都必须
        //    对应一个已存储的属性，否则编译器无法合成 encode(to:)，整个类型就不是 Codable 了。
        //    所以单独开一个备用 key 枚举，从另一个 keyed container 里读。
        let alt = try? decoder.container(keyedBy: AltCodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? alt?.decode(String.self, forKey: .name))
            ?? "(无标题)"

        difficulty = (try? c.decode(Int.self, forKey: .difficulty)) ?? 0
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        hidden = try? c.decodeIfPresent(Bool.self, forKey: .hidden)
    }

    private enum CodingKeys: String, CodingKey {
        case pid, title, difficulty, url, hidden
    }

    /// 备用字段名（不在 CodingKeys 里，理由见上）。
    private enum AltCodingKeys: String, CodingKey {
        case name
    }
}

// MARK: - 提交记录

/// 一条提交记录（列表项）。
///
/// `code` 故意不放进来：列表接口不返回代码，详情接口才有，
/// 混在一个模型里容易让人误以为列表里就有代码。
struct Record: Identifiable, Hashable, Codable {

    let rid: String
    let pid: String
    let uid: String

    /// 语言标识（站点侧的短名，如 `cpp`、`python`）。
    let lang: String

    /// Hydro 的评测状态码：
    /// 1=AC, 2=WA, 3=TLE, 4=MLE, 5=RE, 6=SE, 7=CE
    /// 其他值（含 0= Judging/Queued/Compiling）都视为"未出结果"。
    let status: Int

    /// 得分（0~100 或站点自定义满分）。
    let score: Int

    /// 运行耗时（毫秒）。
    let time: Int

    /// 内存（千字节，Hydro 惯例）。
    let memory: Int

    /// 提交时间（站点返回的原始值，可能是秒级时间戳，也可能是格式化字符串）。
    ///
    /// 用 `Double?` + 自定义解码两种都接，避免为了一个展示字段在解析层翻车。
    let at: Double?

    var id: String { rid }

    /// 是否通过。**status == 1 就是 AC，这是 Hydro 内核的固定约定。**
    var isAC: Bool { status == 1 }

    /// 是否还在评测中（排队/编译/判题中）。
    var isPending: Bool { status == 0 || status < 0 }

    /// 中文状态词，用于列表里直接可读的一列。
    var statusText: String {
        Record.statusText(for: status)
    }

    /// 状态对应的语义色名，供视图层映射成 `.green` / `.orange` 等。
    /// 这里只给出"意图"，具体颜色在视图里选 —— 避免模型层绑死具体外观。
    var statusTint: StatusTint {
        if isAC { return .success }
        if isPending { return .neutral }
        if status == 7 { return .warning }   // CE 是自己的代码问题，不是算法错，颜色上区别开
        return .failure
    }

    // MARK: 手动解码（同 Problem：字段类型不稳定，容错前置）

    private enum CodingKeys: String, CodingKey {
        case rid, pid, uid, lang, status, score, time, memory, at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // rid / pid / uid 站点上都是"数字或字符串"，统一成 String
        func string(_ key: CodingKeys) throws -> String {
            if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { return s }
            if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
            throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                   debugDescription: "字段 \(key.rawValue) 缺失或类型不支持")
        }

        rid = try string(.rid)
        pid = (try? string(.pid)) ?? ""
        uid = (try? string(.uid)) ?? ""

        lang = (try? c.decode(String.self, forKey: .lang)) ?? "未知语言"

        // status 可能是数字，也可能直接是字符串 "AC" / "Accepted"
        if let i = try? c.decode(Int.self, forKey: .status) {
            status = i
        } else if let s = try? c.decode(String.self, forKey: .status) {
            status = Record.statusFromText(s)
        } else {
            status = 0
        }

        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        time = (try? c.decode(Int.self, forKey: .time)) ?? 0
        memory = (try? c.decode(Int.self, forKey: .memory)) ?? 0

        if let t = try? c.decode(Double.self, forKey: .at) {
            at = t
        } else if let s = try? c.decode(String.self, forKey: .at) {
            at = Record.parseDate(s)
        } else {
            at = nil
        }
    }

    // MARK: 状态词表（唯一的真相来源）
    //
    // Record 和 RecordDetail 都要显示状态词，抽成 static 供两边复用。
    // 之前写成两处 switch，结果 RecordDetail 里为了复用不得不构造一个假 Record，
    // 那种绕法迟早会让两边不同步 —— 单一真相来源比"复用"更重要。

    /// Hydro 状态码 → 中文状态词。
    static func statusText(for status: Int) -> String {
        switch status {
        case 1: return "AC"
        case 2: return "WA"
        case 3: return "TLE"
        case 4: return "MLE"
        case 5: return "RE"
        case 6: return "SE"
        case 7: return "CE"
        case 0: return "评测中"
        default: return "状态 \(status)"
        }
    }

    /// 站点返回文字状态时的兜底映射。
    static func statusFromText(_ s: String) -> Int {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "ac", "accepted", "accepted ✅", "success": return 1
        case "wa", "wrong answer", "wrong_answer": return 2
        case "tle", "time limit exceeded": return 3
        case "mle", "memory limit exceeded": return 4
        case "re", "runtime error": return 5
        case "se", "system error", "server error": return 6
        case "ce", "compile error", "compilation error": return 7
        default: return 0
        }
    }

    /// 宽松解析时间：支持秒/毫秒时间戳，也支持 `yyyy-MM-dd HH:mm:ss` 这类字符串。
    /// 有 ISO8601 就用 ISO8601，没有就退回一个简单的分隔符解析。
    static func parseDate(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Double(t) {
            // 站点一般给秒级时间戳；超过 1e12 判定为毫秒级。
            return d > 1e12 ? d / 1000 : d
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: t) {
            return date.timeIntervalSince1970
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")  // 固定 locale，否则非中文系统上解析会失败
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = f.date(from: t) {
            return date.timeIntervalSince1970
        }
        return nil
    }
}

/// 状态色意图。
enum StatusTint: Hashable {
    case success, failure, warning, neutral
}

// MARK: - 提交详情

/// 单条提交的详情（含代码）。
struct RecordDetail: Identifiable, Hashable, Codable {
    let rid: String
    let pid: String
    let uid: String
    let lang: String
    let status: Int
    let score: Int
    let time: Int
    let memory: Int

    /// 源码。**只在有权限时非空** —— 无权限时站点会返回空串或缺这个字段。
    let code: String

    /// 编译器输出（可能为空数组）。
    let compilerTexts: [String]

    /// 用例（可能为空数组）。
    let testCases: [TestCase]

    var id: String { rid }
    var isAC: Bool { status == 1 }

    var statusText: String {
        // 复用 Record 的映射，避免两处各写一份状态词表（那种重复迟早会不同步）
        Record.statusText(for: status)
    }

    private enum CodingKeys: String, CodingKey {
        case rid, pid, uid, lang, status, score, time, memory
        case code, compilerTexts, testCases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String {
            if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { return s }
            if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
            return ""
        }
        rid = string(.rid)
        pid = string(.pid)
        uid = string(.uid)
        lang = (try? c.decode(String.self, forKey: .lang)) ?? "未知语言"
        status = (try? c.decode(Int.self, forKey: .status)) ?? 0
        score = (try? c.decode(Int.self, forKey: .score)) ?? 0
        time = (try? c.decode(Int.self, forKey: .time)) ?? 0
        memory = (try? c.decode(Int.self, forKey: .memory)) ?? 0
        code = (try? c.decode(String.self, forKey: .code)) ?? ""
        compilerTexts = (try? c.decode([String].self, forKey: .compilerTexts)) ?? []
        testCases = (try? c.decode([TestCase].self, forKey: .testCases)) ?? []
    }
}

/// 单个测试用例。
struct TestCase: Hashable, Codable {
    let id: Int
    let status: Int?
    let score: Int?
    let time: Int?
    let memory: Int?
    /// 站点有时给 `result`（期望输出），有时给 `expected`。
    let result: String?

    private enum CodingKeys: String, CodingKey {
        case id, status, score, time, memory, result
    }

    /// 备用字段名（不在 CodingKeys 里 —— 非存储属性会让 encode(to:) 合成失败）。
    private enum AltCodingKeys: String, CodingKey {
        case expected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alt = try? decoder.container(keyedBy: AltCodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        status = try? c.decodeIfPresent(Int.self, forKey: .status)
        score = try? c.decodeIfPresent(Int.self, forKey: .score)
        time = try? c.decodeIfPresent(Int.self, forKey: .time)
        memory = try? c.decodeIfPresent(Int.self, forKey: .memory)
        result = (try? c.decodeIfPresent(String.self, forKey: .result))
            ?? (try? alt?.decodeIfPresent(String.self, forKey: .expected))
    }
}

// MARK: - 宽松数组解码

/// 「能解几个解几个」的数组解码。
///
/// 为什么需要它：标准 `decode([T].self, forKey:)` 是**全有或全无**的 ——
/// 数组里只要有一个元素缺字段，整个数组就抛错，界面表现是"列表全空"。
/// 而站点返回的数据里混着历史脏数据是常态（老题目的字段、被裁剪过的接口响应）。
/// 结果就是**一条脏数据让整个页面白屏**，而用户看到的只是"怎么什么都没有"。
///
/// 这里逐个 try，丢掉解不出来的，剩下的照常显示：宁少几条，不可整页失败。
extension KeyedDecodingContainer {
    func decodeLossyArray<T: Decodable>(_ type: [T].Type, forKey key: Key) throws -> [T] {
        var container = try nestedUnkeyedContainer(forKey: key)
        var result: [T] = []
        while !container.isAtEnd {
            // 关键在 `try?`：解不出来的元素直接跳过，不影响其它元素
            if let item = try? container.decode(T.self) {
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - 列表容器

/// `/client-api/problems` 的响应包装。
///
/// 站点实际返回的是 `{"problems": [...]}`，
/// 但我们故意**不**用裸数组做返回类型：接口层将来加字段（比如分页、总数）时
/// 不用改调用方签名。这是很便宜的一层保险。
struct ProblemListResponse: Codable {
    let problems: [Problem]

    private enum CodingKeys: String, CodingKey {
        case problems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 站点没给 problems 时返回空数组而不是抛错：
        // "没有数据"是正常业务状态，不该被当成解析失败弹红条。
        problems = (try? c.decodeLossyArray([Problem].self, forKey: .problems)) ?? []
    }

    /// 直接从裸数组构造（部分站点的兼容接口会这么返回）。
    init(problems: [Problem]) {
        self.problems = problems
    }

    init(from data: Data) throws {
        // 先试标准包装格式，失败再试裸数组 —— 兼容两种返回形态
        if let wrapped = try? JSONDecoder().decode(ProblemListResponse.self, from: data) {
            self = wrapped
            return
        }
        self.problems = try JSONDecoder().decode([Problem].self, from: data)
    }
}

/// `/client-api/records` 的响应容器。
///
/// ⚠️ 关于 `canViewAll`：
///    它表示当前账号能不能看**别人**的提交。没有权限时接口**只返回自己的记录**，
///    而且**不会**给出任何"为什么不给"的信号。
///    所以界面**不要**显示"你没有权限查看他人提交"这类文案 ——
///    接口没给这个信息，界面上的任何断言都是我们自己编的，属于误导。
///    正确做法是安静地展示接口实际返回的列表。
struct RecordListResponse: Codable {
    let page: Int
    let limit: Int
    let canViewAll: Bool
    let uidScope: String?
    let pidScope: String?
    let statusScope: String?
    let records: [Record]

    /// 总页数。接口有时给 `count`（总条数），有时只给每页条数，两种都处理。
    let count: Int?

    private enum CodingKeys: String, CodingKey {
        case page, limit, canViewAll, uidScope, pidScope, statusScope, records, count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = (try? c.decode(Int.self, forKey: .page)) ?? 1
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? 20
        canViewAll = (try? c.decode(Bool.self, forKey: .canViewAll)) ?? false
        uidScope = try? c.decodeIfPresent(String.self, forKey: .uidScope)
        pidScope = try? c.decodeIfPresent(String.self, forKey: .pidScope)
        statusScope = try? c.decodeIfPresent(String.self, forKey: .statusScope)
        records = (try? c.decodeLossyArray([Record].self, forKey: .records)) ?? []
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
    }

    /// 是否还有下一页。
    /// 优先用 `count`（总条数）算；没有 count 时用"本页取满 limit 条"保守推断。
    var hasMore: Bool {
        if let total = count, total > 0 {
            return page * limit < total
        }
        return records.count >= limit && limit > 0
    }
}

// MARK: - 通用分页容器

/// 轻量分页容器，用于把分页状态和列表数据绑在一起，避免视图里散落一堆 `@State` 分页变量。
struct Paged<T: Codable>: Codable {
    var page: Int
    var limit: Int
    var items: [T]
    var total: Int?

    var hasMore: Bool {
        if let t = total, t > 0 { return page * limit < t }
        return items.count >= limit && limit > 0
    }

    var isEmpty: Bool { items.isEmpty }

    static var empty: Paged<T> {
        Paged(page: 1, limit: 20, items: [], total: nil)
    }
}