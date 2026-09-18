import XCTest

/// Unhosted tests for the quit decision table (GitHub #9):
/// `Sources/QuitPolicy.swift` and `Sources/ServiceConfiguration.swift` are
/// compiled directly into this target, so the three quit behaviours are asserted
/// without AppKit, a window or a real service.
final class QuitPolicyTests: XCTestCase {
    private let allBehaviors: [ServiceConfiguration.QuitBehavior] = [.ask, .keepRunning, .stopService]

    func testAskIsTheDefaultBehaviourAndOnlyAsksFirst() {
        XCTAssertEqual(ServiceConfiguration.default.quitBehavior, .ask)

        let plan = QuitPlan.plan(for: ServiceConfiguration.QuitBehavior.ask)

        XCTAssertTrue(plan.requiresUserConfirmation)
        XCTAssertFalse(plan.terminatesApplication)
        XCTAssertFalse(plan.stopsManagedService)
        XCTAssertEqual(plan.serviceDisposition, QuitPlan.ServiceDisposition.keepRunning)
    }

    func testKeepRunningTerminatesWithoutStoppingTheService() {
        let plan = QuitPlan.plan(for: ServiceConfiguration.QuitBehavior.keepRunning)

        XCTAssertFalse(plan.requiresUserConfirmation)
        XCTAssertTrue(plan.terminatesApplication)
        XCTAssertFalse(plan.stopsManagedService)
        XCTAssertEqual(plan.serviceDisposition, QuitPlan.ServiceDisposition.keepRunning)
    }

    func testStopServiceTerminatesAndStopsOnlyTheManagedService() {
        let plan = QuitPlan.plan(for: ServiceConfiguration.QuitBehavior.stopService)

        XCTAssertFalse(plan.requiresUserConfirmation)
        XCTAssertTrue(plan.terminatesApplication)
        XCTAssertTrue(plan.stopsManagedService)
        XCTAssertEqual(plan.serviceDisposition, QuitPlan.ServiceDisposition.stopManagedService)
    }

    func testConfirmationMappingsMatchTheThreeDialogButtons() {
        let keep = QuitPlan.plan(for: QuitConfirmation.keepServiceRunning)
        XCTAssertTrue(keep.terminatesApplication)
        XCTAssertFalse(keep.stopsManagedService)

        let stop = QuitPlan.plan(for: QuitConfirmation.stopService)
        XCTAssertTrue(stop.terminatesApplication)
        XCTAssertTrue(stop.stopsManagedService)

        let cancel = QuitPlan.plan(for: QuitConfirmation.cancel)
        XCTAssertFalse(cancel.terminatesApplication)
        XCTAssertFalse(cancel.requiresUserConfirmation)
        XCTAssertFalse(cancel.stopsManagedService)
        XCTAssertEqual(cancel.nextStep, QuitPlan.NextStep.stayOpen)
    }

    /// 外部服务在任何退出行为下都不被停止：`QuitPlan` 只描述托管服务的处置，
    /// 没有任何取值表示“停止外部服务”。
    func testNoQuitBehaviourEverStopsExternalServices() {
        let neverStopsExternal = QuitPlan.stopsExternalService
        XCTAssertFalse(neverStopsExternal)

        for behavior in allBehaviors {
            let plan = QuitPlan.plan(for: behavior)
            XCTAssertFalse(QuitPlan.stopsExternalService, "\(behavior) 不应停止外部服务")
        }
        for confirmation in [QuitConfirmation.keepServiceRunning, QuitConfirmation.cancel] {
            let plan = QuitPlan.plan(for: confirmation)
            XCTAssertFalse(plan.stopsManagedService)
            XCTAssertFalse(QuitPlan.stopsExternalService)
        }
        XCTAssertTrue(QuitPlan.plan(for: QuitConfirmation.stopService).stopsManagedService)
    }

    /// 只有“退出并停止服务”（显式行为或用户明确选择）才请求停止托管服务。
    func testOnlyTheExplicitStopChoiceStopsTheManagedService() {
        let stoppingPlans = [
            QuitPlan.plan(for: ServiceConfiguration.QuitBehavior.stopService),
            QuitPlan.plan(for: QuitConfirmation.stopService)
        ]
        let nonStoppingPlans = [
            QuitPlan.plan(for: ServiceConfiguration.QuitBehavior.ask),
            QuitPlan.plan(for: ServiceConfiguration.QuitBehavior.keepRunning),
            QuitPlan.plan(for: QuitConfirmation.keepServiceRunning),
            QuitPlan.plan(for: QuitConfirmation.cancel)
        ]

        for plan in stoppingPlans {
            XCTAssertTrue(plan.stopsManagedService)
        }
        for plan in nonStoppingPlans {
            XCTAssertFalse(plan.stopsManagedService)
        }
    }
}
