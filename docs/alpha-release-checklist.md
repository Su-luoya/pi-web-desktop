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
- [ ] `./Scripts/scan-secrets.sh` 与 `./Scripts/scan-secrets.sh --self-test` 均退出 0（记录结尾的 `scan-secrets: suppressed N lines` 并与本次 diff 新增的内联标记数对照）
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
