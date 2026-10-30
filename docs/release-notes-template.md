<!--
Pi Web Desktop alpha release notes template.

.github/workflows/release.yml renders this file into the release body:
  * {{VERSION}}, {{BUILD}}, {{ZIP_NAME}}, {{SHA256}}, {{EVIDENCE_NAME}} and
    {{NOTES_URL}} are replaced with the values of the packaged build;
  * the SUMMARY marker is replaced with the "## 摘要" section of
    docs/release-notes-<tag>.md, so the release page shows a short summary and
    the long verification record stays in the repository.

The body is deliberately short: the release page answers "what changed, how do I
install it, how do I verify it, what is broken". Everything else (S1–S8 gates,
real-machine versions, reproducibility notes) belongs in
docs/release-notes-<tag>.md, which is committed before the tag is pushed.

Rules for this file:
  * the artifact is ad-hoc signed and not notarized: never write that it is
    signed or notarized, and never tell users to disable Gatekeeper;
  * do not add version numbers here, the build adds them from
    Configuration/AppIdentity.xcconfig;
  * do not add host names, user names, private paths, proxy endpoints or tokens;
  * use absolute links: release pages do not resolve repository-relative paths;
  * never reintroduce a <待填写> field: the release body is published as
    rendered, so a placeholder would reach users.

Everything above the first "# " heading is a template instruction comment: the
workflow strips it before building the release body.
-->

# Pi Web Desktop {{VERSION}} (build {{BUILD}}) — Apple Silicon alpha（未公证）

**一句话**：面向 Apple Silicon（arm64）、macOS 26 或更高版本的早期 alpha。ZIP 里的应用是
**ad-hoc 签名、未公证** 的，macOS Gatekeeper 默认会阻止双击打开，需要针对这一个应用手动放行。
ZIP 只包含应用包，不含 Node.js、Pi 与 `@agegr/pi-web`。

## 本版改动

<!-- SUMMARY -->

## 安装 / 升级

- **已装旧版**：菜单「更新 → 下载并安装桌面应用更新…」（仅安装在 `/Applications` 时可用）。
- **全新安装**：

  ```bash
  shasum -a 256 -c {{ZIP_NAME}}.sha256   # 下载目录执行
  ditto -x -k {{ZIP_NAME}} .
  ```

  然后把 `Pi-Web-Desktop.app` 拖进 `/Applications`，首次打开用 Control 点按（右键）→「打开」放行。
- **依赖**：应用不打包 Node.js、Pi、`@agegr/pi-web`，请先按
  [README](https://github.com/Su-luoya/pi-web-desktop/blob/main/README.md) 与
  [开发文档](https://github.com/Su-luoya/pi-web-desktop/blob/main/docs/development.md) 安装；
  首次启动的诊断界面会检查这些依赖。

不要为了运行这个 alpha 关闭 Gatekeeper，也不要把 `sudo spctl --master-disable` 当作安装步骤。

## 校验

- ZIP：`{{ZIP_NAME}}`
- SHA-256：`{{SHA256}}`
- 校验命令：`shasum -a 256 -c {{ZIP_NAME}}.sha256`
- 不一致时不要安装，先在 Release Issue 里报告。

## 已知问题

- 未公证：首次打开必须手动放行；换成新的 ad-hoc 构建（含应用内更新装上的版本）后可能再次提示，
  这是 CDHash 变化导致的预期行为，不是更新失败。
- 只支持 Apple Silicon 与 macOS 26 或更高版本，不支持 Intel Mac。
- 应用内更新只在 `/Applications` 下可用，且需要用户确认后才执行；没有无人值守的自动更新。

## 完整记录

- 本版验证记录、真机环境与回退步骤：[docs/release-notes-v{{VERSION}}.md]({{NOTES_URL}})
- 签名与 Gatekeeper 证据：资产 `{{EVIDENCE_NAME}}`
- 回退：保留上一版 ZIP 与 checksum，解压后替换应用包即可；应用没有系统级常驻组件，删除应用包即卸载。
- 没有 SLA：alpha 预览按“现状”提供，不承诺修复时间，也没有 Apple 支持渠道。
