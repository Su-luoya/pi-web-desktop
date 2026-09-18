# 安全政策

## 报告渠道

请使用 GitHub 的[私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)。**不要**在公开 Issue、Pull Request、讨论或日志中报告漏洞，也不要粘贴密码、token、代理凭据、私有主机名、包含主目录绝对路径（以 `/Users` 开头）的信息、查询参数或未脱敏的完整日志。

如果私密报告入口暂时不可用，请先不要公开细节，并通过仓库维护者可见的 GitHub 私信请求私密沟通渠道。

一份可处理的报告应包含：

- 受影响版本（本仓库的版本只有 `Configuration/AppIdentity.xcconfig` 一个来源，例如 `0.1.0-alpha.1` / build `1`）与安装方式（源码构建或 ZIP）。
- macOS 版本、Mac 芯片类型，以及 Node.js、Pi、`@agegr/pi-web` 的版本。
- 最小复现步骤、实际影响和假设的攻击者能力。
- 是否已有修复建议或 PoC。PoC 只能验证问题，不要携带真实凭据、真实主机名或私人数据。

## 覆盖范围

本仓库负责应用本体（`Sources/`）、构建与安装脚本（`Scripts/`）、CI 工作流和文档中的安全问题。

以下不属于本仓库范围，请按对应上游项目的安全流程报告：

- 上游 Pi Web 服务（[`agegr/pi-web`](https://github.com/agegr/pi-web)）。
- Pi CLI 与 Pi packages（[`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)）。
- Node.js 与 npm 工具链（[nodejs.org](https://nodejs.org/en/download)）。

## 支持的版本

- 项目只承诺评估最新 alpha 或最新稳定发行版。当前只有 alpha 基线（`0.1.0-alpha.1`），没有稳定发行版。
- 旧 alpha 版本不承诺修复；修复通常只落在 `main` 和后续版本。
- 项目**不承诺**响应时限或修复 SLA。维护者按可用时间处理，修复完成后根据影响决定是否发布 GitHub Security Advisory 或 CVE。

## 已知边界（不是漏洞）

- 应用是 ad-hoc 签名且未公证。Gatekeeper 拒绝打开或要求用户在“系统设置 → 隐私与安全性”里手动批准，是预期行为；不要请求或建议全局关闭 Gatekeeper。
- 默认只监听 loopback。远程访问需要用户在 Keychain 中设置非空密码，且**密码认证不等于传输加密**，加密必须由用户自备的隧道或 HTTPS 反向代理提供。
- 应用不读取、复制或迁移 Pi 的认证内容（例如 `~/.pi/agent/auth.json`）。
- 应用不收集遥测，也不执行安装命令或调用 `sudo`；依赖安装与升级始终由用户完成。
- 版本检查尚未实现，因此当前不存在对应的出站请求。

如果问题属于上述边界的**文档表述不准确**（例如文档把 ad-hoc 签名写成 Developer ID 签名，或暗示已通过公证、兼容性得到保证），请按普通文档 Issue 报告，并同时指出具体文件和表述。

## 披露流程

1. 维护者确认收到后评估影响与受影响版本。
2. 在私密 Advisory 草稿中修复、验证并协商披露时间。
3. 修复发布后再公开 Advisory；如果影响上游或下游，维护者会同步通知对应上游项目。
4. 贡献者希望署名时请在报告中说明；不要在公开渠道提前披露未修复细节。
