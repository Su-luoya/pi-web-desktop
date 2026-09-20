import Foundation

// MARK: - 更新事务（GitHub #23）
//
// 本文件是 #20（Pi Web）/ #21（Pi CLI）/ #22（Pi 扩展包）三条更新路径共用的
// 事务模型：阶段化结果、更新前指纹、有限回滚/降级判定、统一更新历史与用户可见
// 文案。它只做判定与记录，**不执行任何副作用**：
//
//   * 不安装、不卸载、不删除、不改写任何文件；
//   * 不调用 shell、不调用 `sudo`；
//   * 不向任何进程发送信号（不 kill / SIGTERM / SIGKILL）；
//   * 回滚只允许“把调用方指向更新前仍然可用的可执行文件路径/版本”，
//     绝不复制、移动或恢复文件内容。
//
// 真实边界（必须与文档一致）：只有当应用自己保留了更新前的可执行文件路径与
// 版本证据、并且该证据在新版本安装后仍然存在且可用时，才允许自动降级；对
// pnpm / Homebrew / nvm / mise / git checkout / 本地路径 / 未知来源一律不回滚，
// 只报告并给出手动命令文本（只展示，不执行）。

// MARK: - 组件

/// 更新事务的组件标识。`packageName` 只承载已通过 npm 包名校验的扩展包名。

/// Transaction components, phases and the transaction environment.

struct UpdateTransactionComponent: Equatable {
    var kind: ComponentKind
    var packageName: String?

    var displayName: String {
        switch kind {
        case .piWeb: return "Pi Web"
        case .piCLI: return "Pi CLI"
        case .piPackage: return packageName.map { "Pi 扩展包 \($0)" } ?? "Pi 扩展包"
        case .desktopApp: return "Pi Web Desktop"
        }
    }

    static let piWeb = UpdateTransactionComponent(kind: .piWeb, packageName: nil)
    static let piCLI = UpdateTransactionComponent(kind: .piCLI, packageName: nil)
    static func piPackage(_ packageName: String?) -> UpdateTransactionComponent {
        UpdateTransactionComponent(kind: .piPackage, packageName: packageName)
    }

    /// 静态清单里的期望包名：Pi Web / Pi CLI 固定；扩展包只有自身包名。
    var expectedPackageName: String? {
        switch kind {
        case .piWeb: return InstallCommandManifest.piWebPackageName
        case .piCLI: return InstallCommandManifest.piCLIPackageName
        case .piPackage: return packageName
        case .desktopApp: return nil
        }
    }
}

// MARK: - 事务阶段

/// 事务阶段：准备 → 执行 → 验证 → 启用/提交 → 失败降级。
enum UpdateTransactionPhase: String, CaseIterable, Equatable {
    case preflight
    case install
    case verify
    case commit
    case degrade

    var title: String {
        switch self {
        case .preflight: return "准备"
        case .install: return "执行安装"
        case .verify: return "验证"
        case .commit: return "启用/提交"
        case .degrade: return "失败降级"
        }
    }
}

enum UpdateTransactionPhaseStatus: String, Equatable {
    case succeeded
    case failed
    case skipped
    case notAttempted
    /// 降级阶段专用（GitHub #106）：确实执行了一次恢复动作，把调用方指回更新前
    /// 记录的路径。只有这一种降级才算“做成了一件事”。
    case applied
    /// 降级阶段专用（GitHub #106）：只记录了结论，没有执行任何回滚动作
    /// （安装失败，或核对后确认文件仍是更新前那份）。
    case recordedOnly
    /// 降级阶段专用（GitHub #106）：无法执行自动回滚，只报告 + 手动提示。
    case notPossible

    var displayName: String {
        switch self {
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .skipped: return "跳过"
        case .notAttempted: return "未执行"
        case .applied: return "已执行"
        case .recordedOnly: return "仅记录"
        case .notPossible: return "无法执行"
        }
    }
}

/// 单阶段结果：阶段、状态、可读原因与时间。`reason` 必须由固定文案 + 已校验的
/// 版本号/包名组成，不含路径、子进程输出或凭据。
struct UpdateTransactionPhaseResult: Equatable {
    var phase: UpdateTransactionPhase
    var status: UpdateTransactionPhaseStatus
    var reason: String
    var recordedAt: Date

    var displayLine: String {
        "\(phase.title)：\(status.displayName)（\(reason)）"
    }
}

// MARK: - 协调器注入的事务环境

/// #20/#21/#22 三个协调器共用的更新事务注入。
///
/// 默认值是“无探针、不记历史、不应用降级”：已有测试与未接入场景的行为保持
/// 不变。生产路径显式注入 `.live` 探针、历史写入与降级应用。
struct UpdateTransactionEnvironment {
    /// 文件系统探针。
    var probe: UpdateArtifactProbe
    /// 历史写入（生产：UserDefaults；测试：内存数组）。
    var recordHistory: (UpdateHistoryEntry) -> Void
    /// 应用降级结果：把服务/重检测指向更新前仍然可用的可执行文件。
    /// 只允许改调用方自己的配置，不做文件操作、不发信号、不执行命令。
    var applyDegradation: (UpdateDegradationPlan) -> Void
    /// 时钟（测试注入固定时间）。
    var now: () -> Date

    static let disabled = UpdateTransactionEnvironment(
        probe: .disabled,
        recordHistory: { _ in },
        applyDegradation: { _ in },
        now: Date.init
    )
}
