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

标准 Xcode 工程使用 Apple Silicon、macOS 14 SDK，并包含 `PiWebDesktopTests` XCTest target。该测试 target 是 **unhosted** 的独立测试 bundle：不设置 `TEST_HOST`，也不依赖或启动 `PiWebDesktop` app。为了让测试在没有 host app 的情况下仍可编译，target 会把被测源码直接加入测试源：`Sources/ServiceConfiguration.swift`、`Sources/AppConfiguration.swift`、`Sources/ProcessInspector.swift`、`Sources/DiagnosticsCollector.swift`、`Sources/ServiceManager.swift`、`Sources/WebViewNavigationPolicy.swift`；因此测试文件直接使用该 target 内编译的这些类型，不通过 `@testable import PiWebDesktop` 引入 app target。`Sources/WebViewController.swift` 依赖 AppKit/WebKit 且需要真实窗口，只进 app target；它使用的 URL 判定规则因此拆在 `WebViewNavigationPolicy.swift` 里，可以在 unhosted 目标里测试。这些测试使用假的 `ps`/`lsof` 输出、注入的存活判定、假的进程启动器、即时执行的调度器和临时目录，不访问真实进程、网络、Keychain 或 `~/.pi`。

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

默认服务地址是 `http://127.0.0.1:30141/`。首版基线默认 loopback，不开放局域网监听。

## Smoke 运行

```bash
./Scripts/smoke.sh
```

`Scripts/smoke.sh` 是没有完整 Xcode 时验证“应用能启动、主窗口能建立、进程能正常退出”的可执行入口。它在 `build/Pi-Web-Desktop.app` 不存在时先运行 `./Scripts/build.sh`，然后用 `PI_WEB_DESKTOP_SMOKE=1` 运行 `build/Pi-Web-Desktop.app/Contents/MacOS/PiWebDesktop`，默认 60 秒超时（可用 `PI_WEB_DESKTOP_SMOKE_TIMEOUT_SECONDS` 覆盖，必须是正整数），断言退出码为 0 且输出包含固定标记 `smoke: ready`；失败时打印退出码、超时原因和已捕获的应用输出。退出码 0 表示 smoke 通过，1 表示构建/退出码/标记/超时任一失败，2 表示超时参数非法。

`PI_WEB_DESKTOP_SMOKE=1` 只影响那一次启动：

- support 目录改为 `$TMPDIR/pi-web-desktop-smoke-<pid>`，日志也写在该临时目录下，退出前删除；不写 `~/Library/Application Support/Pi Web Desktop`，也不写 `~/Library/Logs`。
- 跳过单实例锁与 `service.autoStart` 的服务自动启动，不启动真实 pi-web，也不启动健康检查。
- 建立主菜单与主窗口后向 stdout 打印 `smoke: ready` 并以 0 退出；临时目录创建失败或主窗口未建立时向 stderr 报错并以 1 退出，不打印标记。

变量未设置时行为完全不变。smoke 只验证窗口建立与退出路径，不验证服务功能，也不替代 `xcodebuild` 的构建和 `xcodebuild test` 的单元测试：本机只有 Command Line Tools 时无法运行 XCTest，smoke 不声称覆盖测试用例。

## 验证

```bash
sh -n Scripts/build.sh Scripts/install.sh Scripts/check-identity.sh Scripts/smoke.sh
./Scripts/build.sh
codesign --verify --deep --strict build/Pi-Web-Desktop.app
./Scripts/check-identity.sh
./Scripts/smoke.sh
```

服务生命周期、依赖诊断、版本解析、安装来源、脱敏和所有权判定应使用单元测试和本地假服务测试。测试不得访问真实 npm、GitHub、用户 Keychain 或 `~/.pi`。

`PiWebDesktopTests/ServiceManagerTests.swift` 覆盖服务所有权（过期 PID 记录、外部进程、匹配进程、运行中的子进程优先）和启动决策（完整命令行与环境变量、找不到可执行文件、停止中忽略启动、复用已运行进程）、停止与退出行为、健康检查重试；所有副作用都走注入的 `CommandRunning`/`ServiceLaunching`/`ServiceProbing`/`ServiceScheduling`，断言不依赖真实的进程、网络或墙钟时间。`PiWebDesktopTests/WebViewNavigationPolicyTests.swift` 覆盖本地/外链 URL 判定。

## 开发约束

- 一个 GitHub Issue 对应一个主要实现 task、worktree、分支和 PR。
- 修改前先确认 Issue 的 Target、Change、Constraints、Ownership 和 Observable acceptance。
- worker 默认只提交本地 commit；coordinator 验证后 push、创建 PR 和映射 GitHub 状态。
- 新增第三方依赖必须单独记录许可证、维护状态和供应链理由。
