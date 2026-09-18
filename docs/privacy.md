# 隐私说明

## 无遥测

Pi Web Desktop 不收集或上传遥测、使用统计、会话内容、认证信息或诊断报告。用户主动复制诊断信息或打开日志时，数据才离开本机，且用户负责在公开提交前脱敏。

## 版本检查

计划中的版本检查会访问相应上游服务，例如 GitHub Releases、npm registry 或 Pi 上游。请求会让这些服务看到网络请求的 IP 和 User-Agent。版本检查不是项目遥测，首版实现后会在首次启动说明中披露，并允许用户分别关闭。

## 本地数据

- 普通设置写入 UserDefaults。
- 远程访问密码写入 macOS Keychain。
- 运行状态写入 `~/Library/Application Support/Pi Web Desktop/`。
- 日志写入 `~/Library/Logs/Pi Web Desktop.log` 并轮转。
- 应用不读取、复制或迁移 `~/.pi/agent/auth.json` 等 Pi 认证内容。
- 首次启动诊断只检查 `~/.pi/agent` 是否存在与可读（不列目录、不读取任何文件），报告里只出现脱敏后的路径 `~/.pi/agent`。
- 用户在诊断窗口选择 pi-web 路径时，只对该文件做两件本地只读的事：执行 `--version`、向上查找并读取 package.json 的 `name`（不安装、不联网、不读取其他文件）。

## 诊断脱敏

公开 Issue 或 PR 不得包含密码、token、API key、代理凭据、查询参数、用户名、Home 路径、私人主机名或完整私有日志。诊断功能会尽量隐藏这些信息，但用户提交前仍必须检查复制内容。

## 远程访问

默认服务只监听 loopback。密码认证不等于传输加密；远程访问需要用户配置受信任的加密隧道或 HTTPS 反向代理。项目文档不会把个人 Tailscale 主机名或其他私人网络地址写入默认配置。
