/// “更新进度”窗口的生命周期（GitHub #219）。
///
/// 这里只做两件事：把 `UpdateProgressCenter` 的快照交给窗口，以及决定窗口什么时候
/// 出现/关闭。所有进度内容都由更新路径自己推进来（事务阶段、桌面应用自更新步骤、
/// 已脱敏日志行）；这个文件不联网、不执行命令、不改配置，也不改变任何更新判定。

import Cocoa

extension AppDelegate {
    // MARK: - 菜单入口

    /// “更新 → 显示更新进度”：重新打开最近一次（或当前进行中的）进度。
    @objc func showUpdateProgress(_ sender: Any?) {
        presentUpdateProgressWindow(activating: true)
    }

    // MARK: - 快照 → 窗口

    /// 进度中心每次变化都会在主线程走到这里。
    func handleUpdateProgressChange(_ session: UpdateProgressSession?) {
        guard let session else {
            updateProgressWindowController?.render(nil)
            return
        }
        // 冒烟启动不弹窗口：那条路径只验证主窗口与诊断页，不应该多出界面。
        guard !appConfiguration.isSmokeLaunch else { return }

        let controller = updateProgressWindowController ?? makeUpdateProgressWindowController()
        controller.render(session)

        if session.isFinished {
            if session.outcome?.isSuccess == true {
                // 成功：窗口自己关掉（用户在 #219 的分诊里选了“成功自动关”）。
                controller.closeAfterDelay(2)
            } else {
                // 失败：必须留在最前，用户需要看到停在哪一步、原因是什么。
                controller.present(activating: true)
            }
            return
        }
        // 进行中：只在这次会话第一次变化时自动出现，后续日志行不再抢焦点，
        // 也不把用户手动关掉的窗口重新弹出来。
        guard lastAutoPresentedUpdateProgressStart != session.startedAt else { return }
        lastAutoPresentedUpdateProgressStart = session.startedAt
        controller.present(activating: true)
    }

    private func presentUpdateProgressWindow(activating: Bool) {
        let controller = updateProgressWindowController ?? makeUpdateProgressWindowController()
        controller.render(updateProgressCenter.session)
        controller.present(activating: activating)
    }

    private func makeUpdateProgressWindowController() -> UpdateProgressWindowController {
        let controller = UpdateProgressWindowController()
        // 复用现有脱敏诊断导出：窗口不自己采集任何内容。
        controller.onCopyDiagnostics = { [weak self] in
            self?.copyDiagnostics(nil)
        }
        controller.onClose = { [weak self] in
            self?.updateProgressWindowController = nil
        }
        updateProgressWindowController = controller
        return controller
    }

    // MARK: - 桌面应用自更新（GitHub #175 的流程，进度由这里推给窗口）

    /// 桌面应用自更新的固定步骤。它们不是 `UpdateTransactionPhase`：这条路径不走
    /// 事务日志（下载/校验/替换由 `DesktopAppUpdateInstaller` 自己完成）。
    static let desktopAppUpdateProgressSteps = [
        "核对发布页",
        "下载更新包",
        "校验安装包",
        "替换应用"
    ]

    /// 用户确认后开始一次进度会话。
    func beginDesktopAppUpdateProgress(version: String) {
        let steps = Self.desktopAppUpdateProgressSteps.enumerated().map { index, title in
            UpdateProgressStep(
                title: title,
                detail: index == 0 ? "正在读取发布页…" : "",
                state: index == 0 ? .running : .pending
            )
        }
        updateProgressCenter.begin(
            title: "Pi Web Desktop 更新到 \(version)",
            steps: steps
        )
    }

    /// 推进桌面应用自更新的某一步。
    func setDesktopAppUpdateProgressStep(
        _ index: Int,
        _ state: UpdateProgressStepState,
        detail: String
    ) {
        updateProgressCenter.setStep(index, state: state, detail: detail)
    }

    /// 桌面应用自更新结束。成功时窗口会在 2 秒后自动关闭，失败时保留。
    func finishDesktopAppUpdateProgress(_ outcome: UpdateProgressOutcome) {
        updateProgressCenter.finish(outcome)
    }

    /// 把当前“进行中”的那一步标成失败：安装器失败时窗口要停在真正失败的位置，
    /// 而不是笼统地把还在跑的那一行记成“跳过”。
    func failRunningDesktopAppUpdateStep(detail: String) {
        guard let session = updateProgressCenter.session,
              let index = session.steps.firstIndex(where: { $0.state == .running }) else { return }
        updateProgressCenter.setStep(index, state: .failed, detail: detail)
    }
}
