<!--
Pi Web Desktop alpha release notes template.

.github/workflows/release.yml renders this file into the release body:
  * {{VERSION}}, {{BUILD}}, {{ZIP_NAME}} and {{SHA256}} are replaced with the
    values of the packaged build;
  * the RELEASE-EVIDENCE marker below is replaced with the signature and
    Gatekeeper evidence produced by Scripts/package-release.sh.

Fields marked <待填写> must be filled from the Release Issue before the draft
release is published; they describe a real Apple Silicon Mac, not the CI runner.

Rules for this file:
  * the artifact is ad-hoc signed and not notarized: never write that it is
    signed or notarized, and never tell users to disable Gatekeeper;
  * do not add version numbers here, the build adds them from
    Configuration/AppIdentity.xcconfig;
  * do not add host names, user names, private paths, proxy endpoints or tokens;
  * use absolute links: release pages do not resolve repository-relative paths.

Everything above the first "# " heading is a template instruction comment: the
workflow strips it before building the release body.
-->

# Pi Web Desktop {{VERSION}} (build {{BUILD}}) — Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop {{VERSION}} 是面向 Apple Silicon（arm64）、macOS 14 或更高版本的早期 alpha。ZIP 里的应用是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，因此 macOS Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。

Pi Web Desktop {{VERSION}} is an early alpha for Apple Silicon (arm64) Macs running macOS 14 or later. The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID certificate and no Apple notarization, so Gatekeeper blocks a plain double-click and the user has to approve this app explicitly.

## 目标平台

| 项目 | 值 |
| --- | --- |
| CPU 架构 | Apple Silicon（arm64）。**不支持 Intel（x86_64）**。 |
| 最低系统 | macOS 14.0 |
| 应用包 | `Pi-Web-Desktop.app`，`CFBundleShortVersionString={{VERSION}}`，`CFBundleVersion={{BUILD}}` |
| 签名 | ad-hoc（打包脚本执行 `codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 会拒绝，需要手动放行一个应用 |

## 实测版本（真机）

以下值必须来自 Release Issue 中记录的真机 smoke 环境，不是 CI runner；发布草稿前由维护者填写。

| 项目 | 值 |
| --- | --- |
| 机器与芯片 | <待填写> |
| macOS 版本 | <待填写> |
| 架构（应为 arm64） | <待填写> |
| Node.js 版本 | <待填写> |
| Pi（`@earendil-works/pi-coding-agent`）版本 | <待填写> |
| `@agegr/pi-web` 版本 | <待填写> |
| `./Scripts/smoke.sh` 结果（启动模式与诊断模式） | <待填写> |

## 安装

1. 校验下载的 ZIP（在下载目录执行）：

   ```bash
   shasum -a 256 -c {{ZIP_NAME}}.sha256
   ```

2. 解压：

   ```bash
   ditto -x -k {{ZIP_NAME}} .
   ```

3. 把 `Pi-Web-Desktop.app` 移到 `~/Applications` 或 `/Applications`。
4. 首次打开：在 Finder 中按住 Control 点按（或右键）应用，选择“打开”，再确认一次“打开”。如果系统不再提供这一选项，请在“系统设置 → 隐私与安全性”里找到刚被拦截的条目并选择“仍要打开”。
5. 应用不打包 Node.js、Pi 和 `@agegr/pi-web`，请先按 [README](https://github.com/Su-luoya/pi-web-desktop/blob/main/README.md) 与 [开发文档](https://github.com/Su-luoya/pi-web-desktop/blob/main/docs/development.md) 安装依赖；首次启动的诊断界面会检查这些依赖。

不要为了运行这个 alpha 而关闭 Gatekeeper，也不要把 `sudo spctl --master-disable` 之类的命令当作安装步骤。

## 未公证与 Gatekeeper 警告

- ZIP 内应用只有 ad-hoc 签名：它能证明 bundle 在打包后没有被改动，但不包含开发者身份，Apple 也没有对它做过公证。
- macOS 默认会阻止它直接运行。放行是“针对这一个应用”的决定，系统会把它记录在“隐私与安全性”中。
- 未公证的后果：无法验证发布者身份，也无法使用依赖 Developer ID 的能力（例如自动更新和部分系统权限的持久授权）。
- 本项目的说明不会把 ad-hoc 签名或“本机校验通过”描述成“已签名”或“已公证”。如果别处出现不同说法，以本文件与下面的证据段落为准。

## 校验值

- 资产：`{{ZIP_NAME}}`
- SHA-256：`{{SHA256}}`
- 校验命令（下载目录执行）：`shasum -a 256 -c {{ZIP_NAME}}.sha256`
- 同一个 checksum 也会记录在 Release Issue 中；不一致时不要安装，先在 Release Issue 报告。

<!-- RELEASE-EVIDENCE -->

## 已知问题

- 未公证导致首次打开必须手动放行；重新下载后（quarantine 属性存在时）可能需要再次确认。
- 依赖（Node.js、Pi、`@agegr/pi-web`）需要用户自行安装；缺失时应用只显示诊断信息，不会自动安装。
- `v0.1.0-alpha.14` 及更早版本不实现应用内更新，升级需要重新下载并替换应用包；从 `v0.1.0-alpha.15` 起有应用内自更新（菜单「下载并安装桌面应用更新…」，仅 `/Applications` 可用）。
- 换成另一个 ad-hoc 构建（包括用应用内更新装上的新版本）后首次启动，macOS 可能弹窗要求授权新的
  可执行文件读取已保存的远程访问密码（Keychain 授权弹窗）。这是 ad-hoc 签名的 CDHash 变化导致的
  预期行为，不是更新失败；授权或拒绝都不影响应用启动与其它功能。
- 只支持 Apple Silicon，Intel Mac 不支持。
- <待填写：Release Issue 中记录的本版本已知问题>

## 回退

1. 保留上一版 ZIP 与它的 checksum；回退时解压上一版并替换当前的 `Pi-Web-Desktop.app`。
2. 应用没有系统级常驻组件，删除应用包即可卸载；服务配置保留在用户目录（UserDefaults、Application Support 与 Logs），回退时不会自动清理。
3. 没有应用内自动回滚；自更新需要用户确认后才执行（`v0.1.0-alpha.15` 起，仅 `/Applications`），新版本不可用时按上面步骤手动换回旧版本，并在 Release Issue 中记录问题。
4. Node.js、Pi、Pi Web 的版本回退由用户自行管理；本项目不承诺能恢复第三方包的旧版本。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本。
- 没有 SLA：这是 alpha 预览，按“现状”提供，不承诺修复时间。
- 没有无人值守的自动更新：自更新从 `v0.1.0-alpha.15` 起可用，但必须由用户在菜单里确认后才执行，且只在 `/Applications` 下可用。
- 没有 Developer ID 签名、没有 Apple 公证，也没有 Apple 支持渠道。
- 不要在公开 issue 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。
