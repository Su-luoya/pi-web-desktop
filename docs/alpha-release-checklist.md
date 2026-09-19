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
