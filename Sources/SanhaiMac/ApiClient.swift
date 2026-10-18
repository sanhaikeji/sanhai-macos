import Foundation

// MARK: - API 客户端

/// SanhaiOJ（Hydro 内核）JSON 接口客户端。
///
/// 只做四件事：拼 URL、带上 Bearer 令牌、发请求、把错误翻译成人话。
/// 不引入任何第三方网络库 —— 这点请求量用 `URLSession` 完全够，
/// 而且少一个依赖就少一份 CI 缓存和供应链负担（见 Package.swift 里的说明）。
///
/// 线程安全：这是一个 `actor`，所有状态访问天然串行，
/// 不需要到处加锁。用法是 `await api.fetchProblems()`。
actor ApiClient {

    /// 接口错误。
    enum APIError: LocalizedError {
        case notConfigured
        case badURL(String)
        case transport(String)
        case timeout
        case http(status: Int, body: String)
        case decoding(String)
        case noToken

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "还没配置站点地址或令牌，请到「设置」填写。"
            case .badURL(let s):
                return "站点地址不合法：\(s)"
            case .transport(let s):
                return "网络请求失败：\(s)"
            case .timeout:
                return "请求超时。站点可能被墙、太慢，或者 Wi-Fi 不稳。"
            case .http(let status, let body):
                // 401/403 是最常遇到的两个，单独给一句能行动的建议，
                // 光甩一个 401 用户是不知道怎么处理的。
                switch status {
                case 401:
                    return "令牌无效或已过期（401）。请到「设置」重新填令牌。"
                case 403:
                    return "没有权限访问该资源（403）。"
                case 404:
                    return "接口不存在（404）。请确认站点地址填的是站点根地址。"
                case 429:
                    return "请求太频繁（429），被站点限流了，稍后再试。"
                case 500...599:
                    return "站点服务端出错（\(status)）。这是站点的问题，不是客户端的。"
                default:
                    let tail = body.isEmpty ? "" : "：\(body.prefix(200))"
                    return "请求失败（HTTP \(status)）\(tail)"
                }
            case .decoding(let s):
                return "返回数据解析失败：\(s)"
            case .noToken:
                return "需要令牌才能访问该接口。"
            }
        }
    }

    /// 请求日志，界面上可以直接显示 —— 网络出问题时，"到底发出去了什么"是最关键的信息。
    private(set) var lastRequestLog: String?

    private let session: URLSession

    /// - Parameter timeout: 单次请求超时（秒）。
    init(timeout: TimeInterval = 20) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        // 缓存关掉：OJ 的题目/提交记录要求实时性，
        // 拿到 30 秒前的缓存列表比拿一份新数据糟糕得多。
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = true
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 底层请求

    /// 发一个请求，返回 `Data`。
    /// 所有对外方法都走这里，保证 baseURL、令牌、超时、错误处理的**行为完全一致** ——
    /// 这类"四份代码各写一遍令牌头"的事情，历史上每次都会漏掉一处。
    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)

            lastRequestLog = """
            \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "-")
            → HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)
            字节数 \(data.count)
            """

            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("响应不是 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode,
                                     body: String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let e as APIError {
            throw e                       // 已经是我们的错误，原样抛
        } catch let e as URLError {
            switch e.code {
            case .timedOut:
                throw APIError.timeout
            case .cancelled:
                throw APIError.transport("请求被取消")
            default:
                throw APIError.transport("\(e.localizedDescription)（\(e.code.rawValue)）")
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    /// 构造请求。baseURL 与 token 由调用方从设置里传入（Settings 在 MainActor 上，
    /// actor 里不能直接读 —— 所以用参数传，而不是引全局单例）。
    private func makeRequest(path: String,
                             method: String,
                             query: [URLQueryItem],
                             body: Data?,
                             baseURL: URL?,
                             token: String) throws -> URLRequest {
        guard let baseURL else { throw APIError.notConfigured }

        // 路径拼接用 appendingPathComponent（它会正确编码中文和空格），
        // 查询串用 URLComponents（它会正确百分号编码 pid 里的特殊字符）。
        // 两者都用字符串插值手拼的话，遇到含空格或中文的 pid 一定生成非法 URL。
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.path = baseURL.appendingPathComponent(path).path
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else {
            throw APIError.badURL(path)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        // Bearer 令牌为空时**不设** Authorization 头，而不是设成 `Bearer `。
        // 后者会让站点认为"你提供了一个无效令牌"，返回 401，
        // 而真相其实是"根本没配令牌"——这两种情况的排查方式完全不同。
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        return d
    }

    // MARK: - 业务接口

    /// 题目列表。
    ///
    /// `GET /client-api/problems` → `{"problems": [...]}`
    func fetchProblems(baseURL: URL?, token: String) async throws -> [Problem] {
        let req = try makeRequest(path: "client-api/problems",
                                  method: "GET",
                                  query: [], body: nil,
                                  baseURL: baseURL, token: token)
        let data = try await data(for: req)
        do {
            return try decoder().decode(ProblemListResponse.self, from: data).problems
        } catch {
            // 保留原始 body 的前 200 字符：只看 "data couldn't be read" 是查不出问题的，
            // 而实际原因常常就藏在 body 里（比如返回了 HTML 登录页）。
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw APIError.decoding("\(error.localizedDescription) 响应开头：\(preview)")
        }
    }

    /// 提交记录（分页）。
    ///
    /// `GET /client-api/records?pid=&uid=&status=&page=&limit=`
    ///
    /// - Parameters:
    ///   - pid: 只看某题，传 nil 表示全部。
    ///   - uid: 只看某个用户。
    ///   - status: 只看某种评测状态（例如只筛 AC 传 1）。
    ///   - page / limit: 分页，从 1 开始。
    func fetchRecords(baseURL: URL?,
                      token: String,
                      pid: String? = nil,
                      uid: String? = nil,
                      status: Int? = nil,
                      page: Int = 1,
                      limit: Int = 50) async throws -> RecordListResponse {

        var q: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(max(1, limit)))
        ]
        // 空字符串的查询参数站点会当成"筛选值就是空"而不是"不过滤"，
        // 所以这里的可选值一律 nil 时**不加入**查询串。
        if let pid, !pid.isEmpty {
            q.append(URLQueryItem(name: "pid", value: pid))
        }
        if let uid, !uid.isEmpty {
            q.append(URLQueryItem(name: "uid", value: uid))
        }
        if let status {
            q.append(URLQueryItem(name: "status", value: String(status)))
        }

        let req = try makeRequest(path: "client-api/records",
                                  method: "GET",
                                  query: q, body: nil,
                                  baseURL: baseURL, token: token)
        let d = try await data(for: req)
        do {
            return try decoder().decode(RecordListResponse.self, from: d)
        } catch {
            let preview = String(data: d, encoding: .utf8)?.prefix(200) ?? ""
            throw APIError.decoding("\(error.localizedDescription) 响应开头：\(preview)")
        }
    }

    /// 单条提交详情（含代码）。
    ///
    /// `GET /client-api/record?rid=xxx`
    ///
    /// ⚠️ `code` 只在有权限时非空。没有权限时返回的是空串，**不是**错误 ——
    ///    所以这里返回的类型是 `RecordDetail`（code 可空）而不是可选值，
    ///    视图层要自己处理"有详情但没代码"这个正常状态。
    func fetchRecordDetail(baseURL: URL?, token: String, rid: String) async throws -> RecordDetail {
        let req = try makeRequest(path: "client-api/record",
                                  method: "GET",
                                  query: [URLQueryItem(name: "rid", value: rid)],
                                  body: nil,
                                  baseURL: baseURL, token: token)
        let d = try await data(for: req)
        do {
            return try decoder().decode(RecordDetail.self, from: d)
        } catch {
            let preview = String(data: d, encoding: .utf8)?.prefix(200) ?? ""
            throw APIError.decoding("\(error.localizedDescription) 响应开头：\(preview)")
        }
    }

    /// 换令牌：`POST /client-api/auth/login`。
    ///
    /// 站点侧的字段名各版本有差异（`uname`/`username`、`password`/`pass`），
    /// 这里两种都发，服务端认哪个用哪个。
    /// - Returns: 新令牌。
    func login(baseURL: URL?, username: String, password: String) async throws -> String {
        let payload: [String: Any] = [
            "uname": username, "username": username,
            "password": password, "pass": password
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        // 登录接口用的是 Cookie/表单会话，不是 Bearer —— 所以 token 传空串，
        // 让 makeRequest 不去设 Authorization 头（见那里对空令牌的说明）。
        let req = try makeRequest(path: "client-api/auth/login",
                                  method: "POST",
                                  query: [], body: body,
                                  baseURL: baseURL, token: "")
        let d = try await data(for: req)

        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw APIError.decoding("登录接口返回的不是 JSON 对象")
        }

        // 令牌可能放在 data.token，也可能直接在顶层 token。
        if let data = obj["data"] as? [String: Any],
           let t = data["token"] as? String, !t.isEmpty {
            return t
        }
        if let t = obj["token"] as? String, !t.isEmpty {
            return t
        }

        // 有些部署不返回令牌，而是种一个 Cookie。
        // 这时把 Cookie 值当作令牌是最实用的折中（在多数 Hydro 配置下它就是 session token）。
        if let headers = obj["headers"] as? [String: Any],
           let cookie = headers["Set-Cookie"] as? String,
           let t = cookie.split(separator: ";").first.map(String.init), !t.isEmpty {
            return t
        }

        throw APIError.decoding("登录成功但响应里没有令牌字段，站点可能改过登录接口")
    }

    /// 拉一道「能连通吗」的自检：取题目列表，只看是否成功，不关心内容。
    /// 设置页的"测试连接"按钮用它。
    func ping(baseURL: URL?, token: String) async throws -> Int {
        let probs = try await fetchProblems(baseURL: baseURL, token: token)
        return probs.count
    }
}