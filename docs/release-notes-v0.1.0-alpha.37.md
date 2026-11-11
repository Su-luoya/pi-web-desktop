# Pi Web Desktop v0.1.0-alpha.37（build 37）

Apple Silicon（arm64）、macOS 26+ 的 alpha prerelease；ad-hoc 签名、未公证，不含 Node.js、Pi CLI 或 Pi Web。

## 摘要

- 手机访问失败时显示可复制的 Tailscale 具体报错与重试命令；tailnet 未启用 HTTPS 时，可直接打开经校验的启用链接，完成后回到应用重试。
- 命令探针分开收集 stdout / stderr，保留失败与超时的诊断输出，不让提示文字破坏 JSON 解析；两条管道均非阻塞排空。
- 手机主屏 PWA 图标与桌面应用保持一致：裁去透明边距、铺满图标底色，启动受管服务前同步三个尺寸；内容相同不写入，失败不阻断服务。
- 图标直接原子覆盖 Pi Web 包内文件，**不保留备份**。重新安装 Pi Web 可恢复上游图标，之后由桌面应用再次启动服务仍会同步；手机缓存的旧图标可能需要刷新或重新添加主屏入口。

## 范围与安全边界

Tailscale Serve 只在 tailnet 内提供 HTTPS 入口，不启用 Funnel、不执行 `serve reset`。入口没有应用访问密码，tailnet 身份是唯一认证边界；无需密码不等于访问不受限，密码认证也不等于传输加密。启用链接只允许受信任主机与指定的路径形状，展示/日志输出继续统一脱敏。

PWA 同步仅在真正启动应用受管服务前执行；外部服务只读策略不变。读取包名只用于定位精确匹配的 `@agegr/pi-web` 包；写入位置与不保留备份的行为见 [隐私说明](privacy.md)。不增加第三方依赖，不变更设置 schema，也不执行真实 Pi CLI / 扩展升级。

## 真机记录

用户已在本机替换后的候选应用确认以下三项正常：

1. 桌面启动与基本操作。
2. 启用 Tailscale HTTPS，并从手机访问。
3. 手机添加或刷新主屏入口，图标正常。

这次用户实测候选的版本字段仍为 alpha.36；alpha.37 在相同功能代码上更新版本号与发布文档，并重新执行自动验证，不把旧字段候选冒充正式 CI 包实测。

本次读取的环境：Mac16,10 / Apple M4；macOS 27.2（26B123）；arm64；Node.js v26.13.0；Pi 1.5.2；`@agegr/pi-web` 0.15.0。Pi 版本是发布准备时重新读取的值，不追溯声称早先实机操作时也是该版本。

## 验证记录

- 本地全量 XCTest：**1091 tests, 0 failures**；独立 `xcodebuild build` 与默认 `-O -wmo` 发布构建均通过。
- 启动 / 诊断两种 smoke 均退出 0；Xcode app、XCTest bundle 与发布 app 的交叉身份检查 **56 checks** 通过；版本 / tag / build 检查通过。
- shell 语法、diff 与 CI 同款 personal-data 固定模式扫描通过。secret scanner 及其自测通过，`suppressed 17 lines`、无 rejected，本版无新增抑制标记；扫描通过不等于没有秘密。
- 版本与打包自测通过，包含真实 bundle 完整打包、元数据 source 和包内容白名单拒绝路径。为保持临时输出都在项目内，在 git-ignored `.scratch` 内导出已暂存的候选快照，运行字节相同的脚本；第一次打包自测因快照尚无 Git 提交而失败，补上夹具提交后通过，未改产品脚本。
- 签名完整性通过，`Signature=adhoc`、`TeamIdentifier=not set`；本机 `spctl` exit 3 / rejected 是未公证产物的预期结果。
- S1–S8 在候选代码上复核，无阻断项；历史风险的逐项处置、命令证据与未验证范围见 [Release Issue #276](https://github.com/Su-luoya/pi-web-desktop/issues/276)。
- 上一版 alpha.36 ZIP 与 checksum 已重新下载，校验 OK。PR、main CI、公开资产与 appcast 的最终证据将追加到该 Issue 和 [逐版本执行记录](release-records/execution-log.md)，不以本地打包值冒充 CI 公开资产。

## 已知限制与未验证范围

- ad-hoc 签名、未公证；首次打开或新的应用构建可能需要在「系统设置 → 隐私与安全性」中针对这一个应用放行，或通过 Finder 右键打开。不关闭 Gatekeeper。
- 只支持 Apple Silicon、macOS 26+；不承诺 Intel 或其他系统版本。
- 未执行真实 CLI / 扩展安装端到端，未用 VoiceOver 逐项朗读，未在另一台 Mac 验证首次 Gatekeeper 放行。隔离测试与 smoke 不证明任意本机安装都能升级。
- 自动 smoke 不启动真实 pi-web，但会创建默认 WKWebView；应用自己的状态/日志隔离到临时目录，WebKit 的网站数据仍由系统框架管理。
- 图标按文件原子覆盖，不是三个文件的事务；中途失败可能只更新部分尺寸，下次启动可重试。应用不保留原图标备份；主屏缓存的更新由浏览器/系统决定。
- secret scanner 与 personal-data 检查只覆盖固定形状，不扫描全部 Git 历史、任意自由文本或二进制秘密；检查通过不等于没有秘密。

## 回退

保留 [alpha.36](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.36) 的 ZIP 与 checksum；退出应用后解压并替换应用包。无设置 schema 或服务数据迁移，应用内安装器不提供自动降级。从 appcast 移除本版条目可停止推送。

回退桌面应用不会自动恢复已覆盖的 Pi Web 图标；需要恢复上游图标时重新安装 Pi Web。既有备份文件不清理，本版不再创建图标备份。
