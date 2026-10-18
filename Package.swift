// swift-tools-version:5.9
import PackageDescription

// SanhaiOJ macOS 客户端（原生 SwiftUI）
//
// 为什么用 SwiftPM 而不是 Xcode 工程：
//   1) 我们要在 **Windows 上开发**，靠 GitHub Actions 的 macos runner 云端编译。
//      SwiftPM 的工程描述是纯文本（就是本文件），跨平台编辑毫无摩擦；
//      .xcodeproj 是二进制包，Windows 上没法正常编辑/合并。
//   2) `swift build -c release` 在 CI 上一条命令就能跑，不依赖 xcodebuild 的
//      workspace/scheme 解析，失败信息也更直接。
//   3) 产出的可执行文件由 CI 手工组装成 .app bundle（见 .github/workflows/build-macos.yml）。
//      SwiftPM 默认不做 App bundle 包装，所以这一步必须自己做。
let package = Package(
    name: "SanhaiMac",
    platforms: [
        // .v13 是刻意选的保守下限：
        // - NavigationSplitView 从 macOS 13 起是正式 API（之前只有实验性）；
        // - .searchable / Table / .task 等我们要用的 API 在 13 上都已稳定；
        // - 定得太高（比如 .v14）会让一部分还在 13 上跑的老机器直接装不上。
        // GitHub 的 macos-latest 远高于此，不影响云端构建。
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SanhaiMac", targets: ["SanhaiMac"])
    ],
    dependencies: [
        // 刻意 **零外部依赖**。
        // 网络层直接用 URLSession（Foundation 自带），Keychain 用 Security 框架（系统自带）。
        // 理由：SwiftPM 的二进制依赖在 CI 上要额外缓存/校验，
        // 而这个客户端的全部网络需求就是 4 个 JSON 接口 + 一个令牌存储，
        // 引入第三方库带来的供应链和缓存成本远大于收益。
    ],
    targets: [
        .executableTarget(
            name: "SanhaiMac",
            path: "Sources/SanhaiMac"
        )
    ]
)