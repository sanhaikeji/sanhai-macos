# SanhaiMac —— SanhaiOJ 的 macOS 原生客户端

SwiftUI 写的真原生 macOS 客户端，**在 Windows 上开发，靠 GitHub Actions 云端编译**。
面向的场景是竞赛教练：看题库、查评测记录。

- 站点：SanhaiOJ（Hydro 内核），默认地址 `https://www.myijk.com`
- 最低系统：macOS 13
- 依赖：**零第三方库**（网络用 `URLSession`，钥匙串用系统 `Security` 框架）

---

## 一、为什么是这样一套结构

### 为什么用 SwiftPM（`Package.swift`）而不是 Xcode 工程

1. **要在 Windows 上开发。** `Package.swift` 是纯文本，跨平台编辑毫无摩擦；
   `.xcodeproj` 是个二进制包，Windows 上没法正常编辑、也没法在 Git 里干净地合并。
2. **`swift build -c release` 一条命令搞定 CI。** 不依赖 xcodebuild 去解析
   workspace/scheme，也不受"Xcode 版本变了 scheme 就坏"这类问题影响。
3. **代价是要自己组 `.app` bundle。** SwiftPM 只产出一个裸可执行文件，
   没有 `Info.plist`、没有图标，双击是打不开的。CI 里的 `build-macos.yml` 补上了这一步。

### 为什么只有两页

题库、评测。刻意不做更多。空出来的页面如果只是"占位"，不如不做 ——
每个页面都要各自处理加载中/空/错三种状态，是实打实的维护成本。

### 为什么产物是未签名的

用户**没有 Apple 开发者账号**，无法签名和公证。所以流水线里整段签名步骤被省略了
（在 `build-macos.yml` 里留了注释，写明将来有账号时该在哪插 `codesign` + `notarytool`）。

未签名应用的代价是 Gatekeeper 会拦，见下面「安装」一节。

---

## 二、目录结构

```
SanhaiMac/
  Package.swift                     SwiftPM 工程描述
  .gitignore                        排掉一切构建产物
  .github/workflows/build-macos.yml 云端构建
  Sources/SanhaiMac/
    SanhaiMacApp.swift              @main 入口、菜单命令、退出前清理
    Models.swift                    Problem / Record / RecordDetail / 分页容器
    ApiClient.swift                 actor 化的 HTTP 客户端
    SettingsStore.swift             设置 + 令牌存储（钥匙串优先，明文降级）
    DataStore.swift                 全局数据仓库 + 三态加载状态（LoadState）
    Views/
      RootView.swift                NavigationSplitView 骨架 + 三态占位组件
      ProblemListView.swift         题库
      RecordListView.swift          评测（列表 | 详情 两级）
      SettingsView.swift            设置
```

> 比原计划多了 `DataStore.swift` 和 `Views/RootView.swift` 两个文件。
> 原因是原来的 6 个文件清单里没有"谁持有数据"和"谁搭骨架"的落点，
> 把这些逻辑塞进 `SanhaiMacApp.swift` 会让入口文件同时负责生命周期、
> 数据加载和视图组装三层职责。拆开之后各文件职责单一，也更好改。

---

## 三、怎么构建

### 自动（推荐）

推到 `main` 或打 `v*` tag，或在 Actions 页面手动触发。
产物在 run 的 Artifacts 里（`SanhaiMac-macos`），含 `.zip` 和 `.dmg`。

### 本地（需要有 macOS + Xcode 命令行工具）

```bash
swift build -c release
./.build/release/SanhaiMac
```

注意这样跑起来的是**裸可执行文件**，没有 bundle 信息，图标和 Dock 行为都不对。
要得到真正的 `.app`，走 CI，或者自己手工组 bundle（参考 `build-macos.yml` 里的那几步）。

### Windows 上不能构建

Windows 没有 Swift 工具链，装不了。这就是"在 Windows 上开发、云端编译"的前提：
**本工程的代码只能在 Windows 上写，不能在 Windows 上编译。**

---

## 四、安装（重要：未签名应用怎么打开）

下载 zip 或 dmg 之后：

**推荐（zip）**
1. 解压 `SanhaiMac-macos.zip`
2. 把 `SanhaiMac.app` 拖进「应用程序」文件夹
3. 首次打开：**右键点 app 图标 → 选「打开」→ 在弹窗里再点「打开」**

**dmg**
1. 双击 dmg 挂载，把 app 拖到中间的 Applications 图标上
2. 到「应用程序」里右键打开，步骤同上

**如果右键也开不了**
- 「系统设置 → 隐私与安全性」，往下翻到被阻止的提示，点「仍要打开」
- 或者在「访达」里选中 app，按 `⌘I`，在「隐私与安全性」一栏点「仍要打开」

**哪些方式不管用**
- **双击直接打开**：一定会被 Gatekeeper 拦下并提示"无法打开，因为无法验证开发者"
- 直接把 dmg 里的 app 拖到 Dock：Dock 启动走的是和双击不同的路径，有时也不给放行

> 之所以未签名就这么难装：Gatekeeper 对"来源不明"的应用默认是拒绝的，
> 而「右键打开」是苹果留给用户的一次性手动确认入口。
> 一旦签名+公证通过，上面所有麻烦都会消失。

---

## 五、首次使用

1. 启动后进入左侧「设置」
2. 「站点」里填站点根地址（**填根地址，不要带 `/client-api` 之类的路径**）
3. 「令牌」里填 Bearer 令牌
   - 已经有令牌 → 直接粘进去
   - 没有 → 用下面的「用账号密码换令牌」，填用户名密码自动获取
4. 点「测试」，提示"连接成功"再走
5. 回到「题库」「评测」页，用工具栏的刷新按钮（⌘R）加载数据

### 令牌存在哪

优先存**系统钥匙串**（`~/Library/Keychains`）。

钥匙串在无签名的 bundle、CI 环境等情况下可能读写失败。
所以设置里保留了「允许明文文件保存（调试用）」开关：

- 开了 → 令牌会**额外**写一份到
  `~/Library/Support/SanhaiMac/token.plist`（权限 0600）
- 明文文件位置在设置页底部有显示

> ⚠️ 令牌等同于账号密码。**不要在长期使用的机器上开着明文模式。**
> 这个开关存在的意义是：在调试环境里不至于卡在"存不进去"上查不下去。
> 关闭明文模式**不会**自动删掉已经写下的明文文件，需要自己去那个路径删。

---

## 六、几个刻意为之的设计

### 6.1 加载状态是三种，不是一种

`LoadState` 明确区分「还没请求 / 请求中 / 请求成功 / 请求失败」。

原因很实际：**现在站点上勋章和提交记录本来就是空的。**
如果界面只按"数组是否为空"来判断，这三种情况会渲染成同一个空白界面，
用户看到"列表是空的"其实是"还没加载"。空数据在这个站点上是常态，不是异常，
必须被认真对待。

对应的三处视图都写了完整的空态 / 加载态 / 错误态：

- 没请求过 → 给一个明确的"点击加载"入口（不自动请求，因为设置可能还没填）
- 请求中（首次）→ 转圈
- 请求中（有旧数据）→ **保留旧数据** + 顶部细进度条。
  直接清空列表会让用户以为题目被删了；遮挡式遮罩又会让用户暂时读不了列表。
- 请求成功但 0 条 → 给出"为什么可能空"的说明，并允许重新加载
- 请求失败 → 显示可行动的错误信息 + 重试按钮

### 6.2 不说"你没有权限"

接口的 `canViewAll` 只表示当前账号能不能看**别人**的提交。
没有权限时，接口**只返回自己的记录，并且不给任何"为什么不给"的信号**。

所以界面：
- 可以安静地显示 `canViewAll` 为 true 时的"含全部可见用户"字样
- **不会**显示"你没有权限查看他人提交"之类的话
- 代码为空时也**不会**说"你没有权限查看代码"

这些都不是接口告诉我们的信息。界面上的每一句断言都应该是接口给的事实，
否则就是在骗用户 —— 而且用户会拿着这些假信息来问你。

### 6.3 难度 0 是"未评定"

站点的 `difficulty` 为 0 表示**站点没有评定这个题的难度**，不是"最简单"。

所以界面上显示成「未评定」并用描边样式（弱化），
如果把 0 当成最低难度，所有未评定的题会全部挤到难度榜最前面 ——
那是把"没有数据"伪装成了"数据很极端"。

### 6.4 解析层做了容错

站点的字段类型并不稳定：

- `pid` / `rid` / `uid` **可能是数字也可能是字符串** → 统一用 `String` 接，解析时两种都试
- `difficulty` 可能是数字、字符串或 null
- `status` 可能是数字码，也可能是 `"AC"` 这类文字
- `time` / `at` 可能是秒级时间戳、毫秒时间戳，也可能是 `yyyy-MM-dd HH:mm:ss` 字符串

另外实现了 `decodeLossyArray`：**数组里某一条解析失败，不会让整个数组失败**。

标准 `decode([T].self)` 是全有或全无的，站点数据里混着历史脏数据是常态，
结果就是"一条脏数据让整页白屏，而用户只看到怎么什么都没有"。
这里逐条 try，解不出来的丢掉，其余照常显示：宁少几条，不可整页失败。

### 6.5 深色模式与语义色

全用 `.secondary` / `.tertiary` / `.quaternary` / `Color.green` 这类语义色，
**没有写死任何 RGB 值**。跟随系统深色模式自动适配。

### 6.6 关于构建产物不进仓库

`.gitignore` 排掉了 `.build/`、`.build-app/`、`.build-dmg/`、`*.app`、`*.dmg`、`*.zip`。

这不是洁癖：这个工程在 **OneDrive 同步目录**下。
历史上因为在项目目录里堆了多份完整客户端拷贝，把 OneDrive 同步拖死、构建卡死十几分钟。
CI 里的中间产物一律写进 `.build-app/` / `.build-dmg/`，它们已被忽略。

---

## 七、已知限制

- **Windows 上不能编译**，只能写代码。
- **产物未签名**，首次打开必须走上面第四节的手动放行步骤。
- 登录接口的字段名（`uname` vs `username`）在不同 Hydro 版本上不一致，
  客户端两种都发了，服务端认哪个用哪个。
- 部分部署的登录接口不返回令牌而只种 Cookie，此时客户端把 Cookie 值当令牌用 ——
  在多数 Hydro 配置下它就是 session token，但**不保证所有部署都如此**。
- 题面、判题等页面尚未实现（当前只做两页）。

---

## 八、CI 流水线说明

| 步骤 | 作用 |
|---|---|
| `actions/cache` 缓存 `.build` | 最值钱的一步。Swift 冷启动全量编译要几分钟，不缓存每次提交都要重等。缓存 key 带 `Package.swift` 哈希，依赖变了自动失效 |
| `swift build -c release` | 编译 |
| 组 `.app` bundle | SwiftPM 只出裸可执行文件，需手工补 `Info.plist`。同时 `plutil -lint` 校验，比下载下来双击打不开再回头查快得多 |
| `ditto -c -k` 压 zip | 解压会自动去掉隔离属性，比 dmg 好装 |
| `hdiutil create` 做 dmg | 带 Applications 软链接的拖拽安装镜像。刻意只用系统自带工具，不为做 dmg 引入第三方依赖 |
| `upload-artifact` | 上传 zip + dmg |

签名/公证步骤**当前是关闭的**，在 `build-macos.yml` 里有注释标明将来插入 `codesign` + `notarytool` 的确切位置。