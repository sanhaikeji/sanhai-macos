import SwiftUI
import Security

// MARK: - 设置页

/// 设置页：站点地址、令牌、调试开关。
///
/// 用 macOS 原生的 `Form` + `.formStyle(.grouped)`，
/// 这是系统设置App 那种"左标签右控件"的观感，和 iOS 的分组列表很不一样。
struct SettingsView: View {

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: DataStore

    @State private var username = ""
    @State private var password = ""
    @State private var loginResult: String?
    @State private var isLoggingIn = false
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            siteSection
            tokenSection
            loginSection
            behaviorSection
            storageSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .frame(minWidth: 520, minHeight: 560)
    }

    // MARK: 站点

    private var siteSection: some View {
        Section {
            HStack {
                TextField("站点根地址", text: $settings.baseURLString)
                    .textFieldStyle(.roundedBorder)
                Button("测试") { Task { await testConnection() } }
                    .disabled(isTesting || !settings.isConfigured)
            }
            if let testResult {
                Label(testResult,
                      systemImage: testResult.hasPrefix("连接成功") ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(testResult.hasPrefix("连接成功") ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("站点")
        } footer: {
            // 明确写出 baseURL 的含义：填站点根，不是某个接口的地址。
            // 填错的话所有请求都会 404，而 404 的原因往往很难一眼看出。
            Text("填站点根地址，例如 \(settings.baseURLString.isEmpty ? "https://www.myijk.com" : "https://www.myijk.com")。不要带 /client-api 之类的路径。")
        }
    }

    // MARK: 令牌

    private var tokenSection: some View {
        Section {
            HStack {
                // SecureField 默认不显示内容。
                // 但用户有时需要确认自己粘对了（末尾多空格这种错很常见），
                // 所以给一个"显示"开关 —— 这是 macOS 上比 iOS 更常见的做法。
                Group {
                    if showToken {
                        TextField("Bearer 令牌", text: $settings.token)
                    } else {
                        SecureField("Bearer 令牌", text: $settings.token)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    showToken.toggle()
                } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showToken ? "隐藏令牌" : "显示令牌")
            }

            Toggle("允许明文文件保存（调试用）", isOn: $settings.allowPlaintextToken)
        } header: {
            Text("令牌")
        } footer: {
            Text(allowPlaintextNote)
        }
    }

    @State private var showToken = false

    private var allowPlaintextNote: String {
        if settings.allowPlaintextToken {
            return "已开启：令牌会额外写一份到沙盒内的明文文件（\(TokenStore.plaintextURL.path)）。方便在无签名的调试环境里排查问题。**别在长期使用的机器上开着** —— 令牌等同于账号密码。"
        }
        return "令牌优先保存到系统钥匙串。钥匙串不可用时（无签名 bundle、某些 CI 环境），可以临时开启明文文件模式。"
    }

    // MARK: 登录换令牌

    private var loginSection: some View {
        Section {
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("登录并获取令牌") { Task { await doLogin() } }
                    .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
                    .buttonStyle(.borderedProminent)
                if isLoggingIn { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let loginResult {
                Text(loginResult)
                    .font(.callout)
                    .foregroundStyle(loginResult.hasPrefix("成功") ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("用账号密码换令牌")
        } footer: {
            Text("直接 POST /client-api/auth/login，成功后自动填入上面的令牌框。密码不会被保存。")
        }
    }

    // MARK: 行为

    private var behaviorSection: some View {
        Section {
            HStack {
                Text("每页条数")
                Spacer()
                Stepper(value: $settings.pageSize, in: 10...200, step: 10) {
                    Text("\(settings.pageSize)")
                        .monospacedDigit()
                }
                .fixedSize()
            }
            HStack {
                Text("超时（秒）")
                Spacer()
                Stepper(value: $settings.timeoutSeconds, in: 5...120, step: 5) {
                    Text(String(format: "%.0f", settings.timeoutSeconds))
                        .monospacedDigit()
                }
                .fixedSize()
            }
            Toggle("只显示我自己的提交", isOn: $settings.onlyMine)
        } header: {
            Text("请求行为")
        } footer: {
            Text("这些设置会在下次刷新时生效。")
        }
    }

    // MARK: 存储状态

    private var storageSection: some View {
        Section {
            LabeledContent("钥匙串状态") {
                Text(keychainStatusText)
                    .foregroundStyle(keychainOK ? Color.green : Color.orange)
            }
            HStack {
                Button("把当前令牌写入钥匙串") { settings.saveTokenSecurely() }
                Button("从钥匙串读取") {
                    if settings.loadTokenSecurely() {
                        loginResult = nil
                    } else {
                        loginResult = "钥匙串里没有可用令牌。"
                    }
                }
                Spacer()
            }
            if let err = settings.lastError {
                Text(err).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            Text("令牌存储")
        } footer: {
            Text("当前明文文件位置：\(TokenStore.plaintextURL.path)")
        }
    }

    private var keychainOK: Bool {
        (try? TokenStore.read()) != nil
    }

    private var keychainStatusText: String {
        keychainOK ? "已保存" : "未保存（将使用 UserDefaults）"
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("应用") { Text("SanhaiMac") }
            LabeledContent("最低系统") { Text("macOS 13") }
            LabeledContent("签名") {
                // 直说"没签名"，比让用户自己撞 Gatekeeper 那堵墙强得多。
                // 未签名 app 双击是打不开的，这是拿到这个包的人第一个会撞上的问题。
                Text("未签名（未公证）")
                    .foregroundStyle(.orange)
            }
            LabeledContent("构建方式") { Text("GitHub Actions · macOS runner") }
        } header: {
            Text("关于")
        } footer: {
            Text("本应用由 CI 无签名构建。首次打开若被 Gatekeeper 拦下：右键点 app → 选「打开」→ 再点「打开」；或在「系统设置 → 隐私与安全性」里点「仍要打开」。详见 README。")
        }
    }

    // MARK: 动作

    private func testConnection() async {
        isTesting = true
        testResult = nil
        testResult = await store.testConnection()
        isTesting = false
    }

    private func doLogin() async {
        isLoggingIn = true
        loginResult = nil
        defer { isLoggingIn = false }

        let api = ApiClient(timeout: settings.timeoutSeconds)
        do {
            let token = try await api.login(baseURL: settings.baseURL,
                                            username: username,
                                            password: password)
            settings.token = token
            settings.saveTokenSecurely()
            loginResult = "成功，已获取令牌并保存。"
            password = ""       // 拿到令牌后立刻清掉密码输入框
        } catch {
            loginResult = "失败：" + DataStore.describe(error)
        }
    }
}