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
- [ ] #14 安全审查完成，无阻断项：<结论链接 / 日期>
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
