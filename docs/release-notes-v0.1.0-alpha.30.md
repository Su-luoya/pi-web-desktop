# Pi Web Desktop 0.1.0-alpha.30（build 30）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.30` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版有两个新功能，都在远程访问：菜单新增「测试访问延迟…」，逐包报告直连/中转路径与本机 NAT 和 DERP 区域延迟；远程访问可以改为自填内网穿透地址，与 Tailscale 二选一。另修掉四处缺陷，其中最直接的是**更新页把 npm 全局安装误判成 git checkout**（本机 `@agegr/pi-web` 装在 `/opt/homebrew/lib/node_modules` 下时会看到「该来源没有适用的静态命令」，且不允许自动更新）。无破坏性变更。

## 1. 更新来源不再被宿主目录的 `.git` 误判

### 现象

`@agegr/pi-web` 从 Homebrew 前缀的 npm 全局目录安装时，更新页显示「Pi Web 来源是 git checkout（可信度 已验证）」，只给「该来源没有适用的静态命令」，并且不允许自动更新。实际上它就是一个 npm 全局包。

### 原因

`ComponentInstallationDetector` 从包目录一路向上找 `.git`，撞到 **Homebrew 自己的** `/opt/homebrew/.git`，于是整个包被判成 checkout。同一台机器上 `PATH` 里的 `npm` 属于另一套 Node 发行版（vite-plus），它的 `npm root -g` 不覆盖 `/opt/homebrew/lib/node_modules`，于是「npm 全局」这条证据也没命中。

### 做法

- `gitEvidence` 向上查找遇到 `node_modules` 边界即停：`node_modules` 之上的 `.git` 属于宿主目录，不是这个包的 checkout。
- 新增 `packageScopedNPMRoot`：包路径形如 `<prefix>/lib/node_modules/…` 且 `PATH` 里的 npm root 覆盖不到它时，用同前缀、经绝对路径与可执行位校验的 `<prefix>/bin/npm` 再问一次 `npm root -g`；只有它报告的 root 确实包含包路径才采纳，并把这条证据写进 evidence。命令仍是只读、参数固定，不新增可执行入口。
- 回归测试两条：`.git` 不越 `node_modules` 边界；宿主前缀自身是 git 仓库且 `PATH` 里的 npm 指向别处时判为 npm 全局（已验证），并给出 `npm install -g @agegr/pi-web`。用本机真实路径跑探测得出同一结论。

## 2. 远程访问延迟测量

菜单「服务 → 远程访问 → 测试访问延迟…」列出 tailnet 设备，选一台后跑 `tailscale ping` 与 `netcheck`：结果窗口逐包给出路径、最小/中位/最大往返、本机 NAT 类型与 DERP 区域延迟，结论行直说「全程直连」还是「全程经中转 tok（Tokyo）」。

`tailscale ping` 没能建立直连时退出码非零而输出仍在，按 `run(_:)` 的「非零即丢弃」语义会把唯一有用的几行丢掉，因此新增 `runAllowingFailure` 单独走一条保留输出的路径。`status` 里的路径只是快照，可能与这几秒内采到的路径不一致（实测同一台机器几秒内从全程中转变全程直连），所以「Tailscale 记录」与「采样路径」分开写，不拿快照替用户下结论。结果文本视图按宽度折行：DERP 延迟表一行可到 700+ pt，不折行会被 480 pt 窗口的右边缘切掉。

## 3. 自填内网穿透地址（与 Tailscale 二选一）

隧道进程与端口映射都在外部工具里，App 只负责记住那个公网 URL：菜单新增「使用自定义隧道地址…」，选过之后延迟测量那项隐藏（它测的是 tailnet 链路），地址与状态仍只有一个来源，启用 Tailscale 会清掉自定义记录，反之亦然。

保存前用 GET 打一次并停在本机失败警告上，但探测**不走系统代理**：开着代理的机器上它会变成「代理能不能出网」，误报比不报更坑。4xx 算通，因为 Host 被挡正是接下来那一层要修的问题。`allowedHosts` 非空时改为一律放行 Host：隧道服务商给的多是按次变化的临时端口，逐条追加一个域名换一次就失效，而 loopback 绑定的默认规则保持原样。主机名已在列表里时不重启服务，避免白断一次会话。弹框里明说拿到地址即可完全控制 pi-web、且没有访问密码；二维码窗口按入口类型给出不同的风险措辞。

## 4. 健康检查计时器改挂 `.common` 运行循环模式

`ServiceScheduling.repeating` 原用 `Timer.scheduledTimer`，只把计时器加入 `RunLoop.Mode.default`。菜单跟踪、拖动窗口、sheet 与 `runModal()` 期间主循环跑在 eventTracking / modalPanel 等模式，默认模式上的计时器整段时间不触发：服务已经挂掉，菜单仍显示正在运行，关掉菜单才补一次检查；健康检查要连续失败 3 次才重启，实际重启延迟被进一步放大。改为 `Timer(timeInterval:repeats:)` + `RunLoop.main.add(_:forMode: .common)`，与更新检查、退出决策计时器保持一致；`UpdateCheckTimerModeTests` 新增一条用例锁住服务侧。

## 5. 两处纵深防御与重构

- `DependencyChecker.shellLookupArguments(named:)` 把名字直接拼进 `/bin/zsh -lc 'command -v <name>'`，补齐 `^[A-Za-z0-9._-]+$` 白名单（与 `ComponentInstallationDetector` 同类拼接已有的闸一致）。现有调用点全是字面量，不是活漏洞；非法名字不再拼出命令，直接落到「未找到」分支。
- 更新检查的三个通道（GitHub API、校验和、appcast）各写一份请求头，收敛为 `AppDelegate.updateRequest(url:accept:)`；两份几乎相同的重定向 `URLSessionTaskDelegate` 合成 `AllowlistRedirectDelegate(allows:)`，拿不到 URL 时照旧拒绝跟随。

## 6. 开发脚本

新增 `Scripts/test.sh`：本机 `xcode-select -p` 常停在 Command Line Tools，此时裸 `xcodebuild` 直接报 `tool 'xcodebuild' requires Xcode`，脚本只对本进程导出 `DEVELOPER_DIR`（需要在 `sudo` 之外跑），DerivedData 落到 git-ignored 的 `.build/DerivedData`，退出码 0 通过 / 1 失败 / 2 找不到完整 Xcode。`CONTRIBUTING.md` 与 `docs/development.md` 改以它为入口。

## 验证

本机 macOS 27.2（build 26B123），Apple M4；Node v26.13.0，Pi 1.5.0，`@agegr/pi-web` 0.13.0（Homebrew 全局安装）。

- `./Scripts/test.sh`（完整 XCTest）：`Executed 1039 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。
- `./Scripts/build.sh`：release 构建（`-O -wmo`）通过；`./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/check-release-version.sh v0.1.0-alpha.30`：`PASSED`。
- `./Scripts/package-release.sh --self-test`：`PASS`；`./Scripts/package-release.sh --tag v0.1.0-alpha.30`：`OK`（内容白名单一致、无 `__MACOSX/`、ad-hoc 签名验证通过）。
- `./Scripts/smoke.sh`：启动与诊断两种模式均 exit 0；诊断模式打印的 `items=6 blockers=3` 来自 `DiagnosticsSmokeFixture` 的确定性样例（用它证明诊断页能渲染出阻断项），不是本机依赖缺失。
- `./Scripts/scan-secrets.sh`：`PASS`（`suppressed 17 lines`，无 `rejected`）；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- 本机演练产物（不是发布资产，CI 会重新构建）：SHA-256 `01d19a3502980287b9f31efe98503ddbe6e253de18c03c46d813d06eea345a6b`，1741321 字节。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；换成另一个 ad-hoc 构建后首次启动可能再次提示放行（CDHash 变化导致的预期行为）。
- 远程访问**没有访问密码**：能进入同一 tailnet 或拿到那个隧道 URL 的设备就能完全控制 pi-web；不想这样就不要启用。
- 远程访问的端到端流程（菜单启用 → 扫码打开 → 关闭）没有自动化覆盖，本版新增的延迟测量与自定义隧道地址也只有单元测试与本次真机启动/诊断冒烟，没有人工点验记录；「重试关闭远程访问」仍未在真机 tailnet 上跑通。
- 应用自更新的真实替换（`/Applications` 下的换包与重启）仍只有单元测试覆盖失败路径，没有端到端演练记录；本版修的是**更新来源判定**，更新页在真机 UI 上点「立即更新」的新路径未做人工点验（判定结果用真实路径直接调用探测器确认）。
- `Sources/App` 的菜单、窗口与退出时序只有单元测试覆盖。
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证。

上一版 `v0.1.0-alpha.29` 的资产仍然保留。回退到 alpha.29 会失去延迟测量与自定义隧道地址两项功能，也会带回「npm 全局安装被宿主 `.git` 误判」与「健康检查计时器在菜单跟踪期间不触发」两个缺陷。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.30+build.30.zip` |
| SHA-256 | 见 release workflow 摘要与草稿资产（本地演练值不作为发布值） |
| 体积 | 见草稿资产 |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.30+build.30.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.30` 输出 `OK`：ZIP 内容与白名单一致、无 `__MACOSX/`，ad-hoc 签名验证通过，`spctl` 证据记录在 `Pi-Web-Desktop-0.1.0-alpha.30+build.30.evidence.md`。
