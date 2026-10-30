# Pi Web Desktop 0.1.0-alpha.26（build 26）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.26` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版只动“更新”这一条链路，三处改进、无破坏性变更：桌面更新改走仓库自带的 appcast（不再撞 GitHub API 每小时 60 次的共享配额）；发布说明从每次近 7KB 的全量文档变成摘要 + 链接；点「更新」不再干等下载（检查时就后台下好，替换改成同卷原子重命名）。

## 1. 更新通道：自建 appcast（GitHub #225）

### 现象

未认证的 GitHub API 按出口 IP 共享每小时 60 次配额。同一网络里其它工具一多，桌面更新检查就会拿到 429，界面上直接显示“检查失败”——明明上游有新版本，用户却以为没有。

### 做法

`Scripts/make-appcast.sh` 在每次发布后生成 `docs/appcast.json`，推到独立的 `appcast` 分支（`raw.githubusercontent.com/Su-luoya/pi-web-desktop/appcast/appcast.json`）。文件只是一个静态 JSON：schema 版本、各版本号、zip 直链、SHA-256、发布时间与说明链接。CDN 不占 API 配额，一个请求就带齐。

- 应用优先读 appcast；主机不是 `raw.githubusercontent.com` 就整份作废。
- feed 解析失败、版本不认识或内容缺项时，**回落到 GitHub Releases API**，与之前行为一致。
- 只有桌面应用走 appcast；Pi CLI、Pi Web、扩展包仍然问 `registry.npmjs.org`（那里没有配额问题）。
- 发布流程在 Release 正式发布后更新 feed，失败不影响 Release 本身。

### 取舍

多一个需要维护的派生文件。选择单独分支而不是 `main`：`main` 有分支保护（必须过 PR + CI），而这份文件是自动生成的派生数据，不该为它走一遍评审。

## 2. 发布说明瘦身

### 现象

每次 Release 正文 6.7–6.9KB，把所有“现象 / 做法 / 取舍 / 边界”细节都写进发布页；25 个版本累积下来，用户要在几百字里找“这一版到底改了什么”。

### 做法

Release 页面只渲染 `docs/release-notes-template.md` + 本次 notes 的「摘要」小节（安装、校验、已知问题、回退）。完整记录仍然留在仓库的 `docs/release-notes-<tag>.md`，发布页给出链接。

### 取舍

细节不再出现在发布页，需要点一次链接。取舍是：发布页回答“要不要更新”，仓库文档回答“具体怎么改的”。

## 3. 更新包后台预下载 + 原子替换（GitHub #228）

### 现象

点「下载并安装桌面应用更新…」后最长的等待是下载（约 1.6MB，慢网几十秒）。另外替换脚本最后两步 `mv` 以前是**跨卷**的（staging 在 `/tmp`、目标在 `/Applications`），跨卷 `mv` 是拷贝不是 rename：拷到一半崩溃就在 `/Applications` 里留下半个应用。

### 做法

- 检查发现更高版本时，后台把包下好、按发布的 `.sha256` 校验后放进 `~/Library/Caches/io.github.su-luoya.pi-web-desktop/desktop-update/`（只保留一个版本）。点「更新」时直接用，只剩解压与替换。
- **只下载、不安装**：安装入口仍然只在用户点击时出现，没有无人值守路径；装之前再算一次 SHA-256（缓存目录在用户可写位置，不能只信写入那一刻）。
- 预下载只用 appcast 通道，不占 API 配额；feed 不可用就不预下载。
- staging 改到目标应用同目录，两步 `mv` 成为同卷 rename——原子且瞬时；父目录不可写时仍退回临时目录。

### 边界

预下载是“提前下载”，不是“提前安装”。进度窗口在命中缓存时把下载那一步标成「已预下载，直接校验」，不会显示一段其实不会发生的下载。

## 验证

本机 macOS 27.2（build 26B123），Mac16,10 / Apple M4。

- `xcodebuild test`：`Executed 1000 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 7 条用例（`PiWebDesktopTests/DesktopUpdatePackageCacheTests.swift`）：写入后命中、版本或 tag 不匹配不命中、只保留最新一个包、缺 `sha256` / `tag` / `assetName` 拒绝写入、缓存被改过则拒绝命中、清理、不合规下载地址不发请求。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/check-release-version.sh`：`PASSED`（`MARKETING_VERSION 0.1.0-alpha.26`、`CURRENT_PROJECT_VERSION 26`）；`./Scripts/scan-secrets.sh --self-test` 与 `./Scripts/scan-secrets.sh`：`PASS`；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功；`./Scripts/package-release.sh --tag v0.1.0-alpha.26`：`OK`（白名单条目一致、无 `__MACOSX/`、ad-hoc 签名验证通过）；`./Scripts/smoke.sh`：两种模式均 exit 0。
- 发布 workflow（tag `v0.1.0-alpha.26`）：build 与 publish 两个 job 通过；发布前占位符计数为 0；发布后 `gh release download` + `shasum -a 256 -c` 复验。
- 下表的 checksum 与体积是**发布出来的那份资产**（CI 重新构建，与本地 `package-release.sh` 的结果不同）；本地那份只用于发版前自检。
- appcast：发布后 workflow 首次跑因 `git diff` 看不到未跟踪文件而静默跳过（分支从未建立），已由 PR #231 修复，并用 `workflow_dispatch` 补登本版；`appcast.json` 里的 `sha256` 与上表一致。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；换成另一个 ad-hoc 构建后首次启动可能再次提示放行（CDHash 变化导致的预期行为）。
- 真机上的完整替换流程（需要把应用装在 `/Applications` 并真的替换一次）没有自动化覆盖，本版只在打包与冒烟层面验证过；预下载命中的路径同样只有单元测试覆盖。
- appcast 是派生数据：发布 workflow 更新失败时 feed 会落后于最新 Release，此时应用回落到 GitHub API（配额可用时结论相同）。
- 没有「取消更新」按钮：更新一旦开始就跑到结束或失败。
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证。

上一版 `v0.1.0-alpha.25` 的资产仍然保留；回退会带回“更新检查撞 API 配额、点更新要等下载、替换非原子”的旧行为（功能缺失，不是缺陷回退）。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.26+build.26.zip` |
| SHA-256 | `095f795ccaffff6d3c20c85ec8bc2b4aabb69df32411d2dfd0273cfd2d9c5069` |
| 体积 | 1727671 字节 |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.26+build.26.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.26` 输出 `OK`：ZIP 内容与白名单一致、无 `__MACOSX/`，ad-hoc 签名验证通过，`spctl` 证据记录在 `Pi-Web-Desktop-0.1.0-alpha.26+build.26.evidence.md`。
