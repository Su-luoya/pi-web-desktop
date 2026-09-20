import Foundation

/// 用户在“退出时是否保持服务运行”对话框里的选择。

/// Pure mapping from quit settings and user choices to a quit plan.

enum QuitConfirmation: Equatable {
    case keepServiceRunning
    case stopService
    case cancel
}

/// 一次退出流程的计划（GitHub #9，纯值类型）。
///
/// 只描述“该怎么走”，不执行任何动作：`AppDelegate` 与 `ServiceManager` 按这个
/// 计划分别弹确认框、退出应用或停止服务。决策因此可以脱离 AppKit 和真实进程
/// 单元测试（三种退出行为、取消、以及“保持运行不停止服务”）。
///
/// 任何退出行为都不会停止外部服务：应用无法证明外部进程是自己启动的，停止只能
/// 针对通过 `ServiceOwnershipVerifier` 校验的托管进程组（见
/// `ServiceManager.stopManagedServiceOnQuit`）。
struct QuitPlan: Equatable {
    /// 退出流程的下一步。
    enum NextStep: Equatable {
        /// 需要先询问用户；询问期间不停止任何服务。
        case askUser
        /// 退出应用（是否停止服务由 `serviceDisposition` 决定）。
        case terminate
        /// 用户取消了退出：应用继续运行。
        case stayOpen
    }

    /// 退出时对服务的处置方式。
    enum ServiceDisposition: Equatable {
        /// 保持服务运行：不发送任何信号，也不删除所有权记录。
        case keepRunning
        /// 停止本应用验证过的托管服务；没有可验证记录时等同于保持运行。
        case stopManagedService
    }

    var nextStep: NextStep
    var serviceDisposition: ServiceDisposition

    /// 本次退出是否会请求停止托管服务。
    var stopsManagedService: Bool { serviceDisposition == .stopManagedService }
    /// 是否需要先弹确认框。
    var requiresUserConfirmation: Bool { nextStep == .askUser }
    /// 是否退出应用。
    var terminatesApplication: Bool { nextStep == .terminate }

    /// 外部服务在任何退出行为下都不会被停止。这是不变量，不是可配置项。
    static let stopsExternalService = false

    /// 三种退出行为 → 计划。默认行为 `ask` 先询问用户，询问期间不做任何停止。
    static func plan(for behavior: ServiceConfiguration.QuitBehavior) -> QuitPlan {
        switch behavior {
        case .ask:
            return QuitPlan(nextStep: .askUser, serviceDisposition: .keepRunning)
        case .keepRunning:
            return QuitPlan(nextStep: .terminate, serviceDisposition: .keepRunning)
        case .stopService:
            return QuitPlan(nextStep: .terminate, serviceDisposition: .stopManagedService)
        }
    }

    /// 用户在确认框里的选择 → 计划。取消时不退出、不停止任何服务。
    static func plan(for confirmation: QuitConfirmation) -> QuitPlan {
        switch confirmation {
        case .keepServiceRunning:
            return QuitPlan(nextStep: .terminate, serviceDisposition: .keepRunning)
        case .stopService:
            return QuitPlan(nextStep: .terminate, serviceDisposition: .stopManagedService)
        case .cancel:
            return QuitPlan(nextStep: .stayOpen, serviceDisposition: .keepRunning)
        }
    }
}
