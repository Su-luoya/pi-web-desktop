# 开发说明

## 环境

首版目标是 Apple Silicon 和 macOS 14 或以上。构建需要 Xcode Command Line Tools、Swift 编译器和 Cocoa/WebKit SDK。

运行服务还需要用户自行安装：

- Node.js `>=22.19.0`，满足当前 Pi Web 上游声明。
- Pi CLI。
- `@agegr/pi-web`。

应用不会自动安装这些依赖，也不会调用 `sudo`。

## 构建

```bash
./Scripts/build.sh
```

当前脚本生成 `build/Pi-Web-Desktop.app`，使用 Apple Silicon、macOS 14 目标和 ad-hoc 签名。源码目录中的图标可能携带 macOS 扩展属性；构建脚本会避免把不适合签名的 Finder 元数据复制进 app bundle。

## Xcode 工程构建与测试

标准 Xcode 工程使用 Apple Silicon、macOS 14 SDK，并包含 `PiWebDesktopTests` XCTest target。该测试 target 是 **unhosted** 的独立测试 bundle：不设置 `TEST_HOST`，也不依赖或启动 `PiWebDesktop` app。为了让测试在没有 host app 的情况下仍可编译，target 会把被测源码直接加入测试源：`Sources/ServiceConfiguration.swift`、`Sources/AppConfiguration.swift`、`Sources/ProcessInspector.swift`、`Sources/DiagnosticsCollector.swift`、`Sources/DependencyChecker.swift`、`Sources/FirstLaunchDiagnostics.swift`、`Sources/InstallCommandManifest.swift`、`Sources/ServiceManager.swift`、`Sources/ServiceOwnership.swift`、`Sources/WebViewNavigationPolicy.swift`、`Sources/KeychainStore.swift`；因此测试文件直接使用该 target 内编译的这些类型，不通过 `@testable import PiWebDesktop` 引入 app target。`Sources/WebViewController.swift` 与 `Sources/DiagnosticsWindowController.swift` 依赖 AppKit/WebKit 且需要真实窗口，只进 app target；依赖诊断的纯文本呈现（`DependencyReportPresenter`）与首次启动路由、控件映射、路径选择因此分别放在 `DependencyChecker.swift` 和 `FirstLaunchDiagnostics.swift` 里，可以在 unhosted 目标里测试。这些测试使用假的 `ps`/`lsof` 输出、注入的存活判定、假的进程启动器、即时执行的调度器、假依赖探针和临时目录，不访问真实进程、网络、Keychain、真实端口或 `~/.pi`。

```bash
DERIVED_DATA_PATH="$(mktemp -d /tmp/PiWebDesktopDerivedData.XXXXXX)"
trap 'rm -rf "$DERIVED_DATA_PATH"' EXIT
XCODEBUILD_ARGS=(
  -project PiWebDesktop.xcodeproj
  -scheme PiWebDesktop
  -sdk macosx
  -derivedDataPath "$DERIVED_DATA_PATH"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
)
xcodebuild "${XCODEBUILD_ARGS[@]}" build
xcodebuild "${XCODEBUILD_ARGS[@]}" test
```

CI 在 `macos-14` 上使用同样的临时 `derivedDataPath` 和 ad-hoc `CODE_SIGN_IDENTITY=-`，不需要开发者账号或 provisioning profile。`xcodebuild` 的工程构建和测试验证需要完整 Xcode（命令行工具目录本身不提供完整的 Xcode 工程构建/测试环境）。当前环境若只有 Command Line Tools，则 `xcodebuild` 不可验证，会因 active developer directory 不是完整 Xcode 而失败；此时请使用下方 alpha 脚本验证构建路径。该临时目录不再在 `xcodebuild` 步骤结束时删除：步骤会把 `Build/Products/Debug/PiWebDesktop.app` 作为 `XCODE_APP_PATH` 导出，下一步在脚本产物和 Xcode 产物上同时运行 `./Scripts/check-identity.sh`，再清理临时目录，因此 DerivedData 不会被提交。

## 身份与版本单一来源

应用身份与版本只有一个来源：`Configuration/AppIdentity.xcconfig`。它包含显示名、可执行名、图标名、最低系统版本、bundle identifier、`MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。`PiWebDesktop.xcodeproj` 的全部 6 个 build configuration（project、app、tests 的 Debug/Release）都通过 `baseConfigurationReference` 继承该文件，`Scripts/build.sh` 也从同一个文件读取并生成 `build/Pi-Web-Desktop.app/Contents/Info.plist`。不要在其他文件里重复版本、bundle id、显示名或最低系统版本字面值：改版本只需要改这一个文件，并让 Git tag 与 `MARKETING_VERSION` 一致（见 docs/releasing.md）。

`APP_ICON_NAME`（`ApplicationIcon`）只由打包脚本与一致性检查使用：xcconfig 里刻意不写 `INFOPLIST_KEY_CFBundleIconFile`，因为 Xcode 不会从该设置生成 `CFBundleIconFile`（已在 CI 的 Xcode 产物上确认），保留它只会制造“已配置图标键”的假象。

测试 target 复用同一身份，但不能形成循环引用。身份变量分两层：`APP_BUNDLE_IDENTIFIER` 是不参与覆盖的基础变量（`io.github.su-luoya.pi-web-desktop`），`PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER)` 与 `APP_TEST_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER).tests` 都由它派生。测试 target 只覆盖 `PRODUCT_BUNDLE_IDENTIFIER = $(APP_TEST_BUNDLE_IDENTIFIER)`；覆盖之后 `PRODUCT_BUNDLE_IDENTIFIER` 在测试 target 里已经是测试 id，所以 `APP_TEST_BUNDLE_IDENTIFIER` 不能反过来引用 `$(PRODUCT_BUNDLE_IDENTIFIER)`，否则两个值互相定义、测试 bundle identifier 就无法被证明能正确解析。`Scripts/check-identity.sh` 对这条做静态断言（检查未展开的模板），出现循环即判定失败；CI 也会在真实的 `.xctest` 产物上断言该 identifier。测试 target 的另外两个覆盖是 `INFOPLIST_KEY_CFBundleDisplayName = $(APP_TEST_DISPLAY_NAME)` 与 `PRODUCT_NAME = $(TARGET_NAME)`，变量同样定义在 xcconfig 里。

## 一致性检查

```bash
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/check-identity.sh /path/to/Xcode_Products/PiWebDesktop.app build/Pi-Web-Desktop.app
./Scripts/check-identity.sh --test-bundle /path/to/Xcode_Products/PiWebDesktopTests.xctest /path/to/Xcode_Products/PiWebDesktop.app build/Pi-Web-Desktop.app
```

`Scripts/check-identity.sh` 退出码 0 表示全部通过，非 0 表示至少一项失败（参数错误为 2）。它接受多个 bundle 路径（位置参数列表，默认 `build/Pi-Web-Desktop.app`），对每个 bundle 独立检查并给出带具体路径的结论，所以同一个命令可以同时校验 Xcode 产物和发布脚本产物。`--test-bundle <X.xctest>` 只接受一个测试 bundle，用于断言测试 target 的 identifier 与版本。它检查：

- xcconfig 存在，且 `APP_BUNDLE_IDENTIFIER`（基础变量）、`PRODUCT_BUNDLE_IDENTIFIER`、`APP_TEST_BUNDLE_IDENTIFIER`、显示名、可执行名、图标名、最低系统版本、`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` 均非空；`APP_TEST_BUNDLE_IDENTIFIER` 的未展开模板里不得出现 `$(PRODUCT_BUNDLE_IDENTIFIER)`（循环引用回归防护，出现即失败）；
- `project.pbxproj` 通过 `baseConfigurationReference` 引用该 xcconfig，所有 build configuration 都继承它，且 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`PRODUCT_BUNDLE_IDENTIFIER`、`PRODUCT_NAME`、`MACOSX_DEPLOYMENT_TARGET`、`INFOPLIST_KEY_CFBundleDisplayName`、`INFOPLIST_KEY_CFBundleShortVersionString`、`INFOPLIST_KEY_CFBundleVersion` 没有任何字面值，版本与 bundle id 字面值也不出现在工程文件中；
- 每个传入的 bundle 分别断言 `CFBundleShortVersionString`、`CFBundleVersion`、`CFBundleIdentifier`、`CFBundleDisplayName`、`CFBundleExecutable`、`LSMinimumSystemVersion` 与 xcconfig 一致（需要先运行 `./Scripts/build.sh` 或先执行 `xcodebuild`）；bundle 不存在或 `Info.plist` 缺失时以该 bundle 路径报错；
- 每个 bundle 必须包含 `Contents/Resources/ApplicationIcon.icns`（即 `Contents/Resources/<APP_ICON_NAME>.icns`），缺失即失败；
- `CFBundleIconFile` 是条件断言：`Info.plist` 里存在该键时必须等于 `APP_ICON_NAME`；不存在时输出 info 行，说明 Xcode 生成的 plist 不产出该键、发布脚本产物会写入；
- `CFBundleName` 只输出信息行，不参与成败判定；
- 传入 `--test-bundle <X.xctest>` 时，额外断言该 bundle 的 `CFBundleIdentifier` 等于解析后的 `APP_TEST_BUNDLE_IDENTIFIER`，并断言其 `CFBundleShortVersionString`、`CFBundleVersion` 与 xcconfig 一致；不传该参数时行为与之前完全一致；
- `Sources/ServiceConfiguration.swift` 默认 hostname 为 `127.0.0.1`、默认 proxy 为空、noProxy 只包含 loopback 条目；
- 仓库文本中不出现私人默认值：Tailscale 主机名（小写形式）、tailnet DNS 后缀、CGNAT 私网地址、`/Users` 下的绝对路径、固定本地代理端点；`MARKETING_VERSION` 的字面值也不得出现在 `Sources/`、`Scripts/`、`PiWebDesktop.xcodeproj/`、`PiWebDesktopTests/`。

脚本通过路径排除与字符串拼接保证自身文本不会触发这些模式，`.github/workflows/build.yml` 里的 personal-data grep 同样排除该脚本。

### CI 上的两类产物

CI 的 `Build and test Xcode project` 步骤导出 `XCODE_APP_PATH`（`$DERIVED_DATA_PATH/Build/Products/Debug/PiWebDesktop.app`），然后 `Check application identity of Xcode and script builds` 步骤运行：

```bash
./Scripts/check-identity.sh \
  --test-bundle "$DERIVED_DATA_PATH/Build/Products/Debug/PiWebDesktopTests.xctest" \
  "$XCODE_APP_PATH" build/Pi-Web-Desktop.app
```

测试 bundle 路径不存在时该步骤直接失败，不会静默跳过；`xcodebuild test` 产出的 `PiWebDesktopTests.xctest` 的 `CFBundleIdentifier` 因此由 CI 在真实产物上验证。

两个产物都要满足上面列出的 6 个 `Info.plist` 字段和图标资源检查；只有静态推断而没有真实构建产物的检查不再算通过。图标在两个产物中本来就不同：Xcode 生成的 plist **不含** `CFBundleIconFile`（`INFOPLIST_KEY_CFBundleIconFile` 不是 Xcode 生成 plist 支持的键，xcconfig 里已删除该行），所以从 Xcode 构建的 dev 产物可能显示通用图标；发布产物由 `./Scripts/build.sh` 打包，会写入 `CFBundleIconFile = ApplicationIcon`。两类产物都包含 `Contents/Resources/ApplicationIcon.icns`，这也是检查脚本对每个 bundle 都断言的资源。`CFBundleName` 同理只作为信息行：Xcode 生成的 plist 取 `PRODUCT_NAME`（`PiWebDesktop`），而发布产物的 `CFBundleName` 与 `CFBundleDisplayName` 都是 `Pi Web Desktop`。检查脚本不用 `INFOPLIST_KEY_CFBundleName` 去覆盖 Xcode 的默认行为。

## 本地运行

```bash
open build/Pi-Web-Desktop.app
```

默认服务地址是 `http://127.0.0.1:30141/`。默认监听 loopback，不开放局域网监听：要改成远程地址，必须在“设置…→远程访问”里先在 Keychain 中保存密码（输入或点“生成高强度密码”）。密码认证只验证访问者，不加密传输；远程访问请自行配置受信任的加密隧道或 HTTPS 反向代理。删除密码会自动把监听地址改回 `127.0.0.1`。设置界面也拒绝 `0.0.0.0` 这类“所有接口”地址。

## 依赖诊断与首次启动

启动时应用会先运行 `DependencyChecker`，检查 Apple Silicon / macOS 14+、Node.js `>=22.19.0`、Pi CLI、Pi Web（可执行文件、版本、真实路径、符号链接目标、pi-web 的 package.json）、默认服务端口（本机 `bind(2)`，不连接网络）和 Pi 配置目录（`~/.pi/agent`，只问“存在/可读”）。

首次启动路由由 `DiagnosticsRouting` 决定（纯函数，只有主窗口与诊断页两种结果，不存在退出应用的分支）：

- 硬性前置（Node.js / Pi CLI / Pi Web）缺失、报告缺项或版本无法解析：诊断页列出需要处理的项与下一步操作，服务控件（启动/停止/重启）全部禁用，WebView 显示诊断页而不是服务页，应用保留窗口。缺项与 `unknown` 与“缺失”一样不放行：无法核对身份就不启动服务。
- 硬性前置已满足但首次设置尚未完成：先显示诊断页（所有行已绿色），点击“开始使用 Pi Web”或在窗口里点“重新检测”后记录设置完成并进入主窗口。首次设置状态存在 UserDefaults（经 `AppConfiguration`），只有环境复核通过才会写入。
- 两者都满足：直接进入正常主窗口，行为与 #6 一致。普通启动沿用 `service.autoStart`；本次路由本身就是“刚完成首次设置”时（点“开始使用 Pi Web”或在就绪后重新检测）会显式启动服务，忽略 `autoStart`。

默认端口被占用或 Pi 配置目录缺失都只提示，不阻塞启动：占用者可能就是已有的 Pi Web 服务（应用会直接复用），而 Pi 配置目录由 Pi CLI 首次运行时自行创建——应用不会创建目录，也不会读取目录内任何文件（认证内容永远不会进入诊断）。

诊断窗口也可以随时从菜单“服务 → 依赖与环境诊断…”打开。窗口里的“复制安装命令”只把 `Sources/InstallCommandManifest.swift` 的静态命令写入剪贴板，“重新检测”只重新运行一次 `DependencyChecker`，“选择 pi-web 路径…”经 `NSOpenPanel` 选择可执行文件，先由 `DependencyChecker.piWebIdentityEvidence(atPath:)` 收集只读身份证据（`--version` 版本与 package.json `name`），再经 `AppConfiguration` 写回 `ServiceConfiguration.piWebPath` 并立即重新检测；不可执行、或可执行但既解析不出版本、package.json 名称也不是 `@agegr/pi-web`（例如 `/bin/echo`）时，窗口显示可读错误且配置不变。应用不会执行安装命令、不会调用 `sudo`、不联网，也不读取认证内容。手工排查时可以单独运行只读命令：

```bash
node --version
npm prefix -g
pi --version
pi-web --version
```

无头环境里也可以用假命令输出、假文件系统探针和假端口探针覆盖同样的判定：`PiWebDesktopTests/DependencyCheckerTests.swift` 使用 `DependencyFakeRunner`（命令）、`DependencyFakeFileSystem`（磁盘）和固定的架构/系统版本与端口结果，覆盖缺少命令、Node 版本过低、符号链接、安装来源未知、版本无法解析为 unknown（pi/pi-web 的 unknown 同样关闭门控）、路径选择的只读身份证据（`--version` 版本 / package.json 名称 / 不可执行）、`canStartService` 门控矩阵、脱敏断言；`PiWebDesktopTests/FirstLaunchDiagnosticsTests.swift` 覆盖首次启动路由（干净环境 → 诊断页并列出缺失项与下一步、缺少 pi/pi-web 不会退出、就绪但未完成首次设置 → 诊断页、就绪 + 已完成 → 主窗口、缺项（含空报告）/版本无法解析必须停在诊断页）、路径选择（可执行且可核对身份（版本或 package.json 名称）→ 写配置并解除门控；可执行但不是 pi-web（如 `/bin/echo`）/不可执行/空/相对路径 → 配置不变 + 可读错误）、首次设置完成后的启动语义（显式启动，普通启动尊重 `autoStart`）、状态页字段完整性（每项都输出路径/版本/来源/可信度）、默认端口（占用/无法判定不阻塞）、Pi 配置目录（缺失/不可读只提示且从未读取目录内容）与控件可用性映射（blocked/checking 时 start/stop/restart 全不可用）。测试不执行真实 npm/pi/pi-web，不访问网络、`~/.pi`、用户 Home、真实端口或真实 npm 前缀。

门控在 `ServiceManager` 层面也是硬前置：`isDependencyGateOpen` 默认关闭，启动/重启、配置变更重载、启动失败重试、启动轮询和健康检查的入口与异步回调都会重新确认它；`AppDelegate` 只在 `canStartService == true` 时打开，并在阻塞时调用 `stopHealthMonitor()`。停止入口也受同一映射约束：门控为 `.checking` 或 `.blocked` 时 start/stop/restart 全部不可用。普通启动调用 `startAtLaunch()`，只有“刚完成首次设置”的这一次传 `forceStart: true`，因此即使 `autoStart` 关闭也会显式启动服务，而之后的每次重启仍沿用户设置。这些行为由 `PiWebDesktopTests/ServiceManagerTests.swift` 的假启动器/假探测/假调度器覆盖，不需要真实进程或网络。

## Smoke 运行

```bash
./Scripts/smoke.sh
```

`Scripts/smoke.sh` 是没有完整 Xcode 时验证“应用能启动、主窗口/诊断页能建立、进程能正常退出”的可执行入口。它在 `build/Pi-Web-Desktop.app` 不存在时先运行 `./Scripts/build.sh`，然后依次执行两种模式（每种模式有独立的超时和标记断言）：

- 启动 smoke：`PI_WEB_DESKTOP_SMOKE=1`，建立主窗口后打印 `smoke: ready`；
- 诊断 smoke：`PI_WEB_DESKTOP_SMOKE=diagnostics`，跑确定性诊断夹具与真实路由决策，打开诊断状态页后先打印 `smoke: diagnostics items=<n> blockers=<n>`，再打印 `smoke: diagnostics ready`。

两种模式都必须在超时内以 0 退出并输出各自的标记；默认超时 60 秒，可用 `PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS` 覆盖（必须是正整数）。失败时脚本打印退出码、超时原因和已捕获的应用输出。退出码 0 表示两种模式都通过，1 表示构建/退出码/标记/超时任一失败，2 表示超时参数非法。

smoke 变量只影响那一次启动：

- support 目录改为 `$TMPDIR/pi-web-desktop-smoke-<pid>`，日志也写在该临时目录下，退出前删除；两种模式都不写 `~/Library/Application Support/Pi Web Desktop`、不写 `~/Library/Logs`，也不写真实 UserDefaults。
- 跳过单实例锁与 `service.autoStart` 的服务自动启动，不启动真实 pi-web，也不启动健康检查。
- 启动 smoke 跳过依赖门控：`applicationDidFinishLaunching` 在 smoke 分支直接返回，不运行 `DependencyChecker`、不等待后台结果、不显示诊断窗口；因此即使本机缺少 Node.js/Pi/Pi Web，仍然验证主窗口建立与退出路径。
- 诊断 smoke 不运行真实探针：`DiagnosticsSmokeFixture` 用假命令 runner、空文件系统和固定端口探针生成确定性报告（系统项用 `DependencyChecker.minimumMacOSVersion` 而不是另一份版本字面值），但路由、诊断行、状态页和窗口都由真实代码生成；前置固定判定为缺失，所以它同时验证了门控路径。
- 建立窗口/诊断页后向 stdout 打印标记并以 0 退出；临时目录创建失败、主窗口未建立或诊断夹具不再进入诊断页时向 stderr 报错并以 1 退出，不打印标记。

变量未设置时行为完全不变。smoke 只验证窗口、诊断页与退出路径，不验证服务功能，也不替代 `xcodebuild` 的构建和 `xcodebuild test` 的单元测试：本机只有 Command Line Tools 时无法运行 XCTest，smoke 不声称覆盖测试用例。

## 验证

```bash
sh -n Scripts/build.sh Scripts/install.sh Scripts/check-identity.sh Scripts/smoke.sh
git diff --check
./Scripts/build.sh
codesign --verify --deep --strict build/Pi-Web-Desktop.app
./Scripts/check-identity.sh
./Scripts/smoke.sh
```

服务生命周期、依赖诊断、版本解析、安装来源、脱敏和所有权判定应使用单元测试和本地假服务测试。测试不得访问真实 npm、GitHub、用户 Keychain 或 `~/.pi`。

`PiWebDesktopTests/ServiceOwnershipTests.swift` 覆盖所有权记录与判定表（匹配/不匹配、PID 复用、启动时间、端口、实时命令文本摘要与空白归一化、可执行标识与来源、进程组、过期记录、`ps` 事实不可读、损坏记录清理、JSON 存取）；`PiWebDesktopTests/KeychainStoreTests.swift` 覆盖远程访问密码，全部使用内存 Keychain 替身（`InMemoryKeychainStore`，不访问真实 Keychain）：密码写入后 UserDefaults 中无该字符串（也没有以密码命名的键）、远程配置缺密码时保存被拒绝、删除密码后远程模式关闭且 hostname 回到 `127.0.0.1`、Keychain 写入失败返回可读错误（即使替身的错误描述故意带上密码，`SecretScrubbing` 也会清掉）、读取失败/空密码按“未设置”处理、loopback/hostname 校验拒绝 `0.0.0.0` 与协议路径、启动环境只在“远程 + 非空密码”时包含 `PI_WEB_PASSWORD`（loopback 还会清除继承值）、`ServiceLaunchSpecification.arguments` 与诊断文本里都没有密码、密码生成长度与字符集（可注入随机源或失败源）；`PiWebDesktopTests/DiagnosticsCollectorTests.swift` 断言诊断文本只出现“已设置（仅存于 Keychain）/未设置”，不出现密码值、长度或 `PI_WEB_PASSWORD`；`PiWebDesktopTests/DependencyCheckerTests.swift` 覆盖依赖诊断（语义化版本解析与比较、缺少命令、Node 版本边界与 prerelease、候选路径不可运行时不借用其他 node 的版本、进程 PATH 回退记录真正的可执行路径、`uname` 失败时系统项置信度为 unknown、符号链接路径/真实路径/链接目标、安装来源 npm-global/homebrew/local-path/unknown、package.json 与 CLI 版本的优先级、版本无法解析为 unknown、`canStartService`/`blockingFindings` 门控矩阵、脱敏与 URL 清洗、命令白名单与只读断言）；`PiWebDesktopTests/ServiceManagerTests.swift` 覆盖磁盘记录的生命周期（启动写入并即时校验、旧 `service.pid` 清理、旧实例记录清理、写入/即时校验失败时终止刚启动的进程组且不重复启动、过期记录只删文件）和启动决策（完整命令行与环境变量、找不到可执行文件、停止中忽略启动、复用已验证的进程或在飞子进程）、停止与退出行为（只对验证通过的进程组发送有限次信号、外部服务零信号且状态不变）、描述符保护（fd ≤ stderr 时先复制到 stderr 之上）、健康检查重试，以及依赖门控（默认关闭、所有启动入口与异步回调在 blocked 时不启动/不加载/不改状态、启动轮询期间关闭门控、blocked 时健康 ready 回调不覆盖诊断页、重新打开门控后恢复启动）；所有副作用都走注入的 `CommandRunning`/`ServiceLaunching`/`ServiceOwnershipStoring`/`ServiceSignaling`/`ServiceProbing`/`ServiceScheduling`，可执行标识读取也可注入，`ServiceManager` 的 `remoteAccessPassword` 闭包默认返回 nil，断言不依赖真实的进程、网络、真实 Keychain 或墙钟时间。`PiWebDesktopTests/WebViewNavigationPolicyTests.swift` 覆盖本地/外链 URL 判定。

## 开发约束

- 一个 GitHub Issue 对应一个主要实现 task、worktree、分支和 PR。
- 修改前先确认 Issue 的 Target、Change、Constraints、Ownership 和 Observable acceptance。
- worker 默认只提交本地 commit；coordinator 验证后 push、创建 PR 和映射 GitHub 状态。
- 新增第三方依赖必须单独记录许可证、维护状态和供应链理由。
