# 发布流程

本文描述当前 alpha 通道的真实流程；结论以仓库里的脚本与 workflow 为准：
`Scripts/build.sh`、`Scripts/check-release-version.sh`、`Scripts/package-release.sh`、
`Scripts/check-identity.sh`、`.github/workflows/release.yml`。
发布前的逐项门槛见 [alpha 发布门槛清单](alpha-release-checklist.md)。

## 现状（先读这一段）

- 本项目**没有 Apple Developer 账号**：不执行 Developer ID 签名，也不执行 Apple 公证。
- 唯一的签名是 ad-hoc（`codesign --force --deep --sign -`）。它只能证明 bundle 打包后没有被改动，
  不包含开发者身份；`codesign -dv --verbose=4` 会显示 `Signature=adhoc` 与 `TeamIdentifier=not set`。
- `spctl -a -vv` 会拒绝该应用（退出码非 0），这是未公证 ad-hoc 产物的预期结果。
- 因此任何文档、Release 说明或回复都不允许声称产物“已签名”或“已公证”，也不允许指导用户关闭
  Gatekeeper。准确说法是“ad-hoc 签名、未公证”。
- 安装限制由应用层面承担：首次打开需要在“系统设置 → 隐私与安全性”中针对该应用放行，
  或在 Finder 中右键打开。这是用户对自己机器的选择，不是关闭 Gatekeeper。

## 版本来源与 Git tag

应用身份与版本的唯一来源是 `Configuration/AppIdentity.xcconfig` 中的 `MARKETING_VERSION`
与 `CURRENT_PROJECT_VERSION`；`PiWebDesktop.xcodeproj` 通过 `baseConfigurationReference`
继承该文件，`Scripts/build.sh` 也从同一文件生成 `Info.plist`。因此：

- tag 名称固定为 `v<MARKETING_VERSION>`（例如 `MARKETING_VERSION = 0.1.0-alpha.2` 对应
  tag `v0.1.0-alpha.2`）；tag 与该值不一致时不得发布。
- 打 tag 前先提交版本改动，再运行 `./Scripts/build.sh && ./Scripts/check-identity.sh`，
  确认 xcconfig、Xcode 工程、已构建 bundle 的 `Info.plist` 与本地服务默认值一致。
- `Scripts/check-identity.sh` 会拒绝 `Sources/`、`Scripts/`、`PiWebDesktop.xcodeproj/`、
  `PiWebDesktopTests/` 里出现 `MARKETING_VERSION` 的字面值；不要在代码、脚本或模板中复制版本号。
- Release 说明里同时写明 `CFBundleShortVersionString`（即 `MARKETING_VERSION`）与
  `CFBundleVersion`（即 `CURRENT_PROJECT_VERSION`），便于用户核对下载的 ZIP。

### tag 与 build 号的对应规则

`CURRENT_PROJECT_VERSION` 是 `CFBundleVersion` 的来源，Sparkle 与系统用它判断“哪个更新”，
所以它必须与 `MARKETING_VERSION` 对得上。`Scripts/check-release-version.sh` 不论 tag 形态都会校这一项，
连不带 tag 的本地演练也会校；规则如下：

| `MARKETING_VERSION` 形态 | 例子 | 对应的 `CURRENT_PROJECT_VERSION` |
| --- | --- | --- |
| 预发布，末尾带数字计数 | `1.2.3-alpha.4` | 末尾数字，即 `4` |
| 预发布，整个预发布段就是数字 | `1.2.3-4` | `4` |
| 正式版，三段数字 | `1.2.3` | `major * 1000000 + minor * 1000 + patch`，即 `1002003` |
| 其它（预发布但没有数字计数、两段或四段版本） | `1.2.3-beta`、`1.2` | 不接受，脚本退出 1 |

- 正式版的 build 号由版本号推导，所以仍然单调（`1.2.3` → `1002003`，`1.2.4` → `1002004`），
  始终高于同版本的预发布计数；它不是“第几次构建”，不要手填。
- 推导要求 `X.Y.Z` 每段最多三位数字，三段合计不超过 `999999999`；预发布计数保持在三位以内
  （≤ 999），这样正式版的推导值（最小 `1000`）总会高于同版本的预发布计数。
- `CURRENT_PROJECT_VERSION` 必须是不带前导零的十进制整数。
- 这条规则就是代码评审 W4 / M5 的修复：不打算号的正式版 tag 过去会把 build 号完全跳过，
  `CURRENT_PROJECT_VERSION` 可以任意漂移（例如 `0.1.0` 配 `999`），现在会直接失败。
- 同样的 build 号规则会出现在资产名里（见下文“产物名带 build 号”），方便在 Release 页面直接核对。

### `Scripts/check-release-version.sh`

- `./Scripts/check-release-version.sh v<MARKETING_VERSION>`：完整比较。tag 必须等于
  `v<MARKETING_VERSION>`，`CURRENT_PROJECT_VERSION` 必须等于上表推导出的值（正式版也不例外）。
  不一致时退出 1 并给出修正提示。
- 不带参数且环境里没有 `GITHUB_REF_NAME`：打印期望的 tag，跳过 tag 比较，退出 0。
  这是本地 checkout 的默认情况，演练不需要先打 tag；但 `CURRENT_PROJECT_VERSION` 与
  `MARKETING_VERSION` 的对应关系仍然会被校验。
- `--print-tag`：只输出 `v<MARKETING_VERSION>`；workflow 在非 tag ref 的演练里用它。
- `--self-test`：在仓库外的临时目录里跑固定用例（正式版配错 build 号、预发布计数漂移、
  无计数预发布、两段版本、tag/版本不一致等），不需要 bundle，也不改工作树。
- 版本值只从 xcconfig 读取，脚本里不写版本字面值。

## 发布前门槛

见 [alpha 发布门槛清单](alpha-release-checklist.md)。简述：`main` CI 为绿；安全审查无阻断项；
tag 与 bundle 版本一致；真机 smoke 记录写入 Release Issue；checksum 与 Release 说明一致；
Release 标记 prerelease；说明中写明未公证与安装限制；上一版资产仍可下载。

## 本地演练（不需要完整 Xcode，不 push tag）

```sh
for f in Scripts/*.sh; do sh -n "$f" || exit 1; done
git diff --check
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/check-release-version.sh "$(./Scripts/check-release-version.sh --print-tag)"
./Scripts/package-release.sh --self-test
./Scripts/package-release.sh --tag v<MARKETING_VERSION>
./Scripts/smoke.sh
```

- 只有 `xcodebuild` 需要完整 Xcode；CI 之外不要求本机安装完整 Xcode。
- `Scripts/build.sh` 默认构建的是用户下载的那一份发布产物：`-O -wmo`（优化 + 全模块优化）。
  需要调试时用 `./Scripts/build.sh --debug-build`（等价于 `PI_WEB_DESKTOP_BUILD_MODE=debug`），
  它用 `-Onone -g` 写同一个 bundle。调试构建会覆盖发布产物，调试完必须重新跑默认构建再打包，
  否则 `package-release.sh` 打包的就是未优化产物；`build.sh` 也会在调试构建结束时打印这条警告。
- `./Scripts/check-release-version.sh --self-test` 与 `./Scripts/package-release.sh --self-test` 都是离线
  自检，不需要 bundle 或 tag，可以先跑。
- `Scripts/package-release.sh` 只打包已经构建好的 bundle（默认 `build/Pi-Web-Desktop.app`）；
  bundle 不存在时加 `--build`，它会先运行 `./Scripts/build.sh`。
- 产物写入 `dist/`（已被 `.gitignore` 忽略）：`Pi-Web-Desktop-<版本>+build.<build>.zip`、
  `<...>.zip.sha256`、`<...>.evidence.md` 与 `release-metadata.env`。
- 证据文件包含运行机器的路径与 macOS 版本，不要把它提交到仓库，也不要把 `dist/` 加进版本控制。
- `./Scripts/package-release.sh --self-test` 在仓库外的临时目录里自检包名/包内容白名单与拒绝路径（见下节），
  不需要 bundle，也不会在仓库里留下 `dist/`。

### 本地演练与 Finder / iCloud 扩展属性

如果工作区放在 iCloud Drive / File Provider 同步的目录（例如被“桌面与文稿”同步的 `~/Documents`），
Finder 或 File Provider 会在构建过程中给 app bundle 或它的可执行文件写 `com.apple.FinderInfo`、
`com.apple.fileprovider.fpfs#P` 这类扩展属性；`codesign --verify --deep --strict` 会因此拒绝产物，
本地演练可能停在：

```text
package-release: FAILED - codesign --verify --deep --strict failed with status 1 for /…/build/Pi-Web-Desktop.app
build/Pi-Web-Desktop.app: resource fork, Finder information, or similar detritus not allowed
file with invalid attached data: Disallowed xattr com.apple.FinderInfo found on /…/build/Pi-Web-Desktop.app
```

`Scripts/build.sh` 在签名前后各清一次扩展属性并复验（失败时重试最多 3 次），
`Scripts/package-release.sh` 在签名校验与打包前也做一次防御性清理（校验失败时清一次再重试），因此
正常路径不会再失败；只有 `xattr` 不可用、或清理后立即被重新写入时才以可读错误停下，并提示下面的命令。
手工排查与恢复：

```bash
xattr -l build/Pi-Web-Desktop.app
xattr -l build/Pi-Web-Desktop.app/Contents/MacOS/PiWebDesktop
xattr -cr build/Pi-Web-Desktop.app
./Scripts/package-release.sh --tag v<MARKETING_VERSION>
```

清除扩展属性不会破坏封条，不需要重新签名；ZIP 流程也不受它影响：打包前已经清过一次，
并且 `ditto -c -k --norsrc --noextattr` 本身也不会写入 `__MACOSX/` AppleDouble 条目或扩展属性。
CI 在干净目录 checkout，不受影响。
更详细的机制与实测见[开发说明的“Finder / iCloud 扩展属性与签名校验”](development.md#finder--icloud-扩展属性与签名校验)。

## 产物名带 build 号

`Scripts/package-release.sh` 产出的资产名是 `<App>-<MARKETING_VERSION>+build.<BUILD>.zip`，
例如 `Pi-Web-Desktop-<版本>+build.<build>.zip`；`.sha256` 与 `.evidence.md` 用同一个前缀。
`+build.N` 是 semver 的 build metadata 写法，`N` 就是 `CFBundleVersion`：

- 下载页与证据文件里能直接看到 build 号，不用解包 `Info.plist` 就能发现 build 号与 tag 不一致；
- 兼容性：`.github/workflows/release.yml` 从 `release-metadata.env` 读 `ZIP_NAME`/`EVIDENCE_NAME`，
  不拼名字；`docs/release-notes-template.md` 用 `{{ZIP_NAME}}` 占位符；README 的校验命令用
  `Pi-Web-Desktop-*.zip.sha256` 通配，都不受影响。历史 Release 与历史清单/记录里的旧名字
  （不含 `+build.N`）只是存档，不要回写。
- `CFBundleVersion` 必须是十进制整数（与上一节的 tag/build 规则一致）；否则打包直接失败，
  不允许出现一个无法对回到 tag 的资产名。

## 包内容白名单

打包前 `Scripts/package-release.sh` 会列出 bundle 里的每一条目（`find` + `LC_ALL=C` 排序），
只允许下列位置，其它一律失败并逐条列出（列出时字节会按 `\xNN` 转义）：

| 允许的位置 | 说明 |
| --- | --- |
| `Contents/MacOS/**` | 可执行文件 |
| `Contents/Info.plist` | 唯一的 `Info.plist` |
| `Contents/Resources/**` | 图标等资源（允许子目录） |
| `Contents/_CodeSignature/**` | 签名封条 |

- 目录本身（`Contents` 与上面四个目录）一并允许；`.DS_Store`、`._*` AppleDouble 条目与
  包含 `..` 的路径即使在允许目录下也被拒绝；包含换行的条目名会被当作无法可靠列出的清单直接失败。
- 检查在创建 `--out` 之前，所以被拒绝的 bundle 不会留下半个 `dist/`。
- 打包后还会用 `unzip -Z1` 把 ZIP 条目与同一份清单逐一比对（方向双向：ZIP 多的、清单多的都失败），
  因此 `ditto` 不可能静默添上或漏掉内容；`--norsrc --noextattr` 下不应该出现 `__MACOSX/` 条目。
- 列出的文件清单与每个文件的 SHA-256 会写进证据 Markdown 的折叠段落，存进 Release 资产便于事后核对。
- 要加新内容时：先改 `Scripts/package-release.sh` 里的白名单（并同步本表），再在
  `--self-test` 里加一条接受用例与一条拒绝用例；不要用“先放进去再说”的方式绕过。

## 发布元数据的字符集白名单

`Scripts/package-release.sh` 生成的 `release-metadata.env` 会被 `.github/workflows/release.yml`
用 `. dist/release-metadata.env` 直接 `source`（build job 里渲染说明与 step summary 各一处，
publish job 里复验与上传前一处）。所以脚本对写入该文件的每个值先做字符集白名单校验：
宁可拒绝一个不常见的名字，也不把一个可能像赋值或命令的值“转义后写进去”。

| 写入的变量 | 取值来源 | 允许的字符集 | 失败行为 |
| --- | --- | --- | --- |
| `VERSION`（`CFBundleShortVersionString`） | bundle 的 `Info.plist` | `0-9A-Za-z._+-` | 退出 1，不打包 |
| `BUILD`（`CFBundleVersion`） | bundle 的 `Info.plist` | 恰好十进制整数 `0-9`（tag/build 规则要求） | 退出 1，不打包 |
| `APP_STEM`，进而 `APP_NAME`、`ZIP_NAME`、`EVIDENCE_NAME` | `--app` 路径的 basename 去掉 `.app` | `0-9A-Za-z_-` | 退出 1，且不创建 `--out` 目录 |
| `SHA256` | `shasum -a 256` 的输出 | 恰好 64 位小写十六进制 `0-9a-f` | 退出 1 |
| `COMMIT` | `git rev-parse HEAD` | 小写十六进制，或缺省值 `unknown` | 退出 1 |

- `APP_STEM` 的白名单比 `VERSION` 更严：**不允许 `.`**。bundle 名不需要 `.`；产物名里的 `.`
  只来自脚本自己追加的固定后缀（`.zip`、`.zip.sha256`、`.evidence.md`），所以不必放开。
- 校验位置：`APP_STEM` 在读取 `Info.plist` 之前、创建 `--out` 之前校验，因此被拒绝的运行
  **不会生成任何 `dist/` 文件**；`SHA256` 与 `COMMIT` 在各自产生的地方立即校验。
- 失败信息给出允许的字符集与当前值的**转义表示**：允许集之外的字节显示为 `\xNN`，因此空格、`;`、
  `$()`、引号、控制字符与非 ASCII 字节都不会原样回显，这条日志行无法被伪造，也不会变成终端转义序列。
  实测（把已构建的 bundle 复制改名后打包，仓库里没有 `dist/`）：

  ```text
  $ ./Scripts/package-release.sh --app "/tmp/…/Pi Web Desktop.app"
  package-release: FAILED - the app bundle name (--app basename minus .app, i.e. APP_STEM) must be non-empty and use only ASCII letters, digits, hyphen and underscore (0-9A-Za-z_-); the value is written to release-metadata.env, which the release workflow sources. Escaped value (bytes outside the set as \xNN): "Pi\x20Web\x20Desktop"
  $ echo $?
  1
  $ ls dist
  ls: dist: No such file or directory
  ```

- 自测路径：`./Scripts/package-release.sh --self-test` 在仓库外的临时目录里复制脚本，构造非法
  （空格、`;`、`$()`、反引号、引号、`.`、换行、非 ASCII）与合法的 bundle 名，断言非法值被拒绝、
  输出里只有转义形式且不产生 `dist/`，合法值通过白名单并到达下一个检查。`build/` 里已有 bundle
  且工作区没有未跟踪文件时，它还会用临时 `--out` 跑一次完整打包（结束后删除），并像 workflow 一样
  真正 `source` 一次生成的 `release-metadata.env`；工作区存在未跟踪文件时这一项会跳过，因为打包路径上的
  `Scripts/check-identity.sh` 会拒绝未扫描的工作区（安全审查 R-11）。

### 已核对、但不需要白名单的值

| 值 | 为什么不加 |
| --- | --- |
| `TAG` | 只作为参数传给 `Scripts/check-release-version.sh`；不写入 `release-metadata.env`，也不拼进任何被 `sh -c`/`eval` 执行的字符串 |
| `APP`、`OUT` | 路径；始终带引号使用，只用于读取 bundle 与写文件，不进入被 `source` 的文件，其中会被写进元数据的部分已经由 `APP_STEM` 覆盖 |
| `APP_NAME`、`ZIP_NAME`、`EVIDENCE_NAME` | 由已校验的 `APP_STEM`/`VERSION` 加固定后缀组成，传递性覆盖，不重复校验 |
| `WORKTREE`、`SW_VERS`、`ARCH`、`VERIFY_STATUS`、`SPCTL_STATUS`、`SPCTL_NOTE` 与 `codesign`/`spctl` 原始输出 | 只写进证据 Markdown，不写进 `release-metadata.env`；原始输出放在围栏代码块里，工作区状态是脚本自己拼的固定字符串 |

白名单保证的是 `release-metadata.env` 的含义不会被这些值改变，不是“脚本可以在任意输入下安全运行”；
参数解析、`--out` 目标、签名与 Gatekeeper 校验仍是各自独立的门槛。

## Tag 驱动 workflow（`.github/workflows/release.yml`）

触发方式：

- push 受保护 tag `v*`：完整发布路径；
- `workflow_dispatch`：演练。同样的构建、校验、打包与 Release 说明渲染，但只上传
  Actions artifact `pi-web-desktop-alpha`，**不创建 Release**，即使 ref 本身是 tag。
  `tag` 输入为空且 ref 不是 tag 时，workflow 用
  `./Scripts/check-release-version.sh --print-tag` 从 xcconfig 推导 tag 再执行同一套比较。

`build` job（`macos-14`，`permissions: contents: read`）：

1. checkout（`actions/checkout` 固定到完整 commit SHA）；
2. 解析 tag 并运行 `./Scripts/check-release-version.sh <tag>`；
3. `sh -n` 检查发布相关脚本语法；
4. `xcodebuild build`（`-sdk macosx -arch arm64`、`CODE_SIGN_STYLE=Manual`、`CODE_SIGN_IDENTITY=-`）：
   这是工程构建与身份交叉检查，发布产物不来自这里；
5. `./Scripts/build.sh` 构建 arm64 发布产物；
6. `./Scripts/check-identity.sh` 同时核对 Xcode 产物与脚本产物；
7. `./Scripts/smoke.sh`（两种模式）；
8. `./Scripts/package-release.sh`：`codesign --verify --deep --strict`、
   `codesign -dv --verbose=4`、`spctl -a -vv`、ZIP、SHA-256、证据与元数据；
9. 用 `docs/release-notes-template.md` 渲染 Release 说明：替换 `{{VERSION}}`、`{{BUILD}}`、
   `{{ZIP_NAME}}`、`{{SHA256}}`，并在固定位置插入证据段落；渲染后若仍有 `{{...}}` 占位符
   或缺少 checksum 则直接失败；模板里的 `<待填写>` 只打 `::warning::`（计数必须为 0，但不阻断草稿创建）；
10. 把 `dist/` 上传为 artifact。

`publish` job（`ubuntu-latest`，只有这里授予 `contents: write`）：

- 下载 artifact，用 `sha256sum -c` 复核 checksum（与用户校验命令一致）；
- 仅在 tag push 时运行：如果同名草稿已存在，只删除草稿再重建，从不改动已发布版本；
- 创建**草稿** prerelease（`gh release create --prerelease --draft`），上传 ZIP、`.sha256`
  与证据 Markdown。资产在这之前不会公开可见。

第三方 Actions 全部固定到完整 commit SHA；workflow 顶层权限为 `contents: read`，
写权限只出现在 `publish` job。

## Release 说明与证据段落

Release 说明由 `docs/release-notes-template.md` 渲染；每个版本还会留一份现成的正文（例如
[v0.1.0-alpha.2 Release 说明](release-notes-v0.1.0-alpha.2.md)），可以在草稿编辑页粘贴并把
`校验值` 换成草稿资产的实际 SHA-256；workflow 渲染的始终是模板。
`Scripts/package-release.sh` 生成的“签名与公证证据”段落会写入固定位置，内容包括：

- `codesign --verify --deep --strict` 的退出码（必须为 0）；
- `codesign -dv --verbose=4` 原始输出，其中必须出现 `Signature=adhoc` 与 `TeamIdentifier=not set`；
- `spctl -a -vv` 原始输出与退出码（未公证 ad-hoc 应用被拒绝是预期结果）；
- ZIP 名称、SHA-256、构建提交、打包环境（明确标注它不等同于真机实测环境）。

如果 bundle 的签名不是 `adhoc`，`package-release.sh` 会拒绝打包，因为现有的说明与安装步骤
只描述未公证的 alpha。真机实测版本（机器、macOS、Node.js、Pi、Pi Web）来自 Release Issue，
由维护者在发布草稿前填入；workflow 不会用 CI runner 的版本冒充真机记录，未填写的字段会以
`<待填写>` 保留在说明里。

发布流程：workflow 结束 → 打开草稿 Release → 从 Release Issue 填入真机记录与已知问题 →
确认没有 `<待填写>`、checksum 与 Issue 记录一致 → 发布（保持 prerelease）。workflow 渲染阶段对
`<待填写>` 只打 `::warning::`（草稿必须仍能创建），因此发布前**必须**人工执行下面的命令，
**输出必须为 0**；非 0 就先补填，不要发布：

```sh
gh release view v<MARKETING_VERSION> --json body --jq .body | grep -c '<待填写>'
```

`grep -c` 在计数为 0 时退出码是 1，不要只看管道退出码；要在计数非 0 时立即失败，用：

```sh
test "$(gh release view v<MARKETING_VERSION> --json body --jq .body | grep -c '<待填写>' || true)" -eq 0
```

## 可复现性与诚实的边界

- 流程是脚本化的：本地演练与 CI 运行同一批脚本，tag、版本与 checksum 都能核对。
- 容器层面尽量可复现：`Scripts/package-release.sh` 在打包前把所有条目的 mtime 固定为同一个值
  （默认 `200101010000.00`，可用 `SOURCE_DATE_EPOCH` 覆盖），再用
  `ditto -c -k --norsrc --noextattr --keepParent` 打包：不再是 `--sequesterRsrc` 的
  `__MACOSX/` AppleDouble 形式，也没有高精度时间戳，同一个 bundle 重复打包会得到相同的字节。
- 但本项目**不承诺 bit-for-bit 可复现**，下面的字节仍然每次不同：
  - `Contents/MacOS/PiWebDesktop`：编译器/链接器版本、构建路径等进入 Mach-O；
  - `Contents/_CodeSignature/CodeResources` 与签名 blob：ad-hoc CDHash 随内容与每次签名调用变化；
  - `Info.plist` 与资源本身（图标）在同一版本下是固定的，但任何工具链差异会连带改变它们的摘要。
  因此同一提交在不同机器上构建出的 ZIP 不一定相同；可复现的是步骤与校验值，
  ZIP 的 SHA-256 记录的是“这一个具体产物”，证据文件里的包内容清单与 SHA-256 也是针对这一份。
- 不要为了对齐 checksum 而替换已发布的资产；版本内容有变化就发布新的 alpha。
- 发布记录（Release Issue、Release 说明、证据文件）必须与实际产物一致；宁可延迟发布，
  也不要补写没有实际运行过的验证结果。

## 版本门槛

- `alpha.1`：安全开源基线、依赖诊断和服务生命周期。
- `alpha.2`：桌面应用、Pi、Pi Web 和 Pi 扩展包的版本检查，逐类策略（关闭 / 每日 / 每周；扩展包为关闭 / 检查并通知 / 询问后更新）、忽略具体版本与应用内提示；alpha.3 的“启动前自动更新 Pi Web”设置位已存在但**默认关闭且尚未生效**（只保存值，不产生任何安装行为）。
- `alpha.3`：受限自动安装（GitHub #20：仅限“已验证的 npm 全局安装”的 Pi Web，启动前自动更新 + 安装后版本重检测与健康检查）、运行进程保护（GitHub #21：只读进程枚举三态判定 + 有 Pi 进程运行时自动更新延迟 + Pi CLI 的受限启动前自动更新与手动入口）、扩展包确认流（GitHub #22：三策略、必须用户确认、永不无人值守）、更新验证与有限回滚（GitHub #23：阶段化事务、五层验证能力边界、降级判定与统一历史）。当前分支已落地 #20 / #21 / #22 与 #23：失败时保留旧版本语义、进入诊断页并写持久警告，**不声称回滚成功**；#21 与 #22 不做任何进程处理（不发送信号、不结束 Pi 会话），命令只以参数数组启动；#23 只允许一种自动降级——把服务/重检测指向应用自己保留、且在安装后仍可用的更新前 npm 全局可执行文件，其它来源与证据缺失/被覆盖的情况一律写“无法自动回滚”。下载缓存、更细的回滚策略与非 npm/pnpm 来源的自动更新仍属后续 issue。
- `beta.1`：根据 alpha 反馈修复，不引入大型新功能。
- `1.0.0`：需要 Developer ID 签名和 Apple 公证；没有开发者账号时不发布稳定二进制。

## 回退

- 草稿阶段：在 Actions 里重跑 workflow，或在草稿上补正说明；确需删除时
  `gh release delete <tag> --yes` 只删除草稿，tag 不受影响。
- 已发布版本：不要静默替换 ZIP 或 checksum。在 Release 说明与 Release Issue 中标注问题，
  必要时发布新的 alpha（例如 `v0.1.0-alpha.2`）并说明回退路径。
- 用户侧回退：保留上一版 ZIP 与 checksum，重新解压替换 `Pi-Web-Desktop.app` 即可；
  应用没有系统级常驻组件，删除应用包即卸载。服务配置保留在用户目录，不会被回退自动清理。
- 更新前记录当前版本。只有安装来源和工具提供可靠恢复路径时才执行回滚；不能承诺所有 npm、
  Git package、本地路径或非标准安装都能自动恢复。更新失败时优先保留可运行的旧版本，
  并把完整但已脱敏的日志留给用户查看。GitHub #20 与 #21 的实现遵循这一条：失败只保留旧版本
  语义（不卸载、不重装、不自动回滚），并写一条持久警告与诊断页提示；Pi CLI 的更新还会
  重新检测版本，版本未变或无法解析同样按失败记录。
- 更新回滚能力有限（GitHub #23）：应用只记录更新前的可执行文件路径、版本与可选的文件大小/ mtime，
  不保留文件副本，因此“回滚”最多只是把服务或版本重检测指回更新前仍在原位、仍带可执行位且指纹一致的
  npm 全局可执行文件。版本未变化时如实报告“仍在使用更新前的版本”；旧路径被覆盖、删除或指纹不一致，
  或来源是 pnpm / Homebrew / nvm / mise / git checkout / 本地路径 / 未知时，一律写“无法自动回滚”，
  只展示静态清单里的手动命令或指引（应用不执行）。验证失败后的持久警告会区分“更新失败，没有执行任何回滚动作”
  与“更新后验证失败，已降级 / 无法自动回滚”，诊断页展示最近一次更新的完成阶段与建议动作。
  commit 成功后不做自动卸载；框架不移动、不复制、不删除任何文件，也不向任何进程发送信号。
- 如果 tag 推送后需要撤回：先删除草稿 Release，再删除 tag
  （`git push origin :refs/tags/<tag>`），并在 Release Issue 记录原因；不要重复使用已公开的版本号。

## 应用自身更新

应用自身（`Pi Web Desktop.app`）的应用内更新自 PR #174 起实现，并且只由用户点击触发：入口仅在本轮刚从 GitHub API 核实出更高版本时出现，确认框说明当前包未签名、未公证；下载固定名字的资产并校验发布的 `.sha256`，只替换 `/Applications/Pi-Web-Desktop.app`，替换后退出并重启。缓存结论不触发安装，没有无人值守路径，也没有降级路径。检查行为由设置控制：四类组件默认“每日 / 扩展包检查并通知”，可逐类关闭或改为每周，可忽略某个具体版本（上游出现更高版本会重新提示）；提示使用应用内提示框，不使用系统通知中心。设置里的“启动前自动更新 Pi Web”开关自 alpha.3 实现（GitHub #20）起生效，但只对“来源为已验证的 npm 全局安装”的 Pi Web 执行受限安装；同一版本新增的“启动前自动更新 Pi CLI”（GitHub #21）也只对“来源为已验证的 npm/pnpm 全局安装”的 Pi CLI 生效，并且在检测到运行中的 Pi 进程或进程状态不确定时自动推迟（应用不会向 Pi 进程发送任何信号）；其它来源仍只显示命令，桌面应用自身仍不自动更新。

## CI 与依赖固定策略

- GitHub Actions 全部按提交 SHA 固定，不使用浮动 tag；例如 `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`。
- `.github/dependabot.yml` 每周检查固定版本的更新，通过带 `dependencies`、`github_actions` 标签的 PR 提出升级；升级必须走 CI 和评审，不允许为了发布临时改用浮动版本。
- 发布工作流不得使用 secrets，也不得引入第三方签名、公证或上传服务；当前 `build` 工作流的权限只有 `contents: read`。
- 通用 secret scan（`./Scripts/scan-secrets.sh`，#11）已实现并由 CI 门禁；发布门槛里要把它的退出码、结尾的 `scan-secrets: suppressed N lines` 以及是否出现 `scan-secrets: rejected` 行一起记入证据，并按 [开发说明](development.md#personal-data-与-secret-扫描能力)核对该 N。它只覆盖固定凭据形状、只扫已跟踪文件、不扫 Git 历史，所以不能写成“没有秘密”；三层文本检查的能力边界与未覆盖类型见 [贡献指南](../CONTRIBUTING.md#personal-data-与-secret-扫描能力)与 [alpha.1 安全与发布审查](security-review-alpha.1.md)。
- 发布流程不依赖新的运行时依赖。应用自身没有第三方 Swift 包或 npm 依赖；新增依赖必须先按 [贡献指南](../CONTRIBUTING.md)记录许可证、维护状态和供应链理由。
