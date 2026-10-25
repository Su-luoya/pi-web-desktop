# Pi Web Desktop 0.1.0-alpha.21（build 21）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.21` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版只有一处修复：日志文件的替换改为原子操作。没有新增功能，没有破坏性变更。

## 缺陷修复：日志替换不是原子的

`Sources/Diagnostics/LogWriter.swift` 有三处「先删除、再改名」的替换：

| 位置 | 替换内容 |
| --- | --- |
| `scrubOnQueue` | 脱敏后的临时文件 → 主日志 |
| `rotateIfNeededOnQueue` | 当前日志 → `.1` |
| `rotateIfNeededOnQueue` | 链式移位 `.n-1` → `.n` |

两步之间任何一步失败（磁盘满、权限变化、进程被终止），就会出现「源文件已删、目标文件还没到位」的状态：整份日志或整份轮转文件就此消失。

日志是这个应用唯一的事后排查手段 —— 用户按提示去"查看日志"时，如果文件已经不在了，那条提示就成了空话。

修复方式：三处全部改为同目录 `rename(2)`。覆盖目标是一次原子操作，不存在中间态。临时文件与主日志本来就在同一目录，不会跨卷。失败时把 `errno` 写进已有的失败记录。

## 关于这次修复的测试局限

新增两条测试：

- `testScrubReplaceLeavesTheLogReadableAndNeverMissing`：替换后文件存在、非空、明文已脱敏、无临时文件残留；
- `testRepeatedScrubbingNeverLosesContent`：连续 5 轮脱敏幂等，正文不丢。

**但这两条测试不能区分新旧实现。** 我把实现回退到旧写法重新跑过，两条测试仍然全绿。

原因：非原子窗口只在两步之间失败的那一瞬间暴露，测试无法可靠制造那个瞬间（需要真的磁盘满或进程被 kill）。原子性由 `rename(2)` 的语义保证，不由测试保证。这一点写进了测试注释，避免后人误以为这里已有回归保护。

## 验证

本机 macOS 27.0，Apple Silicon。

- `./Scripts/build.sh`：成功，`CFBundleShortVersionString=0.1.0-alpha.21`，`CFBundleVersion=21`，`LSMinimumSystemVersion=26.0`，`Mach-O 64-bit executable arm64`；
- `xcodebuild test`：`Executed 925 tests, with 0 failures (0 unexpected)`；
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；
- `./Scripts/check-release-version.sh v0.1.0-alpha.21`：`PASSED`；
- `./Scripts/smoke.sh`：`OK`（两种模式均 exit 0）；
- `./Scripts/scan-secrets.sh`：`PASS`；
- 干净构建警告扫描：0 warning、0 error（排除 Xcode 工具链的 AppIntents 提示）。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证；
- 本版降低的是「日志丢失」的概率，不是消除：`rename` 在文件系统损坏等极端情况下仍可能失败，但那时失败是原子的，原文件还在。

上一版 `v0.1.0-alpha.20` 的资产仍然保留，回退会带回本版修掉的替换窗口。
