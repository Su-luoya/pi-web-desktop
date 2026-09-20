# Alpha 发布门槛清单（Issue 驱动）

每个 alpha 版本（`v<MARKETING_VERSION>`）由一个 Release Issue 驱动：Issue 是发布记录的唯一入口，
本文列出的每一项都要在 Issue 里留下可核对的证据，缺任何一项就不发布。

相关文档：[发布流程](releasing.md)、[Release notes 模板](release-notes-template.md)、[开发与验证](development.md)。

## Release Issue 模板

新建 Issue（标题 `Release v<MARKETING_VERSION>`），粘贴以下内容并逐项填写：

```markdown
## 目标

- 版本：v<MARKETING_VERSION>（build <CURRENT_PROJECT_VERSION>）
- 类型：alpha 预览，Apple Silicon，macOS 14+，ad-hoc 签名，未公证
- 发布 workflow run：<workflow 运行链接>
- 草稿 Release：<draft Release 链接>

## 门槛

- [ ] main CI（build workflow）在 main 上为绿：<run 链接>
- [ ] #14 安全审查完成，无阻断项（结论：[alpha.1 安全与发布审查](security-review-alpha.1.md)，含日期与被执行命令的提交）：<日期 / 链接>
- [ ] 安全门槛逐项核对（见下文“安全门槛”一节的 8 项）：结果写入本 Issue
- [ ] `./Scripts/scan-secrets.sh` 与 `./Scripts/scan-secrets.sh --self-test` 均退出 0（记录结尾的 `scan-secrets: suppressed N lines` 并与本次 diff 仍在命中的内联标记数对照；确认没有 `scan-secrets: rejected` 行）
- [ ] tag 与 bundle 版本一致：`./Scripts/check-identity.sh` 与 `./Scripts/check-release-version.sh <tag>` 退出 0
- [ ] 真机 smoke 记录（见下表）
- [ ] checksum 记录（见下表，与 Release 资产一致）
- [ ] Release 标记 prerelease，说明中写明未公证与安装限制
- [ ] 回退路径确认（上一版资产仍可下载）

## 真机 smoke 记录

- 机器与芯片：<例如 Apple Silicon 具体机型>
- macOS 版本：<版本>
- 架构：arm64
- Node.js：<版本>
- Pi（@earendil-works/pi-coding-agent）：<版本>
- @agegr/pi-web：<版本>
- `./Scripts/smoke.sh`：<启动模式与诊断模式的结果，含退出码>
- 应用包：`Pi-Web-Desktop.app`，CFBundleShortVersionString=<版本>，CFBundleVersion=<build>

## checksum 记录

- 资产：`Pi-Web-Desktop-<版本>.zip`
- SHA-256：<从 workflow 摘要或草稿资产复制>
- 校验：`shasum -a 256 -c Pi-Web-Desktop-<版本>.zip.sha256` → OK

## 已知问题与回退

- 已知问题：<本版本记录的问题；无则写“无”>
- 回退：<上一版资产链接；确认仍可下载>
```

## 发布前门槛

1. **main CI 为绿。** `build workflow`（`.github/workflows/build.yml`）最近一次在 `main` 上的运行通过；
   发布 tag 指向的提交必须已经包含这次运行的结果。
2. **#14 安全审查无阻断项。** 安全审查（issue #14）在本版本代码上没有未解决的阻断项；
   Issue 中记录审查日期与结论。
3. **tag 与 bundle 版本一致。** 在候选提交上本地运行：

   ```sh
   ./Scripts/build.sh
   ./Scripts/check-identity.sh
   ./Scripts/check-release-version.sh v<MARKETING_VERSION>
   ```

   三条命令都必须退出 0。`check-release-version.sh` 的 tag 必须写成完整的
   `v<MARKETING_VERSION>`；版本值只存在于 `Configuration/AppIdentity.xcconfig`，不要在别处复制。
4. **真机 smoke 记录。** 在一台真实的 Apple Silicon Mac（macOS 14+）上运行：

   ```sh
   ./Scripts/smoke.sh
   ```

   把机器与芯片、macOS 版本、架构、Node.js、Pi、`@agegr/pi-web` 版本和两种模式的结果
   写进 Release Issue。CI runner 上的 smoke 不能代替这一条：真机记录的是用户实际环境。
5. **checksum 记录。** 本地演练或 workflow 产出的 SHA-256 记录到 Issue，并与 Release 说明里的
   `校验值` 段落逐字符一致；不一致就不要发布。
6. **prerelease 标记。** alpha 一律以 prerelease 形式发布；workflow 用
   `--prerelease --draft` 创建草稿，发布草稿前确认 prerelease 复选框仍然勾选。
7. **未公证事实已写明。** Release 说明必须包含签名与公证证据段落，并写明 ad-hoc 与未公证；
   不允许出现“已签名”“已公证”或任何关闭 Gatekeeper 的指导。

## 安全门槛（#14 审查结论映射）

本节的 8 项与 [#14](https://github.com/Su-luoya/pi-web-desktop/issues/14) 的审查范围一一对应；
详细证据、威胁模型、风险清单与阻断条件见 [alpha.1 安全与发布审查](security-review-alpha.1.md)。
每一行都必须在本版本的 Release Issue 里留下可核对的结论（通过 / 不通过）与证据链接。

| # | 安全门槛 | alpha.1 验收标准（可观察） | 证据形式 |
| --- | --- | --- | --- |
| S1 | 服务所有权与外部服务只读 | 只有通过所有权验证的进程组会收到信号；验证失败零信号；无命令行子串匹配的停止路径 | 审查报告的 §1 结论 + `git grep -n "kill(" -- Sources` 与 `sendGroupSignal` 调用点输出 |
| S2 | 凭据边界 | 密码只在 Keychain 与子进程环境；UserDefaults / 命令行 / 日志 / 诊断 / 错误消息中无密码值或长度 | 审查报告的 §2 结论 + `git grep` 反证输出 |
| S3 | 日志与诊断脱敏 | 统一 `LogRedactor` 实例覆盖四处路径；已记录已知不覆盖形态与幂等例外 | 审查报告的 §3 结论与实测矩阵 |
| S4 | 网络边界 | 默认 loopback；非 loopback 强制非空密码；`0.0.0.0`/`::` 在界面不可保存；文档明写“密码认证不等于传输加密” | 审查报告 §4 表 + `./Scripts/check-identity.sh` 的服务默认值检查 |
| S5 | 构建与发布 | CI 权限最小、Actions 固定完整 SHA、ZIP 只含应用包与 AppleDouble 元数据、checksum 可复验 | 审查报告 §5 + `unzip -l` 清单 |
| S6 | 签名与 Gatekeeper 表述 | `codesign` 报告 `Signature=adhoc` / `TeamIdentifier=not set`，`spctl` 预期拒绝；文档只写 ad-hoc/未公证 | 审查报告 §6 + 本机 `codesign` / `spctl` 输出 |
| S7 | 依赖与供应链 | 无第三方 Swift / npm 运行时依赖，无 `Package.swift`；Actions 依赖清单固定 | 审查报告 §7 输出 |
| S8 | 个人数据与 secret | `scan-secrets.sh` 与 CI personal-data `git grep` 均通过；仓库无真实主机名、私网地址、凭据、真实用户路径 | 审查报告 §8 与 §8.1 + 两条扫描的退出码（**先 `git add` 再扫**，否则未跟踪文件会给出假绿，见 R-11） |

安全门槛的判定规则：

- **阻断项必须为 0 才可发布。** 阻断项定义见审查报告 §11.2；任一项触发就不要 push tag，
  已创建的草稿 Release 保留并在 Release Issue 里记录阻塞点。
- **非阻断风险要显式接受。** 审查报告 §10 的风险清单（含严重度与建议）必须在本 Issue 里
  逐条给出“接受 / 本版本修 / 转后续 Issue”的处置，不允许默认忽略。
- **后续 Issue 建议要在本 Issue 里链接。** follow-up Issue 由 coordinator/维护者创建，
  审查 worker 不创建 Issue；未创建时在本 Issue 记录待创建条目。
- **能力描述不得夸大。** 特别不要把“scan-secrets 通过”或“脱敏通过”写成“没有秘密”，
  也不要把本地 `codesign --verify` 通过写成“已签名”。
- **S1–S8 的复核命令必须在候选提交上重跑**，而不是引用更早的审查运行；脚本链见
  [开发说明](development.md#验证)与 `## 演练（不发布）` 小节。基于 `git grep` 的两条文本检查
  只扫已跟踪文件，复核前先暂存，否则新建文件会被跳过（见审查报告 R-11）。

## 演练（不发布）

任何一个提交都可以先演练打包，不 push tag、不创建 Release：

1. GitHub Actions 页面选择 `release` workflow → `Run workflow`，`tag` 留空或填候选 tag。
   非 tag ref 上留空时，workflow 会用 `./Scripts/check-release-version.sh --print-tag`
   从 xcconfig 推导 tag，再执行同一套比较逻辑。
2. 等 workflow 结束，下载 `pi-web-desktop-alpha` artifact，核对：
   - `release-metadata.env` 里的 `VERSION` / `BUILD` 与 xcconfig 一致；
   - `*.zip.sha256` 校验通过；
   - 证据段落明确写出 adhoc 与未公证。
3. workflow_dispatch 永不创建 Release，即使 ref 是 tag 也是如此；因此演练是安全的。

本机同样可以演练，且不需要完整 Xcode（`xcodebuild` 只在 CI 运行）：

```sh
sh -n Scripts/*.sh
git diff --check
./Scripts/scan-secrets.sh --self-test
./Scripts/scan-secrets.sh
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/check-release-version.sh v<MARKETING_VERSION>
./Scripts/package-release.sh --tag v<MARKETING_VERSION>
./Scripts/smoke.sh
```

## 打 tag 与发布

1. 确认候选提交已通过上面所有门槛，并且提交本身只包含预期改动。
2. 在候选提交上创建并推送受保护 tag（仓库需要在 tag protection ruleset 中保护 `v*`）：

   ```sh
   git tag v<MARKETING_VERSION>
   git push origin v<MARKETING_VERSION>
   ```

   推送后 `release` workflow 会按 tag 重新构建、校验、打包，并创建一个**草稿** prerelease，
   资产为 ZIP、`.sha256` 与证据 Markdown。
3. 打开草稿 Release，把 Release Issue 里的真机实测版本、已知问题和回退路径填进说明，
   确认没有剩余的 `<待填写>` 字段。
4. 确认草稿资产与 Issue 中记录的 checksum 一致，然后发布（保持 prerelease 标记）。
   在这之前资产不会公开可见。
5. 在 Release Issue 中记录最终 Release 链接与发布日期，勾选全部门槛。

## 发布后核对

```sh
gh release view v<MARKETING_VERSION>
gh release download v<MARKETING_VERSION> --pattern '*.zip*'
shasum -a 256 -c Pi-Web-Desktop-<MARKETING_VERSION>.zip.sha256
```

确认 Release 说明包含 adhoc/未公证证据段落，且 Issue 与 Release 的 checksum 一致。

## 门槛未满足时

- 任何一项不满足：不 push tag；若已经创建草稿 Release，保留草稿并在 Issue 中记录阻塞点。
- 已经发布的版本发现问题：不要静默替换资产（checksum 与证据会不匹配）。
  在 Release 说明中标注问题，必要时发布新的 alpha（`v0.1.0-alpha.2`）并在 Issue 中说明回退路径。
- 安全相关阻断项按 [SECURITY.md](https://github.com/Su-luoya/pi-web-desktop/blob/main/SECURITY.md)
  的渠道处理，不要写进公开 issue。

## 本次发布执行记录（v0.1.0-alpha.1）

本节记录 `v0.1.0-alpha.1` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

- 被测候选提交：`f195f26`（`docs(release): v0.1.0-alpha.1 发布说明与 README 扫描能力修正 (#15)`）
- 执行环境：Apple M4（Mac mini，`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.85.1、`@agegr/pi-web` 0.9.1
  （Homebrew 前缀下的 npm 全局安装）；`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.1` / `1`）；
  下面所有命令都在该提交上重跑，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.1 Release 说明](release-notes-v0.1.0-alpha.1.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- **追加修复（本节下方的“追加修复实测”小节）**：上表的签名校验行记录的是干净目录下的结果；把仓库放在
  iCloud/File Provider 同步目录时，Finder 写入的 `com.apple.FinderInfo` 会让 `codesign --verify` 失败。
  修复在提交 `03e0b86`（`Scripts/build.sh`、`Scripts/package-release.sh`），实测证据见下方小节

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Mach-O 64-bit executable arm64` | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.1`、`CFBundleVersion=1`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop` | 退出 0，通过 |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.1` | `PASSED (tag v0.1.0-alpha.1, MARKETING_VERSION 0.1.0-alpha.1, CURRENT_PROJECT_VERSION 1)` | 退出 0，通过 |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | `valid on disk`、`satisfies its Designated Requirement`（干净目录；同步目录下的 xattr 变体见下方追加小节） | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Signature=adhoc`、`TeamIdentifier=not set`、`Format=app bundle with Mach-O thin (arm64)` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | `rejected`；本机不打印拒绝原因（已记入审查报告 R-10） | 退出 3；未公证 ad-hoc 产物的预期结果 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh` | app exit 0（0s）；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | app exit 0（1s）；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, suppression verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 11 lines`、`scan-secrets: PASS (no matches in tracked files)`；N=11 为仓库现有夹具标记数，本提交没有新增标记 | 退出 0，通过（先 `git add`，见 R-11） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.1` | 退出 0；产出 `Pi-Web-Desktop-0.1.0-alpha.1.zip`、`.zip.sha256`、`.evidence.md`、`release-metadata.env`；证据段落含 `Signature=adhoc`、`spctl` 退出码与 `COMMIT=f195f26…` | 通过 |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.1.zip` | 23 项，只有 `Pi-Web-Desktop.app/`（含 `_CodeSignature/`、`Info.plist`、`MacOS/`、`Resources/ApplicationIcon.icns`）与 `__MACOSX/` AppleDouble 元数据；无源码、测试、`.git`、日志或用户路径 | 通过 |
| 15 | checksum 复验 | `cd dist && shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.1.zip.sha256` | `Pi-Web-Desktop-0.1.0-alpha.1.zip: OK` | 退出 0，通过 |
| 16 | 文档过期表述复查 | `git grep -n 'secret scan' docs README.md CONTRIBUTING.md` | README 的 R-7 旧表述已删除，其余命中均为“已实现 + 能力边界”描述 | 通过 |

本地演练的 checksum 只用于验证流程：同一提交、同一工作树上多次打包每次都得到不同的 SHA-256
（本机实测四次分别为 `6956bc46…`、`184df997…`、`f6939c05…`、`b7ac408c…`；本机演练不承诺
bit-for-bit 可复现，见 [发布流程](releasing.md#可复现性与诚实的边界)）。因此**发布说明里的
SHA-256 必须从 workflow 产出的资产复制**，不要使用上表任何本地值；本地证据文件的 `COMMIT`
也只能证明“哪个提交被本机打包”。

### 追加修复实测：Finder/iCloud 扩展属性导致 ad-hoc 签名校验失败（#15）

被测提交：`03e0b86`（`fix(release): 清理 Finder/iCloud 扩展属性，修复 ad-hoc 签名校验失败 (#15)`）。
环境同上（Apple M4 / macOS 27.0 / arm64）。本机工作区不在同步目录，因此用测试用的 `codesign` 包装
脚本（放在 `$TMPDIR` 下、不进入仓库）在签名后或校验前注入 `com.apple.FinderInfo`，模拟 File
Provider 的重挂载时机；注入的 32 字节 FinderInfo 值取自同步目录里 `com.apple.FinderInfo` 的实际形状。

| # | 场景 | 命令（摘要） | 实测输出 | 判定 |
| --- | --- | --- | --- | --- |
| X1 | 复现：修复前的 `build.sh`（`bf90611` 版本）+ 签名后注入 | `git show bf90611:Scripts/build.sh` 到临时目录（符号链接 `Sources/`、`Resources/`、`Configuration/`）后带注入 shim 运行 | 退出 1；`resource fork, Finder information, or similar detritus not allowed` | 复现了报告的现象 |
| X2 | 验前手工注入（症状确认） | `xattr -wx com.apple.FinderInfo … <app 与 Contents/MacOS/PiWebDesktop>` 后 `codesign --verify --deep --strict --verbose=2` | 退出 1；`file with invalid attached data: Disallowed xattr com.apple.FinderInfo found on …/build/Pi-Web-Desktop.app` | 与报告输出一致 |
| X3 | 修复后 + 签名后注入 | `PATH=<shim> ./Scripts/build.sh` | 退出 0；无 warning；产物 `Mach-O 64-bit executable arm64` | 通过（签名后清理生效） |
| X4 | 修复后 + 首次验前注入（触发重试） | `PATH=<shim-once> ./Scripts/build.sh` | 退出 0；`warning: codesign --verify --deep --strict failed (attempt 1/3 …); clearing extended attributes and retrying`、`info: … passed on attempt 2` | 通过（清属性重试生效，不重新签名） |
| X5 | 修复后 + 持续注入（对抗性） | `PATH=<always-inject-shim> ./Scripts/build.sh` | 退出 1；打印每次尝试的真实 `codesign` 输出 + `xattr -l` / `xattr -cr` 提示 | 预期失败：清理后立即被重写时不静默忽略签名错误 |
| X6 | 打包前的防御性清理 | 先 `xattr -wx com.apple.FinderInfo …`（bundle 根与可执行文件），`codesign --verify` 退出 1，再 `./Scripts/package-release.sh --tag v0.1.0-alpha.1` | 退出 0；`ok   codesign --verify --deep --strict passed`、`package-release: OK`；打包后 `xattr -l` 只剩 `com.apple.provenance` | 通过 |
| X7 | ZIP 内容 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.1.zip` | 23 项；按源码、测试、日志、`.DS_Store` 与本地绝对路径前缀逐一过滤后无命中（过滤表达式里的路径前缀在此按字面量拆分书写，避免文档自身触发 personal-data 门禁） | 通过（与上表第 14 项一致） |
| X8 | 解压后复验（用户视角） | `ditto -x -k <zip> $TMPDIR && codesign --verify --deep --strict <解压的 app>` | 退出 0；`valid on disk`、`satisfies its Designated Requirement` | 通过 |
| X9 | 幂等性 | 连续两次 `./Scripts/build.sh` 后 `codesign --verify --deep --strict` | 两次退出 0，复验退出 0 | 通过 |

定位细节（实测）：把 `com.apple.FinderInfo` 挂在 bundle 根目录或 `Contents/MacOS/PiWebDesktop` 上会
导致校验失败；挂在 `Contents/Info.plist` 上仍然通过。`xattr -cr` 清除后同一 bundle 立即复验通过，
不需要重新签名。修复后的普通路径（无注入）不打印任何 warning，退出码与标记与上表一致（X6–X9）。
上述测试 shim 只存在于 `$TMPDIR`，没有进入仓库；`Scripts/check-identity.sh` 未被修改。

### 仍需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖 |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds`（`check-identity.sh --test-bundle …`） | 本机只检查了脚本产物，由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`；该步骤由 CI 覆盖（本地复现命令见[开发说明](development.md#personal-data-与-secret-扫描能力)） |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；Issue 中记录 run 链接 |
| C5 | Release 资产校验：ZIP/`.sha256`/证据 Markdown 上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的 `Package ZIP, checksum, signature evidence and identity checks`、`Render the release notes from the template`、`publish` job | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact，不建 Release） |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job（`gh release create --prerelease --draft`） | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，不读版本化的 [v0.1.0-alpha.1 Release 说明](release-notes-v0.1.0-alpha.1.md)；若要用后者作为草稿正文，需在草稿编辑页手工粘贴并填入实际 SHA-256 |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | Release Issue 的“真机 smoke 记录” | `./Scripts/smoke.sh` 已在本机（Apple Silicon 真机）通过，版本值见 Release 说明的“本机实测环境与版本”一节；仍待填入 Issue |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | `v0.1.0-alpha.1` 是本项目第一个 alpha，没有上一版资产可回退；Issue 中记为“不适用（首个 alpha）” |

本节的边界：C1–C4 只在 CI 上运行，本机没有对应的实测输出，不要写成已在本机验证；C5–C6 的产物
（ZIP、checksum、证据、Release 正文）由 workflow 生成，本机 `dist/` 下的同名文件只是演练产物。
本节新增后按同一命令链重跑过一次以上本地命令，退出码与标记均与表中一致（只有本地打包的
SHA-256 每次都不同，原因见上）。

## 发布执行结果（v0.1.0-alpha.1）

- **发布状态**：已发布为 prerelease，非草稿：<https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.1>
- **Tag 与提交**：`v0.1.0-alpha.1` → `ea9df60`（main）；`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` / bundle id 与 tag、bundle、Release 标题一致（`sh Scripts/check-release-version.sh v0.1.0-alpha.1` 退出 0）。
- **Release workflow**：run `35417813221`（macos-14，arm64）全绿，含 `xcodebuild build/test`、脚本构建、身份检查、smoke launch、ZIP/checksum/签名证据打包与 draft 生成。
- **下载产物复核（Apple M4 / macOS 27.0 / arm64）**：`shasum -a 256 -c` 通过；`codesign --verify --deep --strict` 通过（`adhoc`，`TeamIdentifier=not set`）；`unzip -l` 9 项且无源码/测试/日志/个人路径；对下载产物运行 `PI_WEB_DESKTOP_SMOKE=1` 输出 `smoke: ready` 且退出 0。
- **SHA-256**：`aa6c51851adb3cc457191fb96f7f08b6b34810ec335b07666cc91af4ebedd915`
- **macOS 14 边界**：macOS 14 层面的验证由 CI 的 `macos-14` runner 承担；本机证据的系统版本为 macOS 27.0，两者在 Release 说明与 Issue #15 中分别标注，不混同。

### 发布过程中修复的两个真实缺陷

1. `release.yml` 的 publish 任务没有 checkout，`gh` 无法定位仓库（`failed to run git: fatal: not a git repository`）→ 显式使用 `GH_REPO` 与 `--repo`（PR #43）。
2. Finder/iCloud 写入的 `com.apple.FinderInfo` 等扩展属性会让 `codesign --verify --deep --strict` 失败并使 `package-release.sh` 中断（CI 干净 checkout 不触发）→ `build.sh` / `package-release.sh` 在签名与打包前清理扩展属性（PR #42）。

### 发布后遗留（不阻断 alpha.1）

安全审查 R 清单中的低风险项已建 Issue：#38（R-1/R-2 脱敏缺口与幂等）、#39（R-3 启动路径地址校验）、#40（R-9 `APP_STEM` 白名单）、#41（R-7/R-11 门禁处理未跟踪文件与 README 表述）。

## 本次发布执行记录（v0.1.0-alpha.2）

本节记录 `v0.1.0-alpha.2` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

- 被测候选提交：`98e4f71`（`chore(release): v0.1.0-alpha.2 版本 bump、发布说明与文档更新`）；
  前置提交为 `c02b02d`（`fix(update): 移除 UpdateChecker 注释中的版本字面值`，见下方“发布前置修复”），
  两者共同构成候选提交
- 执行环境：Apple M4（Mac mini，`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.85.1、`@agegr/pi-web` 0.9.1
  （Homebrew 前缀下的 npm 全局安装）；`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.2` / `2`）；
  下面所有命令都在候选提交上重跑，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.2 Release 说明](release-notes-v0.1.0-alpha.2.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- 本地演练的 SHA-256 每次都不同（见 [发布流程](releasing.md#可复现性与诚实的边界)）；
  Release 说明的校验值必须从 workflow 产出的资产复制，不能使用本节的本机值

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Mach-O 64-bit executable arm64` | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.2`、`CFBundleVersion=2`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过 |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.2` | `PASSED (tag v0.1.0-alpha.2, MARKETING_VERSION 0.1.0-alpha.2, CURRENT_PROJECT_VERSION 2)`；另有 `ok tag pre-release counter 2 matches CURRENT_PROJECT_VERSION` | 退出 0，通过 |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | `valid on disk`、`satisfies its Designated Requirement` | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`Signature=adhoc`、`TeamIdentifier=not set` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`；本机不打印拒绝原因（审查 R-10） | 退出 3；未公证 ad-hoc 产物的预期结果 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh` | app exit 0（0s）；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | app exit 0（0s）；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, suppression verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 11 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`；N=11 与 alpha.1 记录相同，本提交没有新增内联标记 | 退出 0，通过（工作区已全部提交，没有未跟踪文件） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.2` | 退出 0；产出 `Pi-Web-Desktop-0.1.0-alpha.2.zip`、`.zip.sha256`、`.evidence.md`、`release-metadata.env`；元数据为 `VERSION=0.1.0-alpha.2`、`BUILD=2`、`COMMIT=98e4f71…`；证据段落含 `Signature=adhoc`、`spctl` 退出码 3 与未公证说明 | 通过 |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.2.zip` | 23 项，只有 `Pi-Web-Desktop.app/`（`_CodeSignature/`、`Info.plist`、`MacOS/PiWebDesktop`、`Resources/ApplicationIcon.icns`）与 `__MACOSX/` AppleDouble 元数据；按源码、测试、日志、`.DS_Store` 与本地绝对路径前缀逐一过滤后无命中 | 通过 |
| 15 | checksum 复验 | `cd dist && shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.2.zip.sha256` | `Pi-Web-Desktop-0.1.0-alpha.2.zip: OK` | 退出 0，通过 |
| 16 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig`（见下方“发布前置修复”） | 通过 |

### 发布前置修复：`Sources/UpdateChecker.swift` 的版本字面值

- 现象：PR #50 在 `Sources/UpdateChecker.swift` 的 User-Agent 文档注释里写了与下一版相同的版本
  字面值。`MARKETING_VERSION` bump 到 `0.1.0-alpha.2` 后，`check-identity.sh` 的“xcconfig 之外
  不得出现版本字面值”门禁命中该注释，`check-identity.sh` 退出 1，`package-release.sh`（内部调用
  `check-identity.sh`）随之失败。
- 处置：提交 `c02b02d` 只把该注释改成占位形态，不改变逻辑（`userAgent` 仍从 Info.plist 读取
  版本）。该改动不在 #19 原本允许的写范围内（“只改 `Configuration/`、`docs/`、`README.md`”），
  由发布 worker 作为解除门槛的最小改动单独提交，便于维护者单独 revert。
- 现状：该门禁在候选提交上退出 0；如果维护者不接受改动 `Sources/`，revert `c02b02d` 后
  `check-identity.sh` 会重新失败，`v0.1.0-alpha.2` 不能发布。

### 仍需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖 |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds` | 本机只检查了脚本产物，由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`；该步骤由 CI 覆盖 |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；Issue 中记录 run 链接 |
| C5 | Release 资产校验：ZIP/`.sha256`/证据上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的打包与渲染步骤 | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact） |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，若要用版本化正文需在草稿编辑页粘贴 [v0.1.0-alpha.2 Release 说明](release-notes-v0.1.0-alpha.2.md) 并填入实际 SHA-256 |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | Release Issue 的“真机 smoke 记录” | `./Scripts/smoke.sh` 已在本机（Apple Silicon 真机）通过，版本值见 Release 说明的“本机实测环境与版本”一节；仍待填入 Issue |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | `v0.1.0-alpha.1` 已作为 prerelease 发布，资产应在 Releases 中仍可下载；发布时在 Issue 中确认 |

本节的边界：C1–C4 只在 CI 上运行，本机没有对应的实测输出，不要写成已在本机验证；C5–C6 的产物
（ZIP、checksum、证据、Release 正文）由 workflow 生成，本机 `dist/` 下的同名文件只是演练产物。
`v0.1.0-alpha.2` **没有新的独立安全审查**：[alpha.1 安全与发布审查](security-review-alpha.1.md)
的审查对象是 alpha.1，本版本的安全门槛 S1–S8 仍须在候选提交上重跑并把结论写入 Release Issue；
审查报告的 R-1、R-2、R-3、R-7、R-9、R-11 已在 #15 与 PR #45–#48 修复，R-4、R-5、R-6、R-8、
R-10 按非阻断风险在 Release 说明的“已知问题”一节逐条列出。

### 本次没有改动的、仍写死 alpha.1 的位置（超出 #19 的写范围）

- `.github/ISSUE_TEMPLATE/bug_report.yml` 的 `placeholder` 仍是 `0.1.0-alpha.1`。
- `SECURITY.md` 的受影响版本示例与“当前只有 alpha 基线”一句仍写 `0.1.0-alpha.1`。

两处都属于会随版本变化的引用，但不在本次允许修改的路径（`Configuration/AppIdentity.xcconfig`、
`docs/`、`README.md`）内，因此原样保留，留给后续文档 Issue 处理。

## 本次发布执行记录（v0.1.0-alpha.3）

本节记录 `v0.1.0-alpha.3` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

- 被测候选提交：本记录所在的发布提交（`chore(release): v0.1.0-alpha.3 版本 bump、发布说明、安全审查与门槛执行记录`）；
  功能代码的最后一个提交是 `4c53df0`（#58，更新事务、验证能力边界与有限回滚）。本节与版本 bump、
  Release 说明、安全审查、README/文档同步在同一个提交里；命令在提交前的同一工作区上执行，
  提交后按同一命令链复核过一次（结果与下表一致）。
- 执行环境：Apple M4（Mac mini，`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.85.1、`@agegr/pi-web` 0.9.1
  （Homebrew 前缀下的 npm 全局安装）；`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.3` / `3`）；
  下面所有命令都在候选提交上重跑，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.3 Release 说明](release-notes-v0.1.0-alpha.3.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- 本地演练的 SHA-256 每次都不同（见 [发布流程](releasing.md#可复现性与诚实的边界)）；
  Release 说明的校验值必须从 workflow 产出的资产复制，不能使用本节的本机值
- 本版**新增一份独立的只读安全审查**：[alpha.3 更新流水线安全审查（delta）](security-review-alpha.3.md)，
  只覆盖 #16–#23 的更新流水线，服务/密钥/脱敏规则/CI 等沿用 [alpha.1 审查](security-review-alpha.1.md)

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Mach-O 64-bit executable arm64` | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.3`、`CFBundleVersion=3`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过 |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.3` | `PASSED (tag v0.1.0-alpha.3, MARKETING_VERSION 0.1.0-alpha.3, CURRENT_PROJECT_VERSION 3)`；另有 `ok tag pre-release counter 3 matches CURRENT_PROJECT_VERSION` | 退出 0，通过 |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | `valid on disk`、`satisfies its Designated Requirement` | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`Signature=adhoc`、`TeamIdentifier=not set` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`；本机不打印拒绝原因（审查 R-10） | 退出 3；未公证 ad-hoc 产物的预期结果 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh` | app exit 0（0s）；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | app exit 0（0s）；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, suppression verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 11 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`；N=11 与 alpha.1/alpha.2 记录相同，本次没有新增内联标记 | 退出 0，通过（工作区已全部提交，没有未跟踪文件） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.3` | 退出 0；产出 `Pi-Web-Desktop-0.1.0-alpha.3.zip`、`.zip.sha256`、`.evidence.md`、`release-metadata.env`；元数据为 `VERSION=0.1.0-alpha.3`、`BUILD=3`；证据段落含 `Signature=adhoc`、`spctl` 退出码 3 与未公证说明 | 通过 |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.3.zip` | 23 项，只有 `Pi-Web-Desktop.app/`（`_CodeSignature/`、`Info.plist`、`MacOS/PiWebDesktop`、`Resources/ApplicationIcon.icns`）与 `__MACOSX/` AppleDouble 元数据；按源码、测试、日志、`.DS_Store` 与用户主目录绝对路径前缀过滤后 0 命中 | 通过 |
| 15 | checksum 复验 | `cd dist && shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.3.zip.sha256` | `Pi-Web-Desktop-0.1.0-alpha.3.zip: OK` | 退出 0，通过 |
| 16 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |

### 本版本的安全审查结论（更新流水线 delta）

- 审查报告：[docs/security-review-alpha.3.md](security-review-alpha.3.md)（只读；没有修改 `Sources/`、
  `Scripts/`、`.github/`）。
- 范围：#16–#23 的更新流水线（三条执行器的命令/环境/超时、三套规划器的前置条件、进程保护的
  只读枚举与遮罩、五层验证与三态、阶段化事务与有限降级、更新相关本地状态与用户可见文案）。
  服务所有权、Keychain、监听地址、脱敏规则本身、CI/发布脚本、依赖供应链、CSP/WebKit 与网站数据
  沿用 [alpha.1 审查](security-review-alpha.1.md)，本版没有重新审计。
- 结论：**阻断项 0 项**（B1–B8 全部未触发）；新增 9 条非阻断风险 A-1 … A-9（2 条“低—中”：
  缓存可影响自动更新目标版本、Pi Web 自动安装不传 `--ignore-scripts` 且继承 `HOME`/npm 配置）。
  A-1 … A-9 与 alpha.1 的 R-4、R-5、R-6、R-8、R-10 需要在 Release Issue 里逐条给出
  “接受 / 本版本修 / 转后续 Issue”的处置。
- 审查建议的 follow-up（由协调者创建，worker 不建 Issue）：F1 缓存完整性/新鲜度约束、
  F2 `--ignore-scripts` 评估、F3 进程 argv 读取面收敛、F4 超时/放弃等待后的子进程行为与重叠更新、
  F5 有限降级判定加固；标题与内容见审查报告 §5。
- 边界说明：本次审查是“读代码 + 只读门禁 + 负向 grep”，**没有**真的打开两个自动更新开关执行
  真实安装，也**没有**做抓包、模糊测试或渗透测试；`xcodebuild test` 仍由 CI 覆盖。

### 发布说明中 #16–#23 的覆盖方式

`v0.1.0-alpha.2` 已经发布并在 Release 说明里描述了 #16–#18（组件识别、只读检查、逐类策略与忽略
版本）；`v0.1.0-alpha.3` 的 Release 说明因此把 #20–#23 写成“本版新增”，把 #16–#18 写成“alpha.2
引入、本版未改变这些行为，只有两个预留的设置位在本版生效”。这是据实描述，不要把它们写成
alpha.3 的新增功能。

### 还需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖 |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds` | 本机只检查了脚本产物，由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`；该步骤由 CI 覆盖 |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；Issue 中记录 run 链接 |
| C5 | Release 资产校验：ZIP/`.sha256`/证据上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的打包与渲染步骤 | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact） |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，若要用版本化正文需在草稿编辑页粘贴 [v0.1.0-alpha.3 Release 说明](release-notes-v0.1.0-alpha.3.md) 并填入实际 SHA-256（本版说明写的是“发布后由协调者填写”） |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | Release Issue 的“真机 smoke 记录” | `./Scripts/smoke.sh` 已在本机（Apple Silicon 真机）通过，版本值见 Release 说明的“本机实测环境与版本”一节；仍待填入 Issue |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | 本仓库本地 tag `v0.1.0-alpha.2` 指向 `7699a3b`；但清单里**没有** alpha.2 的“发布执行结果”记录，它是否已作为 prerelease 公开可下载需由协调者/维护者确认后再写进 Release Issue |

本节的边界：C1–C4 只在 CI 上运行，本机没有对应的实测输出，不要写成已在本机验证；C5–C6 的产物
（ZIP、checksum、证据、Release 正文）由 workflow 生成，本机 `dist/` 下的同名文件只是演练产物。

### 本版同时做的文档一致性改动

- `README.md`：把“更新与隐私”“已知限制”里与 #22/#23 有关的表述改成与实现一致——扩展包有
  “询问后更新”但仍无无人值守更新；回滚能力有限的准确表述；更新验证不做代码签名确认。
- `docs/architecture.md`：更新“尚未实现（后续 issue 范围）”条目（改为：桌面应用自身更新、下载缓存
  与内容哈希/签名校验、更完整的回滚策略、非 npm/pnpm 全局来源的自动更新）；删除“更新检查、设置
  与缓存”一节里重复了一次的“请求边界 / 可信度 / 缓存 / 失败隔离”四条（alpha.2 起就存在的重复）。
- `docs/development.md`：支持矩阵的“应用内更新”一行改为与 #20–#23 实现一致。
- `docs/settings-and-workspace.md`、`docs/releasing.md`、`docs/privacy.md`、`docs/logging-and-diagnostics.md`
  已由功能提交同步，本次复核没有发现与实现矛盾的表述，因此未改动。

### 仍未处理的旧版本引用（超出本次写范围）

- `.github/ISSUE_TEMPLATE/bug_report.yml` 的 `placeholder` 仍是 `0.1.0-alpha.1`。
- `SECURITY.md` 的受影响版本示例与“当前只有 alpha 基线（`0.1.0-alpha.1`）”仍写 `0.1.0-alpha.1`。

两处都是会随版本变化的引用，但不在本次允许修改的路径内，因此原样保留；建议的 follow-up issue
（由协调者创建）标题：`docs: 让 SECURITY.md 与 issue 模板的版本引用不再写死具体 alpha 版本`
（内容：把 `SECURITY.md` 的示例改为“见 `Configuration/AppIdentity.xcconfig`”或当前版本占位，
把 bug 模板的 `placeholder` 改为不带具体版本的写法，避免每次发布都要改两处）。

## 本次发布执行记录（v0.1.0-alpha.4）

本节记录 `v0.1.0-alpha.4` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

- 被测候选提交：本记录所在的发布提交（`chore(release): v0.1.0-alpha.4 版本 bump、发布说明、安全审查与门槛执行记录`）；
  功能/加固代码的最后一个提交是 `1c5210c`（#70，超时/放弃等待的「已放弃」记录与同一组件的重叠防护）。
  本节与版本 bump、Release 说明、安全审查、README/文档同步在同一个提交里；命令在提交前的同一工作区上
  执行，提交后按同一命令链复核过一次（结果与下表一致）。
- 执行环境：Apple M4（Mac mini，`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.85.1、`@agegr/pi-web` 0.9.1
  （Homebrew 前缀下的 npm 全局安装）；`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.4` / `4`）；
  下面所有命令都在候选提交上重跑，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.4 Release 说明](release-notes-v0.1.0-alpha.4.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- 本地演练的 SHA-256 每次都不同（见 [发布流程](releasing.md#可复现性与诚实的边界)）；
  Release 说明的校验值必须从 workflow 产出的资产复制，不能使用本节的本机值
- 本版**新增一份独立的只读安全审查**：[alpha.4 更新流水线安全审查（delta）](security-review-alpha.4.md)，
  范围限定为 alpha.3 → alpha.4 的改动（#59–#63 / PR #66–#70 的代码与文档）；服务/密钥/脱敏规则/CI 等
  沿用 [alpha.1 审查](security-review-alpha.1.md)，alpha.3 已覆盖但本次未改动的部分沿用
  [alpha.3 审查](security-review-alpha.3.md)

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Mach-O 64-bit executable arm64` | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.4`、`CFBundleVersion=4`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过 |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.4` | `PASSED (tag v0.1.0-alpha.4, MARKETING_VERSION 0.1.0-alpha.4, CURRENT_PROJECT_VERSION 4)`；另有 `ok tag pre-release counter 4 matches CURRENT_PROJECT_VERSION` | 退出 0，通过 |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | `valid on disk`、`satisfies its Designated Requirement` | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`Signature=adhoc`、`TeamIdentifier=not set` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`；本机不打印拒绝原因（审查 R-10） | 退出 3；未公证 ad-hoc 产物的预期结果 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh` | app exit 0；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | app exit 0；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, suppression verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 11 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`；N=11 与 alpha.1/alpha.2/alpha.3 记录相同，本次没有新增内联标记 | 退出 0，通过（工作区已全部提交，没有未跟踪文件） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.4` | 退出 0；产出 `Pi-Web-Desktop-0.1.0-alpha.4.zip`、`.zip.sha256`、`.evidence.md`、`release-metadata.env`；元数据为 `VERSION=0.1.0-alpha.4`、`BUILD=4`；证据段落含 `Signature=adhoc`、`spctl` 退出码 3 与未公证说明 | 通过 |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.4.zip` | 23 项，只有 `Pi-Web-Desktop.app/`（`_CodeSignature/`、`Info.plist`、`MacOS/PiWebDesktop`、`Resources/ApplicationIcon.icns`）与 `__MACOSX/` AppleDouble 元数据 | 通过 |
| 15 | checksum 复验 | `cd dist && shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.4.zip.sha256` | `Pi-Web-Desktop-0.1.0-alpha.4.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k dist/Pi-Web-Desktop-0.1.0-alpha.4.zip <临时目录>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.4`、`CFBundleVersion=4`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |

### 本版本的安全审查结论（alpha.3 → alpha.4 delta）

- 审查报告：[docs/security-review-alpha.4.md](security-review-alpha.4.md)（只读；没有修改 `Sources/`、
  `Scripts/`、`.github/`）。
- 范围：#59–#63（PR #68、#69、#66、#67、#70）涉及的更新流水线代码与文档——检查结果来源与缓存校验、
  npm 生命周期脚本策略、进程保护的候选筛选与遮罩、降级证据等级、超时/放弃等待记录与重叠防护、
  独立进程组与信号边界、以及新增的持久键。服务所有权、Keychain、监听地址、脱敏规则本身、CI/发布
  脚本、依赖供应链、CSP/WebKit 与网站数据沿用 [alpha.1 审查](security-review-alpha.1.md)，本版没有
  重新审计。
- 结论：**阻断项 0 项**（B1–B9 全部未触发）；新增 6 条非阻断风险 N-1 … N-6（全部“低”）：内容哈希
  不可得时的元数据回退、记账式的重叠防护、展示用的 npm `integrity`、进程组信号与回收之间的窄时序
  窗口（分析结论，未动态验证）、缓存回退只影响提示但仍可被同用户投喂、新增记录可被同用户写入以
  阻断自动更新并展示受控文本。
- 上一版 A-1 … A-9 的复核（详细证据见报告 §4）：**A-1 闭环**（自动安装面）；**A-6、A-7 的自动路径
  闭环**（保留“不确认派生进程结束”“不检测被放弃进程存活”的记账式残余）；**A-3、A-4、A-5 部分闭环**；
  **A-2、A-8、A-9 按现状接受**（A-2 的结论与静态证据已由 #60 写进代码、日志与文档；A-9 新增一类键）。
- 审查建议的 follow-up（由协调者创建，worker 不建 Issue）：F1 内容哈希不可得时的降级判定、F2 让
  重叠防护能判断被放弃的进程是否仍在运行、F3 明确 npm `integrity` 是展示证据、F4 发进程组信号前确认
  子进程未被回收、F5 缓存回退提示层的完整性约束、F6 记录「已放弃」记录的同用户可写边界；标题与内容
  见审查报告 §7。A-2 与 A-8 已明确为“接受”，不需要新 issue。
- 边界说明：本次审查是“读 diff + 读代码 + 只读门禁 + 负向 grep”，**没有**真的打开两个自动更新开关
  执行真实安装，也**没有**做动态测试、抓包、模糊测试或渗透测试；没有在本机运行 `xcodebuild test`。

### 发布说明中 #59–#63 的覆盖方式

`v0.1.0-alpha.3` 的 Release 说明已经把 #16–#23 的行为写清楚；`v0.1.0-alpha.4` 的 Release 说明因此
把 #59、#60、#61、#63、#62 写成“本版新增/加固”（依次对应 PR #68、#69、#66、#67、#70），并明确
本版**没有新增功能面**。#16–#23 的既有能力不重复描述，只在“自动更新的准确边界”“已知问题”两节里
更新受影响的条件（新增“检查结果来源必须是本次网络结果”与“无未清除的『已放弃』记录”两条前置）。
据实描述，不要把本版写成引入新功能。

### 还需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖。本版新增的 XCTest 文件：`PiWebDesktopTests/UpdateAbandonedAttemptTests.swift`，以及 `UpdateCheckerTests` / `UpdateTransactionTests` / `PiProcessInspectorTests` / `PiWebUpdateAdapterTests` / `PiPackageUpdateAdapterTests` / `PiCLIUpdateAdapterTests` / `UpdateSettingsTests` 的增量用例 |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds` | 本机只检查了脚本产物，由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`；该步骤由 CI 覆盖 |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；Issue 中记录 run 链接 |
| C5 | Release 资产校验：ZIP/`.sha256`/证据上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的打包与渲染步骤 | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact） |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，若要用版本化正文需在草稿编辑页粘贴 [v0.1.0-alpha.4 Release 说明](release-notes-v0.1.0-alpha.4.md) 并填入实际 SHA-256（本版说明写的是“发布后由协调者填写”） |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | Release Issue 的“真机 smoke 记录” | `./Scripts/smoke.sh` 已在本机（Apple Silicon 真机）两种模式通过，版本值见 Release 说明的“本机实测环境与版本”一节；仍待填入 Issue |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | 本地 tag `v0.1.0-alpha.3` 指向 `e367e06`；它是否已作为 prerelease 公开可下载、`v0.1.0-alpha.2` 的同类确认是否完成，需由协调者/维护者确认后再写进 Release Issue |
| C9 | tag 只能创建一次、且必须指向本发布提交 | 维护者操作 + `Scripts/check-release-version.sh`（CI 里由 `release.yml` 调用） | 由协调者执行；本机只验证了脚本在 `v0.1.0-alpha.4` 上退出 0（未创建 tag、未 push） |

本节的边界：C1–C4、C5–C6 与 C9 只在 CI / workflow / 维护者操作里完成，本机没有对应的实测输出，
不要写成已在本机验证；本机 `dist/` 下的同名文件只是演练产物。

### 本版同时做的文档一致性改动

- `README.md`：“更新与隐私”补上三条本版新事实——缓存回退只提示、不参与自动更新；自动更新用的是
  你自己的 npm、会运行包声明的安装脚本（不想这样就把开关保持关闭）；一次更新超时会被记成
  「已放弃、结束时间未知」的记录，下次启动会提示并且不会自动重复。
- `docs/privacy.md`：两处——补上“手动『立即更新 Pi Web…』同样要求目标版本来自本次网络检查”
  （与实现一致：该入口也走同一条 `PiWebUpdatePlanner.decide`），并在本地数据一览的 UserDefaults
  行里补上三个「已放弃」键的字段范围（无结束时间、单个键可清除）。「已放弃」记录一段复核后与
  实现一致（可见性与清除位置、超时语义、独立进程组与信号边界）。
- `docs/settings-and-workspace.md`：给 Pi Web / Pi CLI / 扩展包三条自动判定各补一句“目标版本必须
  来自本次网络检查结果（GitHub #59：缓存回退与无结果都不自动执行）”，与三条适配器的 `decide`
  硬前置对齐；其余表述复核后与实现一致。
- `docs/architecture.md`、`docs/logging-and-diagnostics.md`：已在功能提交（#59–#63）里同步；本次
  逐条复核“检查结果来源 / 缓存校验 / 生命周期脚本 / 候选筛选与遮罩 / 证据等级 / 「已放弃」记录与
  重叠防护”的表述，没有发现与实现矛盾的句子，因此没有改动。
- 本版说明与安全审查是本版新增的两份文档，链接已从 `docs/releasing.md` 之外的既有文档与 Release 说明
  交叉引用（发布说明注释里的相关文档列表）。

### 仍未处理的旧版本引用（超出本次写范围）

- `.github/ISSUE_TEMPLATE/bug_report.yml` 的 `placeholder` 仍是 `0.1.0-alpha.1`。
- `SECURITY.md` 的受影响版本示例与“当前只有 alpha 基线”一句仍写 `0.1.0-alpha.1`。

两处都是会随版本变化的引用，但不在本次允许修改的路径内，因此原样保留；建议的 follow-up issue
（由协调者创建）标题与内容与 alpha.2/alpha.3 记录相同：
`docs: 让 SECURITY.md 与 issue 模板的版本引用不再写死具体 alpha 版本`
（内容：把 `SECURITY.md` 的示例改为“见 `Configuration/AppIdentity.xcconfig`”或当前版本占位，
把 bug 模板的 `placeholder` 改为不带具体版本的写法，避免每次发布都要改两处）。

## 本次发布执行记录（v0.1.0-alpha.5）

本节记录 `v0.1.0-alpha.5` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

- 被测候选提交：本记录所在的发布提交（`chore(release): v0.1.0-alpha.5 版本 bump、发布说明、安全评审与门槛执行记录 (#97)`）；
  功能/加固代码的最后一个提交是 `6821ecd`（#95，应用自更新安装器改为可重入并拒绝重叠 install）。
- 执行环境：Apple M4（Mac mini，`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.86.0、`@agegr/pi-web` 0.9.1；
  `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.5` / `5`）；
  下面所有命令都在候选提交上执行，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- 本地演练的 SHA-256 每次都不同（见 [发布流程](releasing.md#可复现性与诚实的边界)）；
  Release 说明的校验值必须从 workflow 产出的资产复制，不能使用本节的本机值
- **本机边界**：第 6、13–16 项在同步目录之外的临时 worktree（`/tmp/alpha5-rehearsal`，提交 `838cb25`）
  上执行。原因是本机工作区在 `~/Documents`（iCloud 同步目录）内，File Provider 会把
  `com.apple.FinderInfo` 贴回 bundle，让 `codesign --verify --deep --strict` 失败并中断
  `package-release.sh`（与 alpha.1 记录的 #15 同类；不改变发布流程：CI runner 在干净 checkout 上
  运行，不在同步目录内，不受影响）
- 本版**新增一份独立的只读安全审查**：[alpha.5 更新流水线与工具 PATH 安全审查（delta）](security-review-alpha.5.md)，
  范围限定为 alpha.4 → alpha.5 的改动（#72–#93 / PR #76–#95）；服务所有权与 Keychain、监听地址、
  脱敏规则本身、CI/发布脚本、依赖供应链、CSP/WebKit 等沿用
  [alpha.1 审查](security-review-alpha.1.md)，alpha.4 已覆盖但本次未改动的部分沿用
  [alpha.4 审查](security-review-alpha.4.md)

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | 首次在同步目录内失败：`resource fork, Finder information, or similar detritus not allowed`；`rm -rf build/Pi-Web-Desktop.app` + `xattr -cr build` 后重跑退出 0：`Built: build/Pi-Web-Desktop.app`、`Mach-O 64-bit executable arm64` | 清理后通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.5`、`CFBundleVersion=5`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过 |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.5` | `check-release-version: PASSED (tag v0.1.0-alpha.5, MARKETING_VERSION 0.1.0-alpha.5, CURRENT_PROJECT_VERSION 5)` | 退出 0，通过 |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 同步目录内失败两次（`code has no resources but signature indicates they must be present`、`resource fork, Finder information, or similar detritus not allowed`）；在 `/tmp/alpha5-rehearsal` 的打包流程内通过：`valid on disk`、`satisfies its Designated Requirement` | 同步目录内失败（环境问题，同 #15）；演练 worktree 通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=PiWebDesktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x20002(adhoc,linker-signed)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Info.plist=not bound`、`Sealed Resources=none`（主仓库脚本构建产物，是 linker 签名；与 alpha.4 记录里的 `Identifier=io.github.su-luoya.pi-web-desktop` 不同）；演练 worktree 打包后的 bundle 为 `Identifier=io.github.su-luoya.pi-web-desktop`、`Sealed Resources version=2 rules=13 files=1` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`；`spctl exited with status 3: Gatekeeper did not accept the bundle, which is the expected result for an ad-hoc, non-notarized app` | 退出 3；未公证 ad-hoc 产物的预期结果 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh` | app exit 0 after 0s；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | app exit 0 after 1s；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | 各条 `self-test: ok: …` 全部打印后：`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)` | 退出 0，通过（工作区已全部提交，没有未跟踪文件） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.5`（在 `/tmp/alpha5-rehearsal`） | 同步目录内两次失败（先是 `code has no resources…`，重试后 `Disallowed xattr com.apple.FinderInfo found on …`）；演练 worktree 内 `package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip`（1,506,741 字节，SHA-256 `fb71823f68a4…`）、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.5`、`BUILD=5`、`COMMIT=838cb25…`） | 演练 worktree 通过；发布产物由 workflow 在 tag 上生成 |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip`（在 `/tmp/alpha5-rehearsal`） | 9 项：`Pi-Web-Desktop.app/` 与 `Contents/{,_CodeSignature,MacOS,Resources}` 四个目录，加 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`、无源码/测试/日志/个人路径 | 通过 |
| 15 | checksum 复验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip.sha256`（在 `/tmp/alpha5-rehearsal/dist`） | `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k <zip> <mktemp -d>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.5`、`CFBundleVersion=5`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |

**第 12 项的 N=15 归因（与 alpha.4 记录的 11 不同）**：本次确实新增了内联标记，用
`grep -c 'scan-secrets: allow'` 在 `v0.1.0-alpha.4` 与本工作区上对逐个文件核对，计数为：
`PiWebDesktopTests/ToolPathTests.swift` alpha.4 不存在 / 本版 6（#89 新增文件）、
`PiWebDesktopTests/PiWebUpdateAdapterTests.swift` 0 / 2（#95）、
`PiWebDesktopTests/KeychainStoreTests.swift` 0 / 1、`PiWebDesktopTests/ServiceManagerTests.swift`
0 / 1、`PiWebDesktopTests/UpdateTransactionTests.swift` 0 / 1、`PiWebDesktopTests/LogWriterTests.swift`
3 / 6；同时 #78 收紧了抑制标记格式（旧的无 `reason` 标记按违规处理，见本版自检项）。15 行全部是
`PiWebDesktopTests/` 里的脱敏与环境夹具（`// scan-secrets: allow(reason=…)`），没有在 `Sources/`
里新增标记。本地未运行也没有新规则的完备性结论：`--self-test` 只证明已写下的规则会触发。

本节的边界：第 3、6、7、13 项在同步目录内不是全部通过——是 iCloud/File Provider 的
`com.apple.FinderInfo` 环境问题（与 alpha.1 的 #15 同类），不是代码缺陷；第 6、13–16 项已在
`/tmp/alpha5-rehearsal`（提交 `838cb25`）上重跑并通过，第 7 项记录的是主仓库脚本构建产物的
`codesign -dv`。`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行仍不在本机
范围（本机 `xcode-select -p` 指向 Command Line Tools，没有 Xcode，也没有 GUI 交互环境）。
- 复现与处置（iCloud 扩展属性）：`xattr -l` 可见 `com.apple.FinderInfo` 与
  `com.apple.fileprovider.fpfs#P`；`xattr -cr` 后立即校验退出 0，约 15 秒后再校验又失败 —— File
  Provider 会在打包脚本清理之后把属性重新贴回，所以 `package-release.sh` 的防御性清理与重试一次
  覆盖不了这种持续重贴。本次因此用 `git worktree add /tmp/alpha5-rehearsal 838cb25`（detached）
  在同步目录之外重跑构建/打包/解包复验，演练后用 `git worktree remove` 清理（未 push 分支、未留提交）。
  影响面仅限本机演练：CI runner 在干净 checkout 上运行，`release.yml` 的打包与签名步骤不受影响，
  发布流程、产物命名与校验方式不变。

### 本版本的安全审查结论（alpha.4 → alpha.5 delta）

- 审查报告：[docs/security-review-alpha.5.md](security-review-alpha.5.md)（585 行，只读；没有修改
  `Sources/`、`Scripts/`、`.github/`，也没有打 tag、push 或跑打包脚本）。
- 范围：`git diff v0.1.0-alpha.4..838cb25`，即 #72–#93 / PR #76–#95（12 个修复提交 + 1 个版本 bump 提交，
  55 个文件、+10547 / −1045 行）。本版**没有新增功能面**，全部是修复与加固；新增两个独立文件
  `Sources/QuitCoordinator.swift`（286 行）与 `Sources/ToolPath.swift`（584 行）及对应测试。
  服务所有权与 Keychain、监听地址、脱敏规则本身、CI/发布脚本、依赖供应链、CSP/WebKit 与网站数据
  沿用 [alpha.1 审查](security-review-alpha.1.md)，alpha.4 已覆盖但本次未改动的部分沿用
  [alpha.4 审查](security-review-alpha.4.md)。
- 结论：**阻断项 0 项**（B1–B9 全部未触发），高严重性发现 0 条；新增 1 条中危（M-1）与 7 条低危
  （L-1 … L-7），另有 3 条信息级记录（I-1 … I-3）。全部落在可用性 / 同一用户可写状态 / 证据强度 /
  门禁覆盖四类，没有一条能造成权限提升、凭据外泄、向非自己启动的进程发信号或不可逆的文件破坏。
- M-1（中，可用性，未实测）：`Sources/PiWebApp.swift:166-174` 在 `AppDelegate.init` 里解析 PATH，
  单次启动最坏约 26 秒不返回主线程（登录 shell `-lc` 3 s + 交互式 `-ilc` 3 s + `npm prefix -g` 10 s
  + `/usr/bin/env node -p process.execPath` 10 s）。
- L-1 … L-7（低，各一行）：L-1 合并 PATH 让更新子进程多了一批用户可写搜索目录，且 npm 解析取 PATH
  首个可执行文件；L-2 应用退出时更新子进程的 stdout/stderr 读端不移交；L-3「放弃等待」不终止子进程，
  跨重启只有持久记录与用户确认；L-4 诊断与外部进程信息的遮罩是模式化的，导出内容含本机路径；
  L-5 `scan-secrets.sh` 的逐行 `allow(reason=…)` 仍是「任意一行可免检」；L-6 退出决策的 5 分钟兜底
  在无人值守场景会推迟注销/关机并保持服务运行；L-7 登录 shell 查询子进程继承应用环境，与探测环境的
  「去凭据」策略不一致。
- I-1 … I-3（信息）：I-1 扩展包入口没有「重启应用可恢复」提示（发布说明自陈的边界，审查确认属实）；
  I-2 版本/发布校验链只做了只读观察（未执行 `package-release.sh` / `build.sh`，因此对「打包产物是否
  能绕过 bundle 内容白名单」无法判定）；I-3 指出的发布说明不一致已在本版修掉——
  `docs/release-notes-v0.1.0-alpha.5.md` 原先写「本版没有新增 `docs/security-review-alpha.5.md`」，
  已改为链接本报告。
- §4 上一版遗留项复核（报告 §4.1）：**部分缓解** N-1、N-2、N-5、A-3、A-4、A-5、A-7；**维持已闭环** A-1；
  **仍存在** N-3、N-4、N-6、A-2、A-6、A-8、A-9（其中 A-2、A-6、A-8 按现状接受）。alpha.4 的
  F1 … F6：F1、F5 **部分处理**，F2、F3、F4、F6 **未处理**。
- 审查建议的处置（报告 §4.2，供 Release Issue 用）：建议本版接受、不追加修复 A-2、A-6、A-8、L-6；
  建议转后续 Issue：N-3 / F3、N-4 / F4、N-6 / F6、L-3、L-7；建议评估是否本版修：M-1、L-1、L-2、L-5；
  不需要新 issue：N-1 / A-4 / F1。报告没有另列编号式 follow-up 清单（§7 不存在）。
- 审查边界：只读（读 diff + 读代码 + 只读门禁 + 负向 grep），**不是**动态测试或渗透测试；**没有**
  真实执行过一次更新（没有跑 `npm install -g` / `pi update --self` / `pi update npm:<包名>`），
  **没有**跑 `xcodebuild test`，也没有验证签名/公证。M-1 的真实耗时、L-1 的伪造 `npm`/`node` 是否
  真被采用、L-2 的 EPIPE 行为、遮罩与扫描规则的完备性（含 N-4 的 PID 复用窗口）均在报告 §5.2 标为
  未实测或无法判定。

### 发布说明中 #72–#93 的覆盖方式

- `v0.1.0-alpha.5` 的 [Release 说明](release-notes-v0.1.0-alpha.5.md) 把 12 组 issue/PR 逐条成节：
  #72 / PR #76（退出决策移出 AppKit 终止序列）、#74 / PR #77（缓存回退结论按本机版本现算）、
  #75 / PR #78（秘密扫描规则补齐、抑制标记收紧）、#73 / PR #79（子进程输出走管道 + 串行 `O_APPEND`）、
  #81 / PR #87（设置窗口单例、诊断导出后台化、argv 遮罩）、#88 / PR #90（CI 抖动：确定性排空屏障）、
  #80 / PR #84（服务启动/停止状态机代次校验与会话预算）、#82 / PR #85（遮罩与依赖探针补齐）、
  #83 / PR #86（发布脚本加固）、#89 / PR #91（依赖探测统一使用合并后的工具 `PATH`）、
  #92 / PR #94（扩展包执行器每轮独立状态、身份与回滚结论不超出证据）、
  #93 / PR #95（应用自更新安装器可重入、事务门控、菜单不跨组件误伤）。
- 发布说明同时写明**本版没有新增功能面**：12 节全部是修复与加固；每条都有“边界与未验证”或
  代价说明（例如退出行为的 GUI 手工验收未执行、菜单的“重启应用可恢复”提示只覆盖 CLI / Web
  两个入口、#94 的 B-4/B-5/B-8…B-13 与 W2A 的 F5/F6/F7 未修）。
- 未修项写在“已知问题”节，不隐藏：W2B 剩余条目（B-4、B-5、B-8…B-13）、W2A 的 F5/F6/F7、
  两套安装失败文案、扩展包 `PiPackageUpdateRunning` 缺 `isRunning`、`abandon()` 在排水宽限窗口
  仍可能写一条不实的「已放弃」记录、「重启应用可恢复」提示只覆盖两个入口（均带 `Sources/...:line`）。
- “已知问题”里同时列出了本版**已在本机实测**与**仍未在本机执行**的项，并写明打包/签名类步骤
  在 `~/Documents` 之外的临时工作区执行（iCloud File Provider 会把 `com.apple.FinderInfo` 贴回
  bundle），与本节第 1 张表一致，不把两者混同。

### 还需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖。本版新增的 XCTest 文件：`PiWebDesktopTests/QuitCoordinatorTests.swift`（#72）、`PiWebDesktopTests/ToolPathTests.swift`（#89）；`PiWebDesktopTests/` 下另外 16 个既有文件带增量用例（`git diff --name-only v0.1.0-alpha.4..6821ecd -- PiWebDesktopTests/` 共 18 个文件），其中 #94 改动 `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`、`PiWebDesktopTests/UpdateTransactionTests.swift`，#95 改动 `PiWebDesktopTests/PiWebUpdateAdapterTests.swift`、`PiWebDesktopTests/PiCLIUpdateAdapterTests.swift`、`PiWebDesktopTests/UpdateAbandonedAttemptTests.swift`、`PiWebDesktopTests/UpdateTransactionTests.swift` |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds`（`check-identity.sh --test-bundle …`） | 本机只检查了脚本产物（`check-identity: PASSED (45 checks)`），Xcode 产物与 `.xctest` 由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`（自检 + 仓库扫描）；该步骤由 CI 覆盖 |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；Issue 中记录 run 链接。合并前各提交的 CI 结果：#94 的 `b99e501` pass 4m23s、`87f124b` pass；#95 的 `6622b5d` pass 3m34s；合并后 main `6821ecd` pass 4m16s（run `35491357493`） |
| C5 | Release 资产校验：ZIP/`.sha256`/`.evidence.md` 上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的 `Package ZIP, checksum, signature evidence and identity checks`、`Render the release notes from the template`、`publish` job | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact）。本机演练的产物在 `/tmp/alpha5-rehearsal/dist`，不是发布资产。workflow 渲染模板时用 `release-metadata.env` 注入版本/build/ZIP 名/SHA-256；模板里残留 `{{` 会让渲染失败，`<待填写>` 只产生提示不失败 |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job（`gh release create --prerelease --draft`） | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，不读版本化的 [v0.1.0-alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md)。该说明的“本机实测环境与版本”与“已知问题”两节可直接用作草稿依据，但“校验值”一节的值是本机演练值，发布前需在草稿编辑页换成 workflow 产物的真值 |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | Release Issue #97 的“真机 smoke 记录” | **本版已写入**：Apple M4（`Mac16,10`）、macOS 27.0（`26A428`）、arm64、Node.js v24.21.0、npm 11.19.0、Pi CLI 0.86.0、`@agegr/pi-web` 0.9.1；本机 `smoke.sh` 两种模式均已通过（见第 1 张表第 9、10 项） |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | 上一版是 `v0.1.0-alpha.4`（本地 tag 指向 `f9a2af1`）；它是否已作为 prerelease 公开可下载需由维护者确认后写进 Release Issue（不能写成本机已验证） |
| C9 | tag 只能创建一次、且必须指向本发布提交 | 维护者操作 + `Scripts/check-release-version.sh`（CI 里由 `release.yml` 调用） | 由协调者执行；本机只验证了脚本在 `v0.1.0-alpha.5` 上退出 0（**未创建 tag、未 push**） |

本节的边界：C1–C6 与 C9 只在 CI / workflow / 维护者操作里完成，本机没有对应的实测输出，
不要写成已在本机验证；第 1 张表里标注在 `/tmp/alpha5-rehearsal` 执行的行是本机演练，不是发布产物。

### 本版同时做的文档一致性改动

- `docs/release-notes-v0.1.0-alpha.5.md`（本版说明）：五处——① “校验值”填入本机演练的 ZIP 名、
  字节数与 SHA-256，并明确标注“本机演练、不是发布产物”，删掉 `FILL-AFTER-PACKAGE` 注释与“本文件
  不含任何哈希或字节数”的旧表述；② “构建与签名验证记录”从“未运行”改为本次实测输出（含 iCloud/
  File Provider 边界与 `/tmp/alpha5-rehearsal`）；③ “已知问题”末条拆成“仍未在本机执行 / 验证”与
  “已在本机实测”两条；④ “本机实测环境与版本”的应用包身份行改为实测值；⑤ “文档与仓库同步”补上
  “本版新增并提交了安全评审”，文末“待补值清单”改为指向 `release.yml` 产物。
- `docs/security-review-alpha.5.md`（本版新增）：I-3 指出的发布说明不一致已由本记录所在提交修掉。
- 本文件：新增本节（alpha.5 执行记录、安全审查结论、#72–#93 覆盖方式、C 项与文档一致性清单）。
- `README.md`、`docs/privacy.md`、`docs/settings-and-workspace.md`、`docs/architecture.md`、
  `docs/logging-and-diagnostics.md`、`docs/releasing.md`：逐条复核后与实现一致，**未改动**。其中
  四份文档已由功能提交（#72–#95）同步：`docs/privacy.md:74-87` 已有“登录 shell PATH 查询（GitHub #89）”
  一节（含 `-lc` / `-ilc`、3 秒上限、去凭据子进程环境与“不落盘”的表述），`README.md:182`、`:189`
  的自动更新硬前置与“已放弃”记录描述与 `PiWebUpdateAdapter` 实现一致；`docs/releasing.md:333`
  要求把 `scan-secrets: suppressed N lines` 记入门槛证据，与本版实际输出（N=15、无 `rejected` 行）
  一致。

### 仍未处理的旧版本引用（超出本次写范围）

- `.github/ISSUE_TEMPLATE/bug_report.yml:16` 的 `placeholder` 仍是 `0.1.0-alpha.1`。
- `SECURITY.md:11` 的受影响版本示例仍是 `0.1.0-alpha.1` / build `1`；`SECURITY.md:28` 的“项目只承诺
  评估最新 alpha 或最新稳定发行版。当前只有 alpha 基线（`0.1.0-alpha.1`）”也仍写 `0.1.0-alpha.1`。

两处都是会随版本变化的引用，但不在本次允许修改的路径内，因此原样保留；建议的 follow-up issue
（由协调者创建）标题与内容与 alpha.2/alpha.3/alpha.4 记录相同：
`docs: 让 SECURITY.md 与 issue 模板的版本引用不再写死具体 alpha 版本`
（内容：把 `SECURITY.md` 的示例改为“见 `Configuration/AppIdentity.xcconfig`”或当前版本占位，
把 bug 模板的 `placeholder` 改为不带具体版本的写法，避免每次发布都要改两处）。

## 本次发布执行记录（v0.1.0-alpha.6）

本节记录 `v0.1.0-alpha.6` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

- 被测候选提交：本记录所在的发布提交（`chore(release): v0.1.0-alpha.6 版本 bump、发布说明、安全评审与门槛执行记录 (#111)`）；
  功能/加固代码的最后一个提交是 `8b591c9`（#104，README 重写），此前依次是 `a47dd46`（#102，更新
  失败文案与放弃等待记录）与 `3306398`（#100，设置窗口可缩放）。
- 执行环境：Apple M4（`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.86.0、`@agegr/pi-web` 0.9.1；
  `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.6` / `6`）；
  下面所有命令都在候选提交上执行，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.6 Release 说明](release-notes-v0.1.0-alpha.6.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- 本地演练的 SHA-256 每次都不同（见 [发布流程](releasing.md#可复现性与诚实的边界)）；
  Release 说明的校验值必须从 workflow 产出的资产复制，不能使用本节的本机值
- **本机边界**：本次演练在 `~/Documents`（iCloud 同步目录）**之外**的 worktree
  （`~/orca/workspaces/Pi-Web/release-alpha-6`，分支 `HaotianDeng/release-alpha-6`）里执行，
  因此没有再遇到 alpha.5 记录的 iCloud File Provider 把 `com.apple.FinderInfo` 贴回 bundle 的问题
  （与 alpha.1 的 #15 同类）；发布流程不变，CI runner 在干净 checkout 上运行
- 本机打包发生在“版本 bump 已写入工作区、但发布提交尚未创建”的状态下，
  `dist/release-metadata.env` 的 `COMMIT` 记的是打包时的工作区 `HEAD`（`8b591c9`）；因此演练 ZIP
  **不等于**发布资产，发布资产由 `release.yml` 在 tag 上重新打包

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` | 退出 0，通过（本次没有 iCloud 扩展属性问题） |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.6`、`CFBundleVersion=6`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过 |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.6` | `check-release-version: PASSED (tag v0.1.0-alpha.6, MARKETING_VERSION 0.1.0-alpha.6, CURRENT_PROJECT_VERSION 6)` | 退出 0，通过（脚本只做字符串比对，**不检查 tag 是否存在**；本次 tag 尚未创建） |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 无输出（`valid on disk` / `satisfies its Designated Requirement`） | 退出 0，通过（与 alpha.5 不同：本次在同步目录之外，不需要 `/tmp` 演练 worktree） |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 | 退出 3，预期 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh`（脚本内含两种模式） | app exit 0 after 1s；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | app exit 0 after 0s；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | 各条 `self-test: ok: …` 全部打印后：`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)` | 退出 0，通过；N=15 与 alpha.5 记录一致（本版没有新增抑制标记，逐行清单见 alpha.5 记录） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.6` | `package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip`（1,510,257 字节，SHA-256 `febf404bfe90…`）、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.6`、`BUILD=6`、`COMMIT=8b591c966e05a5f9b37de76f0fb11abc37be56fa`）；脚本同时复验“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（无 `__MACOSX/`）” | 通过（演练值；发布产物由 workflow 在 tag 上生成） |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip` | 9 项：`Pi-Web-Desktop.app/` 与 `Contents/{,_CodeSignature,MacOS,Resources}` 四个目录，加 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`、无源码/测试/日志/个人路径 | 通过 |
| 15 | checksum 复验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip.sha256` | `Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k <zip> <mktemp -d>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.6`、`CFBundleVersion=6`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |

本节的边界：第 13–16 项是**本机演练**（`COMMIT=8b591c9`、版本 bump 尚未提交时打包），不是发布
资产；`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行仍不在本机范围（本机
`xcode-select -p` 指向 Command Line Tools，没有 Xcode）。第 6、7 项的差异（alpha.5 需要
`/tmp` 演练 worktree）只反映执行位置不同，不是代码或流程变化。

### 发布说明中 #99–#104 的覆盖方式

- `v0.1.0-alpha.6` 的 [Release 说明](release-notes-v0.1.0-alpha.6.md) 把本版三组改动逐条成节：
  #99 / PR #100（设置窗口可自由缩放、表单滚动、底部按钮固定）、#101 / PR #102（更新失败文案、
  扩展包门闩的「已放弃等待、退出未确认」区分、包与 CLI 在排水宽限窗口不再写不实的「已放弃」记录）、
  #103 / PR #104（README 重写为面向普通用户的说明）。
- 发布说明同时写明**本版没有新增功能面**，并逐项写清边界：信号语义未变、三条路径仍不确认被放弃
  进程是否结束、仍不保证所有来源都能回滚、更新检查的域名/频率/开关未变（沿用 alpha.5 说明的两节）。
- 未修项写在“已知问题”节并指向本版新建的跟进 issue：#105（验证器边界 B-4/B-5/B-11）、
  #106（降级状态与文案 B-8/B-10 与 `UpdateTransaction.swift:394`/`:513` 两套文案）、
  #107（扩展包执行器 B-12/B-13 与 `PiPackageUpdateRunning` 缺 `isRunning`）、
  #108（Web/CLI 输出与放弃等待窗口 B-9/F5/F6/F7，含 `PiWebUpdateAdapter.stopWaitingLocked`）。
- 发布说明的“构建与签名验证记录”与“本机实测环境与版本”两节与本记录第 1 张表一致，不把演练值
  当发布值。

### 本版本的安全审查结论（alpha.5 → alpha.6 delta）

- 审查报告：[docs/security-review-alpha.6.md](security-review-alpha.6.md)（本版新增，只读；没有修改仓库文件）。
  审查范围 `git diff d6fa883..8b591c9`（3 个提交、10 个文件、+403 / −213 行），基线是
  [alpha.5 安全评审](security-review-alpha.5.md)；alpha.1 已覆盖且本次未改动的部分沿用
  [alpha.1 审查](security-review-alpha.1.md)。
- **结论：阻断项 0**（中 1、低 5、信息 5）。中危 M-1：`Sources/UpdateTransaction.swift:394` 的
  `displayName` 仍写「更新失败，仍在使用旧版本」，与同一弹窗里的 `:732-734`「没有执行任何回滚动作」互斥
  ——该文件**不在本 delta 内**，是既有代码，本版登记为已知问题（#106），不阻断发布。
- 低危：L-1 三路日志仍写「旧版本保持不变」；L-2 `detectedVersion == nil` 时「仍在使用更新前的版本」
  句内不自洽；L-3 CLI 的 `.updateAlreadyInProgress` 文案缺「重启应用可恢复」；L-4 超时重试上限
  （5 × 0.2 s）之后仍可能落一条有界的失实「已放弃」记录；L-5 扩展包 runner 退出时不 `abandon()`，重启
  恢复可能与仍在运行的旧 `npm` 子进程重叠。信息级 I-1 … I-5 记录结论（新门闩只改文案、排水窗口守卫不会
  漏结算、未引入新能力、设置窗口只改布局、README 安全表述一致）。
- 非阻断项的处置：M-1 / L-1 / L-2 → #106；L-3 / L-4 → #108；L-5 → #107；I-1 … I-5 仅记录。
- 报告自述的边界（不要写成已实测）：它是**自动化只读审查、不是人工审计**，未编译、未运行测试、未运行
  GUI；M-1 的用户可见弹窗拼接与 L-4 的时序结论均为按代码路径的推断。本机未执行的验证由 CI 与维护者的
  GUI 验收覆盖。

### 还需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖。本版新增/改动的测试只有 `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`（+94 行）与 `PiWebDesktopTests/PiCLIUpdateAdapterTests.swift`（+59 行），共 5 个确定性用例（#102） |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds`（`check-identity.sh --test-bundle …`） | 本机只检查了脚本产物（`check-identity: PASSED (45 checks)`），Xcode 产物与 `.xctest` 由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`（自检 + 仓库扫描）；该步骤由 CI 覆盖 |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；本版三个提交的 main run 均为 **success**：`3306398`（#100）run `35493841592`、`a47dd46`（#102）run `35494635211`、`8b591c9`（#104）run `35494836484` |
| C5 | Release 资产校验：ZIP/`.sha256`/`.evidence.md` 上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的 `Package ZIP, checksum, signature evidence and identity checks`、`Render the release notes from the template`、`publish` job | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact）。本机演练产物在 `dist/`，不是发布资产 |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job（`gh release create --prerelease --draft`） | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，不读版本化的 [v0.1.0-alpha.6 Release 说明](release-notes-v0.1.0-alpha.6.md)。发布前需把该说明的正文、以及 workflow 产物的 ZIP 名/SHA-256/字节数填进草稿 |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | 本版 Release Issue 的“真机 smoke 记录” | **本版已写入**：Apple M4（`Mac16,10`）、macOS 27.0（`26A428`）、arm64、Node.js v24.21.0、npm 11.19.0、Pi CLI 0.86.0、`@agegr/pi-web` 0.9.1；本机 `smoke.sh` 两种模式均已通过（见第 1 张表第 9、10 项） |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | 上一版是 `v0.1.0-alpha.5`；它是否仍作为 prerelease 公开可下载需由维护者确认后写进 Release Issue（不能写成本机已验证） |
| C9 | tag 只能创建一次、且必须指向本发布提交 | 维护者操作 + `Scripts/check-release-version.sh`（CI 里由 `release.yml` 调用） | 由协调者执行；本机只验证了脚本在 `v0.1.0-alpha.6` 上退出 0（**未创建 tag、未 push**） |

本节的边界：C1–C6 与 C9 只在 CI / workflow / 维护者操作里完成，本机没有对应的实测输出，
不要写成已在本机验证。

### 本版同时做的文档一致性改动

- `docs/release-notes-v0.1.0-alpha.6.md`（本版新增）：三组改动逐条成节；“更新检查与自动更新的
  边界”一节明确本版没有改动域名、频率、开关与自动更新前置条件，并链接 alpha.5 说明的两节；
  “校验值”一节区分演练值与 `release.yml` 的发布值；文末“发布时需要补全的值清单”在发布前删除。
- `Configuration/AppIdentity.xcconfig`（本版唯一版本来源）：`MARKETING_VERSION` → `0.1.0-alpha.6`、
  `CURRENT_PROJECT_VERSION` → `6`。
- `docs/security-review-alpha.6.md`（本版新增）：alpha.5 → alpha.6 的只读 delta 安全评审，结论为阻断项 0；
  它同时是 Release Issue 里 S1–S8 复核命令与 M/L/I 发现的证据来源。
- `Sources/UpdateTransaction.swift` **不在本 delta 内**，本版未改动它；M-1 指出的矛盾文案保留为已知问题（#106）。
- 本文件：新增本节（alpha.6 执行记录、覆盖方式、C 项与文档一致性清单）。
- 逐条复核后与实现一致、**未改动**：`README.md`（本版重写后的版本）、`docs/privacy.md`、
  `docs/settings-and-workspace.md`、`docs/architecture.md`、`docs/logging-and-diagnostics.md`、
  `docs/releasing.md`。其中 `docs/settings-and-workspace.md` 已由 #100 同步（窗口缩放与折行行为），
  `docs/architecture.md` 已由 #102 同步。

### 仍未处理的旧版本引用（超出本次写范围）

- `.github/ISSUE_TEMPLATE/bug_report.yml:16` 的 `placeholder` 仍是 `0.1.0-alpha.1`。
- `SECURITY.md:11` 的受影响版本示例仍是 `0.1.0-alpha.1` / build `1`；`SECURITY.md:28` 的“项目只承诺
  评估最新 alpha 或最新稳定发行版。当前只有 alpha 基线（`0.1.0-alpha.1`）”也仍写 `0.1.0-alpha.1`。

这两处从 alpha.2 起就被逐版记录为“超出本次写范围”。本版的处理是：把一直建议的 follow-up 落地成
一个真实 issue（见本版 Release Issue 的关联项），而不是继续在每版记录里重复同一句建议。

## 本次发布执行记录（v0.1.0-alpha.7）

本节记录 `v0.1.0-alpha.7` 候选提交上**实际执行过**的本地门槛与输出摘要，供 Release Issue 与草稿
Release 使用；未在本机执行的门槛在第 2 张表里单独标出，不要把它们写成已实测。

**发布结果（回填于 2026-09-20）**：发布提交经 PR [#122](https://github.com/Su-luoya/pi-web-desktop/pull/122)
squash 合入 main → `fba1f12`（CI run `35499346342`，`build` success）；tag `v0.1.0-alpha.7` push 后
`release.yml` run `35499610608` success，草稿 Release 填入真机表后发布为 prerelease：
<https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.7>（`2026-09-20T08:30:20Z`）。
发布资产 `Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip` 1,590,986 字节、SHA-256
`782f97ef755c596b1e458964cdc1eb4fd47a588db3e867559dccb8dc2da38c1f`，下载后 `shasum -a 256 -c` 通过、
`unzip -l` 9 个条目且无 `__MACOSX`、包内 `0.1.0-alpha.7`/`7`、`codesign --verify --deep --strict` 退出 0、
`spctl` 拒绝（未公证的预期结果）。

- 被测候选提交：本记录所在的发布提交（`chore(release): v0.1.0-alpha.7 版本 bump、发布说明、安全
  评审与门槛执行记录 (#122)`）；功能/加固代码的最后一个提交是 `4e6e332`（#108），此前依次是
  `fbae499`（#107）、`0c1610c`（#106）、`be13c88`（#109）、`9ede020`（#113）、`af47866`（#105），
  基线是 `b162544`（`v0.1.0-alpha.6` 发布提交）。
- 执行环境：Apple M4（`Mac16,10`）、macOS 27.0（`26A428`）、arm64；Node.js v24.21.0、
  npm 11.19.0、Pi CLI（`@earendil-works/pi-coding-agent`）0.86.0、`@agegr/pi-web` 0.9.1；
  `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- 版本与 build 的唯一来源仍是 `Configuration/AppIdentity.xcconfig`（`0.1.0-alpha.7` / `7`）；
  下面所有命令都在候选提交上执行，输出摘要为本次实际输出
- 同一批事实也写在 [v0.1.0-alpha.7 Release 说明](release-notes-v0.1.0-alpha.7.md) 的
  “本机实测环境与版本”与“构建与签名验证记录”两节
- 本地演练的 SHA-256 每次都不同（见 [发布流程](releasing.md#可复现性与诚实的边界)）；
  Release 说明的校验值必须从 workflow 产出的资产复制，不能使用本节的本机值
- **本机边界**：本次演练在 `~/Documents`（iCloud 同步目录）**之外**的 worktree
  （`~/orca/workspaces/Pi-Web/release-alpha-7`，分支 `HaotianDeng/release-alpha-7`）里执行，
  沿用 alpha.6 的做法，没有再遇到 iCloud File Provider 把 `com.apple.FinderInfo` 贴回 bundle 的问题
- 本机打包发生在“版本 bump 已写入工作区、但发布提交尚未创建”的状态下，
  `dist/release-metadata.env` 的 `COMMIT` 记的是打包时的工作区 `HEAD`（`4e6e332`）；因此演练 ZIP
  **不等于**发布资产，发布资产由 `release.yml` 在 tag 上重新打包
- 一条流程事实（本版新增记录）：`check-identity.sh` 会把**仓库文本扫描范围内的未跟踪文件**当成
  门槛失败（`FAIL 1 untracked file(s) are inside the repository text scan scope and were not scanned`）。
  本版新增的两份文档在 `git add` 之前会各触发一次这个失败，`git add` 之后复跑为
  `check-identity: PASSED (45 checks)`

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64`（重复构建时先打印 `replacing existing signature`） | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.7`、`CFBundleVersion=7`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过（首次运行因新增文档尚未 `git add` 而报 `FAILED (1 of 46 checks)`，见上条流程事实） |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.7` | `check-release-version: PASSED (tag v0.1.0-alpha.7, MARKETING_VERSION 0.1.0-alpha.7, CURRENT_PROJECT_VERSION 7)` | 退出 0，通过（脚本只做字符串比对，**不检查 tag 是否存在**；本次 tag 尚未创建） |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 无输出（`valid on disk` / `satisfies its Designated Requirement`） | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 | 退出 3，预期 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh`（脚本内含两种模式） | `app exit status 0 after 0s`；标记 `smoke: ready` | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | `app exit status 0 after 1s`；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)` | 退出 0，通过；N=15 与 alpha.5 / alpha.6 记录一致（本版没有新增抑制标记） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.7` | `package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip`（1,517,551 字节，SHA-256 `5efd8a56c49e…`）、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.7`、`BUILD=7`、`COMMIT=4e6e332e72469d835468a03ebe1e1aace623d6d3`）；脚本同时复验“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（无 `__MACOSX/`）”，并打印 `signature: adhoc (TeamIdentifier=not set), not notarized` | 通过（演练值；发布产物由 workflow 在 tag 上生成） |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip` | 9 项：`Pi-Web-Desktop.app/` 与 `Contents/{,_CodeSignature,MacOS,Resources}` 四个目录，加 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`、无源码/测试/日志/个人路径 | 通过 |
| 15 | checksum 复验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip.sha256`（在 `dist/` 内执行） | `Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k <zip> <mktemp -d>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.7`、`CFBundleVersion=7`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |

本节的边界：第 13–16 项是**本机演练**（`COMMIT=4e6e332`、版本 bump 尚未提交时打包），不是发布
资产；`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行仍不在本机范围（本机
`xcode-select -p` 指向 Command Line Tools，没有 Xcode）。

### 发布说明中 #105–#109 的覆盖方式

- `v0.1.0-alpha.7` 的 [Release 说明](release-notes-v0.1.0-alpha.7.md) 把本版四条修复与两处文档改动
  逐条成节：#105 / PR #112（验证器有界读取、`integrity` 取值确定化、目标版本不可解析判定）、
  #106 / PR #115（降级阶段结果 `applied` / `recordedOnly` / `notPossible`、探针不可用归因、两套失败
  文案收敛）、#107 / PR #117（进程保护判定先于「已放弃」记录、安装失败分支补 `applyDegradation`、
  `PiPackageUpdateRunning` 新增 `isRunning` 与 `abandonedChildrenUnconfirmed` 驱动菜单三态）、
  #108 / PR #116（增量 UTF-8 解码、`PATH` 空项与相对项拒绝、退出后排水的有界宽限与 `pendingFinish`、
  成功路径保留健康检查最终报告）、#109 / PR #114（版本引用指向唯一来源）、#113（alpha.6 校验值回填）。
- 发布说明同时写明**本版没有新增功能面**，并逐项写清边界：信号语义未变、三条路径仍不确认被放弃
  进程是否结束、仍不保证所有来源都能回滚、更新检查的域名/频率/开关未变（沿用 alpha.5 说明的两节）。
- 未修项与残留边界写在“已知问题”节，并指向仍开放的跟进 issue（见本节安全审查一节的映射）。

### 本版本的安全审查结论（alpha.6 → alpha.7 delta）

- 审查报告：[docs/security-review-alpha.7.md](security-review-alpha.7.md)（本版新增，只读评审：由发布执行者
  派发的独立只读评审在单独上下文里执行并出具清单，未修改仓库任何文件、未提交。原定由 Orca 编排里的
  只读 worker `task_b1489e938b4a` 执行，该 worker 因模型账号额度不足（`403 insufficient_user_quota`）
  中断、未产出报告，Dispatch 停在 `stop_unknown`；这一过程瑕疵与评审限制都记在报告里）。审查范围
  `git diff b162544..4e6e332`（本版六个提交），基线是
  [alpha.6 安全评审](security-review-alpha.6.md)。
- **结论：阻断项 0；中危 2 项（`F1` 主线程读扩展包执行器状态可能长时间阻塞、`F2` 扩展包执行器仍在
  有损解码路径上）、低危 4 项（`F3` 路径信任边界与 TOCTOU、`F4` FIFO 读取无超时、`F5` 排水窗口内
  `cancel()` 静默失效、`F6` Pi Web outcome 携带未脱敏输出尾巴）。六项都不改变信号语义、文件操作、
  权限范围与凭据处理，因此本版按当前提交发布；登记在
  [#121](https://github.com/Su-luoya/pi-web-desktop/issues/121)，其中 `F1`、`F2` 建议下一版修掉。**

### 还需 CI / 发布 workflow 完成

| # | 门槛 | 覆盖位置 | 本机状态与回填结果 |
| --- | --- | --- | --- |
| C1 | `xcodebuild build` / `xcodebuild test`（含 XCTest 与集成测试） | `.github/workflows/build.yml` 的 `Build and test Xcode project`；`release.yml` 的 `Build the Xcode project (arm64)` | 本机未执行（无完整 Xcode），由 CI 的 `macos-14` job 覆盖。本版新增/改动的测试集中在 `PiWebDesktopTests/UpdateTransactionTests.swift`（#105 / #106）、`PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`（#107）、`PiWebDesktopTests/PiCLIUpdateAdapterTests.swift` 与 `PiWebDesktopTests/PiWebUpdateAdapterTests.swift`（#108） |
| C2 | Xcode 产物 + `.xctest` bundle 的身份检查 | `build.yml` 的 `Check application identity of Xcode and script builds`（`check-identity.sh --test-bundle …`） | 本机只检查了脚本产物（`check-identity: PASSED (45 checks)`），Xcode 产物与 `.xctest` 由 CI 覆盖 |
| C3 | CI personal-data `git grep` 步骤 | `build.yml` 的 `Check for accidental personal data` | 本机只复现了 `scan-secrets.sh`（自检 + 仓库扫描）；该步骤由 CI 覆盖 |
| C4 | main CI 在候选提交之后仍为绿 | `build.yml` 的 `push: branches: [main]` 运行 | 由 CI 覆盖；本版六个提交的 main run 均为 **success**：`af47866`（#112）run `35496917660`、`9ede020`（#113）run `35497135814`、`be13c88`（#114）run `35497336171`、`0c1610c`（#115）run `35497649990`、`fbae499`（#117）run `35497954810`、`4e6e332`（#116）run `35498186531` |
| C5 | Release 资产校验：ZIP/`.sha256`/`.evidence.md` 上传、`sha256sum -c`、Release 说明渲染 | `release.yml` 的 `Package ZIP, checksum, signature evidence and identity checks`、`Render the release notes from the template`、`publish` job | 由 workflow 覆盖（tag push 时执行；`workflow_dispatch` 只产出 artifact）。本机演练产物在 `dist/`，不是发布资产；结果见本节开头的「发布结果」（run `35499610608`） |
| C6 | 草稿 prerelease 创建与发布前人工复核（assets 名称、checksum 与 Issue 一致、prerelease 勾选） | `release.yml` 的 `publish` job（`gh release create --prerelease --draft`） | 由 workflow + 维护者完成；workflow 渲染的是 [Release notes 模板](release-notes-template.md)，不读版本化的 [v0.1.0-alpha.7 Release 说明](release-notes-v0.1.0-alpha.7.md)。发布前需把该说明的正文、以及 workflow 产物的 ZIP 名/SHA-256/字节数填进草稿；结果：草稿由 `publish` job 创建，协调者把版本化说明正文与真机表填进草稿后 `gh release edit --draft=false`，于 `2026-09-20T08:30:20Z` 发布为 prerelease（<https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.7>） |
| C7 | 真机 smoke 的机器与依赖版本写入 Release Issue | 本版 Release Issue 的“真机 smoke 记录” | 机器与依赖版本同“执行环境”一条（Apple M4 / macOS 27.0 `26A428` / arm64 / Node.js v24.21.0 / npm 11.19.0 / Pi CLI 0.86.0 / `@agegr/pi-web` 0.9.1）；本机 `smoke.sh` 两种模式均已通过（见第 1 张表第 9、10 项）；已写入 Release 说明的「实测版本」表与 Release Issue #118 的发布评论（`2026-09-20`） |
| C8 | 上一版资产的回退路径确认 | Release Issue 的“回退路径确认” | 上一版是 `v0.1.0-alpha.6`；确认结果（`2026-09-20`，`gh release list` / `gh release view v0.1.0-alpha.6`）：它仍是已发布的 prerelease（`2026-09-20T07:25:04Z`），ZIP / `.sha256` / `.evidence.md` 三个资产都在，回退路径成立 |
| C9 | tag 只能创建一次、且必须指向本发布提交 | 维护者操作 + `Scripts/check-release-version.sh`（CI 里由 `release.yml` 调用） | 由协调者执行：tag `v0.1.0-alpha.7` 已创建一次（注释 tag，指向合并提交 `fba1f12`）并 push；`release.yml` 在 tag 上调用 `check-release-version.sh` 通过；本机另外单独验证过该脚本在 `v0.1.0-alpha.7` 上退出 0 |

本节的边界：C1–C6 与 C9 的检查在 CI / workflow / 维护者操作里完成，本机没有对应的实测输出；表格里 `2026-09-20` 的回填结果来自 workflow 产物与维护者操作，不要写成已在本机验证。

### 本版同时做的文档一致性改动

- `docs/release-notes-v0.1.0-alpha.7.md`（本版新增）：四条修复 + 两处文档改动逐条成节；“更新检查与
  自动更新的边界”一节沿写本版没有改动域名、频率、开关与自动更新前置条件；“校验值”一节区分演练值
  与 `release.yml` 的发布值（发布后回填）。
- `Configuration/AppIdentity.xcconfig`（本版唯一版本来源）：`MARKETING_VERSION` → `0.1.0-alpha.7`、
  `CURRENT_PROJECT_VERSION` → `7`。
- `docs/security-review-alpha.7.md`（本版新增）：alpha.6 → alpha.7 的只读 delta 安全评审。
- `SECURITY.md`、`.github/ISSUE_TEMPLATE/bug_report.yml`：不再写死 `0.1.0-alpha.1`，改为指向
  `Configuration/AppIdentity.xcconfig`（#109 / PR #114）。从 alpha.2 起被逐版记录为“超出本次写范围”
  的两处旧版本引用至此关闭。
- `docs/architecture.md`、`docs/settings-and-workspace.md`：由 #106 / #107 / #108 同步（降级阶段结果、
  计划判定顺序与菜单三态、三个适配器的排水与放弃等待描述）。
- 本文件：新增本节（alpha.7 执行记录、覆盖方式、C 项与文档一致性清单）。

## 本次发布执行记录（v0.1.0-alpha.8）

本记录对应 `v0.1.0-alpha.8`（PR #125 合并后的发布提交）。候选提交是 `c4f26a1`（PR #125 squash 合入
`main` 的提交，`build.yml` run `35501956085` **success**）。本版只有这一个代码提交，除此之外只有发布
提交本身（版本 bump、发布说明、安全评审与本节的记录）。

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.8`、`CFBundleVersion=8`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过（首次运行报 `FAILED (1 of 46 checks)`：本版新增的两份文档尚未 `git add`，未跟踪文件不在文本扫描范围内；`git add -A` 后重跑通过） |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.8` | `check-release-version: PASSED (tag v0.1.0-alpha.8, MARKETING_VERSION 0.1.0-alpha.8, CURRENT_PROJECT_VERSION 8)` | 退出 0，通过（脚本只做字符串比对，**不检查 tag 是否存在**；本次 tag 尚未创建） |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 无输出（`valid on disk` / `satisfies its Designated Requirement`） | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 | 退出 3，预期 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh`（脚本内含两种模式） | 标记 `smoke: ready`（app 退出 0） | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | 标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready`（app 退出 0） | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)` | 退出 0，通过；N=15 与 alpha.5 / alpha.6 / alpha.7 记录一致（本版没有新增抑制标记） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.8` | `package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip`（1,520,630 字节，SHA-256 `74aabbe2447e…`）、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.8`、`BUILD=8`、`COMMIT=c4f26a1c28886c2c79d17e85907c6be6c1b6a8a1`）；脚本同时复验“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（无 `__MACOSX/`）”，并打印 `signature: adhoc (TeamIdentifier=not set), not notarized` | 通过（演练值；发布产物由 workflow 在 tag 上生成） |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip` | 9 项：`Pi-Web-Desktop.app/` 与 `Contents/{,_CodeSignature,MacOS,Resources}` 四个目录，加 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`、无源码/测试/日志/个人路径 | 通过 |
| 15 | checksum 复验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip.sha256`（在 `dist/` 内执行） | `Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k <zip> <mktemp -d>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.8`、`CFBundleVersion=8`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |
| 18 | 更新事务与执行器测试 | `REPO=$PWD sh /private/tmp/piweb-testkit/run.sh UpdateVerifierTests.swift PiPackageUpdateAdapterTests.swift UpdateTransactionTests.swift PiWebUpdateAdapterTests.swift PiCLIUpdateAdapterTests.swift` | `UpdateVerifierTests` 9、`PiPackageUpdateAdapterTests` 56、`UpdateTransactionTests` 35、`PiWebUpdateAdapterTests` 44、`PiCLIUpdateAdapterTests` 44，共 **188 passed、0 failed** | 通过（本机没有完整 Xcode：用 `/private/tmp/piweb-testkit` 的 XCTest shim 逐文件运行；权威结果是 CI 的 `xcodebuild test`） |

本节的边界：第 13–16 项是**本机演练**（打包时 `COMMIT=c4f26a1`，发布提交尚未创建），不是发布资产；
`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行仍不在本机范围（本机
`xcode-select -p` 指向 Command Line Tools，没有 Xcode）。第 18 项是本地 shim 的结果。

### 发布说明中 #119 / #120 / #121 / #124 的覆盖方式

| issue | 本版改的内容 | 发布说明里的位置 | 证据 |
| --- | --- | --- | --- |
| [#119](https://github.com/Su-luoya/pi-web-desktop/issues/119) | 日志尾句改成「本次没有执行任何回滚动作」；`detectedVersion == nil` 不再句内自相矛盾；Pi CLI 的「更新进行中」拒绝补上恢复提示 | 摘要第 1 条、第 1 节 | `Sources/PiCLIUpdateAdapter.swift`、`Sources/PiWebUpdateAdapter.swift`、`Sources/PiPackageUpdateAdapter.swift`、`Sources/PiWebApp.swift`；`PiWebDesktopTests/PiWebUpdateAdapterTests.swift` 的旧断言同步更新 |
| [#121](https://github.com/Su-luoya/pi-web-desktop/issues/121) | `F1` 完成回调改走专用投递队列；`F2` UTF-8 分块解码在 EOF 冲刷；`F4` 只在常规文件上读取；`F5` 取消落在收尾窗口时被记录；`F6` 失败输出先脱敏；`F3` 信任边界写入文档 | 摘要第 2 条、第 2 节、第 5 节 | `Sources/PiPackageUpdateAdapter.swift`、`Sources/UpdateVerifier.swift`、`Sources/PiWebUpdateAdapter.swift`、`docs/security-ownership.md`、`docs/architecture.md`；测试：`UpdateVerifierTests` 9 例 + 包执行器两个用例 |
| [#124](https://github.com/Su-luoya/pi-web-desktop/issues/124) | npm `integrity` 的基准版本固定为本次更新的目标版本（同一条 `node_modules` 路径、同一个包名） | 摘要第 3 条、第 3 节 | `Sources/UpdateVerifier.swift`、`Sources/UpdateTransaction.swift`；`UpdateTransactionTests.testIdentityWordingFollowsTheEvidenceSource` |
| [#120](https://github.com/Su-luoya/pi-web-desktop/issues/120) | 测试面 `T-1` / `T-2` / `T-3` | 摘要第 4 条、第 4 节 | 新增 `PiWebDesktopTests/UpdateVerifierTests.swift`（9 个对抗用例，`PiWebDesktop.xcodeproj/project.pbxproj` 四处登记）+ 三个行为用例 |

### 本版本的安全审查结论（alpha.7 → alpha.8 delta）

- 范围：`git diff 3ed1a09..c4f26a1`（本版唯一的提交，PR #125）。
- 报告：`docs/security-review-alpha.8.md`（本版新增，只读评审）。
- 结论：阻断项 **0 条**，非阻断项 **5 条**（`L-1` 四条 nil 版本日志行仍写「旧版本保持不变」；`L-2` 本文档关于 `integrity` 基准的措辞——本版已按代码实际语义「更新前已安装的版本」改正；`L-3` `openRegularFile` 的类型检查与打开之间的 TOCTOU 窗口；`L-4` 排水宽限到期结束时不冲刷增量解码器暂存；`L-5` 既有的「已放弃等待」日志行）。评审确认 `#121` / `#120` 的修法与测试按主张落实、`#124` 的代码语义正确，给出**不阻断发布**的结论；未在本版处理的四项登记在 [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127)。

### 还需 CI / 发布 workflow 完成

| # | 检查 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- |
| C1 | PR CI（候选提交 `c4f26a1`） | `build.yml` run `35501956085` | **success** |
| C2 | 发布提交的 CI | `build.yml` run `35502904190`（`5f8f38b`） | **success** |
| C3 | `git tag -a v0.1.0-alpha.8` 指向发布提交 | tag `v0.1.0-alpha.8` → `5f8f38b`（PR #128 squash 合入 `main`） | 已推送（`git push origin v0.1.0-alpha.8`） |
| C4 | `release.yml`（tag push 触发） | run `35502909886` | **success**（`2026-09-20T09:39:25Z` → `09:42:39Z`） |
| C5 | 草稿 prerelease 的正文与真机表 | `Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip`（1,594,019 字节）/ SHA-256 `f90df492376aed022356b74f48e1e47140566e55d07dc3f809b3b873beb88c76`；正文已填真机表与已知问题 | 已完成（本机重新下载三个资产复核：`shasum -a 256 -c` → `OK`、ZIP 内 9 项无 `__MACOSX`、包内 `0.1.0-alpha.8` / `8`、`codesign --verify` 退出 0） |
| C6 | 真机 macOS 与 Node / pi / pi-web 版本 | Apple M4（`Mac16,10`）/ macOS 27.0（`26A428`）arm64 / Node v24.21.0 / pi 0.86.0 / `@agegr/pi-web` 0.9.1；`smoke.sh` 双模式通过（`items=6 blockers=3`） | 已写入 Release 正文 |
| C7 | `gh release edit --draft=false`（prerelease） | 发布时间 `2026-09-20T09:43:25Z`（prerelease） | 已完成 |
| C8 | 回退路径（上一版资产仍在 Releases） | `v0.1.0-alpha.7`（`2026-09-20T08:30:20Z`，3 个资产：ZIP / `.sha256` / `.evidence.md`） | 已核实 |
| C9 | 回填 Release issue 的 run 链接与 SHA-256、关闭 issue | issue #126（回填评论 + 关闭） | 已完成 |

本节的边界：C2–C4 与 C9 在 CI / workflow / 维护者操作里完成，本机没有对应的实测输出；C5–C7 的正文
与真机表由维护者在本机填写，其中 C5 的资产已在本机重新下载复核（表格内的 `OK` 与包内版本都来自
那次复核，不是 workflow 日志）。

### 本版同时做的文档一致性改动

- `Configuration/AppIdentity.xcconfig`（本版唯一版本来源）：`MARKETING_VERSION` → `0.1.0-alpha.8`、
  `CURRENT_PROJECT_VERSION` → `8`。
- `docs/release-notes-v0.1.0-alpha.8.md`（本版新增）：四条修复逐条成节；“更新检查与自动更新的边界”
  一节沿写本版没有改动域名、频率、开关与自动更新前置条件；“校验值”一节区分演练值与 `release.yml`
  的发布值（发布后回填）；“已知问题”把上一版列出的 `L-1` / `L-2` / `L-3`、`T-1` / `T-2` / `T-3`、
  `F1` … `F6` 与 #124 移到“已修”，保留 `L-4` / `L-5` 两条按设计保留的有界窗口。
- `docs/security-review-alpha.8.md`（本版新增）：alpha.7 → alpha.8 的只读 delta 安全评审。
- `docs/security-ownership.md`：`PATH` 即信任边界（不固定可执行文件位置、不校验签名）由
  #121 / `F3` 记录。
- `docs/architecture.md`：更新适配器的结果投递与收尾窗口由 #121 / `F1`、`F2`、`F5` 同步（专用投递
  队列、管道 EOF 冲刷、取消落在收尾窗口时的记录）。
- `docs/alpha-release-checklist.md`（本文件）：新增本节（alpha.8 执行记录、覆盖方式、安全审查结论、
  C 项与文档一致性清单）。

## 本次发布执行记录（v0.1.0-alpha.9）

本记录对应 `v0.1.0-alpha.9`（PR #130 合并后的发布提交）。候选提交是 `8b7e74d`（PR #130 squash 合入
`main` 的提交，`build.yml` run `35506224959` **success**）。本版只有这一个代码提交，另有一个纯文档提交
（PR #129 回填 alpha.8 的发布值），除此之外只有发布提交本身（版本 bump、发布说明、安全评审与本节的记录）。

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` | 退出 0，通过（首次运行报 codesign 失败：iCloud 同步目录在打包后把 `com.apple.FinderInfo` 贴回临时包；`xattr -cr .` 清理后重跑通过） |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.9`、`CFBundleVersion=9`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过（首次运行报 `FAILED (1 of 46 checks)`：本版新增的两份文档尚未 `git add`，未跟踪文件不在文本扫描范围内；`git add -A` 后重跑通过） |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.9` | `check-release-version: PASSED (tag v0.1.0-alpha.9, MARKETING_VERSION 0.1.0-alpha.9, CURRENT_PROJECT_VERSION 9)` | 退出 0，通过（脚本只做字符串比对，**不检查 tag 是否存在**；本次 tag 尚未创建） |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 无输出（`valid on disk` / `satisfies its Designated Requirement`） | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 | 退出 3，预期 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh`（脚本内含两种模式） | 标记 `smoke: ready`（app 退出 0） | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | 标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready`（app 退出 0） | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)` | 退出 0，通过；N=15 与 alpha.5 … alpha.8 记录一致（本版没有新增抑制标记） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.9` | `package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.9+build.9.zip`（1,521,314 字节，SHA-256 `08728d60c960…`）、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.9`、`BUILD=9`、`COMMIT=8b7e74dda24eb41e9a2a20a4d56b63683441b686`）；脚本同时复验“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（8 条，无 `__MACOSX/`）”，并打印 `signature: adhoc (TeamIdentifier=not set), not notarized` | 通过（演练值；发布产物由 workflow 在 tag 上生成） |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.9+build.9.zip` | 9 项：`Pi-Web-Desktop.app/` 与 `Contents/{,_CodeSignature,MacOS,Resources}` 四个目录，加 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`、无源码/测试/日志/个人路径 | 通过 |
| 15 | checksum 复验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.9+build.9.zip.sha256`（在 `dist/` 内执行） | `Pi-Web-Desktop-0.1.0-alpha.9+build.9.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k <zip> <mktemp -d>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.9`、`CFBundleVersion=9`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |
| 18 | 更新事务与执行器测试 | `REPO=$PWD sh /private/tmp/piweb-testkit/run.sh UpdateVerifierTests.swift` 等五个文件（逐个运行） | `UpdateVerifierTests` 9、`PiPackageUpdateAdapterTests` 57、`UpdateTransactionTests` 36、`PiWebUpdateAdapterTests` 44、`PiCLIUpdateAdapterTests` 44，共 **190 passed、0 failed** | 通过（本机没有完整 Xcode：用 `/private/tmp/piweb-testkit` 的 XCTest shim 逐文件运行；权威结果是 CI 的 `xcodebuild test`。并行跑多个文件时两个依赖亚秒级进程启动的既有用例会假失败，本表的数字来自串行单文件运行） |

本节的边界：第 13–16 项是**本机演练**（打包时 `COMMIT=8b7e74d`，发布提交尚未创建），不是发布资产；
`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行仍不在本机范围（本机
`xcode-select -p` 指向 Command Line Tools，没有 Xcode）。第 18 项是本地 shim 的结果。

### 发布说明中 #127 的覆盖方式

| 项 | 本版改的内容 | 发布说明里的位置 | 证据 |
| --- | --- | --- | --- |
| [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127) `L-1` | 新增 `UpdateWarningText.oldVersionClaimText(detectedVersion:)`，四处「验证失败」日志行（Pi CLI、Pi Web、扩展包两条路径）改用三态措辞 | 摘要第 1 条、第 1 节 | `Sources/UpdateTransaction.swift`、`Sources/PiCLIUpdateAdapter.swift:1350`、`Sources/PiWebUpdateAdapter.swift:1726`、`Sources/PiPackageUpdateAdapter.swift:1598` 与 `:1860`；`PiWebDesktopTests/UpdateTransactionTests.swift` 的 `testOldVersionClaimFollowsTheDetectedVersionEvidence` |
| [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127) `L-3` | `openRegularFile(atPath:)` 对已打开句柄复核 `S_IFREG`，不满足即关闭并放弃 | 摘要第 2 条、第 2 节 | `Sources/UpdateVerifier.swift`；既有用例（符号链接到常规文件可读、FIFO 不可读）继续覆盖判定结果 |
| [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127) `L-4` | `completeLocked` 在结束流程里冲刷 stdout / stderr 增量解码器 | 摘要第 3 条、第 3 节 | `Sources/PiPackageUpdateAdapter.swift`；`PiWebDesktopTests/PiPackageUpdateAdapterTests.swift` 的 `testRealExecutorDrainGraceExpiryFlushesPendingDecoderBytes` |
| [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127) `L-5` | 退出时「已放弃等待」的日志不再断言旧版本仍在原位 | 摘要第 4 条、第 4 节 | `Sources/PiWebApp.swift:1684`；退出日志的直接复核（`O-1` 之外的版本断言已消除） |

### 本版本的安全审查结论（alpha.8 → alpha.9 delta）

- 范围：`git diff 5f8f38b..8b7e74d`（本版的代码提交 PR #130，加上一个纯文档提交 PR #129）。
- 报告：`docs/security-review-alpha.9.md`（本版新增，只读评审）。
- 结论：阻断项 **0 条**，非阻断项 **0 条**。alpha.8 登记的四项（`L-1` / `L-3` / `L-4` / `L-5`）在本版全部关闭；评审另记录一条既往文案观察 `O-1`（`Sources/PiCLIUpdateAdapter.swift:1528` 与 `Sources/PiWebUpdateAdapter.swift:1883` 的持久警告以「旧版本语义保持不变：…」开头，属语义陈述而非文件位置断言，早于本版 delta，本次未改），不影响发布。

### 还需 CI / 发布 workflow 完成

| # | 检查 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- |
| C1 | PR CI（候选提交 `8b7e74d`） | `build.yml` run `35506224959` | **success** |
| C2 | 发布提交的 CI | `build.yml` run `35507032580`（`push` / `main` / head `0b52e2c`） | **success** |
| C3 | `git tag -a v0.1.0-alpha.9` 指向发布提交 | tag → `0b52e2c68e127df2deae1154682402f6e6ea0191`（`chore(release): v0.1.0-alpha.9 … (#132)`），与 `origin/main` 顶端一致 | 通过 |
| C4 | `release.yml`（tag push 触发） | run `35507037689`（`push` / `v0.1.0-alpha.9` / head `0b52e2c`）：上传 ZIP（`1595202` 字节）、`.zip.sha256`、`.evidence.md`，并创建草稿 prerelease（`2026-09-20T11:09:14Z`） | **success** |
| C5 | 草稿 prerelease 的正文与真机表 | 正文 168 行：真机表已填（值同本表 C6）、「校验值」一节含发布 SHA-256 `b03a4630…`、「已知问题」列出本版修掉的 `L-1` / `L-3` / `L-4` / `L-5` 与保留项 `O-1` | 通过 |
| C6 | 真机 macOS 与 Node / pi / pi-web 版本 | Apple M4（`Mac16,10`）/ macOS 27.0（`26A428`）arm64 / Node v24.21.0 / pi 0.86.0 / `@agegr/pi-web` 0.9.1；`smoke.sh` 双模式通过（`items=6 blockers=3`） | 已实测，已写入 Release 正文 |
| C7 | `gh release edit --draft=false`（prerelease） | 发布于 `2026-09-20T11:13:19Z`；`gh release view v0.1.0-alpha.9` 显示 `isDraft=false`、`isPrerelease=true` | 通过 |
| C8 | 回退路径（上一版资产仍在 Releases） | `v0.1.0-alpha.8`（`2026-09-20T09:43:25Z`，3 个资产：ZIP / `.sha256` / `.evidence.md`） | 已核实 |
| C9 | 回填 Release issue 的 run 链接与 SHA-256、关闭 issue | issue [#131](https://github.com/Su-luoya/pi-web-desktop/issues/131)：回填评论 <https://github.com/Su-luoya/pi-web-desktop/issues/131#issuecomment-5749441365>；issue 已由 PR #132 的 `Closes #131` 在 `2026-09-20T11:09:09Z` 关闭 | 通过 |

本节的边界：C2–C5、C7 与 C9 的输出来自 CI / workflow / 维护者操作，不是本机脚本的直接输出；C5–C6 的
正文与真机表由维护者填写（已写入 Release 正文）。

### 本版同时做的文档一致性改动

- `Configuration/AppIdentity.xcconfig`（本版唯一版本来源）：`MARKETING_VERSION` → `0.1.0-alpha.9`、
  `CURRENT_PROJECT_VERSION` → `9`。
- `docs/release-notes-v0.1.0-alpha.9.md`（本版新增）：四条修复逐条成节；“更新检查与自动更新的边界”
  一节沿写本版没有改动域名、频率、开关与自动更新前置条件；“校验值”一节区分演练值与 `release.yml`
  的发布值（发布后回填）；“已知问题”把 alpha.8 列出的 `L-1` / `L-3` / `L-4` / `L-5` 移到“已处理”，
  保留 `O-1` 与设计边界。
- `docs/security-review-alpha.9.md`（本版新增）：alpha.8 → alpha.9 的只读 delta 安全评审。
- `docs/architecture.md`：三处同步 —— 验证失败措辞的三态来源与退出日志（`L-1` / `L-5`）、已打开句柄上
  的类型复核（`L-3`）、排水宽限到期同样冲刷解码器（`L-4`）。
- `docs/alpha-release-checklist.md`（本文件）：新增本节（alpha.9 执行记录、覆盖方式、安全审查结论、
  C 项与文档一致性清单）。

## 本次发布执行记录（v0.1.0-alpha.10）

本版候选：PR #136（`09f1264`，功能「最近工作目录与快速切换」，关闭
[#134](https://github.com/Su-luoya/pi-web-desktop/issues/134)）之后的 main，加上本版发布提交的版本
bump 与三份文档。本节的脚本输出在**非同步目录**的候选副本里采集：
`/tmp/piweb-alpha10-rehearsal2`（`ditto --norsrc --noextattr` 的干净副本，`HEAD = 09f1264`，工作区含本版
版本 bump 与发布文档、尚未提交），原因是 iCloud 同步目录会在打包后把 `com.apple.FinderInfo` /
`com.apple.fileprovider.fpfs#P` 贴回临时包，导致 `codesign --verify` 与
`package-release.sh --self-test` 失败（alpha.1 记录的 `#15` 现象）。

### 已在候选提交上实测

| # | 门槛 | 命令 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- | --- |
| 1 | 脚本语法 | `sh -n Scripts/*.sh` | 无输出 | 退出 0，通过 |
| 2 | 空白与补丁格式 | `git diff --check` | 无输出 | 退出 0，通过 |
| 3 | 构建 | `./Scripts/build.sh` | `Built: build/Pi-Web-Desktop.app`；`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` | 退出 0，通过 |
| 4 | 身份与版本一致性 | `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.10`、`CFBundleVersion=10`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon` | 退出 0，通过（本版新增的发布文档已 `git add` 后再跑，避免未跟踪文件不进文本扫描造成假失败） |
| 5 | tag 与 bundle 版本一致 | `sh Scripts/check-release-version.sh v0.1.0-alpha.10` | `check-release-version: PASSED (tag v0.1.0-alpha.10, MARKETING_VERSION 0.1.0-alpha.10, CURRENT_PROJECT_VERSION 10)` | 退出 0，通过（脚本只做字符串比对，**不检查 tag 是否存在**；本次 tag 尚未创建） |
| 6 | 签名校验 | `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 无输出（`valid on disk` / `satisfies its Designated Requirement`） | 退出 0，通过 |
| 7 | 签名身份与公证状态 | `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` | 预期结果：ad-hoc、未公证 |
| 8 | Gatekeeper 行为 | `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 | 退出 3，预期 |
| 9 | smoke 启动模式 | `./Scripts/smoke.sh`（脚本内含两种模式） | 标记 `smoke: ready`（app 退出 0） | 通过 |
| 10 | smoke 诊断模式 | `./Scripts/smoke.sh` | 标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready`（app 退出 0） | 通过（脚本整体退出 0，两种模式都断言） |
| 11 | 扫描器自检 | `./Scripts/scan-secrets.sh --self-test` | `self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` | 退出 0，通过 |
| 12 | 仓库 secret 扫描 | `./Scripts/scan-secrets.sh` | `scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)` | 退出 0，通过；N=15 与 alpha.5 … alpha.9 记录一致（本版没有新增抑制标记） |
| 13 | 本地打包与证据 | `./Scripts/package-release.sh --tag v0.1.0-alpha.10` | `package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip`（`1526455` 字节，SHA-256 `ff47675c…`）、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.10`、`BUILD=10`、`COMMIT=09f12646a0129fe355bbd4ab6d84159076dc594d`，工作区 dirty）；脚本同时复验“包内条目固定修改时间（`200101010000`）”“归一化时间后签名仍通过”“白名单条目集合一致（8 条，无 `__MACOSX/`）”，并打印 `signature: adhoc (TeamIdentifier=not set), not notarized` | 通过（演练值；发布产物由 workflow 在 tag 上生成） |
| 14 | ZIP 内容清单 | `unzip -l dist/Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip` | 9 项：`Pi-Web-Desktop.app/` 与 `Contents/{,_CodeSignature,MacOS,Resources}` 四个目录，加 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`、无源码/测试/日志/个人路径 | 通过 |
| 15 | checksum 复验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip.sha256`（在 `dist/` 内执行） | `Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip: OK` | 退出 0，通过 |
| 16 | 包内版本与签名复验 | `ditto -x -k <zip> <mktemp -d>` + `plutil -p .../Info.plist` + `codesign --verify --deep --strict .../Pi-Web-Desktop.app` | `CFBundleShortVersionString=0.1.0-alpha.10`、`CFBundleVersion=10`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 | 通过（临时目录已删除） |
| 17 | 版本字面值门禁（回归） | `./Scripts/check-identity.sh` 第 6 节 | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` | 通过 |
| 18 | 新增功能的用例 | `REPO=$PWD sh /private/tmp/piweb-testkit/run.sh RecentWorkspaceTests.swift` | `RecentWorkspaceTests` **5 passed、0 failed** | 通过（本机没有完整 Xcode：用 `/private/tmp/piweb-testkit` 的 XCTest shim 运行新增文件；本版没有改动更新流水线，因此其它测试文件未重跑，权威结果是 CI 的 `xcodebuild test`） |

### 发布说明中 #134 的覆盖方式

| 项 | 本版改的内容 | 发布说明里的位置 | 证据 |
| --- | --- | --- | --- |
| [#134](https://github.com/Su-luoya/pi-web-desktop/issues/134) | 新增「最近工作目录与快速切换」：`RecentWorkspaceStore`（UserDefaults 单键 `workspace.recentPaths`，最多 10 条、标准化路径去重、最近优先）与纯逻辑 `WorkspaceSwitchDecision`（绝对路径 + 存在/目录/可写校验）；服务菜单子菜单（含「在 Finder 中打开当前工作目录」与「清除历史记录」）；`application(_:open:)` 统一处理拖放 / `open -a` / 「打开方式」入口；切换写 `service.workspacePath` 并重启托管服务，外部进程服务不停止不重启；`CFBundleDocumentTypes`（`public.folder`、`Editor`）使拖放可用 | 摘要第 1–3 条、第 1–3 节 | `Sources/RecentWorkspace.swift`、`Sources/PiWebApp.swift`、`Sources/AppConfiguration.swift`、`Scripts/build.sh`、`PiWebDesktopTests/RecentWorkspaceTests.swift`（5 个用例） |
| [#134](https://github.com/Su-luoya/pi-web-desktop/issues/134) 的文档同步 | `docs/settings-and-workspace.md` 新增功能节与 `CFBundleDocumentTypes` 代价；`docs/privacy.md` 补 `workspace.recentPaths`；`docs/architecture.md` 补组件与 UserDefaults 键；`README.md` 补菜单入口与拖放 | 第 4 节 | 同一提交内的四份文档改动（`git diff 21ce459..09f1264 -- docs/ README.md`） |
| [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135) | 评审的 `F1`–`F4`（重叠切换竞态、外部服务文案、open 事件处理、路径接受面加固）**不在本版修**，登记为后续迭代 | 「已知问题」第 1 小节 | `docs/security-review-alpha.10.md` 第 6 节；issue #135 |

### 本版本的安全审查结论（alpha.9 → alpha.10 delta）

- 范围：`git diff 21ce459..09f1264`（本版的代码提交 PR #136，加上一个纯文档提交 PR #133）。
- 报告：`docs/security-review-alpha.10.md`（本版新增，只读评审）。
- 结论：阻断项 **0 条**，非阻断项 **4 条**（`F1` / `F2` / `F3` / `F4`，已登记
  [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)，其中文案与加固类不构成安全边界）；
  同轮提出的文档缺口 `F5` 已在同一提交内修掉；另记录一条既往文案观察 `O-1`（早于本版 delta，未改）。
- 本版 delta 的性质：新增一条**本地、无网络**的用户输入路径（只接受已存在且可写的绝对目录，任何分支都
  不创建目录）、为接收文件夹声明 `public.folder`（带来 Finder「打开方式」的可见代价，但不新增能力面）。
  不改变更新流水线、信号语义、网络边界、权限与 Keychain 语义。
- 沿用：[alpha.1 审查](security-review-alpha.1.md)（服务/密钥/脱敏/CSP/供应链）、
  [alpha.3 审查](security-review-alpha.3.md)（更新流水线）与 [alpha.9 审查](security-review-alpha.9.md)
  （措辞与句柄级类型复核）；这些路径本版未改动，没有重新审计。

### 还需 CI / 发布 workflow 完成

| # | 检查 | 实测输出摘要 | 判定 |
| --- | --- | --- | --- |
| C1 | PR CI（候选提交 `09f1264` 的 PR head `f441cd6`） | `build.yml` run `35514128406`，job `build` | **success** |
| C2 | 发布提交的 CI | 〈待发布后回填〉 | 〈待回填〉 |
| C3 | `git tag -a v0.1.0-alpha.10` 指向发布提交 | 〈待发布后回填〉 | 〈待回填〉 |
| C4 | `release.yml`（tag push 触发） | 〈待发布后回填：run 链接、ZIP 字节数、草稿 prerelease 创建时间〉 | 〈待回填〉 |
| C5 | 草稿 prerelease 的正文与真机表 | 〈待发布后回填：正文行数、发布 SHA-256、已知问题列表〉 | 〈待回填〉 |
| C6 | 真机 macOS 与 Node / pi / pi-web 版本 | Apple M4（`Mac16,10`）/ macOS 27.0（`26A428`）arm64 / Node v24.21.0 / pi 0.86.1 / `@agegr/pi-web` 0.9.1；`smoke.sh` 双模式通过（`items=6 blockers=3`） | 已实测（本版记录到 `pi` 从 0.86.0 升到 0.86.1） |
| C7 | `gh release edit --draft=false`（prerelease） | 〈待发布后回填〉 | 〈待回填〉 |
| C8 | 回退路径（上一版资产仍在 Releases） | `v0.1.0-alpha.9`（3 个资产：ZIP / `.sha256` / `.evidence.md`） | 已核实 |
| C9 | 回填 Release issue 的 run 链接与 SHA-256、关闭 issue | issue [#137](https://github.com/Su-luoya/pi-web-desktop/issues/137)：〈待回填评论链接与关闭时间〉 | 〈待回填〉 |

本节的边界：C2–C5、C7 与 C9 的输出来自 CI / workflow / 维护者操作，不是本机脚本的直接输出；这些行
在发布与回填提交里补齐（与 alpha.9 的 #133 回填同一流程）。C6 来自本机实测，已写入 Release 正文。

### 本版同时做的文档一致性改动

- `Configuration/AppIdentity.xcconfig`（本版唯一版本来源）：`MARKETING_VERSION` → `0.1.0-alpha.10`、
  `CURRENT_PROJECT_VERSION` → `10`。
- `docs/release-notes-v0.1.0-alpha.10.md`（本版新增）：功能逐条成节；“更新检查与自动更新的边界”一节
  沿写本版没有改动域名、频率、开关与自动更新前置条件；“校验值”一节区分演练值与 `release.yml` 的发布值
  （发布后回填）；“已知问题”把功能评审的 `F1`–`F4` 列为待办并给出真机验证清单。
- `docs/security-review-alpha.10.md`（本版新增）：alpha.9 → alpha.10 的只读 delta 安全评审。
- `docs/architecture.md`：`RecentWorkspaceStore` 条目补注切换边界（只写 `service.workspacePath`、复用既有
  托管进程停止路径、外部服务不被停止或重启）与评审引用。
- `docs/alpha-release-checklist.md`（本文件）：新增本节（alpha.10 执行记录、覆盖方式、安全审查结论、
  C 项与文档一致性清单）。
