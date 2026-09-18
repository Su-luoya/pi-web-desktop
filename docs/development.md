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

标准 Xcode 工程使用 Apple Silicon、macOS 14 SDK，并包含 `PiWebDesktopTests` XCTest target。该测试 target 是 **unhosted** 的独立测试 bundle：不设置 `TEST_HOST`，也不依赖或启动 `PiWebDesktop` app。为了让配置测试在没有 host app 的情况下仍可编译，target 会直接把 `Sources/ServiceConfiguration.swift` 加入测试源；因此测试文件直接使用该 target 内编译的 `ServiceConfiguration`，不通过 `@testable import PiWebDesktop` 引入 app target。

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

测试 target 复用同一身份：`PRODUCT_BUNDLE_IDENTIFIER = $(APP_TEST_BUNDLE_IDENTIFIER)`、`INFOPLIST_KEY_CFBundleDisplayName = $(APP_TEST_DISPLAY_NAME)`、`PRODUCT_NAME = $(TARGET_NAME)`，这些变量同样定义在 xcconfig 里，避免在工程文件中再写一遍身份字面值。

## 一致性检查

```bash
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/check-identity.sh /path/to/Xcode_Products/PiWebDesktop.app build/Pi-Web-Desktop.app
```

`Scripts/check-identity.sh` 退出码 0 表示全部通过，非 0 表示至少一项失败。它接受多个 bundle 路径（位置参数列表，默认 `build/Pi-Web-Desktop.app`），对每个 bundle 独立检查并给出带具体路径的结论，所以同一个命令可以同时校验 Xcode 产物和发布脚本产物。它检查：

- xcconfig 存在，且显示名、可执行名、图标名、最低系统版本、bundle identifier、`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` 均非空；
- `project.pbxproj` 通过 `baseConfigurationReference` 引用该 xcconfig，所有 build configuration 都继承它，且 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、`PRODUCT_BUNDLE_IDENTIFIER`、`PRODUCT_NAME`、`MACOSX_DEPLOYMENT_TARGET`、`INFOPLIST_KEY_CFBundle*` 没有任何字面值，版本与 bundle id 字面值也不出现在工程文件中；
- 每个传入的 bundle 分别断言 `CFBundleShortVersionString`、`CFBundleVersion`、`CFBundleIdentifier`、`CFBundleDisplayName`、`CFBundleExecutable`、`CFBundleIconFile`、`LSMinimumSystemVersion` 与 xcconfig 一致（需要先运行 `./Scripts/build.sh` 或先执行 `xcodebuild`）；bundle 不存在或 `Info.plist` 缺失时以该 bundle 路径报错；
- `CFBundleName` 只输出信息行，不参与成败判定；
- `Sources/ServiceConfiguration.swift` 默认 hostname 为 `127.0.0.1`、默认 proxy 为空、noProxy 只包含 loopback 条目；
- 仓库文本中不出现私人默认值：Tailscale 主机名（小写形式）、tailnet DNS 后缀、CGNAT 私网地址、`/Users` 下的绝对路径、固定本地代理端点；`MARKETING_VERSION` 的字面值也不得出现在 `Sources/`、`Scripts/`、`PiWebDesktop.xcodeproj/`、`PiWebDesktopTests/`。

脚本通过路径排除与字符串拼接保证自身文本不会触发这些模式，`.github/workflows/build.yml` 里的 personal-data grep 同样排除该脚本。

### CI 上的两类产物

CI 的 `Build and test Xcode project` 步骤导出 `XCODE_APP_PATH`（`$DERIVED_DATA_PATH/Build/Products/Debug/PiWebDesktop.app`），然后 `Check application identity of Xcode and script builds` 步骤运行：

```bash
./Scripts/check-identity.sh "$XCODE_APP_PATH" build/Pi-Web-Desktop.app
```

两个产物都要满足上面列出的 7 个 `Info.plist` 字段；只有静态推断而没有真实构建产物的检查不再算通过。`CFBundleName` 在两类产物中本来就不同：Xcode 生成的 plist 取 `PRODUCT_NAME`（`PiWebDesktop`），而发布产物由 `./Scripts/build.sh` 打包，`CFBundleName` 与 `CFBundleDisplayName` 都是 `Pi Web Desktop`。因此检查脚本只把 `CFBundleName` 当作信息行输出，也不用 `INFOPLIST_KEY_CFBundleName` 去覆盖 Xcode 的默认行为。

## 本地运行

```bash
open build/Pi-Web-Desktop.app
```

默认服务地址是 `http://127.0.0.1:30141/`。首版基线默认 loopback，不开放局域网监听。

## 验证

```bash
sh -n Scripts/build.sh Scripts/install.sh Scripts/check-identity.sh
./Scripts/build.sh
codesign --verify --deep --strict build/Pi-Web-Desktop.app
./Scripts/check-identity.sh
```

服务生命周期、依赖诊断、版本解析、安装来源、脱敏和所有权判定应使用单元测试和本地假服务测试。测试不得访问真实 npm、GitHub、用户 Keychain 或 `~/.pi`。

## 开发约束

- 一个 GitHub Issue 对应一个主要实现 task、worktree、分支和 PR。
- 修改前先确认 Issue 的 Target、Change、Constraints、Ownership 和 Observable acceptance。
- worker 默认只提交本地 commit；coordinator 验证后 push、创建 PR 和映射 GitHub 状态。
- 新增第三方依赖必须单独记录许可证、维护状态和供应链理由。
