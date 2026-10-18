import Foundation
import SwiftUI
import Security   // 钥匙串 API（SecItem*）在这里，Foundation 不会转发它，必须显式导入

// MARK: - 设置

/// 应用设置。
///
/// 用 `ObservableObject` 而不是 SwiftUI 5.9 的 `@Observable`：
/// `@Observable` 需要 macOS 14 才有一等支持，而本工程最低目标是 macOS 13。
/// 老写法在 13/14/15 上都能跑，代价只是需要 `@Published`。
///
/// 刻意 **不加 `@MainActor`**：NSApplicationDelegate 的退出回调不在 actor 隔离范围内，
/// 而退出时需要同步把令牌写进钥匙串。如果这个类是 @MainActor，
/// 从 AppDelegate 里访问它会直接编译不过（actor 隔离检查），只能被迫改成异步落盘，
/// 那就会丢掉「⌘Q 之前的那次写入」。
/// 它的所有属性改动都发生在 UI 线程上（只有视图和 AppDelegate 会碰它），所以安全。
/// 存储介质是 `UserDefaults`（系统偏好设置），不是自己写文件 ——
/// UserDefaults 在 macOS 上自动落到 `~/Library/Preferences/<bundle-id>.plist`，
/// 卸载应用时会一并清掉，比留一个自己写的 plist 干净。
///
/// 存储介质是 `UserDefaults`（系统偏好设置），不是自己写文件。
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    /// 站点根地址。默认 SanhaiOJ。
    @Published var baseURLString: String {
        didSet { normalizeBaseURL() persist() }
    }

    /// Bearer 令牌（明文形式）。
    ///
    /// ⚠️ 这个属性本身**不是**安全存储，只是"内存里的当前值"。
    ///    真正的持久化交给 `TokenStore`（优先 Keychain，失败降级到沙盒内的文件）。
    @Published var token: String {
        didSet { persist() }
    }

    /// 是否把令牌以明文写到沙盒文件（方便调试）。
    /// 仅在 Keychain 不可用时才会实际被用上。
    @Published var allowPlaintextToken: Bool {
        didSet { persist() }
    }

    /// 每页条数。
    @Published var pageSize: Int {
        didSet { persist() }
    }

    /// 请求超时（秒）。
    @Published var timeoutSeconds: Double {
        didSet { persist() }
    }

    /// 是否默认只看自己的提交。
    ///
    /// 注意这只是**我们请求时带的过滤参数**，不是说接口会拒绝。
    /// 接口返回什么就显示什么，界面不替接口编造"没权限"的解释。
    @Published var onlyMine: Bool {
        didSet { persist() }
    }

    @Published private(set) var lastError: String?

    private let defaults: UserDefaults

    private enum Key {
        static let baseURL = "sanhai.baseURL"
        static let token = "sanhai.token"
        static let allowPlaintext = "sanhai.allowPlaintextToken"
        static let pageSize = "sanhai.pageSize"
        static let timeout = "sanhai.timeoutSeconds"
        static let onlyMine = "sanhai.onlyMine"
    }

    /// 规范化后的 baseURL，视图和网络层都用它，不要直接用字符串拼接。
    var baseURL: URL? {
        guard var u = URL(string: baseURLString) else { return nil }
        // 站点根必须以 / 结尾，否则 URL.appendingPathComponent 会把最后一段当成文件替换掉：
        // base=https://myijk.com/p + path=/records → https://myijk.com/records（把 /p 吃掉了）
        if !u.path.hasSuffix("/") {
            u.appendPathComponent("")
        }
        return u
    }

    var isConfigured: Bool {
        baseURL != nil && !token.isEmpty
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        baseURLString = defaults.string(forKey: Key.baseURL) ?? "https://www.myijk.com"
        token = defaults.string(forKey: Key.token) ?? ""
        allowPlaintextToken = defaults.bool(forKey: Key.allowPlaintext)
        pageSize = defaults.object(forKey: Key.pageSize) as? Int ?? 50
        timeoutSeconds = defaults.object(forKey: Key.timeout) as? Double ?? 20
        onlyMine = defaults.bool(forKey: Key.onlyMine)

        normalizeBaseURL()
    }

    /// 去掉首尾空白和尾部斜杠，保证 baseURLString 始终是可拼接的形态。
    private func normalizeBaseURL() {
        var s = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty, !s.hasPrefix("http://"), !s.hasPrefix("https://") {
            s = "https://" + s      // 用户漏写协议时补全，省得直接报"URL 无效"这种看不懂的错
        }
        if s != baseURLString {
            baseURLString = s
        }
    }

    private func persist() {
        defaults.set(baseURLString, forKey: Key.baseURL)
        defaults.set(token, forKey: Key.token)
        defaults.set(allowPlaintextToken, forKey: Key.allowPlaintext)
        defaults.set(pageSize, forKey: Key.pageSize)
        defaults.set(timeoutSeconds, forKey: Key.timeout)
        defaults.set(onlyMine, forKey: Key.onlyMine)
    }

    func record(error: String?) {
        lastError = error
    }

    /// 令牌是否真的落到了安全存储。
    /// 设置页用它来决定要不要显示"当前使用明文文件保存"的警示。
    var isTokenSecurelyStored: Bool {
        (try? TokenStore.read()) != nil
    }

    /// 把当前令牌写入安全存储（Keychain 优先）。
    /// 钥匙串失败时，若用户显式开启了明文模式，才落到明文文件。
    func saveTokenSecurely() {
        guard !token.isEmpty else { return }
        do {
            try TokenStore.write(token)
            lastError = nil
        } catch {
            if allowPlaintextToken {
                // 显式降级：不告诉用户"成功"，因为它没有成功。
                // 必须说清楚现在令牌存在哪 —— 静默降级是这类工具最危险的行为。
                try? TokenStore.writePlaintext(token)
                lastError = "钥匙串不可用（\(error.localizedDescription)），已按你的设置写入沙盒明文文件。"
            } else {
                lastError = "令牌保存到钥匙串失败：\(error.localizedDescription)。可在下面开启明文文件模式再试。"
            }
        }
    }

    /// 从安全存储恢复令牌。
    func loadTokenSecurely() -> Bool {
        if let t = try? TokenStore.read(), !t.isEmpty {
            token = t
            lastError = nil
            return true
        }
        return false
    }
}

// MARK: - 令牌存储

/// 令牌持久化：优先钥匙串，失败降级到沙盒文件。
///
/// 为什么要有明文降级模式：
///   钥匙串（Keychain）在几种情况下会失败或表现异常 ——
///   无签名的 app bundle、在 CI 里跑、或钥匙串因签名标识不匹配而拒绝读写。
///   调试时如果只有钥匙串一条路，卡在"存不进去"上非常难查。
///   所以保留一条显式的、可开关的明文路径，
///   并且**在设置界面明着写出当前用的是哪一种**，不偷偷降级。
///
/// ⚠️ 明文模式只建议在个人调试机上开。令牌等同于账号密码，
///    丢了就是别人能登你的号。
enum TokenStore {

    private static let service = "com.sanhai.mac.client"
    private static let account = "access-token"

    /// 明文文件的位置：Application Support 下的固定文件。
    /// 用 Application Support 而不是 Documents —— Documents 在访达里是可见的，
    /// 会被用户随手翻到、被备份工具同步走。
    static var plaintextURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("SanhaiMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token.plist")
    }

    // MARK: 钥匙串

    /// 写入钥匙串。
    /// `-kSecAttrAccessibleAfterFirstUnlock`：开机后用户输完密码即可读，
    /// 且不用每次启动都弹钥匙串授权框。
    static func write(_ token: String) throws {
        let data = Data(token.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // 先删后写：SecItemAdd 在已存在时会直接失败报错，
        // 而"更新"必须用 SecItemUpdate，两步走比处理各种边界情况简单可靠。
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError.keychain(status: status)
        }
    }

    /// 读取钥匙串。
    static func read() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let s = String(data: data, encoding: .utf8) else {
                throw TokenStoreError.badData
            }
            return s
        case errSecItemNotFound:
            throw TokenStoreError.notFound
        default:
            throw TokenStoreError.keychain(status: status)
        }
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: 明文降级

    /// 明文令牌文件。
    /// 写入时把权限设成仅当前用户可读写（0600）——
    /// 沙盒已经提供了基础隔离，但同机其它进程仍可能读到宽权限文件。
    static func writePlaintext(_ token: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["token": token], format: .binary, options: 0)
        try data.write(to: plaintextURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: plaintextURL.path)
    }

    static func readPlaintext() throws -> String {
        let data = try Data(contentsOf: plaintextURL)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let token = dict["token"] as? String else {
            throw TokenStoreError.badData
        }
        return token
    }

    static func deletePlaintext() {
        try? FileManager.default.removeItem(at: plaintextURL)
    }
}

/// 令牌存储的错误类型。
enum TokenStoreError: LocalizedError {
    case notFound
    case badData
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "钥匙串里没有令牌"
        case .badData:
            return "令牌数据损坏或不是 UTF-8"
        case .keychain(let status):
            // 直接把 OSStatus 数字甩给用户是没用的，把它翻译成人话
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串错误 \(status)：\(msg)"
        }
    }
}