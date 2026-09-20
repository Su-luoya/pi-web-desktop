# Pi Web Desktop `0.1.0-alpha.10` 安全评审（delta）

评审对象：`git diff 21ce459..09f1264` —— 即 `v0.1.0-alpha.9` 的发布提交到本版候选
（`v0.1.0-alpha.9` 之后的全部提交）。这段区间里是两个提交：`21ce459`（PR #133，alpha.9 发布值回填，
纯文档）与 `09f1264`（PR #136，关闭 [#134](https://github.com/Su-luoya/pi-web-desktop/issues/134)
的「最近工作目录与快速切换」功能，含文档与用例）。真正的代码改动只有 PR #136。

评审性质：只读 delta 评审。逐处对照新增代码、用例、门槛输出与文档，不修改文件、不提交、不联网。

**结论：阻断项 0 条，非阻断性发现 4 条（`F1`–`F4`，已登记
[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)），其中同轮提出的文档缺口 `F5` 已在同一
提交内修掉，不影响本版发布。**

## 0. 变更面

- `git diff --stat 21ce459..09f1264`：**10 个文件、350 行新增、9 行删除**。
- 文件清单：`Sources/RecentWorkspace.swift`（新增）、`Sources/PiWebApp.swift`、`Sources/AppConfiguration.swift`、
  `PiWebDesktopTests/RecentWorkspaceTests.swift`（新增）、`Scripts/build.sh`、`PiWebDesktop.xcodeproj/project.pbxproj`、
  `docs/settings-and-workspace.md`、`docs/privacy.md`、`docs/architecture.md`、`README.md`。
- 本版**没有**改动：更新检查与更新流水线的任何文件（`Sources/UpdateChecker.swift`、`Sources/UpdateVerifier.swift`、
  `Sources/UpdateTransaction.swift`、三个更新适配器）、服务启动与探测命令、密钥与脱敏规则、CSP / 网站数据、
  CI 与发布脚本的判定逻辑。因此 [alpha.1 审查](security-review-alpha.1.md) 与
  [alpha.3 审查](security-review-alpha.3.md) 的结论继续适用，本文只评审这个 delta。

## 1. 新增的路径接受面（本次唯一的新输入面）

这是本版唯一的新「外来输入」：用户可以要求应用切换工作目录。逐条核对它的边界：

- 只接受绝对路径：`Sources/RecentWorkspace.swift` 的 `WorkspaceSwitchDecision.decide(requestedPath:currentPath:probe:)`
  对非绝对路径（含 `~`，**不展开**）直接返回 `.reject`，不写状态、不创建目录。
- 目录必须**存在、是目录、可写**：`probingIsDirectory` / `probingIsWritable` 逐项判定，任一不满足即 `.reject`，
  并给出固定原因文案。
- **任何分支都不创建目录**：用例 `testSwitchDecisionNeverCreatesARequestedDirectory`
  （`PiWebDesktopTests/RecentWorkspaceTests.swift:85`）专门断言这一点；这也是与「应用不会因为用户给错路径
  而新建目录」这条用户可见承诺对应的证据。
- 拒绝时只显示可读提示，不改 `service.workspacePath`、不停止服务、不写历史记录。
- 与当前目录相同 → `.unchanged`，不做任何界面动作。

结论：新增输入面只接受「已存在的、可写的目录」，不接受任意字符串，且不接受相对路径。

## 2. 持久化内容（隐私面）

- 单键：`workspace.recentPaths`（唯一写入点 `Sources/RecentWorkspace.swift:9` 的 `static let storageKey`），
  按最近使用顺序、按标准化路径去重、**最多 10 条**（`maximumCount`）。
- 写入内容是用户自己选过或被要求打开的**绝对目录路径**；没有凭据、没有环境变量值、没有子进程输出。
- 新文件里**没有任何**日志、网络、钥匙串或剪贴板调用：对 `Sources/RecentWorkspace.swift` 逐项 grep
  `URLSession` / `SecItem` / `Keychain` / `NSPasteboard` / `FileManager` / `print(` / `Logger` / `Process(` 均**无命中**。
- 路径不会进入日志与诊断导出：`docs/privacy.md` 的本地数据一览已补这一项，并写明它只用于菜单展示、
  确认框与「在 Finder 中打开」。

结论：新增持久化落在既有 UserDefaults 域内，可直接用 `defaults delete` 或菜单里的「清除历史记录」清掉，
不引入新的本地数据位置。

## 3. 切换的生效面（进程与信号）

- 切换成功后**只写** `service.workspacePath`，因此进入 `ServiceConfiguration.runtimeSignature`；界面
  依据该签名判断是否需要重启托管服务。
- 停止路径**复用既有实现**：本版 delta 对停止语义的改动是「从既有界面动作里抽出可复用入口」，不是新写一套。
  证据：`git diff 21ce459..09f1264 -- Sources/PiWebApp.swift` 里**没有任何新增的** `kill` / `terminate` / `signal`
  调用行（grep 无命中）。也就是说，本版没有扩大「应用会向哪些进程发信号」的范围。
- 服务是**外部进程**（不是本应用托管的）时，切换只改配置并告知用户需自行重启：应用不停止、不重启它，
  界面文案也不声称已生效（`F2` 指出这里的说明还不够，但不存在「停掉别人的进程」这种行为）。
- 所有发送信号的行为仍受既有约束：只对已验证属于本应用的托管进程组生效。

结论：本版不新增信号语义，也不改变「谁会被停」的判定。

## 4. 「打开方式」的代价：`CFBundleDocumentTypes` 声明

- 为使拖放文件夹可用，`Scripts/build.sh` 的 Info.plist 拼装声明了 `CFBundleDocumentTypes`
  （`CFBundleTypeName = Folder`、`CFBundleTypeRole = Editor`、`LSItemContentTypes = [public.folder]`），
  两个 app target 的 `project.pbxproj` 同步。
- 这是**声明式**改动：它让系统把文件夹交给本应用，但它**不新增能力面** —— `AppDelegate.application(_:open:)`
  只取第一个 URL（`urls.count > 1` 时其余静默忽略），随后走与菜单完全同一条校验、确认与重启路径。
- 真实代价是**呈现层的**：Finder 的「打开方式」会为任意文件夹列出本应用。已在
  `docs/settings-and-workspace.md` 写明。这条代价不涉及读取文件夹内容、不涉及遍历目录。
- 该入口的处理不够严（未检查 `isFileURL`、多 URL 静默丢弃）是 `F3`；它不构成安全边界，因为下游校验
  与菜单路径共用同一份判定。

结论：声明带来了可见的菜单项，但没有引入新的数据访问或新的执行路径。

## 5. 测试面

- 新增文件 `PiWebDesktopTests/RecentWorkspaceTests.swift`，5 个用例（行号：
  `testHistoryDeduplicatesMovesLatestToFrontAndCapsAtTen`:9、`testHistoryPersistsAcrossStoreInstancesAndClears`:27、
  `testAppConfigurationUsesItsInjectedDefaultsForHistory`:41、
  `testSwitchDecisionSkipsCurrentRejectsInvalidAndConfirmsUsableDirectory`:54、
  `testSwitchDecisionNeverCreatesARequestedDirectory`:85）。
- 本机串行运行（XCTest shim，本机只有 Command Line Tools）：**5 passed、0 failed**。
- 覆盖到的判定：历史去重/置顶/上限、跨实例持久化与清除、注入 UserDefaults、切换决策的四种结果、
  「拒绝时不创建目录」。
- **未覆盖**（明确记录）：真机 GUI 交互（菜单、确认框、拖放、重启后的实际工作目录）、重叠切换竞态
  （`F1`）。权威的 `xcodebuild test` 由 PR #136 上的 CI 承担。

## 6. 发现

### 阻断项

**无。**

### 非阻断项（`F1`–`F4`，登记为 #135，本版不修）

- `F1` **重叠切换竞态**：`Sources/PiWebApp.swift:2358-2361` 在停止服务的完成回调里**无条件**写回它捕获的
  配置，`ServiceManager.updateConfiguration` 没有代次校验。停止过程中再次切换（A 未停完就选 B）时，
  A 的迟到回调可能把配置写回 A，与界面显示不一致。判断：**不是安全边界**（只影响配置与显示一致性，
  不涉及外部输入或权限），但会造成「界面说 B、实际是 A」的困惑，建议下次迭代修。
- `F2` **外部服务的文案**：服务是外部进程时，界面没有说明「新目录要等自行重启服务后才生效」。
  判断：文案缺口，不涉及行为。
- `F3` **open 事件处理不严**：`application(_:open:)` 未检查 `url.isFileURL`，`urls.count > 1` 时静默丢弃其余 URL。
  判断：下游校验会拒绝非目录，不构成绕过。
- `F4` **路径接受面未收紧**：不展开 `~`（落成 `.missing` 提示）、未显式拒绝根目录 `/`、未
  `resolvingSymlinksInPath`、没有超长路径与控制字符防护。判断：这些路径只进 UserDefaults、菜单标题与
  `NSWorkspace.shared.open`（打开一个本地目录），都不构成安全边界；登记为加固项而非缺陷。

### 同轮提出并已修

- `F5` **文档缺口**：`workspace.recentPaths` 未进用户可见文档。已在 PR #136 内修：`docs/privacy.md`、
  `docs/settings-and-workspace.md`、`docs/architecture.md`、`README.md` 同步。

### 既往观察（非本次 delta）

- `O-1`（沿用 alpha.9 评审，本版未改）：`Sources/PiCLIUpdateAdapter.swift:1528` 与
  `Sources/PiWebUpdateAdapter.swift:1883` 的持久警告以「旧版本语义保持不变：应用不会自动回滚已替换的文件，
  也不声称更新成功」开头，说的是语义而非文件位置断言，早于本版 delta，本次保持原样。

## 7. 已核实无问题

- 新增功能**不联网**：`Sources/RecentWorkspace.swift` 无任何网络调用；更新检查的两个主机常量
  （`api.github.com`、`registry.npmjs.org`）与本版改动无关，未被触碰。
- 新增功能**不读文件夹内容**：只做路径级判定（存在 / 目录 / 可写），不遍历、不读取、不上传目录内容。
- 版本唯一来源与一致性：`Configuration/AppIdentity.xcconfig` 是唯一来源，
  `Scripts/check-release-version.sh v0.1.0-alpha.10` 与 `Scripts/check-identity.sh`（45 checks）在本版候选上通过。
- 门槛与产物：`build.sh`、`smoke.sh`（默认与 `--diagnostics`，`items=6 blockers=3`）、`scan-secrets.sh`
  （含 `--self-test`）、`package-release.sh`（含 `--self-test`）、`codesign --verify --deep --strict` 均按预期通过；
  `spctl` 判 `rejected` 属未公证 ad-hoc 产物的预期结果。
- 改动范围：区间内只有文档回填（PR #133）与本功能（PR #136），没有顺带改动安全敏感路径。

## 8. 证据不足 / 无法确认（不作猜测）

- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本评审不对菜单、确认框、拖放的
  真机呈现作断言；这属于发布前需要补的人工验证（记录在发布说明「已知问题」第 3 小节）。
- **`F1` 的竞态未被实际复现**：结论来自代码复核（回调里无条件回写 + 缺少代次校验），没有构造真实的重叠
  切换场景，因此不评估它在真实使用中的触发概率。
- **「打开方式」的真实呈现**：`CFBundleDocumentTypes` 的代价按声明语义描述，未在真实 Finder 上逐一核对
  不同 macOS 版本的呈现差异。
- **目录消失后的历史条目**：应用不自动清理失效条目（切换时拒绝并提示），这是设计选择；本评审不对
  「用户会不会觉得历史被污染」下结论。

## 9. 发布决定

不阻断发布。本版 delta 只做三件事：新增「最近工作目录与快速切换」这一条本地、无网络的用户输入路径
（只接受已存在且可写的绝对目录，任何分支都不创建目录）、为接收文件夹声明 `public.folder`（带来
Finder「打开方式」的可见代价，但不新增能力面）、以及相应的文档与用例。它不改变更新流水线、
不改变信号语义、不改变网络边界、不改变权限与 Keychain 语义。四条非阻断发现
（[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)）与一条既往观察（`O-1`）记录在案，
不影响本版发布。
